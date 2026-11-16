#!/usr/bin/env python3
"""Run every plugin hook in both trees and check what it prints.

Each hooks.json command runs as the runtime would start it: through bash, with
the runtime's plugin-root variable, a provider-shaped event payload on stdin
and an isolated HOME. Its stdout, stderr and exit code must be output the
runtime accepts for that event (hook_contracts.hook_output_effect), and the
effect must match the hook's declared intent (hook_contracts.check_hook_intent):
for example, a reminder meant for the user must not reach the model, and a Stop
hook must not continue the turn unless it is declared to.

Every hook runs once with a bare environment, where most hooks stay silent, and
then in scenarios that make it print. A scenario names the effect it must
produce, so a hook that stops printing fails instead of passing vacuously.

A hooks.json command with no CONTRACT row fails, so a new hook has to declare
what its output is for. A CONTRACT row with no hook fails too.

Usage: python3 -B scripts/test-hook-output-contracts.py [-v]
"""
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from hook_contracts import check_hook_intent, hook_output_effect  # noqa: E402

TREES = {"claude": ROOT / "plugins", "codex": ROOT / "codex" / "plugins"}
ROOT_VAR = {"claude": "CLAUDE_PLUGIN_ROOT", "codex": "PLUGIN_ROOT"}
VERBOSE = "-v" in sys.argv[1:]

# (plugin, event, script, args) -> intent. The script is the first
# scripts/<name> the command names; args are what follows it, without the
# provider adapter flag --codex-hook-output.
CONTRACT = {
    ("chronos", "UserPromptSubmit", "inject-current-time.sh", ""): "context",
    ("chronos", "PostToolBatch", "inject-current-time.sh", ""): "context",
    ("knowledge", "SessionStart", "detect-snapshots.sh", ""): "context",
    ("knowledge", "SessionStart", "inject-recall.sh", "--session-start"): "context",
    ("knowledge", "UserPromptSubmit", "inject-recall.sh", "--prompt"): "context",
    ("knowledge", "Stop", "nudge-consolidate.sh", "--stop-json"): "notice",
    ("session-chat", "SessionStart", "dispatch-tmux.conf", ""): "silent",
    ("session-chat", "SessionStart", "auto-name-pane.sh", ""): "silent",
    ("session-chat", "UserPromptSubmit", "detect-incoming-message.sh", ""): "context",
    ("session-chat", "Stop", "detect-incoming-message.sh", ""): "continue-turn",
    ("session-workspace", "SessionStart", "guard-lifecycle.sh", "--event session"): "context",
    ("session-workspace", "UserPromptSubmit", "guard-lifecycle.sh", "--event prompt"): "context",
    ("session-workspace", "PreToolUse", "harness-hook.sh", ""): "gate",
    ("session-workspace", "Stop", "guard-health.sh", ""): "notice",
}

SCRIPT_RE = re.compile(r"scripts/([A-Za-z0-9_.-]+)\"?((?:\s+--?[A-Za-z0-9_-]+(?:\s+[a-z]+)?)*)")


def hook_identity(command):
    match = SCRIPT_RE.search(command)
    if not match:
        raise ValueError(f"cannot find a scripts/<name> in hook command: {command}")
    args = [a for a in match.group(2).split() if a != "--codex-hook-output"]
    return match.group(1), " ".join(args)


def discover():
    hooks = []
    for provider, tree in TREES.items():
        for path in sorted(tree.glob("*/hooks/hooks.json")):
            plugin = path.parent.parent.name
            doc = json.loads(path.read_text(encoding="utf-8"))
            for event, entries in doc.get("hooks", {}).items():
                for entry in entries:
                    for handler in entry.get("hooks", []):
                        if handler.get("type") != "command":
                            continue
                        script, args = hook_identity(handler["command"])
                        hooks.append({
                            "provider": provider, "plugin": plugin, "event": event,
                            "matcher": entry.get("matcher", ""), "command": handler["command"],
                            "timeout": handler.get("timeout", 60), "key": (plugin, event, script, args),
                            "plugin_dir": path.parent.parent,
                        })
    return hooks


