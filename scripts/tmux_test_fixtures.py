"""Run commands as descendants of named panes on a test's private tmux server."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time


def run_in_pane(tmux, pane, args, env, directory, *, input="", timeout=30):
    """Replace the fixture pane's cat with a test command, then resume cat."""
    # Limit the temporary script to the identity, transport and OS settings the fixture needs.
    settings = {k: v for k, v in env.items()
                if k in {"HOME", "PATH", "TMPDIR", "TMUX", "TMUX_PANE", "CODEX_HOME",
                         "CLAUDE_HOME", "CLAUDE_CONFIG_DIR", "PLUGIN_ROOT", "CLAUDE_PLUGIN_ROOT",
                         "LANG", "LC_ALL"} or k.startswith(("SESSION_CHAT_", "SESSION_SCHEDULER_"))}
    with tempfile.TemporaryDirectory(prefix="pane-command-", dir=directory) as temp:
        job = Path(temp)
        (job / "in").write_text(input)
        argv = ["env", "-i", *(k + "=" + v for k, v in settings.items()), *args]
        script = job / "run.sh"
        script.write_text(
            'job=' + shlex.quote(str(job)) + '\ncd ' + shlex.quote(os.getcwd()) + ' || exit 1\n'
            + shlex.join(argv) + ' <"$job/in" >"$job/out" 2>"$job/err"\n'
            + 'echo "$?" >"$job/status.tmp"\nmv "$job/status.tmp" "$job/status"\nexec /bin/cat\n'
        )
        tmux("respawn-pane", "-k", "-t", pane, "/bin/bash", str(script))
        deadline = time.monotonic() + timeout
        while not (job / "status").is_file():
            if time.monotonic() >= deadline:
                raise subprocess.TimeoutExpired(args, timeout)
            time.sleep(0.03)
        return subprocess.CompletedProcess(args, int((job / "status").read_text()),
                                           (job / "out").read_text(), (job / "err").read_text())
