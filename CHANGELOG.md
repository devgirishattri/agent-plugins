# Changelog

## session-workspace 0.12.11 — 2026-11-04

- **Reviewer panes run only exact read forms.** strict-v1 is the only
  read-only guard for a Claude reviewer, and per-tool option parsing kept
  producing new bypasses. Every reviewer shell command now passes one
  exact-form grammar, built into the immutable floor (`EXACT_FORMS`,
  `EXACT_GIT`); `workspace.json` still cannot add commands or exceptions.
  - Words are plain (letters, digits, `_ . / : , + = @ % -`) or one
    single-quoted run with nothing attached (runs may join only by the POSIX
    `'it'\''s'` idiom, which session-chat prints for a path holding an
    apostrophe), never empty or made only of `; & | ( ) < >`. Segments join
    only with `|`, `||`, `&&` and `;`. No redirection, grouping,
    substitution, comments, control characters, double quotes, backslashes
    or `==` (`reviewer.shell`).
  - The program is a bare listed name. Assignments only to `LC_*`, `LANG`,
    `LANGUAGE`, `TZ`, `NO_COLOR`, `FORCE_COLOR`, `TERM`, `COLUMNS` and
    `LINES`. Options are whole listed words before the operands; a value
    option takes the next word, which never starts with `-`; `--` only right
    after the options; a bare `-` is refused. Git's listed `OPTION=` forms
    (`--format=`, `--pretty=`, `--max-count=`, `--since=`, `--until=`,
    `--author=`, `--grep=`, `tag --sort=`, `reflog --date=`) are the only
    attached values. An unlisted form is refused
    (`reviewer.form`), and known write, follow and file-list forms keep their
    old rules.
  - Every operand, path option value (`git config --file FILE`) and git
    revision word is checked with symlinks resolved. `git -C` is refused:
    git would read the repository config found there, where
    `core.fsmonitor` or a pager runs a command. `grep -f`/`--file`,
    `rg -f`/`--file` and `jq` are not listed. `diff` and
    `git diff --no-index` compare regular files only. Git revision parts
    never start with `.` or `/`, hold `//` or have a dot-led component.
    `git blame` runs only as `git blame [REV] -- PATH`, and `git config`
    reads need `--file PATH`, except exactly `--get core.hooksPath` and
    `--get-all remote.origin.fetch`.
  - Closed bypasses: `sed -n r/etc/passwd x`, `sed -n wout x`,
    `sed -n -e '{ r /etc/passwd' -e '}' x`, `ls -L`, `ls -RL`,
    `sort -o out x`, `sort -m /etc/passwd x`, `uniq in out`,
    `git diff --output x`, `git diff /etc/passwd /dev/null`,
    `git diff a/../../etc/passwd x`, `git blame` through an outward symlink,
    `git ls-files -X/etc/passwd`, `git grep -f -q -- x`, `git config --list`
    and `--get-regexp` without `--file`, `git reflog expire`,
    `jq 'include "x" {search:"/tmp"}; .' x`, `python3 -m json.tool x`,
    `/tmp/cat x`, `PATH=/tmp cat x`, `LD_PRELOAD=`, `DYLD_*=` and `BASH_ENV=`
    prefixes, `'LANG=./cat' cat x`, zsh `cat ^x` and `a~b`, BSD `cat x --`,
    `ls -- -` (a symlink named `-`), `diff dirA dirB` with outward leaf
    symlinks, `find -L`, `-E`, `-f`, `-Bnewer` and `-samefile`, and
    `grep --context name /etc/passwd`. Of these, 0.12.10 allowed `cat ^x`,
    `a~b`, `cat x --`, `ls -- -`, BSD `find -E`, `-f`, `-Bnewer` and
    `-samefile`, `git grep -f -q -- x` and the `jq include` search path.
  - Now allowed: pipelines and lists of listed forms,
    `sed -n 'N[,M]p' FILE`, `grep -C N`, `grep --context` (a flag; the next
    word is the pattern), `grep --include/--exclude/--exclude-dir GLOB`,
    `nl -ba`, `sha256sum`, `git -P`, `git status --porcelain=v1
    --untracked-files=all --no-renames`, `git tag --list --sort=KEY
    --format FORMAT -- PATTERN`, `git remote get-url --all|--push NAME` and
    `git remote show -n NAME`. A message file is still read by one command
    on its own (`coordination.message_read`).
  - Now refused: forms outside the listed spelling, for example `head -5`,
    `head -n5`, `sort -k2`, `uniq -cf1`, `date -d`, unquoted `HEAD~1`,
    double-quoted paths and backslash escapes, plus `git -C DIR`,
    `grep -f FILE` and `jq`. Rewrite them as `head -n 5`, `sort -k 2`,
    `git diff 'HEAD~1' -- FILE`, `grep -e PATTERN` and single quotes, and
    run git from the pane checkout.
- **Claimed reviewers fail closed.** Without `SESSION_WORKSPACE_CONFIG` the
  hook stays a no-op, except when `SESSION_WORKSPACE_ROLE`,
  `SESSION_WORKSPACE_PANE_NAME` or the tmux pane `@name` holds `reviewer` as
  a word: then every gated call is refused (`identity.reviewer`) until a
  readable config of a known schema backs the pane. The wrapper checks the
  claim without Python.