def payload(provider, event, cwd, **extra):
    doc = {"session_id": "contract-session", "transcript_path": f"{cwd}/transcript.jsonl", "cwd": str(cwd),
           "hook_event_name": event, "model": "contract-model", "permission_mode": "default"}
    if provider == "codex" and event != "SessionStart":
        doc["turn_id"] = "contract-turn"
    if event == "SessionStart":
        doc["source"] = "startup"
    elif event == "UserPromptSubmit":
        doc["prompt"] = "hello"
    elif event == "PreToolUse":
        doc.update(tool_name="Bash", tool_input={"command": "true"}, tool_use_id="toolu_contract")
    elif event == "PostToolBatch":
        doc["tool_calls"] = [{"tool_name": "Bash", "tool_input": {"command": "true"},
                              "tool_use_id": "toolu_contract", "tool_response": ""}]
    elif event == "Stop":
        doc.update(stop_hook_active=False, last_assistant_message="done")
    doc.update(extra)
    # Both runtimes send compact JSON; session-chat matches it literally.
    return json.dumps(doc, separators=(",", ":"))


class Box:
    """One isolated directory per hook run: home, temp and a git work tree."""

    def __init__(self, base, name):
        self.dir = pathlib.Path(tempfile.mkdtemp(prefix=f"{name[:24]}-", dir=base))
        self.home = self.dir / "home"
        self.tmp = self.dir / "tmp"
        self.repo = self.dir / "repo"
        self.bin = self.dir / "bin"
        for path in (self.home, self.tmp, self.repo, self.bin):
            path.mkdir()
        git(self.repo, "init", "-q")
        git(self.repo, "commit", "-q", "--allow-empty", "-m", "root")

    def env(self, provider, plugin_dir, extra):
        env = {
            "PATH": f"{self.bin}:{os.environ.get('PATH', '/usr/bin:/bin')}",
            "HOME": str(self.home), "TMPDIR": str(self.tmp),
            "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
            ROOT_VAR[provider]: str(plugin_dir),
        }
        env.update(extra)
        return env

    def fake_tmux(self, output=""):
        tool = self.bin / "tmux"
        body = f"printf '%s\\n' {output}\n" if output else ""
        tool.write_text(f"#!/usr/bin/env bash\n{body}exit 0\n", encoding="utf-8")
        tool.chmod(0o755)


GIT_ENV = {"GIT_AUTHOR_NAME": "Contract", "GIT_AUTHOR_EMAIL": "contract@example.invalid",
           "GIT_COMMITTER_NAME": "Contract", "GIT_COMMITTER_EMAIL": "contract@example.invalid"}


def git(cwd, *args):
    env = {**os.environ, **GIT_ENV, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}
    subprocess.run(["git", *args], cwd=cwd, env=env, check=True, capture_output=True)


# --- scenarios ---------------------------------------------------------------
# Each takes (box, provider, plugin_dir) and returns (env, payload extras).

def chronos_first_call(box, provider, plugin_dir):
    return {}, {}


def knowledge_snapshot(box, provider, plugin_dir):
    contexts = box.dir / "contexts"
    contexts.mkdir(mode=0o700)
    (contexts / "demo.md").write_text("---\nname: demo\n---\nbody\n", encoding="utf-8")
    return {"SESSION_CONTEXT_HOME": str(contexts)}, {}


