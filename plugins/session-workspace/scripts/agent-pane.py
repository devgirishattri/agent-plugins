#!/usr/bin/env python3
"""Readiness and busy checks for on-demand worker panes (Python 3.9).

`workspace start SESSION --pane NAME` runs `ready` for each selected agent
pane, so the command returns only once the agent can take a message.
`workspace stop SESSION --pane NAME --confirmed` runs `busy` first, so a
worker is never closed in the middle of its work. Both only read: tmux's
visible screen, the scheduler's task files and the session-chat inbox queues.

ready --pane-id ID [--timeout SECONDS] [--interval SECONDS]
    Exit 0 once the pane's last prompt line is an agent input line: Codex
    draws `›` at column 0, Claude Code `❯` (older versions `│ >` inside a box,
    or `>` under a rule). A numbered choice on that line (`› 1. Yes`) is a
    menu, such as a first-run folder trust question, not an input line.
    Exit 1 on timeout, 2 when the pane is gone or its process exited.

busy --pane-id ID --pane NAME [--tasks-dir DIR] [--queue FILE]...
    Print one line per reason the worker is busy and exit 1, or exit 0:
    a scheduler task assigned to it that is still `assigned`, a task it
    reviews that is in `review`, unread rows in its session-chat inbox
    queue, or a turn running on its screen ("esc to interrupt").
"""
import argparse
import json
import os
import re
import stat
import subprocess
import sys
import time
from pathlib import Path

MENU_RE = re.compile(r"\A(?:›|❯)\s*\d+[.)]\s")
TURN_RE = re.compile(r"esc to interrupt", re.IGNORECASE)


def tmux(*args):
    try:
        run = subprocess.run(["tmux", *args], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return run.stdout if run.returncode == 0 else None


def pane_state(pane_id):
    """'live', 'dead' or 'gone'."""
    out = tmux("display-message", "-p", "-t", pane_id, "#{pane_id}\t#{pane_dead}")
    if out is None or not out.strip():
        return "gone"
    parts = out.strip().split("\t")
    if parts[0] != pane_id:
        return "gone"
    return "dead" if len(parts) > 1 and parts[1] == "1" else "live"


def screen(pane_id):
    return tmux("capture-pane", "-p", "-t", pane_id) or ""


def input_line(text):
    """The last agent prompt line on screen, or None (session-chat's rule)."""
    last = None
    prev = ""
    for line in text.splitlines():
        if line.startswith("›") or line.startswith("❯") or line.startswith("│ >"):
            last = line
        elif line.startswith(">") and prev.startswith("─"):
            last = line
        prev = line
    return last


def cmd_ready(opts):
    deadline = time.monotonic() + opts.timeout
    while True:
        state = pane_state(opts.pane_id)
        if state != "live":
            print("pane %s %s before its agent was ready" % (opts.pane_id, "exited" if state == "dead" else "closed"))
            return 2
        line = input_line(screen(opts.pane_id))
        if line is not None and not MENU_RE.match(line):
            return 0
        if time.monotonic() >= deadline:
            if line is not None:
                print("the agent is showing a choice, not its input line (a first-run question such as folder trust needs an answer in the pane)")
            else:
                print("no agent input line on screen after %gs" % opts.timeout)
            return 1
        time.sleep(opts.interval)


def safe_regular(path):
    try:
        info = path.lstat()
    except OSError:
        return False
    return stat.S_ISREG(info.st_mode)


def cmd_busy(opts):
    reasons = []
    if opts.tasks_dir:
        tasks = Path(opts.tasks_dir)
        if tasks.is_dir() and not tasks.is_symlink():
            for entry in sorted(tasks.glob("*.json")):
                if not safe_regular(entry):
                    continue
                try:
                    task = json.loads(entry.read_text())
                except (OSError, ValueError):
                    continue
                if not isinstance(task, dict):
                    continue
                status = task.get("status")
                task_id = str(task.get("id") or entry.stem)
                if task.get("assignee") == opts.pane and status == "assigned":
                    reasons.append("task %s is assigned to it and not finished" % task_id)
                elif task.get("reviewer") == opts.pane and status == "review":
                    reasons.append("task %s is waiting for its review" % task_id)
    for queue in opts.queue or []:
        path = Path(queue)
        if not safe_regular(path):
            continue
        try:
            rows = [line for line in path.read_text().splitlines() if line.strip()]
        except OSError:
            continue
        if rows:
            reasons.append("%d unread message(s) in %s" % (len(rows), path))
    if pane_state(opts.pane_id) == "live" and TURN_RE.search(screen(opts.pane_id)):
        reasons.append("a turn is running (its screen shows \"esc to interrupt\")")
    for reason in reasons:
        print(reason)
    return 1 if reasons else 0


def main(argv):
    parser = argparse.ArgumentParser(prog="agent-pane.py")
    sub = parser.add_subparsers(dest="command", required=True)
    ready = sub.add_parser("ready")
    ready.add_argument("--pane-id", required=True)
    ready.add_argument("--timeout", type=float, default=float(os.environ.get("SESSION_WORKSPACE_AGENT_READY_TIMEOUT", "120")))
    ready.add_argument("--interval", type=float, default=0.5)
    busy = sub.add_parser("busy")
    busy.add_argument("--pane-id", required=True)
    busy.add_argument("--pane", required=True)
    busy.add_argument("--tasks-dir")
    busy.add_argument("--queue", action="append")
    opts = parser.parse_args(argv)
    if not re.fullmatch(r"%[0-9]+", opts.pane_id):
        print("--pane-id must be a tmux pane id such as %12", file=sys.stderr)
        return 64
    return cmd_ready(opts) if opts.command == "ready" else cmd_busy(opts)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