- **Read-only test mode.** `harness-policy.py --decision-json --as-role
  reviewer|executor --as-cwd DIR` judges one stdin payload as that role in
  `DIR`, under enforce, with no grants or workspace identity, and prints the
  normal decision object. It reads no `SESSION_WORKSPACE_*` variable and
  never changes a live decision. `--help` and `harness-status.sh --help`
  document it. The hook wrapper now refuses any argument except
  `--codex-hook-output` (`runtime.args`), so the hook cannot reach it.
- New diag/1 codes: `hook.identity.reviewer`, `hook.reviewer.form` and
  `hook.runtime.args`. Executor, orchestrator and coordinator floors and
  their probe cases are unchanged, and both provider trees decide
  identically.
- Tests: every bypass class above with a working control, symlink cases on
  temporary fixtures, claimed-reviewer and test-mode cases. Set
  `HARNESS_TEST_BASELINE_POLICY_01210` to a 0.12.10 `harness-policy.py` to
  check which cases 0.12.10 allowed.
- No config migration. Update the plugin and restart reviewer panes.

## session-workspace 0.12.10 — 2026-11-04

- **A manual stop's record is no longer lost to the idle watcher.** The
  watcher kept the pane's run record in memory and wrote it at every sample.
  `workspace stop --pane` records the stop first, then sends `Ctrl-C` and
  waits for the pane to exit, so a sample in that wait overwrote the stop.
  `workspace status` then showed no last stop, and once the pane was gone the
  watcher recorded it as `pane closed by something other than its idle
  watcher`. This turned the CI case "stop --pane web: only the dev server
  stops (full pane name accepted); status records when and why" red at
  random on main (0.12.7 and 0.12.9).
  - The watcher and the stop now read, change and write the record under one
    exclusive `flock` on `<pane>.json.lock` next to the record. The watcher
    exits instead of writing over a stop recorded for its pane. The stop's
    write goes through `idle-watch.py record-stop`. Without `python3` no
    watcher can run, and the stop keeps its plain `jq` merge.
  - Affected since 0.12.6: panes with `idle_stop_minutes` stopped by
    `workspace stop --pane` while their watcher was armed. The watcher's own
    idle stop was not affected.
- Test (on-demand block): a pane that takes 3 s to exit on `Ctrl-C`, a
  watcher sampling every 0.05 s, and a manual stop. The stop record, the
  status line and the watcher's exit are checked. 0.12.9 loses the stop
  record every time: no last stop, or the wrong reason once the pane is gone.
- No config migration.

## session-workspace 0.12.9 — 2026-11-04

- **Pane output as an idle-stop signal.** New optional pane field
  `idle_activity`: unique values from `"connections"` and `"output"`, default
  `["connections"]` (the behavior so far). It is allowed only on a service
  pane that sets `idle_stop_minutes` and `port`, never on the browser pane,
  where Chrome writes to its pane on its own. With `"output"` selected, the
  watcher fingerprints the pane at each sample (tmux `#{history_size}` plus a
  hash of the joined screen and the last 50 lines of history), and any change
  since the previous sample counts as use. The fingerprint taken when the
  watcher arms is the baseline. A sample at which the pane's size changed (a
  resize, a sibling pane started or closed, a client attaching at another
  size) only takes a new baseline, since rewrapped text is not output. Use is
  either selected signal; `["output"]` alone ignores connections.
  - This is for dev servers that close every connection after the response,
    such as Laravel's `php artisan serve` with `Connection: close`. A
    30-second sample almost never found a connection open, so a pane in
    steady use was stopped as idle. Such a server logs each request to its
    pane, which `"output"` sees.
  - Any periodic output keeps the pane up too, such as a watcher's rebuild
    line or a health-check log, which is why the signal is opt-in.
  - `workspace status` shows `observing connections+output`, the plan and
    status JSON carry `idle_activity`, and the stop reason names both
    signals: `idle: no inbound connections to port 8000 and no new pane
    output for 30 minutes`.
- **Linux: recently closed connections count as use.** On Linux the
  `connections` signal also counts server-side `TIME_WAIT` sockets on the
  port, read from `/proc/net/tcp{,6}`. The kernel keeps one for 60 seconds
  after the server closes a connection, so the same servers stay up there
  without opting in. `status` adds `(+N closed in the last 60s)` to
  `clients=`. **Behavior change:** on Linux a default dev-server pane stays up
  for up to 60 seconds after its last request, and any short-lived
  connection that repeats at least once a minute keeps it up for good, such
  as a sibling polling a health URL. In 0.12.8 such a pane was usually
  stopped. `["output"]` alone opts out of connection counting. On macOS the
  watcher reads sockets through `lsof`, which never lists `TIME_WAIT`, so use
  `"output"` there.
- The validator refuses an unknown, repeated or empty signal,
  `idle_activity` without `idle_stop_minutes`, on a non-service pane and on
  the browser pane, with a fixture for each. The schema documents the field.
- Tests (on-demand block): a pane that selects output and prints a line
  every second stays up past the window and is stopped once it goes quiet;
  the same pane without the field is stopped (negative control); an
  output-only pane is stopped despite a held connection and window resizes;
  on Linux a default dev server answering HTTP/1.0 requests stays up through
  `TIME_WAIT`; the plan reports the signals in canonical order;
  `idle-watch.py` refuses bad `--activity` values.
- No config migration. To roll back, install 0.12.8 and remove any
  `idle_activity` keys, which older releases reject.

## session-workspace 0.12.8 — 2026-11-03

Security fix for the strict-v1 executor inline-code floor (executors and
confined orchestrators). Update both providers together and restart agents.