def knowledge_store(box, provider, plugin_dir):
    (box.repo / ".gitignore").write_text(".agents/memory/\n", encoding="utf-8")
    git(box.repo, "add", ".gitignore")
    git(box.repo, "commit", "-q", "-m", "ignore store")
    store = box.repo / ".agents" / "memory"
    subprocess.run(["bash", str(plugin_dir / "scripts" / "memory-write.sh"), "bootstrap", "--store", str(store)],
                   cwd=box.repo, env=box.env(provider, plugin_dir, {}), check=True, capture_output=True)
    (store / "zephyr_calibration.md").write_text(
        "---\nschema_version: 1\nname: Zephyr Calibration\ndescription: the zephyr calibration procedure for widget sensors\n"
        "metadata:\n  type: reference\nstatus: active\ncreated: 2026-01-01\nupdated: 2026-01-02\n---\n"
        "**Why:** synthetic fixture.\n\n**How to apply:** synthetic fixture.\n", encoding="utf-8")
    (store / "MEMORY.md").write_text(
        "- [Zephyr Calibration](zephyr_calibration.md) — the zephyr calibration procedure for widget sensors\n", encoding="utf-8")
    return store


def knowledge_index(box, provider, plugin_dir):
    store = knowledge_store(box, provider, plugin_dir)
    return {"KNOWLEDGE_AUTO_RECALL": "1", "KNOWLEDGE_MEMORY_HOME": str(store)}, {}


def knowledge_recall(box, provider, plugin_dir):
    store = knowledge_store(box, provider, plugin_dir)
    return ({"KNOWLEDGE_AUTO_RECALL": "1", "KNOWLEDGE_MEMORY_HOME": str(store)},
            {"prompt": "how do I run the zephyr calibration for the widget sensors"})


def knowledge_pending(box, provider, plugin_dir):
    store = knowledge_store(box, provider, plugin_dir)
    candidate = box.dir / "candidate.md"
    candidate.write_text(
        "---\nsource: contract-session\nsensitivity: normal\nproposed:\n  schema_version: \"1\"\n"
        "  name: Contract Note\n  description: a captured learning about widgets\n  metadata:\n    type: project\n---\n"
        "**Why:** synthetic capture.\n\n**How to apply:** n/a.\n", encoding="utf-8")
    subprocess.run(["bash", str(plugin_dir / "scripts" / "memory-remember.sh"), "--store", str(store), "--staged", str(candidate)],
                   cwd=box.repo, env=box.env(provider, plugin_dir, {}), check=True, capture_output=True)
    return {"KNOWLEDGE_CONSOLIDATE_NUDGE": "1", "KNOWLEDGE_MEMORY_HOME": str(store)}, {}


def chat_in_tmux(box, provider, plugin_dir):
    box.fake_tmux()
    return {"TMUX": "/tmp/contract-tmux,1,0", "TMUX_PANE": "%1", "SESSION_CHAT_PANE_NAME": "me"}, {}


def chat_live_message(box, provider, plugin_dir):
    env, _ = chat_in_tmux(box, provider, plugin_dir)
    return env, {"prompt": "[from:peer pane:%1 id:deadbeef] hello from a contract test"}


def chat_queued_message(box, provider, plugin_dir):
    env, _ = chat_in_tmux(box, provider, plugin_dir)
    messages = box.home / (".claude" if provider == "claude" else ".codex") / "messages"
    (messages / "queue").mkdir(parents=True)
    subprocess.run(["bash", "-c", 'source "$1/scripts/lib.sh"; export MESSAGES_DIR="$2"; '
                    'export SESSION_CHAT_QUEUE_RECOVERY_GRACE_MS=0; '
                    'enqueue_message me feedc0de send peer "queued hello from a contract test" "$2"; '
                    'mark_message_ready me feedc0de "$2"', "_", str(plugin_dir), str(messages)],
                   cwd=box.repo, env=box.env(provider, plugin_dir, env), check=True, capture_output=True)
    return env, {}


