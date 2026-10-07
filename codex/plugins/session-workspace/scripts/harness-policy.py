#!/usr/bin/env python3
"""Provider-neutral strict-v1 PreToolUse policy for session-workspace.

The policy is deliberately configuration-poor. workspace.json selects whether
the reviewed strict-v1 profile is active, its audit/enforce mode, semantic role
names, and gate freshness values. It cannot add scripts, regexes, commands, or
permission exceptions -- the safety floor below is immutable.

Inputs (all engine-owned, emitted per pane by adapters.sh / lifecycle.sh):
  SESSION_WORKSPACE_CONFIG        absolute workspace.json path (absent => no-op)
  SESSION_WORKSPACE_PROJECT_ROOT  canonical project root
  SESSION_WORKSPACE_PANE_NAME     this pane's configured name
  SESSION_WORKSPACE_ROLE          this pane's configured role name
  SESSION_WORKSPACE_PANE_CWD      this pane's resolved cwd
  SESSION_WORKSPACE_HARNESS_MODE  audit|enforce when active, empty when inactive
  SESSION_WORKSPACE_GUARDS_JSON   canonical schema-v3/v4 guard pack JSON, when configured
  SESSION_WORKSPACE_READ_PATHS_JSON canonical reviewer shell-read grants, when configured

Hook mode reads one JSON event (Claude- or Codex-shaped) from stdin:
  allow / inactive  -> silent, exit 0
  audit             -> one stderr line, exit 0 (never blocks), or one inert
                       Codex ``systemMessage`` JSON object on stdout when
                       ``--codex-hook-output`` is selected by hooks.json
  enforce deny      -> one concise stderr line, exit 2 (blocks the tool call)
``--decision-json`` (test/parity mode) always exits 0 and prints exactly one
JSON object with a fixed, sorted key set so the two provider trees can
byte-compare decisions:
  {"active","decision","mode","pane","profile","reason","role","rule","tool"}
``decision`` is one of allow | deny | audit. Integrity failures (invalid or
drifted config, unknown/mismatched identity) are ``deny`` in BOTH modes --
audit only softens policy denials.

Runs on the stock macOS python3 (3.9): stdlib only, no 3.10+ syntax.
"""

from __future__ import annotations

import json
import fnmatch
import os
import re
import shlex
import stat
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable, List, Optional, Tuple

HERE = Path(__file__).resolve().parent
MARKETPLACE = "girishattri-plugins"
PROFILE = "strict-v1"

CONTROL_TOKENS = {";", ";;", "&&", "||", "|", "|&", "&", "(", ")", ">", ">>", ">|", "<", "<<", "<<<", "<>", "<&", ">&"}
CONTROL_CHARS = set(";&|()<>")

# Tool classification is by NAME, never by payload shape: a Read/Grep/Glob
# payload also carries file_path/path and must stay an unknown-allowed tool.
EDIT_TOOL_NAMES = {
    "edit",
    "write",
    "multiedit",
    "notebookedit",
    "apply_patch",
    "write_file",
    "edit_file",
    "create_file",
    "delete_file",
    "move_file",
    "str_replace_editor",
    "str_replace_based_edit_tool",
}
SHELL_TOOL_NAMES = {
    "bash",
    "shell",
    "local_shell",
    "shell_command",
    "exec_command",
    "run_command",
    "execute_command",
    "container.exec",
    "run_terminal_cmd",
}
PATH_FIELDS = {
    "absolute_path",
    "file_path",
    "new_path",
    "notebook_path",
    "old_path",
    "path",
    "relative_path",
    "target_file",
}
# Reviewer read-only command allowlist. Deliberately excludes sed/awk/perl
# (write/exec-capable scripts), tee/env/xargs, and every mutating tool.
READ_COMMANDS = {
    "basename",
    "cat",
    "cksum",
    "cut",
    "date",
    "df",
    "diff",
    "dirname",
    "du",
    "echo",
    "false",
    "file",
    "find",
    "grep",
    "head",
    "jq",
    "ls",
    "nl",
    "printf",
    "pwd",
    "realpath",
    "rg",
    "shasum",
    "sort",
    "stat",
    "tail",
    "tr",
    "true",
    "uniq",
    "wc",
    "which",
}
READ_GIT = {
    "blame",
    "branch",
    "diff",
    "diff-files",
    "diff-index",
    "diff-tree",
    "for-each-ref",
    "grep",
    "log",
    "ls-files",
    "ls-tree",
    "merge-base",
    "name-rev",
    "range-diff",
    "reflog",
    "remote",
    "rev-list",
    "rev-parse",
    "shortlog",
    "show",
    "show-branch",
    "show-ref",
    "status",
    "tag",
    "verify-commit",
    "verify-tag",
    "whatchanged",
}
READ_GIT_GLOBAL_FLAGS = {
    "--bare",
    "--glob-pathspecs",
    "--icase-pathspecs",
    "--literal-pathspecs",
    "--no-advice",
    "--no-lazy-fetch",
    "--no-optional-locks",
    "--no-pager",
    "--no-replace-objects",
    "--noglob-pathspecs",
    "--paginate",
    "-P",
    "-p",
}
READ_GIT_VALUE_OPTIONS = {"--git-dir", "--namespace", "--work-tree", "-C"}
GIT_DANGEROUS = {"--output", "--ext-diff", "--textconv", "--exec-path", "--config-env", "-O", "--open-files-in-pager"}
# Mutating git subcommands that also take branch/remote positionals; a read
# subcommand is anything in READ_GIT when invoked without a write flag.
GIT_BRANCH_WRITE_FLAGS = {"-d", "-D", "-m", "-M", "-c", "-C", "--delete", "--move", "--copy", "--set-upstream-to", "-u", "--unset-upstream", "--edit-description"}
GIT_TAG_WRITE_FLAGS = {"-a", "-s", "-d", "-f", "-m", "-F", "--annotate", "--sign", "--delete", "--force", "--message", "--file"}
GIT_REMOTE_WRITE_SUBS = {"add", "rename", "remove", "rm", "set-head", "set-branches", "set-url", "prune", "update"}

# tmux verbs a child pane must never drive directly: they are the exact
# transport bypasses the session-chat courier exists to prevent.
CHILD_TMUX_DENIED = {
    "send-keys",
    "send-key",
    "paste-buffer",
    "load-buffer",
    "set-buffer",
    "run-shell",
    "respawn-pane",
    "respawn-window",
    "kill-pane",
    "kill-window",
    "kill-session",
    "kill-server",
    "set-environment",
    "pipe-pane",
}
# Outbound coordination helpers: for a child role these may ONLY appear as one
# canonical trusted invocation (recipient == orchestrator); any other mention
# (composed, wrapped, copied, relative) is a routing bypass.
OUTBOUND_HELPER_BASENAMES = {
    "send-message.sh",
    "dispatch-to-session.sh",
    "broadcast-message.sh",
    "share-context.sh",
    "task-assign.sh",
    "task-new.sh",
}

LABEL_RE = re.compile(r"\A[A-Za-z0-9_.-]+\Z")
REPLY_RE = re.compile(r"\A[a-f0-9]{8,16}\Z")
TASK_ID_RE = re.compile(r"\A[A-Za-z0-9_-]+\Z")
POSITIVE_RE = re.compile(r"\A[1-9][0-9]*\Z")
SAFE_VERSION_RE = re.compile(r"\A[0-9][A-Za-z0-9._+-]*\Z")
ISO_UTC_RE = re.compile(r"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\Z")
PATCH_FILE_RE = re.compile(r"^\*\*\* (?:Add|Update|Delete) File: (.+)$", re.M)
PATCH_MOVE_RE = re.compile(r"^\*\*\* Move to: (.+)$", re.M)
DRAFT_NAME_RE = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.(?:md|txt)\Z")
MESSAGE_NAME_RE = re.compile(r"\A[0-9]+-[0-9]+-[a-f0-9]{8,16}-(.+)\.md\Z")


@dataclass(frozen=True)
class Context:
    mode: str
    semantic_role: str
    pane_name: str
    pane_cwd: Path
    project_root: Path
    config_path: Path
    orchestrator_pane: str
    executor_panes: frozenset
    reviewer_panes: frozenset
    child_roots: tuple
    grant_roots: tuple
    message_roots: tuple
    claude_home: Path
    codex_home: Path
    guards: dict
    environment: str = ""
    route_peers: frozenset = frozenset()
    scoped: bool = False
    session_ids: frozenset = frozenset()
    scheduler_root: Optional[Path] = None
    read_paths: tuple = ()
    plan_panes: frozenset = frozenset()
    plan_message_roots: tuple = ()

    @property
    def confined_orchestrator(self):
        return self.semantic_role == "orchestrator" and bool(self.environment) and self.pane_cwd != self.project_root


@dataclass(frozen=True)
class Decision:
    active: bool
    mode: str
    role: str
    pane: str
    decision: str
    rule: str
    reason: str
    tool: str

    def normalized(self) -> dict:
        return {
            "active": self.active,
            "decision": self.decision,
            "mode": self.mode,
            "pane": self.pane,
            "profile": PROFILE if self.active else "",
            "reason": self.reason,
            "role": self.role,
            "rule": self.rule,
            "tool": self.tool,
        }


class PolicyFailure(RuntimeError):
    def __init__(self, rule: str, reason: str) -> None:
        super().__init__(reason)
        self.rule = rule
        self.reason = reason


def allow(ctx: Optional[Context], tool: str, rule: str = "allow", reason: str = "allowed by strict-v1") -> Decision:
    if ctx is None:
        return Decision(False, "", "", "", "allow", "inactive", "harness is not active", tool)
    return Decision(True, ctx.mode, ctx.semantic_role, ctx.pane_name, "allow", rule, reason, tool)


def deny(ctx: Optional[Context], tool: str, rule: str, reason: str, mode: str = "enforce", integrity: bool = False) -> Decision:
    """A policy denial becomes ``audit`` in audit mode; an integrity denial never does."""
    effective_mode = ctx.mode if ctx is not None else mode
    decision = "deny"
    if not integrity and effective_mode == "audit":
        decision = "audit"
    return Decision(
        True,
        effective_mode,
        ctx.semantic_role if ctx is not None else "",
        ctx.pane_name if ctx is not None else os.environ.get("SESSION_WORKSPACE_PANE_NAME", "").strip(),
        decision,
        rule,
        reason,
        tool,
    )


def canonical(path: Path) -> Path:
    return path.expanduser().resolve(strict=False)


def within(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def walk(value: Any) -> Iterable[Tuple[Optional[str], Any]]:
    if isinstance(value, dict):
        for key, child in value.items():
            yield str(key), child
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield None, child
            yield from walk(child)


def tool_input_of(payload: dict) -> dict:
    for key in ("tool_input", "input", "arguments", "params"):
        value = payload.get(key)
        if isinstance(value, dict):
            return value
        if isinstance(value, str) and value.strip():
            # Some Codex shapes carry tool_input as one JSON-encoded string, or
            # as the bare apply_patch text. Decode; never guess a path from it.
            try:
                decoded = json.loads(value)
            except ValueError:
                decoded = None
            if isinstance(decoded, dict):
                return decoded
            return {"input": value}
    return {}


def edit_targets(tool_input: dict) -> set:
    values = set()
    for key, child in walk(tool_input):
        if key in PATH_FIELDS and isinstance(child, str) and child.strip():
            values.add(child.strip())
    # apply_patch (Codex) carries every target inside one patch string.
    for _, child in walk(tool_input):
        if isinstance(child, str) and "*** " in child:
            for match in PATCH_FILE_RE.finditer(child):
                values.add(match.group(1).strip())
            for match in PATCH_MOVE_RE.finditer(child):
                values.add(match.group(1).strip())
    return values


def read_raw_config(path: Path) -> Optional[dict]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, ValueError):
        return None
    return value if isinstance(value, dict) else None


def raw_harness_state(config: Optional[dict]) -> Tuple[bool, str]:
    if not config or config.get("schema_version") not in {2, 3, 4, 5}:
        return False, ""
    harness = config.get("harness")
    if not isinstance(harness, dict) or harness.get("enabled") is not True:
        return False, ""
    mode = harness.get("mode")
    return True, mode if isinstance(mode, str) else "enforce"


def provider_homes() -> Tuple[Path, Path]:
    home = Path(os.environ.get("HOME", str(Path.home())))
    # CLAUDE_CONFIG_DIR is Claude Code's own override for ~/.claude (plugins
    # live under it); CLAUDE_HOME is the session-chat convention. Honour both.
    claude_dir = os.environ.get("CLAUDE_CONFIG_DIR", "").strip() or os.environ.get("CLAUDE_HOME", "").strip() or str(home / ".claude")
    claude_home = canonical(Path(claude_dir))
    codex_home = canonical(Path(os.environ.get("CODEX_HOME", str(home / ".codex"))))
    return claude_home, codex_home


def scheduler_store_root(pane: dict, owned_panes: List[dict], semantic: str) -> Optional[Path]:
    """The validated scheduler store this pane's contract checks read.

    Children carry it as an explicit grant. The orchestrator works from the
    project root and normally has no grants, but it coordinates the same single
    store its children are granted, so it resolves to that shared grant. Two
    different child scheduler grants are ambiguous and resolve to none.
    """
    def grant_of(entry: dict) -> List[Path]:
        return [canonical(Path(g["path"])) for g in entry.get("grants", []) or []
                if isinstance(g, dict) and g.get("store") == "scheduler" and isinstance(g.get("path"), str) and g["path"]]
    own = grant_of(pane)
    if own:
        return own[0]
    if semantic != "orchestrator":
        return None
    shared = {path for entry in owned_panes for path in grant_of(entry)}
    return next(iter(shared)) if len(shared) == 1 else None