- Executors could run inline code by giving an interpreter or shell its
  program on stdin, because `executor.inline_code` read only argv:
  `echo 'import os' | python3`, `python3 - <<EOF`, `python3 <<EOF`,
  `node <<<'...'`, `python3 < tool.py`, `echo ls | bash`, `bash <<EOF`,
  `sh -s`. An interpreter or shell with no script operand, or with `-` as
  the script, now counts as reading its program from stdin and is refused.
  Version, help and info runs with no other option (`python3 --version`,
  `node -v`, `perl -v`, `ruby -v`, `php -m`, `bash --version`; `ruby -v -w`
  reads stdin), `python3 -m MODULE`, `node --test`/`--run`, `php -S`,
  `php -f FILE` and every script run, with or without piped input, stay
  allowed. Shell `-o`/`-O` take the next word wherever they sit in a
  cluster, so `bash -ox pipefail` has no script. Bare `python3` or `bash`
  with nothing piped in is refused too; it would only read the pane's
  stdin.
- Executors could hide inline code behind a launch prefix that the policy
  did not unwrap: `timeout 5 python3 -c ...`, `nice`, `stdbuf`, `ionice`,
  `setsid`, `taskset` and `chrt`, a shell keyword before the command
  (`then`, `do`, `else`, `!`), and `find -exec`/`-execdir`/`-ok`/`-okdir`.
  The inline-code check now unwraps each of these with its own option
  grammar, nested and combined with `env`, `command`, `exec`, `nohup` and
  `time` (which were already unwrapped), then applies the same checks. An
  option outside a prefix's reviewed grammar falls back to the first later
  shell or interpreter token. `timeout 5 python3 tool.py` and
  `nice -n 5 make` stay allowed. This unwrapping is used for the
  inline-code check only.
- A newline in a command was folded into whitespace, so a command on a later
  line was read as arguments of the first: `ls` then `python3 -c ...` on the
  next line passed every per-command floor check, and `ls` then `sudo ls`
  passed `shell.privilege`. The floor now also reads the command split into
  lines the way the shell runs it, with backslash-newline joins, unquoted
  `#` comments and heredoc bodies (`<<` and `<<-`) dropped. Both readings
  must pass, so the line-split reading can only narrow what is allowed. A
  heredoc body written to a file (`cat > notes.md <<EOF`) is data, as
  before.
- fish `--command`, `--init-command` and `-C` count as inline shell code.
- `harness-status --probe` decides five new executor and confined
  orchestrator cases: a pipe into `python3`, a heredoc into `bash`,
  `timeout 5 python3 -c ...`, `python3 -c` on a second line, and a script
  run behind `timeout`. `--floor-json` lists the launch prefixes.
- Still not covered: task-runner launchers (`uv run`, `poetry run`, `npx`,
  `bundle exec`, `npm exec`), `flock`, `watch`, `strace` and `script`, and
  languages outside the floor's tables (`awk`, `deno`, `bun`, `lua`,
  `Rscript`).
- Tests: one case per gap with an allowed control next to it. With
  `HARNESS_TEST_BASELINE_POLICY_0127` pointing at the 0.12.7
  `harness-policy.py`, each gap case also asserts that 0.12.7 allowed it.
  `HARNESS_TEST_BASELINE_POLICY` stays the baseline for the 0.12.7 cases.
- No config migration.

## session-workspace 0.12.7 — 2026-11-03

Security fix for the strict-v1 reviewer read-only floor, the orchestrator
child-write floor and the executor inline-code floor. Update both providers
together and restart agents.

- Reviewers could create or overwrite a file in their checkout with `uniq`.
  POSIX `uniq [input [output]]` writes its second operand, and nothing checked
  it, so `uniq package.json src/b.txt` or `uniq README.md notes.txt` passed.
  A `uniq` with a second operand is now refused as `reviewer.uniq`. Operands
  are counted the way BSD getopt reads them, so the macOS form
  `uniq README.md -c`, which writes a file named `-c`, is refused too.
  `uniq FILE` with options and stdin forms stay allowed.
- Every other `READ_COMMANDS` entry was audited for an operand or option that
  writes, executes or loads hidden operands, for GNU and BSD variants. The
  result is recorded next to the table in `harness-policy.py`. Gaps closed:
  `file -C`/`--compile` (writes `NAME.mgc`, `reviewer.file`); `date -s`,
  `--set` and a non-`+FORMAT` operand (set the clock, `reviewer.date`);
  `file -f`/`--files-from` and `shasum`/`cksum -c`/`--check` (read the files
  a list names, `reviewer.file_list`). No write or exec form was found in
  `cut`, `diff` (GNU diffutils has no `--output`), `du`, `jq`, `nl`, `stat`,
  `tr`, `realpath`, `printf` or the rest of the table.
- Reviewers could destroy reflog history: `git reflog` was allowed with any
  subcommand. Only bare `git reflog [options]`, `show`, `list` and `exists`
  are allowed now. `expire`, `delete`, `drop` (Git 2.50) and any other word
  after `reflog` are refused as `reviewer.git`; name a ref with
  `git reflog show REF`.
- The orchestrator's child-write floor treated every allowlisted read command
  as a read. `uniq a child/out`, `find child -delete`/`-exec`,
  `rg --pre PROG ... child`, `file -C` inside a child and
  `git -C child reflog expire` now count as child mutations
  (`orchestrator.child_write`); a confined orchestrator's
  `git reflog expire` is `orchestrator.git`.
