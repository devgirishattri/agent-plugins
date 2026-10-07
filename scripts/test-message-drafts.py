#!/usr/bin/env python3
"""Synthetic native-payload and real tmux dispatch regressions, both providers.

MESSAGE_DRAFTS_TEST_CODEX_POLICY / _CLAUDE_POLICY select an original policy for
failure evidence. No agents, paid calls, real stores, or live panes are used.
MESSAGE_DRAFTS_TEST_CODEX_CHAT_SCRIPTS / _CLAUDE_CHAT_SCRIPTS overlay original
transport scripts in the synthetic installation for consumption failure evidence.
Native writes are emulated only after a policy allow; this is not an installed
provider sandbox test. The hook/bootstrap check uses the current real adapter;
the policy overrides affect the unit and transport checks only.
"""
import dataclasses
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
ENV = {k: v for k, v in os.environ.items() if not k.startswith(("SESSION_", "KNOWLEDGE_")) and k not in ("TMUX", "TMUX_PANE")}


class DraftCases:
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="drafts-", dir="/tmp")
        self.root = Path(self.tmp.name).resolve()
        self.cwd = self.root / "child"
        self.store = self.root / "messages"
        self.cwd.mkdir(); self.store.mkdir()
        script = Path(os.environ.get("MESSAGE_DRAFTS_TEST_" + self.provider.upper() + "_POLICY", self.tree / "session-workspace/scripts/harness-policy.py"))
        spec = importlib.util.spec_from_file_location("draft_policy_" + self.provider, script)
        self.policy = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = self.policy
        spec.loader.exec_module(self.policy)
        self.ctx = self.policy.Context(
            mode="enforce", semantic_role="reviewer", pane_name="sample-reviewer",
            pane_cwd=self.cwd, project_root=self.root, config_path=self.root / "config.json",
            orchestrator_pane="recipient", executor_panes=frozenset({"recipient"}),
            reviewer_panes=frozenset(), child_roots=(self.cwd,), grant_roots=(self.store,),
            message_roots=(self.store,), claude_home=self.root / "claude",
            codex_home=self.root / "codex", guards={})

    def tearDown(self):
        self.tmp.cleanup()

    def roles(self):
        for role in ("reviewer", "executor", "orchestrator"):
            yield dataclasses.replace(self.ctx, semantic_role=role, pane_name="sample-" + role,
                                      environment="dev" if role == "orchestrator" else "")

    def draft(self, ctx, name="reply-deadbeef.md"):
        return self.store / "drafts" / ctx.pane_name / name

    def native(self, path, operation="Write"):
        if operation in ("Write", "Edit"):
            return {"tool_name": operation, "tool_input": {"file_path": str(path), "content": "reply", "old_string": "old", "new_string": "new"}}
        text = "*** Begin Patch\n*** " + operation + " File: " + str(path) + "\n"
        text += {"Add": "+reply\n", "Update": "@@\n-old\n+new\n", "Delete": ""}[operation]
        return {"tool_name": "apply_patch", "tool_input": {"input": text + "*** End Patch"}}

    def decision(self, ctx, payload):
        with patch.object(self.policy, "load_context", return_value=(ctx, None)):
            return self.policy.evaluate(json.dumps(payload))

    def check(self, expected, ctx, payload, rule=None):
        result = self.decision(ctx, payload)
        self.assertEqual(result.decision, expected, result)
        if rule:
            self.assertEqual(result.rule, rule, result)

    def test_native_operations_and_cleanup(self):
        for ctx in self.roles():
            for operation in ("Write", "Edit", "Add", "Update", "Delete"):
                with self.subTest(role=ctx.semantic_role, operation=operation):
                    self.check("allow", ctx, self.native(self.draft(ctx), operation))
            path = self.draft(ctx)
            path.parent.mkdir(parents=True); path.write_text("old")
            with self.subTest(role=ctx.semantic_role, existing=True):
                self.check("allow", ctx, self.native(path, "Update"))
                self.check("allow", ctx, self.native(path, "Delete"))

    def test_pending_dispatch_tamper_and_drop(self):
        task = self.store / "1790000000-123-deadbeef-master-to-worker.md"
        task.write_text("original task"); task.chmod(0o600)
        for ctx in self.roles():
            for operation in ("Edit", "Delete"):
                with self.subTest(role=ctx.semantic_role, operation=operation):
                    self.check("deny", ctx, self.native(task, operation), "coordination.draft")
            with self.subTest(role=ctx.semantic_role, control=True):
                self.check("allow", ctx, self.native(self.draft(ctx)))
        self.assertEqual(task.read_text(), "original task")

    def test_namespace_boundaries(self):
        for ctx in self.roles():
            self.check("allow", ctx, self.native(self.draft(ctx, "report_1.txt")))
            forbidden = [self.store / "reply.md", self.store / "queue/reply.md",
                         self.store / "archive/reply.md", self.store / "sent-log.tsv",
                         self.store / "drafts", self.store / "drafts/peer/reply.md",
                         self.draft(ctx, ".hidden.md"), self.draft(ctx, "bad name.md"),
                         self.draft(ctx, "bad@name.md"), self.draft(ctx, "script.sh"),
                         self.draft(ctx, "nested/reply.md"), self.draft(ctx, "a" * 129 + ".md")]
            for path in forbidden:
                self.check("deny", ctx, self.native(path), "coordination.draft")

    def test_no_grant_and_root_compatibility(self):
        for ctx in self.roles():
            self.check("allow", ctx, self.native(self.draft(ctx)))
            ungranted = dataclasses.replace(ctx, message_roots=(), grant_roots=())
            self.check("deny", ungranted, self.native(self.draft(ctx)))
        root = dataclasses.replace(self.ctx, semantic_role="orchestrator", pane_cwd=self.root)
        self.check("allow", root, self.native(self.store / "root-note.md"))

    def test_mixed_patches_and_moves(self):
        for ctx in self.roles():
            path = self.draft(ctx)
            good = self.native(path, "Add")
            self.check("allow", ctx, good)
            mixed = self.native(path, "Add")
            mixed["tool_input"]["input"] = mixed["tool_input"]["input"].replace("*** End Patch", "*** Add File: " + str(self.cwd / "source.md") + "\n+text\n*** End Patch")
            self.check("deny", ctx, mixed, "coordination.draft")
            move = self.native(path, "Update")
            move["tool_input"]["input"] = move["tool_input"]["input"].replace("@@", "*** Move to: " + str(self.draft(ctx, "other.md")) + "\n@@")
            self.check("deny", ctx, move, "coordination.draft")

    def test_links_and_nonregular_files(self):
        for ctx in self.roles():
            path = self.draft(ctx)
            path.parent.mkdir(parents=True)
            self.check("allow", ctx, self.native(path))
            source = self.cwd / (ctx.pane_name + ".md")
            source.write_text("source")
            path.symlink_to(source)
            self.check("deny", ctx, self.native(path), "coordination.draft")
            path.unlink(); os.link(source, path)
            self.check("deny", ctx, self.native(path), "coordination.draft")
            path.unlink(); os.mkfifo(path)
            self.check("deny", ctx, self.native(path), "coordination.draft")
            path.unlink(); path.mkdir()
            self.check("deny", ctx, self.native(path), "coordination.draft")

    def test_symlinked_staging_directories(self):
        for ctx in self.roles():
            path = self.draft(ctx)
            self.check("allow", ctx, self.native(path))
            drafts = self.store / "drafts"
            drafts.symlink_to(self.cwd, target_is_directory=True)
            self.check("deny", ctx, self.native(path), "coordination.draft")
            drafts.unlink(); drafts.mkdir()
            path.parent.symlink_to(self.cwd, target_is_directory=True)
            self.check("deny", ctx, self.native(path), "coordination.draft")
            path.parent.unlink(); drafts.rmdir()

    def test_shell_staging_stays_denied(self):
        for ctx in self.roles():
            path = self.draft(ctx)
            self.check("allow", ctx, self.native(path))
            self.check("allow", ctx, self.native(path, "Delete"))
            for command in ("printf reply > " + shlex.quote(str(path)), "rm " + shlex.quote(str(path)), "rm -- " + shlex.quote(str(path))):
                self.check("deny", ctx, {"tool_name": "Bash", "tool_input": {"command": command}})

    def test_store_inside_checkout_is_still_protected(self):
        for ctx in self.roles():
            nested = self.cwd / "messages"
            own = dataclasses.replace(ctx, message_roots=(nested,))
            self.check("allow", own, self.native(nested / "drafts" / ctx.pane_name / "reply.md"))
            self.check("deny", own, self.native(nested / "pending.md"), "coordination.draft")
            self.check("deny", own, {"tool_name": "Bash", "tool_input": {"command": "printf text > " + str(nested / "pending.md")}})

    def test_launcher_grant_and_real_hook_bootstrap(self):
        scripts = self.tree / "session-workspace/scripts"
        cfg = json.loads((scripts / "fixtures/valid/harness-v2.json").read_text())
        if self.provider == "claude":
            cfg["runtimes"] = {"claude": {"program": "claude", "args": []}}
            for role in cfg["roles"].values():
                role["runtime"] = "claude"
        (self.root / "component-a").mkdir()
        config = self.root / "workspace.json"; config.write_text(json.dumps(cfg))
        pane = "harness-sample-component-executor"
        args = ["bash", str(scripts / "adapters.sh"), "agent-argv", "--pane", pane, "--config", str(config)]
        result = subprocess.run(args, env=ENV, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--add-dir", result.stdout)
        messages = self.root / ".tmp/messages"
        self.assertIn(str(messages), result.stdout)
        env = dict(ENV, SESSION_WORKSPACE_CONFIG=str(config), SESSION_WORKSPACE_PROJECT_ROOT=str(self.root),
                   SESSION_WORKSPACE_PANE_NAME=pane, SESSION_WORKSPACE_ROLE="executor",
                   SESSION_WORKSPACE_PANE_CWD=str(self.root / "component-a"), SESSION_WORKSPACE_HARNESS_MODE="enforce")
        payload = self.native(messages / "drafts" / pane / "report.md", "Add")
        # Exercise the real provider hook adapter, including config-derived grants.
        result = subprocess.run(["bash", str(scripts / "harness-hook.sh")], env=env,
                                input=json.dumps(payload), capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        payload = self.native(messages / "1790000000-123-deadbeef-master-to-worker.md", "Delete")
        result = subprocess.run(["bash", str(scripts / "harness-hook.sh")], env=env,
                                input=json.dumps(payload), capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("coordination.draft", result.stdout + result.stderr)

    def test_real_correlated_dispatch_and_durable_copy(self):
        # Selected synthetic installation runs the real transport on a private
        # tmux socket. It never names or touches an existing user session.
        home = self.ctx.codex_home if self.provider == "codex" else self.ctx.claude_home
        version = json.loads((self.tree / "session-chat" / (".codex-plugin" if self.provider == "codex" else ".claude-plugin") / "plugin.json").read_text())["version"]
        cache = home / "plugins/cache/girishattri-plugins/session-chat" / version
        shutil.copytree(self.tree / "session-chat", cache)
        original_chat = os.environ.get("MESSAGE_DRAFTS_TEST_" + self.provider.upper() + "_CHAT_SCRIPTS")
        if original_chat:
            shutil.copytree(original_chat, cache / "scripts", dirs_exist_ok=True)
        if self.provider == "codex":
            (home / "config.toml").write_text('[plugins."session-chat@girishattri-plugins"]\nenabled = true\n')
            manifest = home / ".tmp/marketplaces/girishattri-plugins/codex/plugins/session-chat/.codex-plugin/plugin.json"
            manifest.parent.mkdir(parents=True); manifest.write_text(json.dumps({"name": "session-chat", "version": version}))
        else:
            (home / "plugins/installed_plugins.json").write_text(json.dumps({"version": 2, "plugins": {"session-chat@girishattri-plugins": [{"scope": "user", "installPath": str(cache), "version": version}]}}))
        env = dict(ENV, CODEX_HOME=str(self.ctx.codex_home), CLAUDE_HOME=str(self.ctx.claude_home), CLAUDE_CONFIG_DIR=str(self.ctx.claude_home),
                   SESSION_CHAT_TARGET_MESSAGES_DIR=str(self.store), SESSION_CHAT_ALLOW_SHELL_TARGET="1", SESSION_CHAT_INCOMING_MODE="auto")
        socket = str(self.root / "socket")
        def tmux(*args):
            return subprocess.check_output(["tmux", "-S", socket, *args], env=env, text=True).strip()
        try:
            tmux("new-session", "-d", "-s", "draft-test", "-x", "240", "-y", "30", "cat")
            sender = tmux("display-message", "-p", "-t", "draft-test", "#{pane_id}")
            recipient = tmux("split-window", "-P", "-F", "#{pane_id}", "-t", "draft-test", "cat")
            tmux("set-option", "-p", "-t", recipient, "@name", "recipient")
            env["TMUX"] = tmux("display-message", "-p", "-t", sender, "#{socket_path},#{pid},0")
            env["TMUX_PANE"] = sender
            for ctx, keep_drafts in ((ctx, keep) for ctx in self.roles() for keep in ("0", "1")):
                env["SESSION_CHAT_KEEP_DRAFTS"] = keep_drafts
                tmux("set-option", "-p", "-t", sender, "@name", ctx.pane_name)
                path = self.draft(ctx)
                body = "Read-only report\ngit commit --dry-run -m 'quoted data'\n$(literal data)\nEOF\n" + "details\n" * 160
                self.check("allow", ctx, self.native(path, "Add"))
                path.parent.mkdir(parents=True, exist_ok=True); path.write_text(body)
                args = ["bash", str(cache / "scripts/dispatch-to-session.sh"), "--reply-to", "deadbeef", "recipient", str(path)]
                with patch.dict(os.environ, env, clear=True):
                    self.policy.validate_bash(ctx, shlex.join(args), {})
                before = set(self.store.glob("*.md"))
                result = subprocess.run(args, env=env, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("Dispatched task", result.stdout)
                files = set(self.store.glob("*.md")) - before
                self.assertEqual(len(files), 1)
                delivered = files.pop()
                self.assertEqual(delivered.read_text().rstrip("\n"), "[re:deadbeef] " + body.rstrip("\n"))
                self.assertEqual(stat.S_IMODE(delivered.stat().st_mode), 0o600)
                uid = delivered.name.split("-")[2]
                notice = f"[from:{ctx.pane_name} pane:{sender} msg:{delivered} id:{uid}] dispatch"
                receive_env = dict(env, TMUX_PANE=recipient, PLUGIN_ROOT=str(cache), CLAUDE_PLUGIN_ROOT=str(cache))
                received = subprocess.run(["bash", str(cache / "scripts/detect-incoming-message.sh")], input=notice, env=receive_env,
                                          capture_output=True, text=True, timeout=30)
                self.assertEqual(received.returncode, 0, received.stderr)
                self.assertIn("Read-only report", received.stdout)
                self.assertIn("deadbeef", (self.store / "replies-log.tsv").read_text())
                if keep_drafts == "1":
                    self.assertEqual(path.read_text(), body)
                    self.check("allow", ctx, self.native(path, "Delete")); path.unlink()
                else:
                    self.assertFalse(path.exists(), "default dispatch must consume its own draft")
                    self.assertIn("Removed delivered draft:", result.stdout)
                self.assertTrue(delivered.is_file(), "cleanup must leave durable dispatch intact")
        finally:
            subprocess.run(["tmux", "-S", socket, "kill-server"], env=env, capture_output=True)


class CodexDrafts(DraftCases, unittest.TestCase):
    provider = "codex"
    tree = ROOT / "codex/plugins"


class ClaudeDrafts(DraftCases, unittest.TestCase):
    provider = "claude"
    tree = ROOT / "plugins"


if __name__ == "__main__":
    unittest.main(verbosity=2)