def workspace_env(box, provider, plugin_dir, mode="enforce"):
    """The schema-v3 harness fixture, launched as its orchestrator pane."""
    fixture = json.loads((plugin_dir / "scripts" / "fixtures" / "valid" / "harness-v3.json").read_text(encoding="utf-8"))
    fixture["harness"]["mode"] = mode
    project = box.repo
    (project / ".agent-workspace").mkdir()
    (project / "component-a").mkdir()
    config = project / ".agent-workspace" / "workspace.json"
    config.write_text(json.dumps(fixture), encoding="utf-8")
    (project / "README.md").write_text("root\n", encoding="utf-8")
    git(project, "add", "README.md")
    git(project, "commit", "-q", "-m", "readme")
    (project / "README.md").write_text("root\ndirty\n", encoding="utf-8")
    box.fake_tmux("harness-sample-master")
    guards = json.dumps(fixture["harness"]["guards"], sort_keys=True, separators=(",", ":"))
    return {
        "SESSION_WORKSPACE_CONFIG": str(config), "SESSION_WORKSPACE_PROJECT_ROOT": str(project),
        "SESSION_WORKSPACE_PANE_NAME": "harness-sample-master", "SESSION_WORKSPACE_ROLE": "master",
        "SESSION_WORKSPACE_PANE_CWD": str(project), "SESSION_WORKSPACE_HARNESS_MODE": mode,
        "SESSION_WORKSPACE_GUARDS_JSON": guards,
    }


def workspace_active(box, provider, plugin_dir):
    return workspace_env(box, provider, plugin_dir), {}


def workspace_protected_write(box, provider, plugin_dir, mode="enforce"):
    env = workspace_env(box, provider, plugin_dir, mode)
    tool = "Write" if provider == "claude" else "apply_patch"
    tool_input = ({"file_path": str(box.repo / ".env"), "content": "TOKEN=x\n"} if provider == "claude"
                  else {"command": f"*** Begin Patch\n*** Add File: {box.repo / '.env'}\n+TOKEN=x\n*** End Patch\n"})
    return env, {"tool_name": tool, "tool_input": tool_input}


def workspace_protected_write_audit(box, provider, plugin_dir):
    return workspace_protected_write(box, provider, plugin_dir, mode="audit")


# key -> [(name, setup, expected effect per provider; None = anything valid)]
SCENARIOS = {
    ("chronos", "UserPromptSubmit", "inject-current-time.sh", ""): [
        ("first call", chronos_first_call, {"claude": "model_context", "codex": "model_context"})],
    ("chronos", "PostToolBatch", "inject-current-time.sh", ""): [
        ("first call", chronos_first_call, {"claude": "model_context"})],
    ("knowledge", "SessionStart", "detect-snapshots.sh", ""): [
        ("snapshot saved", knowledge_snapshot, {"claude": "model_context", "codex": "model_context"})],
    ("knowledge", "SessionStart", "inject-recall.sh", "--session-start"): [
        ("auto recall on", knowledge_index, {"claude": "model_context", "codex": "model_context"})],
    ("knowledge", "UserPromptSubmit", "inject-recall.sh", "--prompt"): [
        ("prompt matches a memory", knowledge_recall, {"claude": "model_context", "codex": "model_context"})],
    ("knowledge", "Stop", "nudge-consolidate.sh", "--stop-json"): [
        ("candidate pending", knowledge_pending, {"claude": "user_message", "codex": "user_message"})],
    ("session-chat", "SessionStart", "dispatch-tmux.conf", ""): [
        ("inside tmux", chat_in_tmux, {"claude": None, "codex": None})],
    ("session-chat", "SessionStart", "auto-name-pane.sh", ""): [
        ("inside tmux", chat_in_tmux, {"claude": None, "codex": None})],
    ("session-chat", "UserPromptSubmit", "detect-incoming-message.sh", ""): [
        ("live message in the prompt", chat_live_message, {"claude": "model_context", "codex": "model_context"}),
        ("queued message", chat_queued_message, {"claude": "model_context", "codex": "model_context"})],
    ("session-chat", "Stop", "detect-incoming-message.sh", ""): [
        ("queued message", chat_queued_message, {"claude": "continues_turn", "codex": "continues_turn"})],
    ("session-workspace", "SessionStart", "guard-lifecycle.sh", "--event session"): [
        ("harness active", workspace_active, {"claude": "model_context", "codex": "model_context"})],
    ("session-workspace", "UserPromptSubmit", "guard-lifecycle.sh", "--event prompt"): [
        ("harness active", workspace_active, {"claude": "model_context", "codex": "model_context"})],
    ("session-workspace", "PreToolUse", "harness-hook.sh", ""): [
        ("enforce denies a protected file", workspace_protected_write, {"claude": "blocks", "codex": "blocks"}),
        # Claude's audit line goes to stderr on exit 0, which only the debug
        # log shows; Codex gets an inert systemMessage instead.
        ("audit notes a protected file", workspace_protected_write_audit, {"claude": "silent", "codex": "user_message"})],
    ("session-workspace", "Stop", "guard-health.sh", ""): [
        ("dirty root, missing panes", workspace_active, {"claude": "user_message", "codex": "user_message"})],
}