- Executors could pass `executor.inline_code` with attached or clustered
  interpreter options, because only the exact tokens `-c`, `-e`, `--eval` and
  `-r` were matched: `python3 -c"..."`, `python3 -Bc`, `node --eval=...`,
  `node -p`/`--print`, `perl -e'...'`, `perl -E`, `perl -lne`, `ruby -e'...'`,
  `ruby -ne`, `php -r'...'`, `php -nr`. Each interpreter's options are now
  read with its own grammar up to the script operand, including
  `--eval=`/`--print=`, `perl -M'code'`, `php -B/-R/-E/--run`, `node --import`
  or `--require` of a `data:` URL, and versioned binaries (`python3.12`,
  `perl5.36`, `pypy3`, `nodejs`). The exact tokens are still refused anywhere
  in the command, and the shell branch is unchanged. Running a script file
  stays allowed, and script arguments such as `node server.js -p 3000` are
  not read as interpreter options.
- The diagnostics registry adds `hook.reviewer.uniq`, `hook.reviewer.file`
  and `hook.reviewer.date` for the DIAG line of the new denials.
- `harness-status --probe` decides the new cases: reviewer `uniq` with one
  and two operands, `git reflog` and `git reflog expire`/`delete`, `file -C`
  and `date -s`; executor `python3 -c"print(1)"`, `node --eval=1` and a script
  run; orchestrator `uniq` into a child.
- Not covered by the inline-code floor, unchanged: a program fed to an
  interpreter on stdin, and an interpreter behind a prefix the policy does not
  unwrap (`timeout`, `nice`).
- Tests: one case per gap with an allowed control next to it. With
  `HARNESS_TEST_BASELINE_POLICY` pointing at a released `harness-policy.py`
  (inside a copy of its scripts directory), each gap case also asserts that
  the release allowed it.
- No config migration.
## session-workspace 0.12.6 — 2026-11-03

- **Single service panes on demand.** `workspace start SESSION --pane NAME`
  (repeatable) starts only the named service panes of one session, such as
  the debug browser or one dev server. It creates the session with only those
  panes when it is not running, runs their declared commands, and keeps panes
  that already run. `workspace stop SESSION --pane NAME --confirmed` closes
  only those panes and leaves the session running; stopping the browser pane
  releases its port claim. NAME is the pane name or the part after
  `<project.id>-`, and only role `service` panes can be selected. `--pane`
  never attaches, and a subset start neither builds a `split_tree` layout nor
  restores or saves `retain_layout`.
- **Idle stop.** New optional per-pane `idle_stop_minutes` (1–1440, off by
  default) for service panes with a port to watch. A watcher samples the port
  every 30 seconds and stops the pane after the whole window with no use. For
  a dev server, use is any inbound connection. For the browser, use is CDP
  commands, read as the bytes clients sent (Linux `sock_diag`, macOS
  `nettop`). chrome-devtools-mcp holds its websocket open for its whole
  session and pings on it, so the open connection and its keepalive pings do
  not count. It reconnects by itself after the pane starts again. Where those
  bytes cannot be read, the browser counts connections instead. The stop and
  its reason are recorded in
  `$XDG_STATE_HOME/session-workspace/<project.id>/panes/<pane>.json`. A host
  that cannot count connections never stops a pane for idleness. The watcher
  needs `python3`.
- **Port safety.** `start --pane` refuses a dev-server pane (`port` plus
  `command`) whose port is already bound by another process, on every schema
  version, and names the holder (`... 3001 (web) is held by pid 4242
  (node)`). The schema-v5 full-start check names the holder too.
- **Status.** `workspace status` prints one CDP health line per browser pane
  (`browser: NAME http://127.0.0.1:PORT — up (...)  cdp_clients=N`) and, per
  pane, `running=yes|no`, the idle watcher and the last stop. `status` accepts
  `SESSION --pane NAME`. `workspace plan --json --running` adds a read-only
  `running` field per pane; plain `plan --json` is unchanged and still does
  not read tmux.
- **Harness (strict-v1).** The orchestrator's trusted-helper grammar admits
  `workspace-start.sh SESSION --pane NAME... [--no-attach]` and
  `workspace-stop.sh SESSION --pane NAME... --confirmed` (plus `--config` for
  this workspace) for configured service panes of that session only.
  **Behavior change:** executors and reviewers were already refused the
  lifecycle helpers, but could still run `workspace start` or `stop` through
  the `workspace` dispatcher on `PATH`, a copied dispatcher, or a script
  outside the cache. Every such route is now refused under
  `coordination.write`. Read verbs (`plan`, `status`, `doctor`) are
  unchanged. `harness-status` lists this as the `lifecycle` floor clause
  for executors and reviewers, and `--probe` checks it.
- No config migration. Update both providers and restart agent panes so the
  new policy loads. To roll back, install the previous session-workspace
  release and remove any `idle_stop_minutes` keys, which older releases
  reject.

## knowledge 0.5.12 — 2026-11-03

- Validating the context store while another process saves no longer reports
  a healthy store as unsafe. Every release renames the writer lock into a
  short-lived `.knowledge-context-stale.<pid>` quarantine and then removes it.
  A validator that listed the quarantine just before its releaser removed it
  checked the type of a path that was already gone and failed with
  "writer-lock quarantine must be a directory". A quarantine that has vanished
  is now treated as a finished teardown; one that stays a non-directory is
  still rejected. This was the intermittent
  `validator_no_spurious_failure_under_writer_churn` failure in CI (about 1
  validation in 2,500, so a run of about 240 failed now and then). Outside
  tests it could fail `/context-list`, the doctor's context check, or a save
  that started just as another writer released, because each of these
  validates the store while the previous releaser may still be removing its
  quarantine.
