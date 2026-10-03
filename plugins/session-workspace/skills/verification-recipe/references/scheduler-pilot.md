# Scheduler verification pilot

Use only in the agent-plugins source checkout with `scripts/verify-scheduler-workflow.py`
present. It wraps the existing provider smoke suite; it does not introduce a
second scheduler implementation. Inspect that suite for the exact current
coverage before interpreting a result.

From the checkout root, choose a fresh evidence directory. `--output` must
resolve inside this checkout's `.tmp/` directory:

```bash
python3 -B scripts/verify-scheduler-workflow.py run --provider codex --output .tmp/verification/codex-run-1
python3 -B scripts/verify-scheduler-workflow.py check --output .tmp/verification/codex-run-1
```

Use `--provider claude` and a separate output directory for the other provider.
The runner requires Python 3, Bash, tmux, jq, Git, and ripgrep. It sanitizes inherited
agent/store variables for its test subprocess, allocates a short private tmux
directory and temporary HOME, and invokes the real scheduler smoke suite. The
suite drives creation, assignment, review, rejection/reassignment, completion,
and transport failure cases; some transport cases use deterministic stubs, so
this is not a native agent delivery or production integration claim.

The default timeout is 300 seconds; `--timeout` accepts 1 through 600 seconds.
There are no automatic retries. An unavailable dependency is `blocked`; a failed
suite is `failed`; timeout or input drift is `inconclusive`. Exit zero means
`passed`, one means a nonpassing result, and two means invalid input/evidence.
On `check`, changed source is `stale` (exit 1), a recorded nonpass exits 1,
and a missing or changed log is invalid evidence (exit 2).

`manifest.json` and `output.log` survive fixture cleanup. The manifest records
platform, command, exit code, source inventory, and log digest. `check` is
read-only and never runs recorded commands. It requires a passed record and
matching source/artifact hashes. It checks local consistency, not authenticity,
reviewer approval, coverage adequacy, or permission to release. Source inventory
includes the selected provider's scheduler, chat, knowledge and chronos trees,
the verification recipe directory, and the runner itself. These include the
packaged helpers actually used by the suite; `shared/shell` packaging inputs
and unrelated files are outside that freshness claim. Repackaging changes the
inventoried files and invalidates their evidence.

The smoke suite cleans its own test home; the runner terminates its subprocess
group and its private tmux server before removing its outer fixture directory.
Evidence contains raw test output; keep it local and inspect it before sharing.
Do not run this recipe from a role that disallows execution or artifact writes.