def load_context() -> Tuple[Optional[Context], Optional[Decision]]:
    config_text = os.environ.get("SESSION_WORKSPACE_CONFIG", "").strip()
    env_mode = os.environ.get("SESSION_WORKSPACE_HARNESS_MODE", "").strip()
    tool = ""
    if not config_text:
        return None, None

    config_path = canonical(Path(config_text))
    raw_config = read_raw_config(config_path)
    raw_active, raw_mode = raw_harness_state(raw_config)
    if not raw_active and not env_mode:
        # A stale or user-exported config pointer on an inactive/unreadable
        # config must never brick a shell: true no-op.
        return None, None
    failure_mode = env_mode if env_mode in {"audit", "enforce"} else raw_mode
    if failure_mode not in {"audit", "enforce"}:
        failure_mode = "enforce"
    if raw_config is None:
        return None, deny(None, tool, "identity.config", "active harness config is missing, unreadable, or invalid JSON", failure_mode, integrity=True)

    try:
        run = subprocess.run(
            ["bash", str(HERE / "workspace-plan.sh"), "--config", str(config_path), "--json"],
            check=False,
            capture_output=True,
            text=True,
            timeout=20,
            env=os.environ.copy(),
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return None, deny(None, tool, "identity.config", "could not validate active harness config: %s" % exc, failure_mode, integrity=True)
    if run.returncode != 0:
        detail = (run.stderr or run.stdout).strip().splitlines()
        suffix = detail[0] if detail else "workspace-plan validation failed"
        return None, deny(None, tool, "identity.config", "active harness config failed closed: %s" % suffix, failure_mode, integrity=True)
    try:
        plan = json.loads(run.stdout)
    except ValueError:
        return None, deny(None, tool, "identity.config", "workspace-plan returned invalid JSON", failure_mode, integrity=True)

    harness = plan.get("harness") if isinstance(plan, dict) else None
    if not isinstance(harness, dict) or harness.get("active") is not True:
        if env_mode:
            return None, deny(None, tool, "identity.mode", "launcher says harness is active but validated config is inactive", failure_mode, integrity=True)
        return None, None
    mode = harness.get("mode")
    if mode not in {"audit", "enforce"}:
        return None, deny(None, tool, "identity.mode", "validated harness mode is invalid", failure_mode, integrity=True)
    if env_mode != mode:
        return None, deny(None, tool, "identity.mode", "launcher harness mode does not match validated config", mode, integrity=True)

    plan_guards = harness.get("guards")
    env_guards = os.environ.get("SESSION_WORKSPACE_GUARDS_JSON", "").strip()
    if plan_guards is None:
        if env_guards:
            return None, deny(None, tool, "identity.config", "launcher guard identity is present but validated config has no guards", mode, integrity=True)
        guards = {}
    elif not isinstance(plan_guards, dict):
        return None, deny(None, tool, "identity.config", "validated harness guards are invalid", mode, integrity=True)
    else:
        canonical_guards = json.dumps(plan_guards, sort_keys=True, separators=(",", ":"))
        if env_guards != canonical_guards:
            return None, deny(None, tool, "identity.config", "launcher guard identity does not match validated config; restart the pane", mode, integrity=True)
        guards = plan_guards

    required_env = {
        "SESSION_WORKSPACE_PROJECT_ROOT": os.environ.get("SESSION_WORKSPACE_PROJECT_ROOT", "").strip(),
        "SESSION_WORKSPACE_PANE_NAME": os.environ.get("SESSION_WORKSPACE_PANE_NAME", "").strip(),
        "SESSION_WORKSPACE_ROLE": os.environ.get("SESSION_WORKSPACE_ROLE", "").strip(),
        "SESSION_WORKSPACE_PANE_CWD": os.environ.get("SESSION_WORKSPACE_PANE_CWD", "").strip(),
    }
    missing = sorted(key for key, value in required_env.items() if not value)
    if missing:
        return None, deny(None, tool, "identity.missing", "active harness is missing engine identity: " + ", ".join(missing), mode, integrity=True)

    project = plan.get("project", {})
    project_root = canonical(Path(str(project.get("root", ""))))
    if canonical(Path(required_env["SESSION_WORKSPACE_PROJECT_ROOT"])) != project_root:
        return None, deny(None, tool, "identity.root", "launcher project root does not match validated config", mode, integrity=True)
    if not Path(config_text).expanduser().is_absolute() or Path(config_text).expanduser() != config_path:
        return None, deny(None, tool, "identity.config", "launcher config path is not canonical", mode, integrity=True)

    panes: List[dict] = []
    for session in plan.get("sessions", []):
        if isinstance(session, dict):
            panes.extend(p for p in session.get("panes", []) if isinstance(p, dict))
    pane_name = required_env["SESSION_WORKSPACE_PANE_NAME"]
    matches = [pane for pane in panes if pane.get("name") == pane_name]
    if len(matches) != 1:
        return None, deny(None, tool, "identity.pane", "launcher pane identity is unknown or ambiguous", mode, integrity=True)
    pane = matches[0]
    role_name = required_env["SESSION_WORKSPACE_ROLE"]
    pane_cwd = canonical(Path(required_env["SESSION_WORKSPACE_PANE_CWD"]))
    if pane.get("role") != role_name:
        return None, deny(None, tool, "identity.role", "launcher role does not match the configured pane", mode, integrity=True)
    if not pane.get("cwd") or canonical(Path(str(pane.get("cwd")))) != pane_cwd:
        return None, deny(None, tool, "identity.cwd", "launcher pane cwd does not match the configured pane", mode, integrity=True)
    for alias in ("SESSION_CHAT_PANE_NAME", "KNOWLEDGE_PANE_NAME"):
        value = os.environ.get(alias, "").strip()
        if value and value != pane_name:
            return None, deny(None, tool, "identity.alias", "%s disagrees with engine pane identity" % alias, mode, integrity=True)

    roles = harness.get("roles", {})
    semantic = ""
    for candidate in ("orchestrator", "executor", "reviewer"):
        if roles.get(candidate) == role_name:
            semantic = candidate
            break
    if not semantic:
        return None, deny(None, tool, "identity.role", "configured pane is not a harness role", mode, integrity=True)

    read_paths = pane.get("read_paths", [])
    if any(entry.get("kind") not in {"file", "directory"} for entry in read_paths):
        return None, deny(None, tool, "identity.read_paths", "pane read path is unavailable; inspect workspace-plan and restore the path or update config and restart", mode, integrity=True)
    read_identity = json.dumps(read_paths, sort_keys=True, separators=(",", ":")) if read_paths else ""
    if os.environ.get("SESSION_WORKSPACE_READ_PATHS_JSON", "") != read_identity:
        return None, deny(None, tool, "identity.read_paths", "launcher read paths do not match validated configuration; restart affected sessions", mode, integrity=True)

    scope = pane.get("scope")
    scope_env = os.environ.get("SESSION_WORKSPACE_SCOPE_JSON", "")
    if (scope is None and scope_env) or (scope is not None and scope_env != json.dumps(scope, sort_keys=True, separators=(",", ":"))):
        return None, deny(None, tool, "identity.scope", "launcher scope does not match validated configuration; restart affected sessions", mode, integrity=True)
    environment = ""
    route_peers = frozenset()
    scoped = scope is not None
    own = None
    owned_panes = panes
    orchestrators = [p for p in panes if p.get("role") == roles.get("orchestrator")]
    if scoped:
        root_name = scope.get("root_orchestrator")
        environments = scope.get("environments", [])
        current_session = next(s["id"] for s in plan["sessions"] if any(p["name"] == pane_name for p in s["panes"]))
        own = next((e for e in environments if current_session in e["development"] + e["services"]), None)
        if own:
            environment = own["id"]
            if scope.get("environment") != environment:
                return None, deny(None, tool, "identity.scope", "launcher environment does not match ownership", mode, integrity=True)
            own_ids = own["development"] + own["services"]
            owned_panes = [p for s in plan["sessions"] if s["id"] in own_ids for p in s["panes"]]
            coordinator = own.get("orchestrator", root_name)
            orchestrators = [p for p in panes if p["name"] == coordinator]
            if semantic == "orchestrator":
                route_peers = (frozenset(p["name"] for p in panes if p.get("role") == roles.get("orchestrator") and p["name"] != pane_name)
                               if pane_cwd == project_root else frozenset([root_name]) if root_name else frozenset())
        else:
            if pane_name != root_name:
                return None, deny(None, tool, "identity.scope", "unbound harness pane", mode, integrity=True)
            # Root addresses local coordinators, and workers only in environments
            # deliberately configured without a local coordinator.
            direct_ids = [sid for e in environments if not e.get("orchestrator") for sid in e["development"] + e["services"]]
            owned_panes = [p for s in plan["sessions"] if s["id"] in direct_ids for p in s["panes"]]
            route_peers = frozenset(e["orchestrator"] for e in environments if e.get("orchestrator"))
            orchestrators = [p for p in panes if p["name"] == root_name]
    if len(orchestrators) != 1:
        return None, deny(None, tool, "identity.topology", "validated topology has no unique scope orchestrator", mode, integrity=True)
    executor_panes = frozenset(str(p["name"]) for p in owned_panes if p.get("role") == roles.get("executor"))
    reviewer_panes = frozenset(str(p["name"]) for p in owned_panes if p.get("role") == roles.get("reviewer"))
    child_roots = tuple(
        sorted(
            {canonical(Path(str(p["cwd"]))) for p in panes if p.get("cwd") and p.get("role") in {roles.get("executor"), roles.get("reviewer")}},
            key=str,
        )
    )
    # The coordination stores the engine actually grants THIS pane (its
    # --add-dir grants plus its memory shard) are readable/addressable roots
    # for helper operands even though they live outside a child's cwd.
    grant_paths = set()
    message_paths = set()
    for grant in pane.get("grants", []) or []:
        if isinstance(grant, dict) and isinstance(grant.get("path"), str) and grant["path"]:
            grant_path = canonical(Path(grant["path"]))
            grant_paths.add(grant_path)
            if grant.get("store") == "messages":
                message_paths.add(grant_path)
    # (the memory shard is a grant like any other: it is present in
    # pane.grants only when roles.<r>.grants lists "memory")
    claude_home, codex_home = provider_homes()
    context = Context(
        mode=mode,
        semantic_role=semantic,
        pane_name=pane_name,
        pane_cwd=pane_cwd,
        project_root=project_root,
        config_path=config_path,
        orchestrator_pane=str(orchestrators[0]["name"]),
        executor_panes=executor_panes,
        reviewer_panes=reviewer_panes,
        child_roots=child_roots,
        grant_roots=tuple(sorted(grant_paths, key=str)),
        message_roots=tuple(sorted(message_paths, key=str)),
        plan_panes=frozenset(p["name"] for p in panes),
        plan_message_roots=tuple(sorted({canonical(Path(g["path"])) for p in panes
                                        for g in p.get("grants", []) if g.get("store") == "messages"}, key=str)),
        claude_home=claude_home,
        codex_home=codex_home,
        guards=guards,
        environment=environment,
        route_peers=route_peers,
        scoped=scoped,
        read_paths=tuple((Path(entry["path"]), entry["kind"]) for entry in read_paths) if semantic in {"reviewer", "executor"} else (),
        session_ids=frozenset(own["development"] + own["services"]) if scoped and own else frozenset(),
        scheduler_root=scheduler_store_root(pane, owned_panes, semantic),
    )
    return context, None


# ---------------------------------------------------------------------------
# Shell parsing
# ---------------------------------------------------------------------------


def parse_shell(command: str) -> List[str]:
    if "\x00" in command or "\r" in command:
        raise PolicyFailure("bash.parse", "shell command contains a forbidden control byte")
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|()<>")
        lexer.whitespace_split = True
        lexer.commenters = ""
        return list(lexer)
    except ValueError as exc:
        raise PolicyFailure("bash.parse", "could not parse shell command safely: %s" % exc) from exc


def has_unquoted_expansion(command: str) -> bool:
    """True when the raw command carries any shell expansion or control that
    would run before a helper sees its argv: metacharacters outside quotes,
    or $ / backtick anywhere except inside single quotes. Decided on the RAW
    text, before normalization, so normalization can only narrow trust."""
    in_single = False
    in_double = False
    index = 0
    length = len(command)
    while index < length:
        char = command[index]
        if in_single:
            if char == "'":
                in_single = False
        elif in_double:
            if char == "\\" and index + 1 < length:
                index += 2
                continue
            if char == '"':
                in_double = False
            elif char in "$`":
                return True
        else:
            if char == "\\" and index + 1 < length:
                index += 2
                continue
            if char == "'":
                in_single = True
            elif char == '"':
                in_double = True
            elif char in "$`" or char in CONTROL_CHARS or char == "\n":
                return True
        index += 1
    return in_single or in_double


def is_control(token: str) -> bool:
    return token in CONTROL_TOKENS or (bool(token) and set(token) <= CONTROL_CHARS)


REDIRECT_OPS = {">", ">>", ">|", "<", "<>", "&>", "&>>", ">&", "<&"}
WRITE_REDIRECT_OPS = {">", ">>", ">|", "<>", "&>", "&>>", ">&"}
# Sentinel appended to a segment that writes through a redirection. Carries
# a NUL so it can never be mistaken for a path operand or a command.
REDIR_WRITE_MARK = "\x00redirect-write"
REDIR_PATH_PREFIX = "\x00redirect-path:"


def segments(tokens: List[str]) -> List[List[str]]:
    """Split on control operators. A redirection's target is NOT a new
    command: it is a filename by definition, so it is folded into the current
    segment as an explicit path (`./name` when bare, so bare/space/symlink
    forms all canonicalize) and the segment is marked as writing when the
    redirection writes. Heredoc/herestring bodies are data and are skipped;
    fd duplications (`2>&1`, `>&-`) name no file."""
    out: List[List[str]] = []
    current: List[str] = []
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if token in REDIRECT_OPS:
            target = tokens[index + 1] if index + 1 < len(tokens) else None
            index += 1
            if target is not None and not is_control(target):
                index += 1
                if not (token in {">&", "<&"} and (target.isdigit() or target == "-")):
                    if not (target in {".", "..", "~"} or target.startswith(("/", "./", "../", "~/"))):
                        target = "./" + target
                    # Keep shell-opened files out of command argv: a data
                    # option such as grep -e must never consume this target.
                    current.append(REDIR_PATH_PREFIX + target)
                    if token in WRITE_REDIRECT_OPS:
                        current.append(REDIR_WRITE_MARK)
            continue
        if token in {"<<", "<<<", "<<-"}:
            index += 2
            continue
        if is_control(token):
            if current:
                out.append(current)
            current = []
        else:
            current.append(token)
        index += 1
    if current:
        out.append(current)
    return out


PRIVILEGE_WRAPPERS = {"sudo", "doas", "su", "runuser", "pkexec"}
LAUNCH_WRAPPERS = {"env", "command", "builtin", "exec", "nohup", "time"}
ASSIGNMENT_RE = re.compile(r"\A[A-Za-z_][A-Za-z0-9_]*=.*\Z")


class Wrapped(object):
    """Result of parse_wrappers: the REAL argv after every reviewed wrapper
    hop; the env --chdir targets as ONE LIST PER env HOP, in hop order
    (nested env hops COMPOSE: `env -C a env -C b CMD` runs CMD in <cwd>/a/b;
    within one env a repeated -C/--chdir behaves like env itself -- the LAST
    value wins, resolved against that env's starting cwd -- while every
    given value is still validated); and every assignment value that may be
    a path operand."""

    def __init__(self, argv: List[str], chdirs: List[List[str]], values: List[str]) -> None:
        self.argv = argv
        self.chdirs = chdirs
        self.values = values


def parse_wrappers(segment: List[str]) -> Wrapped:
    """THE wrapper grammar, shared by every classifier. Reviewed literal forms
    only:
      NAME=value ...                      (any count, any hop)
      env [-i|--ignore-environment] [-u NAME|--unset NAME|--unset=NAME]
          [-C DIR|-CDIR|--chdir DIR|--chdir=DIR] [NAME=value ...] [--]
      command CMD ...   (command -v/-V is a query, not a wrapper)
      builtin CMD ...
      exec CMD ...      nohup CMD ...      time CMD ...   (NO options)
    Anything else in wrapper position fails closed: a privilege wrapper
    (sudo/doas/su/runuser/pkexec) at any hop is shell.privilege; an
    unsupported, dynamic, or missing wrapper option (exec -a/-l/-c,
    nohup --, time -o/-p, /usr/bin/time -o, env -S/--split-string, ...)
    is shell.wrapper. A privileged or re-parsed argv is never modelled."""
    index = 0
    chdirs: List[List[str]] = []
    values: List[str] = [t[len(REDIR_PATH_PREFIX):] for t in segment if t.startswith(REDIR_PATH_PREFIX)]
    segment = [t for t in segment if not t.startswith(REDIR_PATH_PREFIX)]
    while index < len(segment):
        token = segment[index]
        if token == REDIR_WRITE_MARK:
            index += 1
            continue
        if ASSIGNMENT_RE.fullmatch(token):
            values.append(token.split("=", 1)[1])
            index += 1
            continue
        name = Path(token).name
        if name in PRIVILEGE_WRAPPERS:
            raise PolicyFailure("shell.privilege", "privilege wrappers are outside strict-v1 for every role: %s" % name)
        if name == "env":
            index += 1
            hop: List[str] = []
            while index < len(segment):
                option = segment[index]
                if ASSIGNMENT_RE.fullmatch(option):
                    values.append(option.split("=", 1)[1])
                    index += 1
                    continue
                if not option.startswith("-"):
                    break
                if option in {"-i", "--ignore-environment"}:
                    index += 1
                    continue
                if option in {"-u", "--unset"}:
                    if index + 1 >= len(segment) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", segment[index + 1]):
                        raise PolicyFailure("shell.wrapper", "env %s requires a literal variable name" % option)
                    index += 2
                    continue
                if option.startswith("--unset="):
                    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", option.split("=", 1)[1]):
                        raise PolicyFailure("shell.wrapper", "env --unset= requires a literal variable name")
                    index += 1
                    continue
                if option in {"-C", "--chdir"}:
                    if index + 1 >= len(segment) or segment[index + 1].startswith("-") or not segment[index + 1]:
                        raise PolicyFailure("shell.wrapper", "env %s requires a literal directory" % option)
                    hop.append(segment[index + 1])
                    index += 2
                    continue
                if option.startswith("--chdir="):
                    hop.append(option.split("=", 1)[1])
                    index += 1
                    continue
                if re.fullmatch(r"-C.+", option):
                    hop.append(option[2:])
                    index += 1
                    continue
                if option == "--":
                    index += 1
                    break
                raise PolicyFailure("shell.wrapper", "unsupported env option is outside strict-v1: %s" % option)
            if hop:
                chdirs.append(hop)
            continue
        if name == "command":
            index += 1
            if index < len(segment) and segment[index].startswith("-"):
                if segment[index] in {"-v", "-V"}:
                    # `command -v X` is a lookup query, not a launch wrapper.
                    return Wrapped(segment[index - 1 :], chdirs, values)
                raise PolicyFailure("shell.wrapper", "unsupported command option is outside strict-v1: %s" % segment[index])
            continue
        if name == "builtin":
            index += 1
            if index < len(segment) and segment[index].startswith("-"):
                raise PolicyFailure("shell.wrapper", "builtin options are outside strict-v1: %s" % segment[index])
            continue
        if name in {"exec", "nohup", "time"}:
            index += 1
            if index < len(segment) and segment[index].startswith("-"):
                raise PolicyFailure("shell.wrapper", "%s options are outside strict-v1: %s" % (name, segment[index]))
            continue
        break
    argv = [t for t in segment[index:] if t != REDIR_WRITE_MARK] if index < len(segment) else []
    return Wrapped(argv, chdirs, values)


def unwrap_prefixes(tokens: List[str]) -> List[str]:
    """The real argv after every reviewed wrapper hop (see parse_wrappers)."""
    return parse_wrappers(tokens).argv


def command_basename(tokens: List[str]) -> str:
    argv = unwrap_prefixes(tokens)
    return Path(argv[0]).name if argv else ""


def git_subcommand(tokens: List[str]) -> Tuple[str, int]:
    """Return (subcommand, index) for a git argv, honoring global options.
    Raises for a non-allowlisted global option (they can redirect execution:
    -c, --exec-path, --config-env ...)."""
    index = 1
    while index < len(tokens):
        token = tokens[index]
        if token in READ_GIT_GLOBAL_FLAGS:
            index += 1
            continue
        if token in READ_GIT_VALUE_OPTIONS:
            if index + 1 >= len(tokens):
                raise PolicyFailure("reviewer.git", "%s requires a literal value" % token)
            index += 2
            continue
        if token.startswith("-C") and len(token) > 2:
            # attached form `-C<dir>`: the directory is a path operand that
            # ensure_paths_within / references_child resolve separately
            index += 1
            continue
        if any(token.startswith(option + "=") for option in READ_GIT_VALUE_OPTIONS if option.startswith("--")):
            index += 1
            continue
        if token.startswith("-"):
            raise PolicyFailure("reviewer.git", "Git global option is not read-only allowlisted: %s" % token)
        break
    if index >= len(tokens):
        raise PolicyFailure("reviewer.git", "git requires a subcommand")
    return tokens[index], index


def git_is_read_only(tokens: List[str]) -> bool:
    tokens = unwrap_prefixes(tokens)
    try:
        sub, index = git_subcommand(tokens)
    except PolicyFailure:
        return False
    if sub not in READ_GIT:
        return False
    rest = tokens[index + 1 :]
    if any(t in GIT_DANGEROUS or any(t.startswith(flag + "=") for flag in GIT_DANGEROUS) for t in rest):
        return False
    positionals = [t for t in rest if not t.startswith("-")]
    if sub == "branch":
        # `git branch <name>` CREATES a branch: a positional is read-only only
        # under an explicit listing mode.
        if any(t in GIT_BRANCH_WRITE_FLAGS for t in rest):
            return False
        if positionals and not any(t in {"-l", "--list", "--contains", "--no-contains", "--merged", "--no-merged", "--points-at"} for t in rest):
            return False
    if sub == "tag":
        if any(t in GIT_TAG_WRITE_FLAGS for t in rest):
            return False
        if positionals and not any(t in {"-l", "--list", "--contains", "--no-contains", "--merged", "--no-merged", "--points-at"} for t in rest):
            return False
    if sub == "remote":
        if any(t in GIT_REMOTE_WRITE_SUBS for t in rest):
            return False
        if positionals and positionals[0] not in {"show", "get-url"}:
            return False
    return True


def candidate_path(token: str, base: Path, child_rel_names: Tuple[str, ...] = (), resolve: bool = True,
                   literal: bool = False) -> Optional[Path]:
    """Resolve one argv token as a path operand, or None when it is data.
    Path forms: absolute, ./ ../ ~/ prefixed, bare . / .. / ~, anything with a
    slash, `--opt=PATH`, an attached cwd option (`-C..`, `-C/tmp`), an
    assignment value (`OUT=/tmp/x`), and a BARE relative name that names an
    existing entry under BASE (the symlink-escape shape, `cat escape-link`,
    with or without whitespace). Free text that names nothing stays data."""
    value = token
    if not literal and token.startswith("--") and "=" in token:
        value = token.split("=", 1)[1]
    elif not literal and re.fullmatch(r"-C.+", token):
        value = token[2:]
    elif not literal and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", token):
        value = token.split("=", 1)[1]
    if not value or value == "-" or (not literal and value.startswith("-")) or any(char in value for char in "\n\r\x00"):
        return None
    if value == "/dev/null":
        return Path(value)
    prefixed = value in {".", "..", "~"} or value.startswith(("/", "./", "../", "~/"))
    has_whitespace = any(char.isspace() for char in value)
    looks_path = prefixed or (not has_whitespace and ("/" in value or value in child_rel_names))
    dynamic = "$" in value or "`" in value or any(char in value for char in "*?{}[")
    if not looks_path:
        # Unquoted expansions/globs are refused by the raw-command scanners
        # before this point; a quoted one ('a*b') is a literal pattern, data.
        if dynamic:
            return None
        try:
            if not os.path.lexists(str(base / value)):
                return None
        except (OSError, ValueError):
            return None
    if dynamic:
        raise PolicyFailure("path.dynamic", "dynamic or globbed path operands are outside strict-v1")
    path = Path(value).expanduser()
    path = path if path.is_absolute() else base / path
    return canonical(path) if resolve else path


# Only these reviewed options may suppress path inference for their values.
# Everything else retains conservative path checks, including every possible
# attached short-option suffix for commands whose grammar we do not know.
SHORT_DATA_OPTIONS = {"grep": "emABCDd", "rg": "eEgtdTjmrMABC", "sort": "ktS"}
SHORT_PATH_OPTIONS = {"grep": "f", "rg": "f", "sort": "oT"}
SHORT_FLAGS = {
    "grep": "EFGPHVabchilLnqrsRvwxyzUuI0123456789",
    "rg": "FPUiSsLvuawxoclnNHIpqz0hV",
    "sort": "bcdfghiMmnrRsuVz",
}
LONG_DATA_OPTIONS = {
    "grep": {"--regexp", "--max-count", "--after-context", "--before-context", "--context", "--devices", "--directories"},
    "rg": {"--regexp", "--encoding", "--glob", "--iglob", "--type", "--type-not", "--threads", "--max-count", "--replace", "--max-columns", "--after-context", "--before-context", "--context", "--max-depth"},
    "sort": {"--key", "--field-separator", "--buffer-size"},
}
LONG_PATH_OPTIONS = {
    "grep": {"--file"}, "rg": {"--file"},
    "sort": {"--output", "--temporary-directory", "--compress-program", "--random-source", "--files0-from"},
}


def argv_fields(argv: List[str], positional_only: bool = False) -> Iterable[Tuple[str, str]]:
    """Yield (kind, value): option names, literal paths, or conservative
    candidates. Data values are consumed but never reinterpreted as options.
    This is shared by read checks, executor fallback and child detection.
    It is deliberately not a complete grammar for arbitrary executables."""
    if not argv:
        return
    command = Path(argv[0]).name
    # Recursive traversal inference must not mistake an option's numeric/data
    # value for a starting path. These exemptions affect positional inference
    # only; the ordinary containment parser still checks all its old operands.
    positional_short_data = {"du": "dBtX", "ls": "DITw"}.get(command, "") if positional_only else ""
    positional_long_data = ({"du": {"--max-depth", "--block-size", "--threshold", "--exclude", "--exclude-from"},
                             "ls": {"--ignore", "--tabsize", "--width", "--block-size", "--format", "--sort", "--time", "--time-style", "--quoting-style"}}
                            .get(command, set())) if positional_only else set()
    index = 1
    positional = False
    while index < len(argv):
        token = argv[index]
        index += 1
        if positional:
            yield "literal", token
            continue
        if token == "--":
            positional = True
            continue
        if token.startswith("--"):
            option, equals, value = token.partition("=")
            yield "option", option
            data = option in LONG_DATA_OPTIONS.get(command, set()) or option in positional_long_data
            path = option in LONG_PATH_OPTIONS.get(command, set())
            if data or path:
                if not equals:
                    if index >= len(argv):
                        raise PolicyFailure("path.option", "%s requires a literal value" % option)
                    value = argv[index]
                    index += 1
                if path and not positional_only:
                    yield "literal", value
            elif equals and not positional_only:
                yield "literal", value
            continue
        if token.startswith("-") and token != "-":
            offset = 1
            while offset < len(token):
                char = token[offset]
                data = char in SHORT_DATA_OPTIONS.get(command, "") or char in positional_short_data
                path = char in SHORT_PATH_OPTIONS.get(command, "")
                if data or path:
                    yield "option", "-" + char
                    value = token[offset + 1:]
                    if not value:
                        if index >= len(argv):
                            raise PolicyFailure("path.option", "-%s requires a literal value" % char)
                        value = argv[index]
                        index += 1
                    if path and not positional_only:
                        yield "literal", value
                    break
                if char not in SHORT_FLAGS.get(command, "") and not (positional_only and command in {"du", "ls"} and char.isascii() and char.isalpha()):
                    # Unknown option/command: any cluster boundary may start
                    # a path value (cp -tDIR, tar -cfFILE, etc.). Do not grant
                    # data exemptions after an unrecognized prefix.
                    yield "option" if positional_only else "candidate", token
                    for start in range(2, len(token)) if not positional_only else ():
                        if not token[start - 1].isascii() or not token[start - 1].isalnum():
                            break
                        yield "literal", token[start:]
                    break
                yield "option", "-" + char
                offset += 1
            continue
        yield "candidate", token


def argv_paths(argv: List[str], base: Path, child_rel: Tuple[str, ...] = ()) -> Iterable[Tuple[str, Path, Path]]:
    for kind, value in argv_fields(argv):
        if kind == "option":
            continue
        raw = candidate_path(value, base, child_rel, resolve=False, literal=kind == "literal")
        if raw is not None:
            yield value, canonical(raw), raw


def sort_writes(argv: List[str]) -> bool:
    # GNU-style long option abbreviations can also write. Conservatively
    # classify even ambiguous prefixes as writes; data values are not options.
    long_options = {"--output", "--temporary-directory", "--compress-program"}
    return any(kind == "option" and (value in {"-o", "-T"} or
               (len(value) > 2 and any(option.startswith(value) for option in long_options)))
               for kind, value in argv_fields(argv))


def executable_path(token: str, base: Path) -> Optional[Path]:
    """The executable of a segment is a PATH operand only when written as one
    (contains a slash or a ./ ../ ~/ prefix); a bare name is a PATH lookup,
    never resolved against the cwd."""
    if not token or token.startswith("-"):
        return None
    if "/" not in token and not token.startswith("~"):
        return None
    return candidate_path(token, base)


def coordination_roots() -> List[Path]:
    roots = []
    for name in ("SESSION_CHAT_TARGET_MESSAGES_DIR", "SESSION_SCHEDULER_HOME", "SESSION_CONTEXT_HOME"):
        value = os.environ.get(name, "").strip()
        if value and Path(value).expanduser().is_absolute():
            roots.append(canonical(Path(value)))
    return roots


def cache_roots(ctx: Context) -> Tuple[Path, Path]:
    return (
        ctx.claude_home / "plugins" / "cache" / MARKETPLACE,
        ctx.codex_home / "plugins" / "cache" / MARKETPLACE,
    )


def allowed_read_roots(ctx: Context) -> Tuple[Path, ...]:
    """Fixed roots a pane may READ through shell/helper operands: its own cwd
    (the orchestrator's is the workspace root; a child's is exactly its
    checkout, never a sibling reached via ../), the coordination stores the
    plan actually GRANTS this pane, and both providers' message inboxes.
    Selected plugin caches are handled by readable() below, per version.
    Inherited SESSION_* environment roots are deliberately NOT trusted."""
    roots = [ctx.pane_cwd]
    roots.extend(ctx.grant_roots)
    roots.append(ctx.claude_home / "messages")
    roots.append(ctx.codex_home / "messages")
    return tuple(roots)


def selected_plugin_readable(ctx: Context, path: Path) -> bool:
    """Read selected installed content without granting stores or execution.
    PATH is canonicalized by the operand parser before reaching this check."""
    for provider, root in (("claude", cache_roots(ctx)[0]), ("codex", cache_roots(ctx)[1])):
        try:
            parts = path.relative_to(root).parts
        except ValueError:
            continue
        if len(parts) < 2:
            return False
        plugin, version = parts[0], parts[1]
        selected = selected_claude_version(ctx, plugin) if provider == "claude" else selected_codex_version(ctx, plugin)
        return bool(selected) and selected == version
    return False


def readable(ctx: Context, path: Path) -> bool:
    """True for allowed read roots or the selected installed plugin version."""
    return any(within(path, root) for root in allowed_read_roots(ctx)) or selected_plugin_readable(ctx, path)


def tmp_readable(ctx: Context, path: Path) -> bool:
    return readable(ctx, path) or any(within(path, root) for root in tmp_roots())


def reviewer_readable(ctx: Context, path: Path) -> bool:
    """Extra grants apply to scoped shell reads, never helper stores."""
    if any(within(path, root) for root in guarded_message_roots(ctx)):
        return own_message_readable(ctx, path, path)
    base_readable = (within(path, ctx.pane_cwd) or selected_plugin_readable(ctx, path)) if ctx.semantic_role == "executor" else readable(ctx, path)
    return base_readable or (ctx.semantic_role in {"reviewer", "executor"} and any(
        (kind == "file" and path == root) or (kind == "directory" and within(path, root))
        for root, kind in ctx.read_paths))


def guarded_message_roots(ctx: Context) -> tuple:
    # Legacy provider inboxes do not grant access without a plan messages grant.
    return ctx.message_roots + ctx.plan_message_roots + (ctx.claude_home / "messages", ctx.codex_home / "messages")


def own_message_readable(ctx: Context, raw: Path, path: Path) -> bool:
    """Read only private, unaliased payloads tied to validated plan identity.

    Like the existing edit guard, this is not atomic against same-uid swaps.
    Check lexical components before canonical containment loses that evidence.
    """
    if ".." in raw.parts:
        return False
    try:
        if any(part.is_symlink() for part in (raw,) + tuple(raw.parents)):
            return False
        info = raw.stat()
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid():
            return False
        if any(raw.parent == root / "drafts" / ctx.pane_name for root in ctx.message_roots):
            return own_message_draft(ctx, raw, path)
        if info.st_mode & 0o077 or not any(raw.parent == root == path.parent for root in ctx.message_roots):
            return False
    except OSError:
        return False
    match = MESSAGE_NAME_RE.fullmatch(path.name)
    if match is None:
        return False
    tail = match.group(1)
    pairs = [(tail[:m.start()], tail[m.start() + 4:]) for m in re.finditer(r"(?=-to-)", tail)]
    pairs = [(sender, recipient) for sender, recipient in pairs
             if sender in ctx.plan_panes and recipient in ctx.plan_panes]
    return len(pairs) == 1 and ctx.pane_name in pairs[0]


def file_list_read(tokens: List[str]) -> bool:
    """NUL-delimited operand lists hide paths from the literal read grammar.

    GNU tools accept unambiguous long-option prefixes (wc can accept --f),
    so reject every nonempty prefix, not just the full option spelling.
    """
    executable = Path(tokens[0]).name if tokens else ""
    if executable == "find":
        return any(token == "-files0-from" for token in tokens[1:])
    if executable not in {"sort", "du", "wc"}:
        return False
    return any(kind == "option" and value.startswith("--") and len(value) > 2
               and "--files0-from".startswith(value) for kind, value in argv_fields(tokens))


def message_read_guard(ctx: Context, tokens: List[str], base: Path) -> bool:
    """Deny message aliases and recursive store traversal before broad grants.

    Returns whether an explicit payload operand uses the scoped exception;
    command grammar still has to pass separately before that can allow a read.
    """
    argv = unwrap_prefixes(tokens)
    if not argv:
        return False
    roots = guarded_message_roots(ctx)
    operands = list(argv_paths(argv, base))
    touched = False
    for _, path, raw in operands:
        lexical = Path(os.path.abspath(raw))
        if any(within(path, root) or within(lexical, root) for root in roots):
            if argv[0] == "git" or not own_message_readable(ctx, raw, path):
                raise PolicyFailure("coordination.message_read", "message reads require a private delivered file addressed to or sent by this validated pane, or its own draft; transport state, aliases, and peer files are forbidden")
            touched = True
    executable = Path(argv[0]).name
    fields = list(argv_fields(argv, positional_only=True))
    options = [value for kind, value in fields if kind == "option"]
    if touched and file_list_read(argv):
        raise PolicyFailure("coordination.message_read", "message files may be read as content, not as lists of additional file operands")
    recursive = executable in {"rg", "find", "du"} or (
        executable in {"grep", "ls"} and any(
            value in {"--recursive", "--dereference-recursive", "--directories", "-d"} or
            (value.startswith("-") and not value.startswith("--") and
             any(flag in value[1:] for flag in ("rR" if executable == "grep" else "R")))
            for value in options))
    if recursive:
        positional = [value for kind, value in fields if kind != "option"]
        if executable in {"rg", "grep"} and not any(
                option in {"-e", "-f", "--regexp", "--file", "--files"} for option in options):
            positional = positional[1:]  # First positional is the search pattern.
        scan_paths = [candidate_path(value, base, literal=True) for value in positional] or [base]
        if executable == "find" and (len(argv) == 1 or argv[1].startswith("-")):
            scan_paths.append(base)  # find expressions may omit the starting path.
        if any(path is not None and path.is_dir() and any(within(root, path) for root in roots) for path in scan_paths):
            raise PolicyFailure("coordination.message_traversal", "recursive reads may enter a message store; name explicit subdirectories outside the store (glob exclusions do not grant access)")
    return touched


def skill_content_readable(ctx: Context, raw: Path) -> bool:
    """Read installed system/user skill content, never provider state or code.

    This is only an extra operand grant in the literal non-Git read grammar.
    It is deliberately absent from helper, workdir, and edit authorization.
    Validate lexical components before resolution so cross-skill symlinks cannot
    borrow the destination skill's authority. No same-uid race guarantee.
    """
    if ctx.semantic_role not in {"reviewer", "executor"} or ".." in raw.parts:
        return False
    for home, system in ((ctx.codex_home, True), (ctx.claude_home, False)):
        skills = home / "skills"
        try:
            parts = raw.relative_to(skills).parts
        except ValueError:
            continue
        base = skills
        if system and parts and parts[0] == ".system":
            base = skills / ".system"
            marker = base / ".codex-system-skills.marker"
            try:
                if marker.is_symlink() or not marker.is_file() or marker.stat().st_nlink != 1:
                    return False
            except OSError:
                return False
            parts = parts[1:]
        if not parts or any(p.startswith(".") for p in parts):
            return False
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", parts[0]):
            return False
        skill = base / parts[0]
        entry = skill / "SKILL.md"
        try:
            # Reject links in all components below the already-resolved home.
            for target in (raw, entry):
                cursor = target
                while cursor != home:
                    if cursor.is_symlink():
                        return False
                    cursor = cursor.parent
            if not skill.is_dir() or not entry.is_file() or entry.stat().st_nlink != 1:
                return False
            if not within(canonical(raw), skill):
                return False
            if raw.is_file():
                return raw.stat().st_nlink == 1
            if raw.is_dir():
                # Recursive tools must not expose linked leaves. Their follow,
                # preprocessor, mutation and execution options are gated above.
                def walk_error(error: OSError) -> None:
                    raise error

                for parent, dirs, files in os.walk(raw, followlinks=False, onerror=walk_error):
                    for name in dirs + files:
                        child = Path(parent) / name
                        if name.startswith(".") or child.is_symlink() or not (child.is_dir() or child.is_file()):
                            return False
                        if child.is_file() and child.stat().st_nlink != 1:
                            return False
                return True
        except (OSError, ValueError):
            return False
        return False
    return False


def resolve_chdir_hops(chdirs: List[List[str]], cwd: Path, allowed: Optional[Callable[[Path], bool]] = None, rule: str = "") -> Path:
    """Apply env --chdir hops IN ORDER. Each env hop starts from the cwd the
    previous hop produced; within a hop every given value is resolved
    (through symlinks) against that starting cwd and validated against
    ALLOWED when given, and -- exactly like env -- the LAST value is the one
    the command runs in. A dynamic or empty value fails closed."""
    for hop in chdirs:
        start = cwd
        effective = start
        for value in hop:
            if not value or "$" in value or "`" in value or any(char in value for char in "*?{}["):
                raise PolicyFailure("path.dynamic", "dynamic or empty env --chdir target is outside strict-v1")
            raw = Path(value).expanduser()
            resolved = canonical(raw if raw.is_absolute() else start / raw)
            if allowed is not None and not allowed(resolved):
                raise PolicyFailure(rule, "env --chdir target escapes the allowed scope: %s" % value)
            effective = resolved
        cwd = effective
    return cwd


def segment_exec_cwd(segment: List[str], cwd: Path) -> Path:
    """The directory the segment's REAL command runs in: CWD composed with
    every reviewed env -C/--chdir hop in order."""
    return resolve_chdir_hops(parse_wrappers(segment).chdirs, cwd)


def ensure_paths_within(tokens: List[str], base: Path, allowed: Callable[[Path], bool], rule: str,
                        extra_read: Optional[Callable[[Path], bool]] = None) -> None:
    """Every path-like operand of ONE segment must satisfy ALLOWED. The
    wrapper prefix (assignments, env and its option VALUES such as
    `-C ..`) resolves against BASE; the real command's execution cwd (BASE,
    or an env --chdir target, itself checked) is where its executable --
    when written as a path -- and its operands resolve, including
    redirection targets segments() folded in as explicit ./ paths. A bare
    command name is a PATH lookup and is not an operand."""
    wrapped = parse_wrappers(tokens)
    argv = wrapped.argv
    for value in wrapped.values:
        path = candidate_path(value, base)
        if path is None or path == Path("/dev/null"):
            continue
        if not allowed(path):
            raise PolicyFailure(rule, "wrapper option escapes the allowed scope: %s" % value)
    exec_cwd = resolve_chdir_hops(wrapped.chdirs, base, allowed, rule)
    path = executable_path(argv[0], exec_cwd) if argv else None
    if path is not None and not allowed(path):
        raise PolicyFailure(rule, "executable path escapes the allowed scope: %s" % argv[0])
    for token, path, raw in argv_paths(argv, exec_cwd):
        if path == Path("/dev/null"):
            continue
        if not allowed(path):
            if extra_read is not None and raw is not None and extra_read(raw):
                continue
            raise PolicyFailure(rule, "path operand escapes the allowed scope: %s" % token)


def has_unquoted_glob(command: str) -> bool:
    """True when a glob/brace character sits outside quotes: the shell would
    expand it into operands the policy cannot see (`cat escape-*`)."""
    in_single = False
    in_double = False
    index = 0
    while index < len(command):
        char = command[index]
        if in_single:
            if char == "'":
                in_single = False
        elif char == "\\" and index + 1 < len(command):
            index += 2
            continue
        elif in_double:
            if char == '"':
                in_double = False
        else:
            if char == "'":
                in_single = True
            elif char == '"':
                in_double = True
            elif char in "*?[{":
                return True
        index += 1
    return False


def has_expansion(command: str) -> bool:
    """True when the raw command carries a shell expansion ($ or backtick)
    anywhere except inside single quotes -- an operand that only exists after
    expansion cannot be resolved, so it fails closed."""
    in_single = False
    in_double = False
    index = 0
    while index < len(command):
        char = command[index]
        if in_single:
            if char == "'":
                in_single = False
        elif char == "\\" and not in_single and index + 1 < len(command):
            index += 2
            continue
        elif in_double:
            if char == '"':
                in_double = False
            elif char in "$`":
                return True
        else:
            if char == "'":
                in_single = True
            elif char == '"':
                in_double = True
            elif char in "$`":
                return True
        index += 1
    return False


CD_COMMANDS = {"cd", "chdir", "pushd"}


def walk_segments(tokens: List[str], base: Path) -> Iterable[Tuple[List[str], Path, Path]]:
    """Yield (segment, cwd_before, cwd_after) across a composed command,
    tracking cd/chdir/pushd/popd so later operands resolve against the
    directory the shell would actually be in. A dynamic target (`cd -`,
    `pushd` with no operand, expansions) is refused outright."""
    cwd = base
    stack: List[Path] = []
    for segment in segments(tokens):
        argv = unwrap_prefixes(segment)
        executable = Path(argv[0]).name if argv else ""
        after = cwd
        if executable in CD_COMMANDS:
            if any(t == "-" for t in argv[1:]):
                raise PolicyFailure("path.dynamic", "cd - / pushd - is not a literal target")
            operands = []
            positional = False
            for token in argv[1:]:
                if token == "--" and not positional:
                    positional = True
                elif token != REDIR_WRITE_MARK and (positional or not token.startswith("-")):
                    operands.append(token)
            if not operands:
                if executable == "pushd":
                    raise PolicyFailure("path.dynamic", "pushd without a literal directory rotates the stack")
                after = canonical(Path.home())
            else:
                target = operands[0]
                if "$" in target or "`" in target or any(char in target for char in "*?{}"):
                    raise PolicyFailure("path.dynamic", "dynamic or globbed cd target is outside strict-v1")
                raw = Path(target).expanduser()
                after = canonical(raw if raw.is_absolute() else cwd / raw)
            if executable == "pushd":
                stack.append(cwd)
        elif executable == "popd":
            if not stack:
                # The shell's directory stack before this command is unknown
                # to the policy: the resulting cwd cannot be resolved.
                raise PolicyFailure("path.dynamic", "popd without a tracked pushd resolves to an unknown directory")
            after = stack.pop()
        yield segment, cwd, after
        cwd = after


# ---------------------------------------------------------------------------
# Installed-plugin provenance (exact selected version, both providers)
# ---------------------------------------------------------------------------


def selected_claude_version(ctx: Context, plugin: str) -> str:
    """The version Claude Code actually loads for <plugin>@MARKETPLACE, from
    installed_plugins.json: a user-scope entry, or a project-scope entry whose
    projectPath is this workspace. Anything else is unselected."""
    registry = read_raw_config(ctx.claude_home / "plugins" / "installed_plugins.json")
    if not registry:
        return ""
    plugins = registry.get("plugins")
    if not isinstance(plugins, dict):
        return ""
    entries = plugins.get("%s@%s" % (plugin, MARKETPLACE))
    if not isinstance(entries, list):
        return ""
    expected_root = ctx.claude_home / "plugins" / "cache" / MARKETPLACE / plugin
    chosen = ""
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        scope = entry.get("scope")
        project_path = entry.get("projectPath")
        if scope != "user":
            if not isinstance(project_path, str) or canonical(Path(project_path)) != ctx.project_root:
                continue
        version = entry.get("version")
        install_path = entry.get("installPath")
        if not isinstance(version, str) or not SAFE_VERSION_RE.fullmatch(version) or ".." in version:
            continue
        if not isinstance(install_path, str) or canonical(Path(install_path)) != canonical(expected_root / version):
            continue
        if scope != "user":
            return version
        chosen = chosen or version
    return chosen


def _toml_plugin_enabled(text: str, key: str) -> bool:
    """Minimal fallback for python < 3.11 (no tomllib): find the
    [plugins."<key>"] table and read a literal `enabled = true` inside it."""
    header = '[plugins."%s"]' % key
    in_table = False
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("["):
            in_table = stripped == header
            continue
        if in_table and re.fullmatch(r"enabled\s*=\s*true", stripped):
            return True
    return False


def selected_codex_version(ctx: Context, plugin: str) -> str:
    key = "%s@%s" % (plugin, MARKETPLACE)
    try:
        text = (ctx.codex_home / "config.toml").read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return ""
    enabled = False
    try:
        import tomllib  # type: ignore

        try:
            config = tomllib.loads(text)
            plugins = config.get("plugins", {})
            entry = plugins.get(key, {}) if isinstance(plugins, dict) else {}
            enabled = isinstance(entry, dict) and entry.get("enabled") is True
        except tomllib.TOMLDecodeError:
            return ""
    except ImportError:
        enabled = _toml_plugin_enabled(text, key)
    if not enabled:
        return ""
    manifest_path = ctx.codex_home / ".tmp" / "marketplaces" / MARKETPLACE / "codex" / "plugins" / plugin / ".codex-plugin" / "plugin.json"
    manifest = read_raw_config(manifest_path)
    version = manifest.get("version") if manifest and manifest.get("name") == plugin else ""
    return version if isinstance(version, str) and SAFE_VERSION_RE.fullmatch(version) and ".." not in version else ""


def trusted_script(ctx: Context, raw_token: str) -> Tuple[str, str, str]:
    """Validate one raw script-path token against exact selected provenance.
    Returns (provider, plugin, script basename) or raises PolicyFailure."""
    if "$" in raw_token or "`" in raw_token or "~" in raw_token:
        raise PolicyFailure("helper.path", "installed helper path must be literal")
    raw = Path(raw_token)
    if not raw.is_absolute() or ".." in raw.parts or "." in raw.parts or "//" in raw_token or os.path.normpath(raw_token) != raw_token:
        raise PolicyFailure("helper.path", "installed helper path must be literal, absolute, normalized, and traversal-free")
    provider = ""
    trusted_root = None
    for name, root in (("claude", cache_roots(ctx)[0]), ("codex", cache_roots(ctx)[1])):
        try:
            canonical(raw).relative_to(root)
        except ValueError:
            continue
        provider = name
        trusted_root = root
        break
    if trusted_root is None:
        raise PolicyFailure("helper.provenance", "helper is outside the trusted selected plugin caches")
    # No symlink may sit anywhere below the trusted cache root: the raw path
    # is compared component by component against the canonical one.
    try:
        rel_parts = canonical(raw).relative_to(trusted_root).parts
    except ValueError as exc:
        raise PolicyFailure("helper.provenance", "helper is outside the trusted selected plugin caches") from exc
    if len(rel_parts) != 4 or rel_parts[2] != "scripts":
        raise PolicyFailure("helper.provenance", "helper must be immediately under <plugin>/<version>/scripts")
    plugin, version, _, script_name = rel_parts
    if not raw_token.endswith("/%s/%s/scripts/%s" % (plugin, version, script_name)):
        raise PolicyFailure("helper.path", "helper path does not name its canonical plugin/version/scripts location")
    probe = trusted_root
    for part in rel_parts:
        probe = probe / part
        if probe.is_symlink():
            raise PolicyFailure("helper.path", "installed helper path contains a symlink: %s" % probe)
    script = probe
    if not script.is_file() or script.suffix != ".sh" or "/" in script_name or script_name.startswith("."):
        raise PolicyFailure("helper.path", "installed helper must be a regular .sh file")
    if not SAFE_VERSION_RE.fullmatch(version):
        raise PolicyFailure("helper.provenance", "installed helper version directory is malformed")
    selected = selected_claude_version(ctx, plugin) if provider == "claude" else selected_codex_version(ctx, plugin)
    if not selected:
        raise PolicyFailure("helper.selection", "plugin %s is not a selected installed plugin for this provider" % plugin)
    if selected != version:
        raise PolicyFailure("helper.selection", "helper version %s is not the selected installed version (%s)" % (version, selected))
    return provider, plugin, script_name


# ---------------------------------------------------------------------------
# Helper grammar table (basename -> allowed child roles + literal argv grammar)
# ---------------------------------------------------------------------------


def no_args(ctx: Context, script: str, args: List[str]) -> None:
    if args:
        raise PolicyFailure("helper.argv", "%s accepts no arguments" % script)


def pr_status(ctx: Context, script: str, args: List[str]) -> None:
    values = {}
    remaining = list(args)
    while remaining:
        flag = remaining.pop(0)
        if flag not in {"--repo", "--pr", "--snapshot", "--expected-head"} or flag in values or not remaining:
            raise PolicyFailure("helper.argv", "pr-status requires unique known value-taking options")
        values[flag] = remaining.pop(0)
    if "--expected-head" in values and not re.fullmatch(r"[a-f0-9]{40}", values["--expected-head"]):
        raise PolicyFailure("helper.argv", "expected-head requires a full SHA")
    if "--snapshot" in values:
        if "--repo" in values or "--pr" in values:
            raise PolicyFailure("helper.argv", "snapshot cannot be combined with repo/pr")
        literal_file(ctx, values["--snapshot"], "PR snapshot")
    elif (not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*", values.get("--repo", ""))
          or not POSITIVE_RE.fullmatch(values.get("--pr", ""))):
        raise PolicyFailure("helper.argv", "pr-status requires --repo OWNER/NAME --pr NUMBER")


def tmp_roots() -> Tuple[Path, ...]:
    return tuple(canonical(Path(p)) for p in (os.environ.get("TMPDIR", ""), "/tmp") if p)


def literal_file(ctx: Context, value: str, what: str, must_exist: bool = True) -> Path:
    """A literal path operand for a helper: resolves inside an allowed read
    root or the temp dir (staged prompt/snapshot/candidate files live there)."""
    path = candidate_path(value, ctx.pane_cwd)
    if path is None:
        raise PolicyFailure("helper.argv", "%s must be a literal path" % what)
    if must_exist and not path.is_file():
        raise PolicyFailure("helper.argv", "%s must name an existing regular file" % what)
    if not tmp_readable(ctx, path):
        raise PolicyFailure("helper.argv", "%s must live in this pane's cwd, a granted coordination store, or the temp dir" % what)
    return path


def parse_chat_options(args: List[str]) -> List[str]:
    remaining = list(args)
    seen = set()
    while remaining and remaining[0].startswith("--"):
        flag = remaining.pop(0)
        if flag in seen or flag not in {"--priority", "--ttl", "--reply-to", "--task"} or not remaining:
            raise PolicyFailure("helper.argv", "session-chat options are duplicated, unknown, or missing a value")
        seen.add(flag)
        value = remaining.pop(0)
        if flag == "--priority" and value not in {"high", "normal"}:
            raise PolicyFailure("helper.argv", "--priority must be high or normal")
        if flag == "--ttl" and (not POSITIVE_RE.fullmatch(value) or int(value) > 1440):
            raise PolicyFailure("helper.argv", "--ttl must be an integer in 1..1440")
        if flag == "--reply-to" and not REPLY_RE.fullmatch(value):
            raise PolicyFailure("helper.argv", "--reply-to must be a literal correlation id")
        if flag == "--task" and not TASK_ID_RE.fullmatch(value):
            raise PolicyFailure("helper.argv", "--task must be a literal task id")
    return remaining


def require_route_target(ctx: Context, target: str) -> None:
    """Master-only routing: a child may address only the orchestrator; the
    orchestrator may address only its configured executor/reviewer panes."""
    if not LABEL_RE.fullmatch(target):
        raise PolicyFailure("helper.argv", "recipient must be a literal pane name")
    if ctx.semantic_role == "orchestrator":
        if target not in ctx.executor_panes | ctx.reviewer_panes | ctx.route_peers:
            raise PolicyFailure("routing.master", "orchestrator may route only to configured executor/reviewer panes")
    elif target != ctx.orchestrator_pane:
        raise PolicyFailure("routing.master", "executor/reviewer outbound coordination must target the orchestrator pane")


def chat_send(ctx: Context, script: str, args: List[str]) -> None:
    positional = parse_chat_options(args)
    if len(positional) < 2:
        raise PolicyFailure("helper.argv", "%s requires a literal target and a message" % script)
    require_route_target(ctx, positional[0])


def chat_dispatch(ctx: Context, script: str, args: List[str]) -> None:
    positional = parse_chat_options(args)
    if len(positional) != 2:
        raise PolicyFailure("helper.argv", "%s requires a literal target and one prompt-file operand" % script)
    require_route_target(ctx, positional[0])
    literal_file(ctx, positional[1], "dispatch prompt file")


def list_panes(ctx: Context, script: str, args: List[str]) -> None:
    if args not in ([], ["all"], ["--all"]):
        raise PolicyFailure("helper.argv", "list-panes.sh accepts only all or --all")


def pane_health(ctx: Context, script: str, args: List[str]) -> None:
    if len(args) > 2 or any(arg != "--all" and not LABEL_RE.fullmatch(arg) for arg in args):
        raise PolicyFailure("helper.argv", "pane-health.sh accepts one literal pane and optional --all")


def check_replies(ctx: Context, script: str, args: List[str]) -> None:
    remaining = list(args)
    seen = set()
    while remaining:
        flag = remaining.pop(0)
        if flag in seen or flag not in {"--pending", "--since", "--task"}:
            raise PolicyFailure("helper.argv", "check-replies.sh accepts [--pending] [--since MINUTES] [--task ID]")
        seen.add(flag)
        if flag == "--pending":
            continue
        if not remaining:
            raise PolicyFailure("helper.argv", "check-replies.sh accepts [--pending] [--since MINUTES] [--task ID]")
        value = remaining.pop(0)
        if flag == "--since" and not POSITIVE_RE.fullmatch(value):
            raise PolicyFailure("helper.argv", "--since must be a positive integer")
        if flag == "--task" and not TASK_ID_RE.fullmatch(value):
            raise PolicyFailure("helper.argv", "--task must be a literal task id")


def messages_list(ctx: Context, script: str, args: List[str]) -> None:
    remaining = list(args)
    while remaining:
        flag = remaining.pop(0)
        if flag not in {"--from", "--to"} or not remaining or not LABEL_RE.fullmatch(remaining[0]):
            raise PolicyFailure("helper.argv", "%s accepts [--from NAME] [--to NAME]" % script)
        remaining.pop(0)


def messages_clean(ctx: Context, script: str, args: List[str]) -> None:
    remaining = list(args)
    while remaining:
        flag = remaining.pop(0)
        if flag == "--apply":
            continue
        if flag == "--older-than" and remaining and POSITIVE_RE.fullmatch(remaining[0]):
            remaining.pop(0)
            continue
        if flag in {"--from", "--to"} and remaining and LABEL_RE.fullmatch(remaining[0]):
            remaining.pop(0)
            continue
        raise PolicyFailure("helper.argv", "%s accepts [--older-than DAYS] [--from NAME] [--to NAME] [--apply]" % script)


def message_search(ctx: Context, script: str, args: List[str]) -> None:
    if not args or args[0].startswith("-"):
        raise PolicyFailure("helper.argv", "message-search.sh requires a literal pattern first")
    remaining = list(args[1:])
    while remaining:
        flag = remaining.pop(0)
        if flag == "--days" and remaining and POSITIVE_RE.fullmatch(remaining[0]):
            remaining.pop(0)
        elif flag == "--peer" and remaining and LABEL_RE.fullmatch(remaining[0]):
            remaining.pop(0)
        else:
            raise PolicyFailure("helper.argv", "message-search.sh accepts <pattern> [--days N] [--peer NAME]")


def incoming_mode(ctx: Context, script: str, args: List[str]) -> None:
    if len(args) > 1 or (args and args[0] not in {"notify", "assist", "auto", "off"}):
        raise PolicyFailure("helper.argv", "incoming-mode.sh accepts at most one reviewed mode")


def task_status(ctx: Context, script: str, args: List[str]) -> None:
    if not args:
        return
    if len(args) == 1 and (args[0] in {"--all", "--active", "--pending", "--mine", "--by-stage", "--by-workflow"} or LABEL_RE.fullmatch(args[0])):
        return
    if len(args) == 2 and args[0] == "--workflow" and LABEL_RE.fullmatch(args[1]):
        return
    raise PolicyFailure("helper.argv", "task-status.sh arguments are outside its reviewed grammar")


def own_draft_note_file(ctx: Context, script: str, value: str) -> None:
    """--note-file must name this pane's own existing private draft inside the
    validated messages grant (same draft rules as native draft edits and
    dispatch). Delivered messages, peer drafts, symlinks, hardlinks and anything
    outside the drafts namespace are refused. Not an atomic sandbox."""
    refusal = PolicyFailure("helper.argv", "%s --note-file must be this pane's own existing draft inside the messages grant" % script)
    if not value or any(char in value for char in "\n\r\x00") or value.startswith("-"):
        raise refusal
    raw = Path(value).expanduser()
    raw = raw if raw.is_absolute() else ctx.pane_cwd / raw
    if ".." in raw.parts:
        raise refusal
    if not any(raw.parent == root / "drafts" / ctx.pane_name for root in ctx.message_roots):
        raise refusal
    if not own_message_readable(ctx, raw, canonical(raw)):
        raise refusal


def task_transition(note_required: bool, note_file: bool = False) -> Callable[[Context, str, List[str]], None]:
    def check(ctx: Context, script: str, args: List[str]) -> None:
        if "--force" in args:
            raise PolicyFailure("helper.argv", "%s: forced transitions are not routine strict-v1 operations" % script)
        if "--note-file" in args:
            # Closed forms only: <id> --note-file <draft> and, for a contracted
            # task, <id> --generation <N> --note-file <draft>. No inline note.
            if note_file and len(args) == 3 and LABEL_RE.fullmatch(args[0]) and args[1] == "--note-file":
                own_draft_note_file(ctx, script, args[2])
                return
            if note_file and len(args) == 5 and LABEL_RE.fullmatch(args[0]) and args[1] == "--generation" \
                    and POSITIVE_RE.fullmatch(args[2]) and args[3] == "--note-file":
                if not isinstance(contract_actor(ctx, script, args[0]).get("contract"), dict):
                    raise PolicyFailure("task.contract", "the --generation form applies only to a contracted task")
                own_draft_note_file(ctx, script, args[4])
                return
            raise PolicyFailure("helper.argv", "%s accepts --note-file only as <id> [--generation N] --note-file <own draft>" % script)
        if len(args)==4 and LABEL_RE.fullmatch(args[0]) and args[1]=='--generation' and POSITIVE_RE.fullmatch(args[2]) and args[3] and not args[3].startswith('--'):
            if not isinstance(contract_actor(ctx,script,args[0]).get('contract'),dict):
                raise PolicyFailure('task.contract','the --generation form applies only to a contracted task')
            return
        if len(args) not in {1, 2} or not LABEL_RE.fullmatch(args[0]):
            raise PolicyFailure("helper.argv", "%s requires a literal task id and at most one note operand" % script)
        if note_required and len(args) != 2:
            raise PolicyFailure("helper.argv", "%s requires a literal reason/note" % script)

    return check


def task_object(data: object) -> dict:
    """A scheduler task file must be one JSON object whose meta, if present, is an object.

    Anything else is refused as data, never dereferenced: an unexpected shape must
    deny, not crash the hook (a crashed hook does not block the tool call).
    """
    if not isinstance(data, dict):
        raise ValueError("task file is not a JSON object")
    if "meta" in data and not isinstance(data["meta"], dict):
        raise ValueError("task meta is not a JSON object")
    return data


def contract_actor(ctx: Context, script: str, task_id: str) -> dict:
    if ctx.scheduler_root is None:
        raise PolicyFailure('task.contract','contract operation requires the configured scheduler store')
    path=ctx.scheduler_root/'tasks'/(task_id+'.json')
    try:
        if path.is_symlink() or not within(canonical(path),ctx.scheduler_root) or path.stat().st_nlink!=1:
            raise ValueError('unsafe task')
        data=task_object(json.loads(path.read_text()))
        operation=script.replace('task-','').replace('.sh','')
        expected=data.get('assigner') if operation in {'attach','assign','reconcile'} else data.get('reviewer') if operation=='done' or (operation=='block' and data.get('status')=='review') else data.get('assignee')
        if operation!='inspect' and expected!=ctx.pane_name: raise ValueError('actor mismatch')
        if data.get('assigner')!=ctx.orchestrator_pane or data.get('reviewer') not in ctx.reviewer_panes:
            raise ValueError('foreign route')
        if data.get('assignee') and data['assignee'] not in ctx.executor_panes: raise ValueError('foreign executor')
        if ctx.scoped and data.get('meta',{}).get('environment')!=(ctx.environment or 'root'): raise ValueError('foreign scope')
        return data
    except (OSError,ValueError,TypeError,AttributeError):
        raise PolicyFailure('task.contract','contract task identity or route mismatch')


def task_contract(ctx: Context, script: str, args: List[str]) -> None:
    if len(args)<2 or not LABEL_RE.fullmatch(args[1]):
        raise PolicyFailure('helper.argv','task-contract requires a public operation and literal task id')
    operation,task_id=args[:2];rest=args[2:]
    roles={'attach':'orchestrator','verify':'executor','reconcile':'orchestrator','inspect':ctx.semantic_role}
    if operation not in roles or roles[operation]!=ctx.semantic_role:
        raise PolicyFailure('task.contract','contract operation is outside this role')
    contract_actor(ctx,operation,task_id)
    if operation=='attach' and len(rest)==2 and rest[0]=='--spec':
        literal_file(ctx,rest[1],'contract spec');return
    if operation=='inspect' and rest in ([],['--committed'],['--fresh']): return
    if operation=='verify' and len(rest)==4 and rest[0]=='--generation' and POSITIVE_RE.fullmatch(rest[1]) and rest[2]=='--spec-digest' and re.fullmatch(r'[0-9a-f]{64}',rest[3]): return
    if operation=='reconcile' and len(rest)==4 and rest[0]=='--generation' and POSITIVE_RE.fullmatch(rest[1]) and rest[2]=='--note' and rest[3] and not rest[3].startswith('--'): return
    raise PolicyFailure('helper.argv','contract arguments are outside the reviewed grammar')


DEPENDS_RE = re.compile(r"\A[A-Za-z0-9_.-]+(,[A-Za-z0-9_.-]+)*\Z")
META_RE = re.compile(r"\A[A-Za-z0-9_.-]+=[^\r\n]*\Z")


def task_new(ctx: Context, script: str, args: List[str]) -> None:
    if not args or args[0].startswith("-"):
        raise PolicyFailure("helper.argv", "task-new.sh requires a literal task name first")
    remaining = list(args[1:])
    while remaining:
        flag = remaining.pop(0)
        if not remaining:
            raise PolicyFailure("helper.argv", "task-new.sh option %s requires a value" % flag)
        value = remaining.pop(0)
        if flag == "--meta" and META_RE.fullmatch(value):
            continue
        if flag in {"--stage", "--workflow"} and LABEL_RE.fullmatch(value):
            continue
        if flag == "--reviewer" and value in ctx.reviewer_panes:
            continue
        if flag == "--depends-on" and DEPENDS_RE.fullmatch(value):
            continue
        raise PolicyFailure("helper.argv", "task-new.sh accepts <name> [--meta k=v ...] [--stage NAME] [--workflow ID] [--reviewer REVIEWER-PANE] [--depends-on ids]")


def task_assign(ctx: Context, script: str, args: List[str]) -> None:
    if len(args) < 3:
        raise PolicyFailure("helper.argv", "task-assign.sh requires <pane> <id> [options] <prompt-text>")
    pane, task_id = args[0], args[1]
    if pane not in ctx.executor_panes | ctx.reviewer_panes:
        raise PolicyFailure("routing.master", "task-assign.sh may target only configured executor/reviewer panes")
    if not LABEL_RE.fullmatch(task_id):
        raise PolicyFailure("helper.argv", "task-assign.sh requires a literal task id")
    remaining = list(args[2:])
    while remaining and remaining[0].startswith("--"):
        flag = remaining.pop(0)
        if flag == "--force":
            raise PolicyFailure("helper.argv", "task-assign.sh --force is not a routine strict-v1 operation")
        if not remaining:
            raise PolicyFailure("helper.argv", "task-assign.sh option %s requires a value" % flag)
        value = remaining.pop(0)
        if flag == "--eta" and POSITIVE_RE.fullmatch(value):
            continue
        if flag in {"--stage", "--context", "--workflow", "--workflow-id"} and LABEL_RE.fullmatch(value):
            continue
        if flag == "--reviewer" and value in ctx.reviewer_panes:
            continue
        raise PolicyFailure("helper.argv", "task-assign.sh accepts [--eta N] [--stage NAME] [--context NAME] [--reviewer REVIEWER-PANE] [--workflow ID] before the prompt")
    if not remaining:
        raise PolicyFailure("helper.argv", "task-assign.sh requires literal prompt text after the options")


def tasks_clean(ctx: Context, script: str, args: List[str]) -> None:
    remaining = list(args)
    while remaining:
        flag = remaining.pop(0)
        if flag == "--apply":
            continue
        if flag == "--older-than" and remaining and POSITIVE_RE.fullmatch(remaining[0]):
            remaining.pop(0)
            continue
        if flag == "--status" and remaining and LABEL_RE.fullmatch(remaining[0]):
            remaining.pop(0)
            continue
        raise PolicyFailure("helper.argv", "tasks-clean.sh accepts [--older-than DAYS] [--status STATUS] [--apply]")


def one_label(ctx: Context, script: str, args: List[str]) -> None:
    if len(args) != 1 or not LABEL_RE.fullmatch(args[0]):
        raise PolicyFailure("helper.argv", "%s requires exactly one literal name" % script)


def search_contexts(ctx: Context, script: str, args: List[str]) -> None:
    if not args or args[0].startswith("-") or (len(args) == 2 and args[1] != "--list") or len(args) > 2:
        raise PolicyFailure("helper.argv", "search-contexts.sh accepts <pattern> [--list]")


def diff_context(ctx: Context, script: str, args: List[str]) -> None:
    if not args or len(args) > 2 or not LABEL_RE.fullmatch(args[0]):
        raise PolicyFailure("helper.argv", "diff-context.sh accepts <name> [--versions | <timestamp>]")
    if len(args) == 2 and args[1] != "--versions" and not LABEL_RE.fullmatch(args[1]):
        raise PolicyFailure("helper.argv", "diff-context.sh accepts <name> [--versions | <timestamp>]")


def save_context(ctx: Context, script: str, args: List[str]) -> None:
    if len(args) < 2 or not LABEL_RE.fullmatch(args[0]):
        raise PolicyFailure("helper.argv", "save-context.sh requires <name> <snapshot-file> [--handoff] [--expires <UTC-ISO>] [--handoff-data <json-file>]")
    literal_file(ctx, args[1], "save-context.sh snapshot")
    remaining = list(args[2:])
    handoff = False
    handoff_data = False
    while remaining:
        flag = remaining.pop(0)
        if flag == "--handoff":
            handoff = True
            continue
        if flag == "--handoff-data":
            if not remaining or not remaining[0] or remaining[0].startswith("--"):
                raise PolicyFailure("helper.argv", "--handoff-data requires a non-empty file path")
            literal_file(ctx, remaining.pop(0), "save-context.sh handoff data")
            handoff_data = True
            continue
        if flag == "--expires" and remaining and ISO_UTC_RE.fullmatch(remaining[0]):
            remaining.pop(0)
            continue
        raise PolicyFailure("helper.argv", "save-context.sh accepts only --handoff, --expires <UTC-ISO>, and --handoff-data <json-file>")
    if handoff_data and not handoff:
        raise PolicyFailure("helper.argv", "--handoff-data requires --handoff")


def share_context(ctx: Context, script: str, args: List[str]) -> None:
    if len(args) != 2 or not LABEL_RE.fullmatch(args[1]):
        raise PolicyFailure("helper.argv", "share-context.sh requires <target-session> <name>")
    require_route_target(ctx, args[0])


def remove_context(ctx: Context, script: str, args: List[str]) -> None:
    if len(args) != 2 or not LABEL_RE.fullmatch(args[0]) or args[1] != "--confirmed":
        raise PolicyFailure("helper.argv", "remove-context.sh requires <name> --confirmed")


def take_knowledge_store(ctx: Context, args: List[str]) -> List[str]:
    """Strip one optional leading `--store PATH`; the store must be a literal
    path inside an allowed read root (the project's own memory store)."""
    remaining = list(args)
    if remaining[:1] == ["--store"]:
        if len(remaining) < 2:
            raise PolicyFailure("helper.argv", "knowledge --store requires one literal path")
        store = candidate_path(remaining[1], ctx.pane_cwd)
        if store is None or not readable(ctx, store):
            raise PolicyFailure("helper.argv", "knowledge --store must be a literal path inside this pane's cwd or a granted store")
        remaining = remaining[2:]
    if "--store" in remaining:
        raise PolicyFailure("helper.argv", "knowledge --store may appear once, before the command/query")
    return remaining


def store_only(ctx: Context, script: str, args: List[str]) -> None:
    if take_knowledge_store(ctx, args):
        raise PolicyFailure("helper.argv", "%s accepts only an optional --store PATH" % script)


def memory_lint(ctx: Context, script: str, args: List[str]) -> None:
    remaining = take_knowledge_store(ctx, args)
    if not remaining:
        return
    if remaining == ["--fix"] and ctx.semantic_role == "orchestrator":
        return
    raise PolicyFailure("helper.argv", "memory-lint.sh accepts [--store PATH]; --fix is an orchestrator-only write")


def knowledge_init(ctx: Context, script: str, args: List[str]) -> None:
    remaining = take_knowledge_store(ctx, args)
    if remaining not in ([], ["--apply"]):
        raise PolicyFailure("helper.argv", "init.sh accepts [--store PATH] [--apply]")


def docs_write(ctx: Context, script: str, args: List[str]) -> None:
    if len(args) != 2 or args[0] != "--repo":
        raise PolicyFailure("helper.argv", "docs-write.sh requires --repo PATH")
    repo = candidate_path(args[1], ctx.pane_cwd)
    if repo is None or not within(repo, ctx.pane_cwd):
        raise PolicyFailure("helper.argv", "docs-write.sh --repo must be a literal path inside this pane's cwd")


def memory_search(ctx: Context, script: str, args: List[str]) -> None:
    remaining = take_knowledge_store(ctx, args)
    seen = set()
    while remaining and remaining[0].startswith("--"):
        flag = remaining.pop(0)
        if flag == "--":
            break
        if flag in seen or flag not in {"--limit", "--json", "--recall"}:
            raise PolicyFailure("helper.argv", "memory-search.sh accepts [--store PATH] [--limit N] [--json|--recall] <query...>")
        seen.add(flag)
        if flag == "--limit":
            if not remaining or not re.fullmatch(r"[0-9]+", remaining[0]):
                raise PolicyFailure("helper.argv", "memory-search.sh --limit requires a non-negative integer")
            remaining.pop(0)
    if {"--json", "--recall"} <= seen:
        raise PolicyFailure("helper.argv", "memory-search.sh --json and --recall are mutually exclusive")
    if not remaining or any(not value or value.startswith("--") for value in remaining):
        raise PolicyFailure("helper.argv", "memory-search.sh requires a non-option literal query")


def memory_backlinks(ctx: Context, script: str, args: List[str]) -> None:
    remaining = take_knowledge_store(ctx, args)
    if not remaining:
        raise PolicyFailure("helper.argv", "memory-backlinks.sh requires a reviewed graph command")
    command, rest = remaining[0], remaining[1:]
    if command in {"report", "orphans", "components"} and not rest:
        return
    if command in {"neighbors", "reverse"} and len(rest) == 1 and LABEL_RE.fullmatch(rest[0]):
        return
    if command == "expand" and rest and all(LABEL_RE.fullmatch(value) for value in rest):
        return
    if command == "graph" and (not rest or (len(rest) == 2 and rest[0] == "--format" and rest[1] in {"json", "dot", "mermaid"})):
        return
    raise PolicyFailure("helper.argv", "memory-backlinks.sh arguments are outside its reviewed read-only grammar")


def memory_remember(ctx: Context, script: str, args: List[str]) -> None:
    remaining = take_knowledge_store(ctx, args)
    if remaining[:1] == ["--list"]:
        if remaining[1:] not in ([], ["--expired-only"], ["--dismissed"], ["--expired-only", "--dismissed"], ["--dismissed", "--expired-only"]):
            raise PolicyFailure("helper.argv", "memory-remember.sh --list accepts only --expired-only and --dismissed")
        return
    if len(remaining) == 2 and remaining[0] == "--staged":
        literal_file(ctx, remaining[1], "memory-remember.sh --staged file")
        return
    raise PolicyFailure("helper.argv", "memory-remember.sh accepts [--store PATH] --staged FILE | [--store PATH] --list [--expired-only]")


def memory_auto_capture(ctx: Context, script: str, args: List[str]) -> None:
    remaining = take_knowledge_store(ctx, args)
    if not remaining or len(remaining) % 2:
        raise PolicyFailure("helper.argv", "memory-auto-capture.sh requires --staged FILE pairs")
    for index in range(0, len(remaining), 2):
        if remaining[index] != "--staged":
            raise PolicyFailure("helper.argv", "memory-auto-capture.sh accepts only --staged FILE pairs")
        literal_file(ctx, remaining[index + 1], "memory-auto-capture.sh --staged file")


SHA_RE = re.compile(r"\A[a-f0-9]{64}\Z")
MEMORY_WRITE_SUBCOMMANDS = {"capture", "apply", "index", "retire", "purge", "bootstrap", "unlock", "dismiss", "restore"}
MEMORY_WRITE_PATH_FLAGS = {"--staged", "--staged-target", "--staged-index", "--confirm", "--manifest"}
MEMORY_WRITE_SHA_FLAGS = {"--expect-target", "--expect-index", "--expect-candidate", "--idempotency-key"}
MEMORY_WRITE_LABEL_FLAGS = {"--target", "--candidate", "--slug", "--ids"}


def memory_write(ctx: Context, script: str, args: List[str]) -> None:
    """memory-write.sh is the single CAS write path of the knowledge store;
    only the orchestrator drives it, and only with literal flag/value pairs."""
    if not args or args[0] not in MEMORY_WRITE_SUBCOMMANDS:
        raise PolicyFailure("helper.argv", "memory-write.sh requires a reviewed subcommand")
    remaining = list(args[1:])
    while remaining:
        flag = remaining.pop(0)
        if flag == "--expired":
            continue
        if not flag.startswith("--") or not remaining:
            raise PolicyFailure("helper.argv", "memory-write.sh accepts only literal --flag value pairs")
        value = remaining.pop(0)
        if flag == "--store":
            store = candidate_path(value, ctx.pane_cwd)
            if store is None or not readable(ctx, store):
                raise PolicyFailure("helper.argv", "memory-write.sh --store must be inside this pane's cwd or a granted store")
        elif flag in MEMORY_WRITE_PATH_FLAGS:
            literal_file(ctx, value, "memory-write.sh %s" % flag, must_exist=False)
        elif flag in MEMORY_WRITE_SHA_FLAGS:
            if not (SHA_RE.fullmatch(value) or (flag == "--expect-target" and value == "absent")):
                raise PolicyFailure("helper.argv", "memory-write.sh %s requires a sha256 (or absent)" % flag)
        elif flag in MEMORY_WRITE_LABEL_FLAGS:
            if not DEPENDS_RE.fullmatch(value):
                raise PolicyFailure("helper.argv", "memory-write.sh %s requires a literal name/id list" % flag)
        else:
            raise PolicyFailure("helper.argv", "memory-write.sh option is outside its reviewed grammar: %s" % flag)


WORKSPACE_VERB_SCRIPT = {
    "jev": "workspace-jev.sh",
    "plan": "workspace-plan.sh",
    "status": "workspace-status.sh",
    "doctor": "workspace-doctor.sh",
    "harness-status": "harness-status.sh",
    "harness-doctor": "harness-doctor.sh",
    "start": "workspace-start.sh",
    "stop": "workspace-stop.sh",
    "restart": "workspace-restart.sh",
    "reconcile": "workspace-reconcile.sh",
    "install": "workspace-install.sh",
    "browser-config": "workspace-browser-config.sh",
}


def workspace_args(ctx: Context, script: str, args: List[str], bare_flags: Tuple[str, ...], allow_target: bool = True, value_flags: Tuple[str, ...] = ()) -> None:
    remaining = list(args)
    positional = 0
    while remaining:
        arg = remaining.pop(0)
        if arg in bare_flags:
            continue
        if arg == "--config":
            if not remaining:
                raise PolicyFailure("helper.argv", "%s --config requires a path" % script)
            path = candidate_path(remaining.pop(0), ctx.pane_cwd)
            if path is None or path != ctx.config_path:
                raise PolicyFailure("helper.argv", "%s --config must name this workspace's config" % script)
            continue
        if arg in value_flags:
            if not remaining or remaining[0].startswith("-"):
                raise PolicyFailure("helper.argv", "%s %s requires a value" % (script, arg))
            value = remaining.pop(0)
            if arg == "--provider" and value not in {"codex", "claude", "all"}:
                raise PolicyFailure("helper.argv", "%s --provider must be codex|claude|all" % script)
            if arg == "--target" and candidate_path(value, ctx.pane_cwd) is None:
                raise PolicyFailure("helper.argv", "%s --target must be a literal path" % script)
            continue
        if allow_target and not arg.startswith("-") and LABEL_RE.fullmatch(arg) and positional == 0:
            positional += 1
            continue
        raise PolicyFailure("helper.argv", "%s argument is outside its reviewed grammar: %s" % (script, arg))


def workspace_read(ctx: Context, script: str, args: List[str]) -> None:
    workspace_args(ctx, script, args, ("--json",))


def workspace_start(ctx: Context, script: str, args: List[str]) -> None:
    workspace_args(ctx, script, args, ("--no-agents", "--no-services", "--no-attach", "--adopt", "--confirmed"))


def workspace_stop(ctx: Context, script: str, args: List[str]) -> None:
    workspace_args(ctx, script, args, ("--no-save", "--confirmed", "--all"))


def workspace_restart(ctx: Context, script: str, args: List[str]) -> None:
    workspace_args(ctx, script, args, ("--no-save", "--no-agents", "--no-services", "--no-attach"))


def workspace_reconcile(ctx: Context, script: str, args: List[str]) -> None:
    workspace_args(ctx, script, args, ("--apply", "--adopt", "--confirmed"))


def workspace_install(ctx: Context, script: str, args: List[str]) -> None:
    workspace_args(ctx, script, args, ("--dry-run",), allow_target=False, value_flags=("--target",))


def workspace_browser_config(ctx: Context, script: str, args: List[str]) -> None:
    workspace_args(ctx, script, args, ("--apply", "--json"), allow_target=False, value_flags=("--provider", "--browser"))


def jev_command(ctx: Context, script: str, args: List[str]) -> None:
    if ctx.semantic_role != "orchestrator":
        raise PolicyFailure("coordination.write", "diagnostic inference is coordinator-only")
    remaining = list(args)
    environment = ""
    seen = set()
    while remaining:
        flag = remaining.pop(0)
        if flag in seen:
            raise PolicyFailure("helper.argv", "duplicate Jev option")
        seen.add(flag)
        if flag in {"--status", "--sanitized"}:
            continue
        if flag not in {"--config", "--environment", "--packet"} or not remaining:
            raise PolicyFailure("helper.argv", "unknown Jev option")
        value = remaining.pop(0)
        if flag == "--config" and candidate_path(value, ctx.pane_cwd) != ctx.config_path:
            raise PolicyFailure("helper.argv", "Jev config must be this workspace")
        if flag == "--environment":
            if not LABEL_RE.fullmatch(value):
                raise PolicyFailure("helper.argv", "invalid environment")
            environment = value
        if flag == "--packet":
            literal_file(ctx, value, "sanitized diagnostic packet")
    if ctx.environment and environment != ctx.environment:
        raise PolicyFailure("routing.scope", "Jev environment must match local scope")


def environment_command(ctx: Context, script: str, args: List[str]) -> None:
    if not args or args[0] not in {"plan", "status", "start", "stop", "restart", "reconcile"}:
        raise PolicyFailure("helper.argv", "environment helper requires a lifecycle verb")
    if args[0] not in {"plan", "status"} and ctx.semantic_role != "orchestrator":
        raise PolicyFailure("coordination.write", "only coordinators manage environments")
    rest = args[1:]
    if rest.count("--environment") != 1:
        raise PolicyFailure("helper.argv", "exactly one --environment is required")
    i = rest.index("--environment")
    if i + 1 >= len(rest) or not LABEL_RE.fullmatch(rest[i+1]):
        raise PolicyFailure("helper.argv", "environment requires a literal id")
    if ctx.environment and rest[i+1] != ctx.environment:
        raise PolicyFailure("routing.scope", "environment selector escapes this coordinator scope")
    workspace_args(ctx, script, rest, ("--services", "--development", "--json", "--confirmed", "--no-save", "--no-agents", "--no-services", "--no-attach", "--apply"), allow_target=False, value_flags=("--environment",))


def workspace_dispatcher(ctx: Context, script: str, args: List[str]) -> None:
    if "--environment" in args and args and args[0] != "jev":
        environment_command(ctx, script, args)
        return
    if args == ["--contract"]:
        return
    if not args or args[0] not in WORKSPACE_VERB_SCRIPT:
        raise PolicyFailure("helper.argv", "workspace.sh requires a reviewed verb")
    target = WORKSPACE_VERB_SCRIPT[args[0]]
    validate_helper(ctx, "session-workspace", target, args[1:])


UUID_RE = re.compile(r"\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\Z")


def sessions_filter(ctx: Context, script: str, args: List[str]) -> None:
    if len(args) > 1 or (args and args[0] != "all" and candidate_path(args[0], ctx.pane_cwd) is None and not LABEL_RE.fullmatch(args[0])):
        raise PolicyFailure("helper.argv", "%s accepts at most one literal project path, name, or all" % script)


def session_search(ctx: Context, script: str, args: List[str]) -> None:
    if len(args) != 1 or args[0].startswith("-"):
        raise PolicyFailure("helper.argv", "search-sessions.sh requires exactly one literal query")


def session_delete(ctx: Context, script: str, args: List[str]) -> None:
    if len(args) != 2 or not UUID_RE.fullmatch(args[0]) or args[1] != "--confirmed":
        raise PolicyFailure("helper.argv", "delete-session.sh requires <session-uuid> --confirmed")


# Helper table: basename -> (allowed roles, exact argv grammar). Roles:
# o=orchestrator e=executor r=reviewer. EVERY entry carries a reviewed
# grammar -- there is no grammar-less pass for any role. A helper absent from
# this table (broadcast, internal helpers, unknown basenames)
# is denied for every role. Both providers' basenames are listed where the
# Claude and Codex trees name the same helper differently.
HELPERS = {
    "session-chat": {
        "send-message.sh": ("oer", chat_send),
        "dispatch-to-session.sh": ("oer", chat_dispatch),
        "get-my-name.sh": ("oer", no_args),
        "list-panes.sh": ("oer", list_panes),
        "pane-health.sh": ("oer", pane_health),
        "check-replies.sh": ("oer", check_replies),
        "messages-list.sh": ("oer", messages_list),
        "list-messages.sh": ("oer", messages_list),
        "message-search.sh": ("oer", message_search),
        "incoming-mode.sh": ("oer", incoming_mode),
        "messages-clean.sh": ("o", messages_clean),
        "clean-messages.sh": ("o", messages_clean),
    },
    "session-scheduler": {
        "task-status.sh": ("oer", task_status),
        "task-board.sh": ("oer", no_args),
        "scheduler-doctor.sh": ("oer", no_args),
        "task-new.sh": ("o", task_new),
        "task-assign.sh": ("o", task_assign),
        "task-contract.sh": ("oer", task_contract),
        "tasks-clean.sh": ("o", tasks_clean),
        "task-review.sh": ("e", task_transition(note_required=True)),
        "task-done.sh": ("er", task_transition(note_required=False, note_file=True)),
        "task-block.sh": ("er", task_transition(note_required=True, note_file=True)),
    },
    "knowledge": {
        "list-contexts.sh": ("oer", no_args),
        "load-context.sh": ("oer", one_label),
        "search-contexts.sh": ("oer", search_contexts),
        "diff-context.sh": ("oer", diff_context),
        "save-context.sh": ("oer", save_context),
        "share-context.sh": ("oer", share_context),
        "memory-search.sh": ("oer", memory_search),
        "memory-backlinks.sh": ("oer", memory_backlinks),
        "doctor.sh": ("oer", store_only),
        "memory-lint.sh": ("oer", memory_lint),
        "check-freshness.sh": ("oer", no_args),
        "validate-links.sh": ("oer", no_args),
        "check-todos.sh": ("oer", no_args),
        "memory-remember.sh": ("oe", memory_remember),
        "memory-auto-capture.sh": ("oe", memory_auto_capture),
        "memory-write.sh": ("o", memory_write),
        "memory-index.sh": ("o", store_only),
        "init.sh": ("o", knowledge_init),
        "remove-context.sh": ("o", remove_context),
        "docs-write.sh": ("o", docs_write),
    },
    "session-workspace": {
        "pr-status.sh": ("o", pr_status),
        "workspace-plan.sh": ("oer", workspace_read),
        "workspace-status.sh": ("oer", workspace_read),
        "workspace-doctor.sh": ("oer", workspace_read),
        "harness-status.sh": ("oer", workspace_read),
        "harness-doctor.sh": ("oer", workspace_read),
        "validate-config.sh": ("oer", workspace_read),
        "workspace.sh": ("oer", workspace_dispatcher),
        "workspace-environment.sh": ("oer", environment_command),
        "workspace-jev.sh": ("o", jev_command),
        "workspace-start.sh": ("o", workspace_start),
        "workspace-stop.sh": ("o", workspace_stop),
        "workspace-restart.sh": ("o", workspace_restart),
        "workspace-reconcile.sh": ("o", workspace_reconcile),
        "workspace-install.sh": ("o", workspace_install),
        "workspace-browser-config.sh": ("o", workspace_browser_config),
    },
    "session-manager": {
        "list-sessions.sh": ("o", sessions_filter),
        "session-stats.sh": ("o", sessions_filter),
        "search-sessions.sh": ("o", session_search),
        "delete-session.sh": ("o", session_delete),
        "delete-all-sessions.sh": ("o", sessions_filter),
    },
}
ROLE_LETTER = {"orchestrator": "o", "executor": "e", "reviewer": "r"}
INTERPRETER_NAMES = {"bash", "sh", "zsh", "dash", "ksh", "python3", "python", "perl", "source", "."}
WRAPPER_NAMES = {"env", "command", "builtin", "exec", "nohup", "time"}


def is_helper_attempt(tokens: List[str]) -> bool:
    """True when any segment EXECUTES something under a plugin cache (directly,
    through an interpreter, or behind a reviewed wrapper prefix). A cache path
    in an operand position (e.g. `cat <cache>/README.md`) is a read, not an
    attempt."""
    for segment in segments(tokens):
        argv = parse_wrappers(segment).argv
        if not argv:
            continue
        if "/plugins/cache/" in argv[0]:
            return True
        if Path(argv[0]).name in INTERPRETER_NAMES and len(argv) > 1 and "/plugins/cache/" in argv[1]:
            return True
    return False


def helper_invocation(ctx: Context, tokens: List[str], raw: str) -> Optional[Tuple[str, str, List[str]]]:
    """If the command is (or pretends to be) an installed-helper invocation,
    validate it as ONE literal `bash <selected script> args...` segment and
    return (plugin, script, args). Returns None when no cache script is
    executed at all. Raises PolicyFailure on any malformed attempt."""
    if not is_helper_attempt(tokens):
        return None
    if any(is_control(token) for token in tokens) or has_unquoted_expansion(raw):
        raise PolicyFailure("helper.segment", "installed helpers require one literal, uncomposed Bash segment")
    if len(tokens) < 2 or tokens[0] != "bash":
        raise PolicyFailure("helper.launch", "installed helpers require literal `bash` followed by one canonical script path")
    _, plugin, script_name = trusted_script(ctx, tokens[1])
    args = tokens[2:]
    if any("\n" in arg or "\r" in arg or "\x00" in arg for arg in args):
        raise PolicyFailure("helper.argv", "helper arguments must be single-line literal argv")
    if any("/plugins/cache/" in arg for arg in args):
        raise PolicyFailure("helper.argv", "helper arguments must not name another installed script")
    return plugin, script_name, args


def scoped_task(ctx: Context, script: str, args: List[str]) -> None:
    expected = ctx.environment or "root"
    if script == "task-new.sh":
        fields = [args[i+1] for i, a in enumerate(args[:-1]) if a == "--meta" and args[i+1].startswith("environment=")]
        if fields != ["environment=" + expected]:
            raise PolicyFailure("task.scope", "scoped task creation requires exactly one --meta environment=" + expected)
        return
    indices = {"task-assign.sh": 1, "task-done.sh": 0, "task-block.sh": 0, "task-review.sh": 0}
    if script not in indices:
        return
    index = indices[script]
    if len(args) <= index or not LABEL_RE.fullmatch(args[index]) or ctx.scheduler_root is None:
        raise PolicyFailure("task.scope", "scoped task requires a valid id and configured scheduler grant")
    task = ctx.scheduler_root / "tasks" / (args[index] + ".json")
    try:
        if not within(canonical(task), ctx.scheduler_root) or task.is_symlink() or task.stat().st_nlink != 1:
            raise ValueError("unsafe task")
        data = task_object(json.loads(task.read_text()))
        if data.get("meta", {}).get("environment") != expected:
            raise ValueError("foreign task")
        allowed_assignees = ctx.executor_panes | ctx.reviewer_panes
        if data.get("assignee") and data["assignee"] not in allowed_assignees:
            raise ValueError("foreign assignee")
        if data.get("reviewer") and data["reviewer"] not in ctx.reviewer_panes:
            raise ValueError("foreign reviewer")
        if data.get("assigner") and data["assigner"] != ctx.orchestrator_pane:
            raise ValueError("foreign assigner")
    except (OSError, ValueError, TypeError, AttributeError):
        raise PolicyFailure("task.scope", "task does not belong to this environment")


def validate_helper(ctx: Context, plugin: str, script: str, args: List[str]) -> None:
    table = HELPERS.get(plugin)
    if not table or script not in table:
        raise PolicyFailure("helper.allowlist", "helper has no reviewed strict-v1 grammar: %s/%s" % (plugin, script))
    roles, grammar = table[script]
    if ROLE_LETTER[ctx.semantic_role] not in roles:
        raise PolicyFailure("coordination.write", "%s is not a %s operation in strict-v1" % (script, ctx.semantic_role))
    if ctx.scoped and plugin == "session-scheduler":
        scoped_task(ctx, script, args)
    if ctx.environment and plugin == "session-workspace":
        mutating = {"workspace-start.sh", "workspace-stop.sh", "workspace-restart.sh", "workspace-reconcile.sh"}
        if script in mutating and (not args or args[0] not in ctx.session_ids or "--all" in args):
            raise PolicyFailure("routing.scope", "local lifecycle requires an explicitly owned session")
        if script in {"workspace-install.sh", "workspace-browser-config.sh"}:
            raise PolicyFailure("routing.scope", "workspace installation/browser config belongs to root coordinator")
    if ctx.environment and (plugin, script) in {("session-scheduler", "tasks-clean.sh"), ("session-chat", "messages-clean.sh"), ("session-chat", "clean-messages.sh"), ("session-manager", "delete-all-sessions.sh"), ("session-manager", "delete-session.sh")}:
        raise PolicyFailure("routing.scope", "shared-store cleanup belongs to root coordinator")
    grammar(ctx, script, args)


# ---------------------------------------------------------------------------
# Role rules
# ---------------------------------------------------------------------------


def validate_reviewer_read(tokens: List[str], command: str, ctx: Context, base: Optional[Path] = None) -> Optional[str]:
    base = ctx.pane_cwd if base is None else base
    if has_unquoted_expansion(command) or any(is_control(token) for token in tokens):
        raise PolicyFailure("reviewer.shell", "reviewer commands must be one literal read-only segment without expansion, pipes, or redirection")
    if has_unquoted_glob(command):
        raise PolicyFailure("path.dynamic", "unquoted glob/brace expansion produces operands the policy cannot resolve; quote the pattern or name the files")
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", tokens[0]) or Path(tokens[0]).name in WRAPPER_NAMES or Path(tokens[0]).name in PRIVILEGE_WRAPPERS:
        raise PolicyFailure("reviewer.shell", "reviewer launch wrappers and environment assignments are forbidden")
    if "/" in tokens[0] or tokens[0].startswith("~"):
        raise PolicyFailure("reviewer.command", "reviewer commands must be bare PATH names, never a path to an executable: %s" % tokens[0])
    executable = command_basename(tokens)
    message_read = message_read_guard(ctx, tokens, base)
    if file_list_read(tokens):
        raise PolicyFailure("reviewer.file_list", "restricted reads cannot load additional file operands from a NUL-separated list; name each file literally")
    if executable == "git":
        sub, index = git_subcommand(tokens)
        if sub not in READ_GIT:
            raise PolicyFailure("reviewer.git", "reviewer Git requires an exact read-only subcommand")
        if not git_is_read_only(tokens):
            raise PolicyFailure("reviewer.git", "reviewer Git write/output/external-execution options are forbidden")
        ensure_paths_within(tokens, base, lambda p: reviewer_readable(ctx, p), "reviewer.path")
        return
    if executable in {"sed", "awk", "perl"}:
        # Script-taking tools can write (sed w/W, s///w, -i) or exec (awk
        # system(), perl); they are excluded from the reviewer set entirely
        # rather than pattern-scanned, which is fail-open.
        raise PolicyFailure("reviewer.sed", "reviewer %s is not read-only: script-taking tools can write or execute" % executable)
    if executable not in READ_COMMANDS:
        raise PolicyFailure("reviewer.command", "reviewer executable is not read-only allowlisted: %s" % (executable or "?"))
    option_tokens = tokens[1:]
    if executable in {"grep", "rg"}:
        # Inspect flags, never letters in a consumed pattern/file value.
        # Unknown short forms retain the previous conservative inspection.
        option_tokens = [value for kind, value in argv_fields(tokens)
                         if kind == "option" or (kind == "candidate" and value.startswith("-"))]
    if executable == "rg":
        # The tool's environment/config may differ from the hook's. Require
        # an unambiguous argv option rather than inspecting that mutable input
        # or mistaking an -e pattern/operand named --no-config for the flag.
        if len(tokens) < 2 or tokens[1] != "--no-config":
            raise PolicyFailure("reviewer.search", "restricted ripgrep reads require rg --no-config as the command prefix")
        for token in option_tokens:
            if token == "--":
                break
            if (token.split("=", 1)[0] in {"--hostname-bin", "--search-zip"} or
                    (token.startswith("-") and not token.startswith("--") and "z" in token[1:])):
                raise PolicyFailure("reviewer.search", "restricted ripgrep reads cannot invoke hostname programs or decompressors")
    # Canonicalizing operands cannot inspect symlinks reached during recursive
    # traversal. Refuse follow flags, including bundled short-option forms.
    short_follow = {"rg": "L", "grep": "RS", "find": "L", "du": "L", "ls": "L", "diff": "rR"}.get(executable, "")
    long_follow = {"rg": {"--follow"}, "grep": {"--dereference-recursive", "--dereference-files"},
                   "find": {"-follow"}, "du": {"--dereference"},
                   "ls": {"--dereference"}, "diff": {"--recursive"}}.get(executable, set())
    for token in option_tokens:
        if token == "--":
            break
        if short_follow and (token.split("=", 1)[0] in long_follow or
                             (token.startswith("-") and not token.startswith("--") and any(c in token[1:] for c in short_follow))):
            raise PolicyFailure("reviewer.symlink_follow", "reviewer recursive symlink traversal is forbidden")
    if executable == "diff":
        for _, path, _ in argv_paths(tokens, base):
            if path.is_dir():
                raise PolicyFailure("reviewer.symlink_follow", "reviewer diff requires file operands; directory comparison follows leaf symlinks")
    if executable == "find" and any(token in {"-delete", "-exec", "-execdir", "-fls", "-fprint", "-fprint0", "-fprintf", "-ok", "-okdir"} for token in tokens):
        raise PolicyFailure("reviewer.find", "reviewer find mutation/execution actions are forbidden")
    if executable == "tail" and any(token in {"-f", "-F", "--follow"} or token.startswith("--follow=") for token in tokens):
        raise PolicyFailure("reviewer.tail", "reviewer tail must not follow (never-terminating)")
    if executable in {"rg", "grep"} and any(token in {"--pre", "--pre-glob"} or token.startswith(("--pre=", "--pre-glob=")) for token in option_tokens):
        raise PolicyFailure("reviewer.search", "reviewer search preprocessors are forbidden")
    if executable == "sort" and sort_writes(tokens):
        raise PolicyFailure("reviewer.sort", "reviewer sort output/program options are forbidden")
    ensure_paths_within(tokens, base, lambda p: reviewer_readable(ctx, p), "reviewer.path",
                        extra_read=lambda p: skill_content_readable(ctx, p))
    return "coordination.message_read" if message_read else None


def executable_tokens(segment: List[str]) -> List[str]:
    """The tokens in EXECUTABLE position of one segment: the real command
    (after every reviewed wrapper hop) and, for an interpreter, its script."""
    argv = parse_wrappers(segment).argv
    if not argv:
        return []
    found = [argv[0]]
    if Path(argv[0]).name in INTERPRETER_NAMES:
        for token in argv[1:]:
            if token.startswith("-"):
                continue
            found.append(token)
            break
    return found


def child_transport_bypass(tokens: List[str], child: bool) -> Optional[str]:
    for segment in segments(tokens):
        executable = command_basename(segment)
        if child and executable == "tmux" and any(token in CHILD_TMUX_DENIED for token in segment[1:]):
            return "tmux %s" % next(token for token in segment[1:] if token in CHILD_TMUX_DENIED)
        # An outbound helper EXECUTED any way other than the one canonical
        # trusted invocation (which returned earlier) is a routing bypass; the
        # same basename in an operand position (cat/ls/grep of it) is a read.
        for token in executable_tokens(segment):
            if Path(token).name in OUTBOUND_HELPER_BASENAMES:
                return token
    return None


def segment_mutates(segment: List[str]) -> bool:
    if REDIR_WRITE_MARK in segment:
        return True
    executable = command_basename(segment)
    if not executable:
        return False
    if executable == "sort":
        try:
            return sort_writes(unwrap_prefixes(segment))
        except PolicyFailure:
            return True
    if executable in READ_COMMANDS or executable in CD_COMMANDS or executable == "popd":
        # A directory change mutates nothing by itself; the segments that run
        # inside the new cwd are judged against it by walk_segments.
        return False
    if executable == "git":
        return not git_is_read_only(segment)
    return True


def references_child(segment: List[str], ctx: Context, cwd: Optional[Path] = None) -> bool:
    base = cwd if cwd is not None else ctx.project_root
    child_rel = tuple(str(root.relative_to(base)) for root in ctx.child_roots if within(root, base) and root != base)
    try:
        wrapped = parse_wrappers(segment)
        paths = [candidate_path(value, base, child_rel) for value in wrapped.values]
        paths.append(executable_path(wrapped.argv[0], base) if wrapped.argv else None)
        paths.extend(path for _, path, _ in argv_paths(wrapped.argv, base, child_rel))
        if any(path is not None and any(within(path, root) for root in ctx.child_roots) for path in paths):
            return True
    except PolicyFailure:
        return True
    return False


def validate_tool_workdir(ctx: Context, tool_input: dict) -> None:
    """A tool-level workdir/cwd (Codex shells carry one) must respect the
    same floor as the command it scopes."""
    for key in ("workdir", "cwd"):
        value = tool_input.get(key)
        if not isinstance(value, str) or not value.strip():
            continue
        raw = Path(value.strip()).expanduser()
        path = canonical(raw if raw.is_absolute() else ctx.pane_cwd / raw)
        if ctx.semantic_role in {"executor", "reviewer"} and any(within(path, root) for root in guarded_message_roots(ctx)):
            raise PolicyFailure("coordination.message_traversal", "child tool workdir cannot be inside a message store; read an explicit permitted file from the pane checkout")
        if (ctx.semantic_role == "executor" or ctx.confined_orchestrator) and not within(path, ctx.pane_cwd):
            raise PolicyFailure("executor.containment", "tool workdir escapes the configured child cwd: %s" % value)
        if ctx.semantic_role == "reviewer" and not reviewer_readable(ctx, path):
            raise PolicyFailure("reviewer.path", "tool workdir escapes the reviewer's allowed roots: %s" % value)
        if ctx.semantic_role == "orchestrator" and any(within(path, root) for root in ctx.child_roots):
            raise PolicyFailure("orchestrator.child_write", "orchestrator cannot execute tools from a child-repository cwd: %s" % value)


ESCAPE_FLAG_TOKENS = {
    "--dangerously-bypass-approvals-and-sandbox",
    "--dangerously-bypass-hook-trust",
    "--dangerously-skip-permissions",
    "--permission-mode=bypassPermissions",
}
INLINE_SHELLS = {"bash", "dash", "fish", "sh", "zsh", "ksh"}
INLINE_INTERPRETERS = {"node", "perl", "python", "python3", "ruby", "php"}


def executor_inline_code(segment: List[str]) -> bool:
    executable = command_basename(segment)
    if executable in INLINE_SHELLS:
        return any(len(token) > 1 and token[0] in "-+" and not token.startswith("--") and "c" in token[1:] for token in segment[1:])
    if executable in INLINE_INTERPRETERS:
        return any(token in {"-c", "-e", "--eval", "-r"} for token in segment[1:])
    return executable == "eval"


# gh 2.100.0 reviewed grammar. This is intentionally role-local: never teach
# candidate_path that arbitrary OWNER/NAME strings are not filesystem paths.
GH_REPO_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*\Z")
GH_MUTATIONS = {
    "run": {"rerun", "cancel", "delete"},
    "pr": {"create", "merge", "close", "comment", "review", "edit", "ready", "reopen", "lock", "unlock", "revert", "update-branch"},
    "workflow": {"run", "enable", "disable"},
    "release": {"create", "delete", "upload", "edit", "delete-asset"},
    "repo": {"create", "edit", "delete", "archive", "unarchive", "fork", "rename", "sync"},
}
# Option definitions are (canonical long name, short name, value kind).
# Only formatting values and reviewed repository slots escape path inference.
GH_FORMAT = [("json", "", "format"), ("jq", "q", "format"), ("template", "t", "format")]
GH_REPO = [("repo", "R", "repo")]
# These commands consume operands as data, rather than launching them. All
# other argv containing a literal gh executable are unsupported launch attempts
# (timeout/nice/find -exec included). Inline program strings remain outside the
# root policy's argv floor; this is not a general shell interpreter.
GH_DATA_COMMANDS = {"grep", "rg", "cat", "head", "tail", "echo", "printf", "wc", "ls", "sort", "uniq", "nl", "tr"}
GH_READ_OPTIONS = {
    ("run", "list"): GH_FORMAT + GH_REPO + [("all", "a", "bool"), ("branch", "b", "value"), ("commit", "c", "value"), ("created", "", "value"), ("event", "e", "value"), ("limit", "L", "number"), ("status", "s", "value"), ("user", "u", "value"), ("workflow", "w", "value")],
    ("run", "view"): GH_FORMAT + GH_REPO + [("attempt", "a", "number"), ("exit-status", "", "bool"), ("job", "j", "number"), ("log", "", "bool"), ("log-failed", "", "bool"), ("verbose", "v", "bool")],
    ("pr", "list"): GH_FORMAT + GH_REPO + [("app", "", "value"), ("assignee", "a", "value"), ("author", "A", "value"), ("base", "B", "value"), ("draft", "d", "bool"), ("head", "H", "value"), ("label", "l", "value"), ("limit", "L", "number"), ("search", "S", "value"), ("state", "s", "value")],
    ("pr", "view"): GH_FORMAT + GH_REPO + [("comments", "c", "bool")],
    ("pr", "diff"): GH_REPO + [("color", "", "value"), ("name-only", "", "bool"), ("patch", "", "bool")],
    ("pr", "checks"): GH_FORMAT + GH_REPO + [("required", "", "bool"), ("watch", "", "bool"), ("fail-fast", "", "bool"), ("interval", "i", "number")],
    ("workflow", "list"): GH_FORMAT + GH_REPO + [("all", "a", "bool"), ("limit", "L", "number")],
    ("workflow", "view"): GH_REPO + [("ref", "r", "value"), ("yaml", "y", "bool")],
    ("release", "list"): GH_FORMAT + GH_REPO + [("exclude-drafts", "", "bool"), ("exclude-pre-releases", "", "bool"), ("limit", "L", "number"), ("order", "O", "value")],
    ("release", "view"): GH_FORMAT + GH_REPO,
    ("repo", "view"): GH_FORMAT + [("branch", "b", "value")],
    ("api", ""): [("method", "X", "method"), ("field", "F", "field"), ("raw-field", "f", "raw-field"), ("input", "", "file"), ("jq", "q", "format"), ("template", "t", "format"), ("include", "i", "bool"), ("paginate", "", "bool"), ("slurp", "", "bool"), ("silent", "", "bool")],
}


def gh_endpoint(value: str) -> bool:
    path, _, query = value.partition("?")
    if not re.fullmatch(r"[A-Za-z0-9_./-]+", path) or any(part in {"", ".", ".."} for part in path.rstrip("/").split("/")):
        return False
    if query and not re.fullmatch(r"[A-Za-z0-9_.%=&+,~-]+", query):
        return False
    parts = path.split("/")
    return ((len(parts) >= 4 and parts[0] == "repos" and GH_REPO_RE.fullmatch("/".join(parts[1:3])) is not None)
            or (len(parts) >= 3 and parts[0] == "repositories" and POSITIVE_RE.fullmatch(parts[1]) is not None))


def validate_orchestrator_gh(ctx: Context, tokens: List[str], command: str, tool_input: dict) -> str:
    """One literal builtin gh read; unsupported/mutating gh NEVER falls through.

    Explicit GET can transmit local files. Retain those as real path operands,
    including @file field values; confined coordinators use their existing
    containment, never reviewer grants. No network/config/alias lookup here.
    """
    def unsupported(reason: str) -> None:
        raise PolicyFailure("orchestrator.gh_unsupported", reason)

    if tokens[0] != "gh" or has_unquoted_expansion(command) or has_unquoted_glob(command):
        unsupported("gh requires one literal direct command without wrappers, expansion, composition or redirection")
    # shlex strips quotes. Raw scanning above distinguishes quoted jq | from a
    # shell pipe; do not run is_control over the resulting data values.
    if len(tokens) < 2:
        unsupported("gh requires an exact reviewed subcommand")
    group = tokens[1]
    verb = "" if group == "api" else (tokens[2] if len(tokens) > 2 else "")
    if verb in GH_MUTATIONS.get(group, set()):
        raise PolicyFailure("orchestrator.gh_mutation", "orchestrator gh mutations belong to the owning executor")
    spec = GH_READ_OPTIONS.get((group, verb))
    if spec is None:
        unsupported("gh subcommand is not read-only allowlisted (aliases and extensions are unsupported)")
    options = {}
    for name, short, kind in spec:
        options["--" + name] = (name, kind)
        if short:
            options["-" + short] = (name, kind)
    seen = set()
    positionals: List[str] = []
    paths: List[str] = []
    method = None
    fields = False
    index = 2 if group == "api" else 3
    while index < len(tokens):
        token = tokens[index]
        index += 1
        if not token.startswith("-"):
            positionals.append(token)
            continue
        if token.startswith("--"):
            option, equals, value = token.partition("=")
            attached = bool(equals)
        else:
            option, value = token[:2], token[2:]
            attached = bool(value)
        if option not in options:
            unsupported("gh option is not read-only allowlisted: %s" % option)
        name, kind = options[option]
        if name in seen and kind not in {"field", "raw-field"}:
            unsupported("duplicate gh option is ambiguous: %s" % option)
        seen.add(name)
        if kind == "bool":
            if attached:
                unsupported("gh boolean options require their standalone spelling")
            continue
        if not attached:
            if index >= len(tokens) or tokens[index].startswith("-") and tokens[index] != "-":
                unsupported("gh option requires a literal value: %s" % option)
            value = tokens[index]
            index += 1
        if not value:
            unsupported("empty gh option value")
        if kind == "repo":
            if GH_REPO_RE.fullmatch(value) is None:
                unsupported("gh repository selector must be OWNER/NAME, never a filesystem path")
        elif kind == "method":
            if value != "GET":
                raise PolicyFailure("orchestrator.gh_mutation" if value.upper() != "GET" else "orchestrator.gh_unsupported",
                                    "orchestrator gh api requires the explicit method GET")
            method = value
        elif kind == "number":
            if POSITIVE_RE.fullmatch(value) is None:
                unsupported("gh numeric option requires a positive integer")
        elif kind in {"field", "raw-field"}:
            fields = True
            key, equals, data = value.partition("=")
            if not equals or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
                unsupported("gh fields require a simple literal key=value")
            if kind == "field" and data.startswith("@"):
                filename = data[1:]
                if not filename or filename == "-" or any(c in filename for c in "$`*?{}["):
                    unsupported("gh field file must be a literal filename, not stdin or expansion")
                paths.append(filename if "/" in filename else "./" + filename)
            else:
                if kind == "field" and any(c in data for c in "{}"):
                    unsupported("gh field placeholders are unsupported")
                paths.append(data)
        elif kind == "file":
            fields = True
            if value == "-" or any(c in value for c in "$`*?{}["):
                unsupported("gh input must be a literal filename, not stdin or expansion")
            paths.append(value if "/" in value else "./" + value)
        elif kind != "format":
            paths.append(value)
    if group == "api":
        if fields and method is None:
            raise PolicyFailure("orchestrator.gh_mutation", "gh api fields/input imply POST unless GET is explicit")
        if len(positionals) != 1 or not gh_endpoint(positionals[0]):
            unsupported("gh api requires repos/OWNER/NAME/ or repositories/ID/ endpoint")
    elif (group, verb) == ("repo", "view"):
        if len(positionals) != 1 or GH_REPO_RE.fullmatch(positionals[0]) is None:
            unsupported("gh repo view requires a literal OWNER/NAME")
    else:
        if "repo" not in seen:
            unsupported("gh read requires an explicit OWNER/NAME repository selector")
        if len(positionals) > (0 if verb == "list" else 1):
            unsupported("unexpected gh positional operand")
        if group in {"run", "pr"} and any(POSITIVE_RE.fullmatch(p) is None for p in positionals):
            unsupported("gh run/pr selectors must be numeric in the reviewed grammar")
        paths.extend(positionals)
    if ctx.confined_orchestrator:
        bases = set()
        for key in ("cwd", "workdir"):
            value = tool_input.get(key)
            if isinstance(value, str) and value.strip():
                raw = Path(value.strip()).expanduser()
                bases.add(canonical(raw if raw.is_absolute() else ctx.pane_cwd / raw))
        if len(bases) > 1:
            raise PolicyFailure("executor.containment", "gh tool cwd and workdir disagree")
        base = next(iter(bases)) if bases else ctx.pane_cwd
        ensure_paths_within(["gh", "--"] + paths, base,
                            lambda p: within(p, ctx.pane_cwd) and not any(within(p, r) for r in ctx.message_roots),
                            "executor.containment")
    else:
        # Preserve conservative rejection of dynamic filesystem operands even
        # though root coordinators may read literal child files.
        for value in paths:
            candidate_path(value, ctx.pane_cwd, literal=True)
    return "orchestrator.gh_read"


def validate_bash(ctx: Context, command: str, tool_input: dict) -> Optional[str]:
    if ctx.semantic_role != "orchestrator" or ctx.confined_orchestrator:
        if tool_input.get("dangerouslyDisableSandbox") is True or tool_input.get("with_escalated_permissions") is True:
            raise PolicyFailure("shell.sandbox_escape", "child roles cannot request a sandbox/approval escape")
    validate_tool_workdir(ctx, tool_input)
    reviewer_base = ctx.pane_cwd
    if ctx.semantic_role in {"reviewer", "executor"}:
        bases = set()
        for key in ("cwd", "workdir"):
            value = tool_input.get(key)
            if isinstance(value, str) and value.strip():
                raw = Path(value.strip()).expanduser()
                bases.add(canonical(raw if raw.is_absolute() else ctx.pane_cwd / raw))
        if len(bases) > 1:
            if ctx.semantic_role == "reviewer":
                raise PolicyFailure("reviewer.path", "reviewer tool cwd and workdir disagree")
            reviewer_base = None  # Ambiguous base cannot authorize extra reads.
        elif bases:
            reviewer_base = bases.pop()
            if not reviewer_base.is_dir():
                if ctx.semantic_role == "reviewer":
                    raise PolicyFailure("reviewer.path", "reviewer tool workdir must be an existing directory")
                reviewer_base = None
    if not command.strip():
        raise PolicyFailure("bash.command", "active harness received an empty shell command")
    tokens = parse_shell(command)
    if not tokens:
        raise PolicyFailure("bash.command", "active harness received no shell argv")
    # ONE wrapper grammar for EVERY role, applied to every segment before any
    # other classification: privilege wrappers (sudo/doas/su/runuser/pkexec)
    # and unsupported/dynamic wrapper options (exec -a/-l, nohup --, time -o,
    # env -S/--split-string, ...) fail closed here, so no later classifier
    # ever sees a re-parsed or privileged argv.
    for segment in segments(tokens):
        parse_wrappers(segment)
    # No permission-widening escape hatch for ANY role: the engine refuses
    # these flags in runtimes.*.args, and a nested agent launched with them
    # from a pane would escape every floor above.
    for index, token in enumerate(tokens):
        if token in ESCAPE_FLAG_TOKENS or token.startswith(("--permission-mode=bypassPermissions", "--dangerously-")):
            raise PolicyFailure("shell.sandbox_escape", "sandbox/approval/permission escape flags are outside strict-v1: %s" % token)
        if token == "--permission-mode" and index + 1 < len(tokens) and tokens[index + 1] == "bypassPermissions":
            raise PolicyFailure("shell.sandbox_escape", "sandbox/approval/permission escape flags are outside strict-v1: bypassPermissions")

    # Installed-helper invocations are gated identically for EVERY role: exact
    # selected provenance, one literal segment, reviewed argv grammar, and
    # master-only routing (children -> orchestrator; orchestrator -> its
    # configured executor/reviewer panes).
    helper = helper_invocation(ctx, tokens, command)
    if helper is not None:
        if ctx.semantic_role == "reviewer" and reviewer_base != ctx.pane_cwd:
            raise PolicyFailure("helper.workdir", "reviewer helpers require the configured pane cwd")
        validate_helper(ctx, *helper)
        return
    bypass = child_transport_bypass(tokens, ctx.semantic_role != "orchestrator" or bool(ctx.environment))
    if bypass is not None:
        raise PolicyFailure("routing.master", "coordination transport may only run as the selected session-chat helper (%s)" % bypass)

    if ctx.semantic_role == "orchestrator":
        # shlex otherwise folds newlines into whitespace. Detection must also
        # see a gh command after a newline, or a continued executable spelling;
        # normalization only detects attempts, never authorizes execution.
        gh_detection = parse_shell(command.replace("\\\n", "").replace("\n", ";"))
        for segment in segments(gh_detection):
            argv = unwrap_prefixes(segment)
            if argv and (Path(argv[0]).name == "gh" or (
                Path(argv[0]).name not in GH_DATA_COMMANDS and any(Path(t).name == "gh" for t in argv[1:])
            )):
                return validate_orchestrator_gh(ctx, tokens, command, tool_input)

    if ctx.semantic_role == "reviewer":
        return validate_reviewer_read(tokens, command, ctx, reviewer_base)
    if ctx.semantic_role == "executor" and reviewer_base is not None:
        # Selected plugin content and grants authorize only the existing
        # single-command read grammar, even when read_paths is empty.
        # Never widen arbitrary executor operands or native edit authority.
        try:
            read_rule = validate_reviewer_read(tokens, command, ctx, reviewer_base)
        except PolicyFailure as exc:
            if exc.rule.startswith("coordination.message"):
                raise
            pass  # Ordinary in-checkout executor commands retain their floor.
        else:
            return read_rule
    if ctx.semantic_role == "executor" or ctx.confined_orchestrator:
        # Executor containment for arbitrary shell: no inline shell/interpreter
        # code (an unreadable escape hatch), no operand that only exists after
        # a shell expansion, no operand feeder (xargs), and every path-like
        # operand -- including bare . / .. / ~, quoted paths with spaces, and
        # every cd/pushd target tracked across the composed command -- must
        # resolve inside the configured child cwd (absolute, traversal, and
        # symlink forms alike). Claude has no filesystem sandbox of its own,
        # so this floor is enforced identically on both providers.
        if has_expansion(command):
            raise PolicyFailure("path.dynamic", "executor operands must be literal; shell expansion cannot be resolved by the policy")
        if has_unquoted_glob(command):
            raise PolicyFailure("path.dynamic", "unquoted glob/brace expansion produces operands the policy cannot resolve; quote the pattern or name the files")
        floor_base = (reviewer_base or ctx.pane_cwd) if ctx.semantic_role == "executor" else ctx.pane_cwd
        for segment, cwd, after in walk_segments(tokens, floor_base):
            if ctx.semantic_role == "executor":
                message_read_guard(ctx, segment, cwd)
            if ctx.semantic_role == "orchestrator" and command_basename(segment) == "git" and not git_is_read_only(segment):
                raise PolicyFailure("orchestrator.git", "local coordinator Git mutations belong to its executor")
            if executor_inline_code(segment):
                raise PolicyFailure("executor.inline_code", "executor inline shell/interpreter code is outside strict-v1 containment")
            if command_basename(segment) == "xargs":
                raise PolicyFailure("executor.containment", "xargs feeds unresolvable operands to a command; outside strict-v1 containment")
            if not within(after, ctx.pane_cwd):
                raise PolicyFailure("executor.containment", "cd target escapes the configured child cwd")
            ensure_paths_within(segment, cwd, lambda p: within(p, ctx.pane_cwd) and not any(
                within(p, root) for root in ctx.message_roots), "executor.containment")
        return

    # Orchestrator: shell is free apart from two floor rules. (1) It never
    # pushes: pushes go through the owning executor and the project's own
    # release gate (shared adopter rule). (2) A mutating (non read-only)
    # segment that names a child root, or that RUNS inside one after a cd,
    # is refused.
    for segment, cwd, after in walk_segments(tokens, ctx.pane_cwd):
        argv = unwrap_prefixes(segment)
        if argv and Path(argv[0]).name == "git":
            try:
                sub, _ = git_subcommand(argv)
            except PolicyFailure:
                sub = "push" if "push" in argv[1:] else ""
            if sub == "push":
                raise PolicyFailure("orchestrator.push", "orchestrator cannot run git push; route it to the owning executor")
        exec_cwd = segment_exec_cwd(segment, cwd)
        orchestrator_guard = ctx.guards.get("orchestrator", {})
        if orchestrator_guard.get("deny_child_chdir") is True and (
            any(within(after, root) for root in ctx.child_roots)
            or any(within(exec_cwd, root) for root in ctx.child_roots)
        ):
            raise PolicyFailure("orchestrator.child_chdir", "orchestrator cannot change its execution directory into a child repository")
        if segment_mutates(segment) and (
            references_child(segment, ctx, cwd)
            or references_child(unwrap_prefixes(segment), ctx, exec_cwd)
            or any(within(exec_cwd, root) for root in ctx.child_roots)
        ):
            raise PolicyFailure("orchestrator.child_write", "orchestrator cannot run a mutating/unknown command against a child repository")


def own_message_draft(ctx: Context, raw: Path, path: Path) -> bool:
    """Native edits may address only this pane's drafts, never transport state.
    Grants and identity come from the validated plan, not inherited store paths.
    Checks are not an atomic sandbox against concurrent same-uid filesystem swaps.
    """
    if not DRAFT_NAME_RE.fullmatch(path.name):
        return False
    for root in ctx.message_roots:
        drafts = root / "drafts"
        parent = drafts / ctx.pane_name
        if path.parent != parent:
            continue
        try:
            if any(p.is_symlink() for p in (drafts, parent, raw)):
                return False
            if any(p.exists() and not p.is_dir() for p in (drafts, parent)):
                return False
            if path.exists():
                info = path.stat()
                if not path.is_file() or info.st_nlink != 1 or info.st_uid != os.getuid():
                    return False
        except OSError:
            return False
        return True
    return False


def validate_edit(ctx: Context, tool_input: dict, payload: dict) -> None:
    targets = edit_targets(tool_input)
    if not targets:
        raise PolicyFailure("edit.path", "active harness could not identify an edit target")
    base = ctx.pane_cwd
    for key in ("workdir", "cwd"):
        value = tool_input.get(key)
        if isinstance(value, str) and value.strip():
            base = canonical(Path(value.strip()))
            break
    else:
        value = payload.get("cwd")
        if isinstance(value, str) and value.strip():
            base = canonical(Path(value.strip()))
    resolved = []
    for value in sorted(targets):
        raw = Path(value).expanduser()
        raw = raw if raw.is_absolute() else base / raw
        resolved.append((value, raw, canonical(raw)))
    if ctx.semantic_role in {"reviewer", "executor"} or ctx.confined_orchestrator:
        # Check the lexical path as well: a symlink under the messages grant
        # must not fall through to ordinary checkout edit authority.
        touches_messages = any(
            within(path, root) or within(Path(os.path.abspath(raw)), root)
            for _, raw, path in resolved for root in ctx.message_roots
        )
        if touches_messages:
            moves = any(isinstance(child, str) and PATCH_MOVE_RE.search(child)
                        for _, child in walk(tool_input))
            moves = moves or any(key in {"old_path", "new_path"} for key, _ in walk(tool_input))
            if moves or not all(own_message_draft(ctx, raw, path) for _, raw, path in resolved):
                raise PolicyFailure("coordination.draft", "message edits require only this pane's draft files; transport state, peer drafts, moves, and mixed edits are forbidden")
            return
    for value, raw, path in resolved:
        if ctx.semantic_role == "reviewer":
            raise PolicyFailure("reviewer.readonly", "reviewer panes cannot edit, write, patch, move, or delete files")
        protected = ctx.guards.get("protected_files")
        if ctx.semantic_role == "orchestrator" and within(path, ctx.project_root) and isinstance(protected, dict):
            basename = path.name
            generic = (
                basename == ".env"
                or basename.startswith(".env.")
                or basename in {"google-services.json", "composer.lock", "package-lock.json", "yarn.lock", "pnpm-lock.yaml"}
                or fnmatch.fnmatchcase(basename, "*service_account*.json")
                or fnmatch.fnmatchcase(basename, "*service-account*.json")
                or fnmatch.fnmatchcase(basename, "*firebase*.json")
            )
            extras = protected.get("extra_basenames", [])
            if generic or (isinstance(extras, list) and basename in extras):
                raise PolicyFailure("orchestrator.protected_file", "orchestrator cannot edit protected credential/lockfile: %s" % value)
        if ctx.semantic_role == "executor" or ctx.confined_orchestrator:
            if not within(path, ctx.pane_cwd):
                raise PolicyFailure("executor.containment", "executor edit escapes its configured child cwd: %s" % value)
        elif any(within(path, root) for root in ctx.child_roots):
            raise PolicyFailure("orchestrator.child_write", "orchestrator cannot edit child-repository content: %s" % value)


def extract_command(tool_input: dict) -> Optional[str]:
    for key in ("command", "cmd", "argv"):
        value = tool_input.get(key)
        if isinstance(value, str):
            return value
        if isinstance(value, list) and all(isinstance(item, str) for item in value):
            # Codex-shaped argv. A `<shell> -c/-lc <script>` wrapper is the
            # script; a plain argv is re-rendered fully quoted so it can only
            # ever parse back into the same literal tokens.
            if len(value) == 3 and Path(value[0]).name in {"bash", "sh", "zsh"} and value[1] in {"-c", "-lc", "-lC", "-ec", "-lec"}:
                return value[2]
            return " ".join(shlex.quote(item) for item in value)
    return None


def evaluate(raw: str) -> Decision:
    ctx, bootstrap_denial = load_context()
    if bootstrap_denial is not None:
        return bootstrap_denial
    if ctx is None:
        return allow(None, "")
    if not raw.strip():
        return deny(ctx, "", "input.empty", "active harness received an empty hook payload", integrity=True)
    try:
        payload = json.loads(raw)
    except ValueError:
        return deny(ctx, "", "input.json", "active harness received malformed hook JSON", integrity=True)
    if not isinstance(payload, dict):
        return deny(ctx, "", "input.shape", "active harness hook payload must be a JSON object", integrity=True)

    tool_name = ""
    for key in ("tool_name", "tool"):
        value = payload.get(key)
        if isinstance(value, str):
            tool_name = value
            break
    tool_input = tool_input_of(payload)
    lower = tool_name.lower()
    try:
        if lower in SHELL_TOOL_NAMES or lower.endswith("bash"):
            command = extract_command(tool_input)
            if command is None:
                raise PolicyFailure("bash.command", "active harness could not read the shell command")
            rule = validate_bash(ctx, command, tool_input)
            if rule is not None:
                reason = ("literal read of this pane's delivered message or draft" if rule == "coordination.message_read"
                          else "reviewed literal orchestrator gh read")
                return allow(ctx, tool_name, rule, reason)
        elif lower in EDIT_TOOL_NAMES:
            if lower in {"str_replace_editor", "str_replace_based_edit_tool"} and tool_input.get("command") == "view":
                return allow(ctx, tool_name, "tool.read", "read-only editor view")
            validate_edit(ctx, tool_input, payload)
        else:
            return allow(ctx, tool_name, "tool.unclassified", "tool is outside the strict-v1 floor; not a blanket allowlist")
    except PolicyFailure as exc:
        return deny(ctx, tool_name, exc.rule, exc.reason)
    return allow(ctx, tool_name)


def audit_message(decision: Decision) -> str:
    return "AUDIT by session-workspace strict-v1 [%s]: %s (would deny in enforce mode)" % (decision.rule, decision.reason)


def emit_codex_system_message(message: str) -> None:
    """Render one inert Codex warning without changing the policy decision.

    Codex ignores stderr from an exit-0 PreToolUse hook. Its supported stdout
    contract accepts a top-level ``systemMessage``; deliberately omit every
    decision/rewrite field so this adapter cannot widen provider permissions.
    A broken output stream must never turn an audit-only denial into a block.
    """
    if sys.stdout is None:
        return
    try:
        rendered = json.dumps({"systemMessage": message}, sort_keys=True, separators=(",", ":"))
        sys.stdout.write(rendered + "\n")
        sys.stdout.flush()
    except (AttributeError, BrokenPipeError, OSError, TypeError, UnicodeError, ValueError):
        return


def main(argv: List[str]) -> int:
    allowed = {"--decision-json", "--codex-hook-output"}
    if len(argv) != len(set(argv)) or any(arg not in allowed for arg in argv):
        print("Usage: harness-policy.py [--decision-json] [--codex-hook-output]  (hook payload JSON on stdin)", file=sys.stderr)
        return 2
    decision_json = "--decision-json" in argv
    codex_hook_output = "--codex-hook-output" in argv
    try:
        decision = evaluate(sys.stdin.read())
    except Exception as exc:  # fail closed: a crashed hook would not block the tool call
        decision = deny(None, "", "policy.internal", "strict-v1 policy error (%s); refusing" % type(exc).__name__, integrity=True)
    if decision_json:
        print(json.dumps(decision.normalized(), sort_keys=True, separators=(",", ":")))
        return 0
    if decision.decision == "deny":
        print("BLOCKED by session-workspace strict-v1 [%s]: %s" % (decision.rule, decision.reason), file=sys.stderr)
        return 2
    if decision.decision == "audit":
        message = audit_message(decision)
        if codex_hook_output:
            emit_codex_system_message(message)
        else:
            print(message, file=sys.stderr)
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