- The writer-churn test now prints the first rejection's message, and
  `scripts/test-context-locks.py` has a deterministic case for both providers
  that removes the quarantine at exactly that check.
- No store migration.

## knowledge 0.5.11 — 2026-11-03

- `validate-links.sh` now decodes a percent-encoded markdown link target before
  it looks for the file. A link target is a URL, so a space in a file name is
  written `%20`, for example the target `../api/1.2%20List%20Items.md`. Before,
  the validator looked for the literal name `1.2%20List%20Items.md` and reported
  the link BROKEN although `../api/1.2 List Items.md` exists.
- Each `%HH` escape decodes to its byte: `%25` is a literal percent sign, and
  UTF-8 escapes such as `%C3%A9` resolve. A `%` without two hex digits after it
  stays as it is, so a link to `50%off.md` still resolves. A link written with
  a plain space still passes.
- A BROKEN line still shows the link as written. Its "expected at" path is now
  the decoded path, so it names the file that was looked for.
- `**Related**:` header references are plain file names in backticks, not URLs,
  and are not decoded.
- The Claude and Codex copies of `validate-links.sh` had drifted. They are now
  byte-identical, and `scripts/test-provider-parity.sh` fails if they differ
  again. Both copies now ignore spaces between `(` and the link target, as
  Markdown does; before, only the Codex copy did.
- `doctor` runs the same validator, so its `docs-links` warnings change in the
  same way. No migration.

## session-walkthrough 0.3.0 — 2026-11-03

- **Recorded bundle removed. The live tour is the only mode.** Every
  walkthrough request runs the live overlay tour in the already-running
  browser. A request for a recorded walkthrough or an evidence bundle gets
  a plain answer that the plugin offers only the live tour.
- Removed `scripts/walkthrough.sh` and `walkthrough.py` (the `validate`,
  `render` and `scope` subcommands), `manifest.schema.json`,
  `descriptor.schema.json`, the capture-target descriptors, the `WT-*` rule
  fixtures, and the `adapters`, `manifest`, `output`, `receipts` and
  `workspace-integration` references. The `SESSION_WALKTHROUGH_*` settings
  are gone with them. No capture pilot was ever recorded, so no supported
  capture target is lost.
- The plugin suite now checks the manifest, the skill, its links, the overlay
  `node:test` suite and the example, and fails if a shipped file names a
  removed bundle helper. It no longer needs `git`; it still needs `python3`
  and `node`.
- Migration: none for the live tour. Bundles recorded under
  `.tmp/walkthroughs/` stay where they are, but this version cannot validate
  or re-render them; keep 0.2.1 installed if you still need to.

## session-chat 0.17.21 — 2026-11-03

- A send or dispatch now checks that the recipient actually submitted the
  line. Before, a successful `tmux send-keys Enter` counted as delivered. Codex
  reads fast input as a paste burst and turns an Enter that arrives inside the
  burst into a newline, so a dispatch to an idle Codex pane could sit in its
  input line forever while the sender reported success and pane-health showed
  `ok`. After Enter the transport reads the recipient's input line (the last
  `›` line for Codex, the `❯` box for Claude Code; the transcript copy above it
  is ignored) and waits up to `SESSION_CHAT_SUBMIT_VERIFY_MS` (default 1000) for
  the text to leave it.
- If the text is still staged, the transport waits
  `SESSION_CHAT_SUBMIT_RETRY_DELAY_MS` (default 250), presses Enter once more
  and checks again. It never pastes a second copy. If the text is still
  staged after that, send and dispatch return the new status 4,
  "Unsubmitted …": the text stays in the input line and the durable copy stays
  queued, so it is not lost. Broadcast counts these as `unsubmitted`. Do not
  resend; press Enter in that pane.
- pane-health reports a pane whose input line holds an unsubmitted
  session-chat message as `UNSUBMITTED` (unsubmitted input). A pane whose send
  lock is held is skipped, since a send in flight stages its text briefly.
- The "landed" check now waits for the end of the payload, not only the first
  `id:` marker. A payload that reached the TUI in two pieces matched the
  header's marker early, and the Enter then submitted the header alone or
  landed in the tail's paste burst. This affected Claude Code as well as Codex.
- Claude Code submits on the first Enter, so on Claude Code panes the check
  only confirms the submit and sends nothing extra. Shells, paste placeholders
  and unrecognized screens keep the old behavior. `SESSION_CHAT_SUBMIT_VERIFY_MS=0`
  turns the check off.
- Same change in the Claude and Codex copies. A sender on 0.17.20 still
  reports these sends as delivered, so update both providers together.

## session-workspace 0.12.5 — 2026-11-03

- `harness-status` now prints the strict-v1 role floor before the guard
  packs. The old `guards:` line listed only the optional `harness.guards`
  packs, and agents read it as the complete enforcement list: executor panes
  refused a correct change, citing that line as proof that reviewer read-only
  and executor containment were not enforced. Both are part of the immutable
  floor and were enforced.
