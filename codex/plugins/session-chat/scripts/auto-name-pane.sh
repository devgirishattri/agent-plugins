#!/usr/bin/env bash
# Name only the hook's own session. Missing/lagging metadata leaves it unnamed.
[ -n "${TMUX:-}" ] || exit 0
CURRENT_NAME=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{@name}' 2>/dev/null) || exit 0
[ -z "$CURRENT_NAME" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

SESSION_NAME=$(python3 -c '
import json, os, pathlib, re, sys
try:
    hook = json.load(sys.stdin)
    sid, cwd = hook.get("session_id"), hook.get("cwd")
    if not isinstance(sid, str) or not re.fullmatch(r"[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", sid):
        sys.exit(0)
    if not isinstance(cwd, str) or not os.path.isabs(cwd):
        sys.exit(0)
    def read_name(path):
        try:
            with path.open(encoding="utf-8") as stream:
                meta = json.loads(stream.readline())
                payload = meta.get("payload", {})
                if (meta.get("type") != "session_meta" or payload.get("id") != sid
                        or payload.get("cwd") != cwd):
                    return None
                # Intentional bound: a first prompt beyond 1000 rows stays unnamed.
                for _, line in zip(range(1000), stream):
                    try:
                        row = json.loads(line)
                    except (ValueError, TypeError):
                        continue
                    item = row.get("payload", {})
                    if row.get("type") == "event_msg" and item.get("type") == "user_message":
                        value = item.get("message")
                        return value if isinstance(value, str) else None
        except (OSError, ValueError, TypeError, AttributeError):
            return None
    explicit = hook.get("transcript_path")
    name = read_name(pathlib.Path(explicit)) if isinstance(explicit, str) and os.path.isabs(explicit) else None
    names = [name] if name is not None else []
    if not names:
        # Only scan on a missing/unusable explicit path. Resolve aliases before
        # counting candidates (/var and /private/var identify one macOS file).
        base = pathlib.Path(os.environ.get("CODEX_HOME", str(pathlib.Path.home()/".codex"))) / "sessions"
        paths = {p.resolve() for p in base.rglob("*-" + sid + ".jsonl")}
        for path in paths:
            name = read_name(path)
            if name is not None:
                names.append(name)
    if len(names) != 1:
        sys.exit(0)
    name = re.sub(r"\s+", "-", names[0][:256])
    name = re.sub(r"[^a-zA-Z0-9_-]", "", name)
    print(re.sub(r"-+", "-", name).strip("-")[:48])
except (OSError, ValueError, TypeError, AttributeError):
    pass
' 2>/dev/null) || exit 0

[ -n "$SESSION_NAME" ] || exit 0
# Preserve a manual name assigned while the transcript was read.
CURRENT_NAME=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{@name}' 2>/dev/null) || exit 0
[ -z "$CURRENT_NAME" ] || exit 0
tmux set-option -p -t "${TMUX_PANE:-}" @name "$SESSION_NAME" 2>/dev/null || true