def run(hook, box, env_extra, payload_extra):
    env = box.env(hook["provider"], hook["plugin_dir"], env_extra)
    data = payload(hook["provider"], hook["event"], box.repo, **payload_extra)
    proc = subprocess.run(["bash", "-c", hook["command"]], input=data, cwd=box.repo, env=env,
                          capture_output=True, text=True, timeout=max(30, int(hook["timeout"])))
    return proc.stdout, proc.stderr, proc.returncode


def check(hook, label, stdout, stderr, code, expect):
    intent = CONTRACT[hook["key"]]
    effect = hook_output_effect(hook["provider"], hook["event"], stdout, stderr, code)
    check_hook_intent(intent, hook["event"], effect)
    if expect == "silent":
        if stdout.strip() or any(effect[k] for k in ("model_context", "user_message", "continues_turn", "blocks", "stops")):
            raise ValueError(f"expected no output the runtime acts on, got {stdout.strip()[:200]!r}")
    elif expect and not effect[expect]:
        raise ValueError(f"expected {expect}; stdout={stdout.strip()[:300]!r} stderr={stderr.strip()[:300]!r} exit={code}")


def main():
    hooks = discover()
    failures = []
    seen = {hook["key"] for hook in hooks}
    for key in sorted(set(CONTRACT) - seen):
        failures.append(f"CONTRACT row {key} matches no hooks.json command")
    for key in sorted(set(SCENARIOS) - set(CONTRACT)):
        failures.append(f"SCENARIOS row {key} has no CONTRACT row")
    base = pathlib.Path(tempfile.mkdtemp(prefix="hook-contract-"))
    runs = 0
    try:
        for hook in hooks:
            name = f"{hook['provider']} {hook['plugin']} {hook['event']} {hook['key'][2]} {hook['key'][3]}".rstrip()
            if hook["key"] not in CONTRACT:
                failures.append(f"{name}: no CONTRACT row; declare its intent ({', '.join(sorted({'context', 'notice', 'continue-turn', 'gate', 'silent'}))})")
                continue
            cases = [("bare environment", lambda b, p, d: ({}, {}), None)]
            cases += [(n, f, e[hook["provider"]]) for n, f, e in SCENARIOS.get(hook["key"], []) if hook["provider"] in e]
            for label, setup, expect in cases:
                box = Box(base, hook["plugin"])
                try:
                    env_extra, payload_extra = setup(box, hook["provider"], hook["plugin_dir"])
                    stdout, stderr, code = run(hook, box, env_extra, payload_extra)
                    check(hook, label, stdout, stderr, code, expect)
                    runs += 1
                    if VERBOSE:
                        print(f"  PASS  {name}: {label}")
                except (ValueError, subprocess.SubprocessError, OSError) as exc:
                    detail = exc.stderr if isinstance(exc, subprocess.CalledProcessError) and exc.stderr else ""
                    failures.append(f"{name}: {label}: {exc} {detail}".rstrip())
                finally:
                    shutil.rmtree(box.dir, ignore_errors=True)
    finally:
        shutil.rmtree(base, ignore_errors=True)
    for failure in failures:
        print(f"FAIL: {failure}")
    if failures:
        print(f"hook output contracts: {len(failures)} failure(s)")
        return 1
    print(f"OK: hook output contracts hold for {len(hooks)} hooks in both trees ({runs} runs)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