- The `floor (strict-v1, not configurable):` lines are generated from
  `harness-policy.py` itself (`--floor-json`): a new `ROLE_FLOOR` table names
  each role's floor clauses and the rule ids the policy raises for them, and
  the bracketed counts are read from the enforcement tables (`EDIT_TOOL_NAMES`,
  `READ_COMMANDS`, `READ_GIT`, `HELPERS`, ...). A pane with an accepted
  identity sees its own role and an `all roles` line. Without one, every role
  is shown, plus `<orchestrator> (confined)` when the plan has environment
  coordinators outside the project root.
- The text line `guards:` is renamed `optional guard packs:`. `--json` adds a
  `floor` object and a `probe` key. `guards` is unchanged, so `harness-doctor`
  and other readers keep working. `orchestrator.child_chdir` and
  `orchestrator.protected_file` are guard-pack rules, so they stay on the packs
  line and are not shown as floor.
- New `harness-status --probe`: the policy decides the built-in cases for the
  pane's own floor (`--probe-json`) through `evaluate_payload()`, the code path
  every hook decision takes, so a pane can check its floor without emulating
  another identity. Nothing is run or written. An unexpected decision prints an
  `UNEXPECTED` line and the script exits 1. The helper grammar accepts
  `--probe` for `harness-status.sh` in every role, directly and through
  `workspace.sh harness-status`; hook decisions are otherwise unchanged.
- Tests: per-role `harness-status` fixtures for the floor and packs lines, a
  copy of the scripts with an edited `READ_COMMANDS`/`ROLE_FLOOR` that changes
  the printed floor, a simulated enforcement drift that `--probe` reports, a
  check that every floor rule is raised by the policy and every
  reviewer/executor/orchestrator rule is floor or a named guard-pack rule, and
  probes for every pane of a schema-v5 environment topology.
- No config migration. Update both providers together and restart agents: a
  0.12.3 policy refuses `harness-status.sh --probe` with `helper.argv`.

## session-workspace 0.12.4 — 2026-11-03

- strict-v1 accepts the documented operands of the knowledge docs
  validators: `validate-links.sh [docs-directory]`,
  `check-todos.sh [docs-directory]` and
  `check-freshness.sh [docs-directory] [days-threshold]`. Before, the policy
  table gave all three a no-argument grammar, so an agent could check only the
  pane's whole cwd. A scoped pass such as
  `validate-links.sh <workspace>/docs/decisions` failed with
  `[helper.argv]: validate-links.sh accepts no arguments`.
- The directory must be literal and must resolve, symlinks included, to an
  existing directory inside the pane's own cwd: the workspace root for the
  orchestrator, the pane's checkout for executors and reviewers. A relative
  directory resolves against that cwd. The policy refuses a directory outside
  that scope, any `..` component, a symlink that points outside, a file, a
  second directory, a glob or `~`, and a value that starts with `-` (the
  validators pass it to `find`, which reads `-delete` as an expression). The
  freshness threshold is an integer from 1 to 3650.
- The other helper rules do not change: one literal `bash` segment, no shell
  composition or expansion, no extra arguments, and only the selected
  installed helper version.
- No config migration; update the plugin and restart affected agents.
  Downgrading to 0.12.3 restores the no-argument rule.

## session-walkthrough 0.2.1 — 2026-11-03

- **Strict Content Security Policy.** A `style-src` without `'unsafe-inline'`,
  nonce-based policies included, blocked the overlay's `<style>` element. The
  card then rendered unstyled below the page while the dry run still reported
  no overlap. The overlay now adopts a constructed stylesheet, which
  `style-src` does not block. Where constructed stylesheets are missing it
  falls back to a `<style>` element with the page's nonce. `status()` reports
  `styles`, and the dry run stops when it is `blocked`.
- **Animated targets.** A target inside a CSS transition, such as a menu that
  opens with a scale effect, was measured mid-animation. The ring stayed on
  the wrong rectangle and the card could cover the target. The overlay now
  waits for the target to stop moving (at most `settleTimeout`, 1000 ms).
- **Re-created targets.** When a framework replaced the highlighted node, the
  ring stayed on the old rectangle and `status()` reported no target until the
  next scroll. Placement now follows page DOM changes and the end of CSS
  transitions and animations, and `status()` queries a detached target again.
- **Tours never discard the user's edits.** In agent trials, four of five
  generated tours reset the whole form from `onClose` or a step's `setup`,
  which would also drop edits the user made during the tour. The docs now
  forbid that, document `onClose` (undo only what the tour set), and put
  field changes behind action buttons.
- Docs: the Vue 2 `el.__vue__` helper now steps down from the outermost
  instance on a shared root element. The reload line works under strict CSP
  through chrome-devtools; the fallback is to repeat the first injection.
  Route steps drop unsaved edits. Optional `sourcePath` injection for
  chrome-devtools-mcp 1.11.0 or later. SKILL.md gives the example's full path,
  which agents missed when they looked next to `SKILL.md`.
- No migration. Update the plugin; an open tour keeps the version it was
  injected with until it is injected again.

## knowledge 0.5.10 — 2026-11-03

- The context store's writer lock no longer treats a successful `mkdir` as
  ownership. uutils mkdir (Rust coreutils, the default on Ubuntu 25.10 and
  later) through 0.10.0 exits 0 when it loses the race to create a directory.
  The loser then failed to write its pid file and deleted the winner's pid and
  lock directory on the way out, so concurrent saves failed with "cannot
  publish writer-lock holder PID" and a third writer could take the lock
  while the first still held it. The holder now claims the lock only by
  creating its pid file exclusively (O_EXCL), and a writer that loses that
  create keeps waiting without touching anything.
- A stale lock (holder process gone) is taken over in place under an
  exclusively created `.reclaim` marker, instead of being renamed away under a
  marker made with `mkdir`, which uutils could hand to two waiters at once. A
  release renames the whole lock directory into the in-store quarantine, so a
  takeover marker in flight leaves with it. The marker is now an empty
  owner-only file. A 0.5.9 directory marker is still accepted and still
  blocks a takeover.
- Same protocol as the session-scheduler task locks and the session-chat
  locks. A store can be shared by Claude and Codex writers, and a 0.5.9 writer
  rejects the new file marker as unsafe, so update both providers together.
  No store migration.

## session-chat 0.17.20 — 2026-11-02

- Send and queue locks no longer treat a successful `mkdir` as ownership.
  uutils mkdir (Rust coreutils, the default on Ubuntu 25.10 and later) through
  0.10.0 exits 0 when it loses the race to create a directory, so two senders
  could hold one lock at once. The holder now claims the lock by creating its
  pid file exclusively (O_EXCL).
- A stale lock (holder process gone) is taken over in place under an
  exclusively created reclaim marker, instead of being deleted. Deleting it
  could remove a lock that another sender claimed after the waiter read the old
  pid, which gave the lock two holders on any coreutils. It happened most
  often when a sender released and exited while a waiter was checking it. A
  release now renames the whole lock directory away, so the lock path never
  shows a directory with no holder.
- A lock whose pid file cannot be written now fails the send with an error,
  instead of being held with no pid. On Codex, a lock released while a sender
  checks it is no longer refused as unsafe.
- Same protocol as the session-scheduler task locks. A recipient's queue lock
  is shared by Claude and Codex senders, and a 0.17.19 sender can still
  double-acquire it, so update both providers together. No store migration;
  restart affected panes after updating.

## session-walkthrough 0.2.0 — 2026-11-02

- **Live tour mode, now the default.** "Walk me through", "walkthrough",
  "tour", "show me the changes" and `/session-walkthrough` run a live,
  self-driven overlay tour in the already-running managed browser. The
  recorded bundle runs only on explicit request ("recorded walkthrough",
  "evidence bundle", "manifest"). The skill description and SKILL.md routing
  say so.
- New `scripts/tour/overlay.js`: a dependency-free overlay injected through
  chrome-devtools `evaluate_script`. It provides a highlight ring, a card of at
  most 350px placed beside the target without covering it, keyboard and
  accessibility support, setup/poll/actions/watch steps, sessionStorage reload
  recovery, an optional setInterval guard and SPA navigation hook, and a Close
  that leaves no residue.
- New `references/live-tour.md`: authority, runtime contract, step shape,
  authoring guidance and procedure (fresh tab, `emulate` not `resize_page`,
  geometry checks not element-scoped screenshots, GET-only dry run, hand-over).
- New walkable example `examples/live-tour/`: a synthetic demo page and a
  nine-step tour, runnable through chrome-devtools or locally with
  `demo.html?manual=1`.
- New `node:test` suite (`scripts/tour/tests/`) for placement math,
  navigation, cleanup, reload restore, the setInterval guard and the demo
  fixture. The plugin suite runs it, so `node` is now needed to run the
  plugin tests.
- Bundle mode: the 0.1.x contracts are unchanged and no pilot is recorded.
  The docs now warn that element-scoped screenshots crop wrongly when
  `devicePixelRatio` is not 1.
- No migration. Update the plugin; the next walkthrough request uses the live
  tour. To roll back, install session-walkthrough 0.1.1.

## session-scheduler 0.7.9 — 2026-11-02

- Per-task locks no longer treat a successful `mkdir` as ownership. uutils
  mkdir (Rust coreutils, Ubuntu's default coreutils since 25.10) through
  0.10.0 exits 0 when it loses the race to create a directory, so two writers
  could hold one task lock at once. The holder now claims the lock by creating
  its pid file exclusively (O_EXCL), and the stale-lock reclaim marker is an
  exclusively created file instead of a directory. Both providers share the
  change.
- Mixed versions interoperate: a 0.7.8 reclaim marker (a directory) still
  blocks a 0.7.9 reclaimer, and the reverse. A 0.7.8 pane on a uutils host
  can still double-acquire, so update both providers together. No store
  migration; restart affected panes after updating.

## session-workspace 0.7.1–0.11.7 — release notes moved from SKILL.md

Upgrade and rollback notes that lived in `skills/session-workspace/SKILL.md`.
The 0.10.0 notes are already recorded below. Add release dates from the
release commits.

- 0.7.1: reviewer writes are limited to the pane's own drafts directory.
  Earlier releases let reviewers write any top-level `.md`/`.txt` in the
  messages store. That reached other panes' pending dispatch files.
  Downgrading restores it.
- 0.7.1: executors may read the selected installed plugin version. No config
  migration; update the plugin and restart affected agents. Downgrading
  restores the earlier executor cache-read restriction.
- 0.7.4: path checks for attached short options, operands after `--`, and
  redirection targets. No config migration; restart agents after updating.
  Downgrading restores the 0.7.3 gap.
- 0.11.7: quoted literal paths and inert note text. No config migration;
  update the plugin and restart affected agents. Ships with scheduler 0.7.6.
  To roll back, install session-workspace 0.11.5 (and session-scheduler 0.7.5,
  commit 69041bb).

## session-workspace 0.10.0 — 2026-09-28

- Executors and reviewers may read complete delivered messages addressed to or
  sent by their validated pane, and existing own drafts, through the existing
  single literal read grammar. Delivered files must be private, owned regular
  files with one link, directly in the validated messages grant, with no
  traversal or symlink component. Filename endpoint parsing uses the complete
  validated topology and rejects ambiguous or unknown pairs.
- **Compatibility change:** reviewer shell reads no longer cover unrelated
  messages, transport state, peer drafts, or ungranted provider inboxes. Removed
  topology peers invalidate their historical payload access. Recursive reads
  through an ancestor of a message store are refused (`rg`, `find`, `du`,
  recursive `grep`, `ls -R`); name explicit safe subdirectories. Glob exclusions
  do not override this boundary. Child tool workdirs inside stores are refused,
  and executor operands resolve from the effective tool workdir.
- Close a pre-existing reviewer read bypass: the restricted grammar rejects
  NUL-separated file-list options in `sort`, `du`, `wc`, and `find`, including
  long-option abbreviations, because list contents hide additional operands.
  Ordinary executor in-checkout shell retains its existing floor; this does
  not claim subprocess isolation. Ordinary content reads remain allowed. Bundled `du`
  depth and `ls` ignore options cannot hide implicit recursive cwd traversal.
  Git receives no message-store read exception.
- Report scoped reads and denials as `coordination.message_read`, and recursive
  traversal/workdir denials as `coordination.message_traversal`, including in
  decision JSON. Own-draft native writes and coordinator rules are unchanged.
- No schema/store migration. Update both plugins and restart affected panes.
  Rollback restores the executor read failure and broader reviewer access.
  This remains a shell-operand guardrail: Claude native Read, arbitrary program
  internals, and same-user filesystem races are not isolated by this change.

## session-chat 0.17.13 — 2026-09-28

- Incoming file dispatches show a literal full-file read command before the
  inline body. Truncation guidance points to that file, including when the total
  hook-context cap truncates the body. Keep `SESSION_CHAT_DISPATCH_INLINE_MAX`
  as a display tunable; reading a full task does not depend on raising it.
  Claude's no-Python fallback now also reports byte-based inline truncation.
- Pair with session-workspace 0.10.0 for scoped executor/reviewer reads. Drafts
  and full transport copies keep their existing locations and send routing;
  notify/assist consent behavior is unchanged. Update both plugins and restart.

## session-workspace 0.9.0 — 2026-09-28

- **Behavior change:** orchestrator remote mutations through direct `gh` calls
  are now denied even when no argument resolves to a child checkout. This closes
  the direct-command named-repository and numeric API-route gap; projects relying on those
  mutations must route them to their executor. Audit mode reports the denial.
- Allow a closed set of literal orchestrator reads using `OWNER/NAME` repository
  selectors, positional `repo view`, and reviewed repository API endpoints with
  effective GET. API fields/input require explicit GET. File input still sends
  contents to GitHub; confined coordinators retain filesystem containment.
- Reject aliases, extensions, unsupported flags, wrappers, shell composition,
  dynamic operands and path-valued repository selectors. Emit distinct
  `orchestrator.gh_read`, `orchestrator.gh_mutation`, and
  `orchestrator.gh_unsupported` decision rules. Executor and reviewer rules are
  unchanged. No owner allowlist or new configuration key is introduced.
- No schema/store migration. Update both providers and restart affected agents;
  accept Codex hook trust if prompted. Rollback restores the old mutation gap
  and read restrictions. Git redirections and loops remain out of scope. The
  policy remains an argv guardrail for root and confined orchestrators, not
  subprocess isolation: script files and stdin-fed interpreters can still run
  gh. Withhold write-scoped orchestrator credentials where remote mutations
  must be impossible.

## session-workspace 0.7.0 — 2026-09-23

- Support root-scoped environment orchestrators with own-worker routing and task
  metadata, the existing root policy floor, and workspace-health guard output.
- Make the unbound root orchestrator optional when all worker environments have
  their own orchestrator; retain control-directory coordinator confinement.
- Allow command-less service shells and browser panes anywhere inside the project
  root while keeping command-bearing services inside their environment checkout.
- Add schema-v5 pane runtime overrides for mixed Claude/Codex roles. Schemas 1–4
  retain their existing plan and policy behavior.
- Report manual browser-profile migration guidance in doctor when changing from
  a singular project profile to per-session profiles; add a shared-root template.

## session-workspace 0.6.4 — 2026-09-23

- Require `rg --no-config` as the prefix for reviewer and scoped executor
  ripgrep reads, preventing inherited configuration from enabling symlink
  traversal or preprocessors.
- Reject hostname-program and compressed-search options in the restricted read
  grammar. General executor in-checkout shell permissions remain unchanged.
- Add real ripgrep controls for hostile configuration and normal searches on
  both provider trees.

## knowledge 0.3.28 — 2026-09-19

- Fix a docs-taxonomy scanner false positive: the exact `docs/decisions/README.md`
  folder index no longer requires decision naming or `decided` metadata. It remains
  covered by documentation link, freshness, and TODO checks.
- Fix memory-backlinks scanner false positives: fenced code blocks and single-backtick inline
  code spans no longer contribute links, warnings, or dangling counts in any
  graph mode. Prose links retain their existing resolution behavior.
