#!/usr/bin/env python3
"""Check peer-orchestrator decisions against a provider's validated plan.

Pass the provider's scripts directory as the first argument. It defaults to Codex.
"""
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import unittest
from unittest.mock import patch


scripts = Path(__file__).resolve().parents[1] / "codex/plugins/session-workspace/scripts"
if len(sys.argv) > 1 and not sys.argv[1].startswith("-"):
    scripts = Path(sys.argv.pop(1)).resolve()
os.environ["WORKSPACE_TEST_SCRIPTS"] = str(scripts)
fixture = runpy.run_path(str(scripts / "test-peers-policy.py"))
policy = fixture["POLICY"]


class PeerStateWrite(unittest.TestCase):
    def setUp(self):
        self.r = fixture["Root"](workers=[])
        self.addCleanup(self.r.close)
        del self.r.cfg["roles"]["master"]["grants"]
        self.r.write_config()
        self.r.state = self.r.home / ".local/state"
        (self.r.state / "session-workspace/sample").mkdir(parents=True)
        self.r.write_instances((2,), [])
        self.scratch = self.r.top / "scratch"
        (self.scratch / "out").mkdir(parents=True)
        (self.scratch / "in.md").touch()
        self.tasks = self.r.root / ".tmp/scheduler/tasks"
        self.messages = self.r.root / ".tmp/messages"

    def check(self, ctx, command, rule="allow", word=None, **tool_input):
        payload = {"tool_name": "Bash", "tool_input": {"command": command, **tool_input}}
        self.check_payload(ctx, payload, rule, word)

    def check_payload(self, ctx, payload, rule, word=None):
        with self.subTest(pane=ctx.pane_name, workers=len(self.r.instances["workers"]), payload=payload):
            with patch.dict(os.environ, self.r.base_env(), clear=True):
                result = policy.evaluate_payload(ctx, json.dumps(payload))
            self.assertEqual(result.decision, "allow" if rule == "allow" else "deny", result)
            if rule != "allow":
                self.assertEqual(result.rule, rule, result)
            if word:
                self.assertIn(word, result.reason)
                self.assertIn("could not resolve", result.reason)

    def test_shell_decisions(self):
        s, m, t = self.scratch, self.messages, self.tasks
        commands = (
            f"ls {m}/*-a-to-b.md >/dev/null 2>&1",
            f"ls {s}/*-a-to-b.md >/dev/null 2>&1",
            f"cp {s}/*.md {s}/out/",
            f"sed -n '/^b$/d' {s}/in.md",
            f"sed -n 's/^PLAN$/TASK/p' {s}/in.md",
            f"sed -n -e '/^a/,/^b$/{{/^b$/d;p;}}' {s}/in.md",
            f'n=0; until ls {m}/*-a-to-b.md >/dev/null 2>&1 || [ "$n" -ge 60 ]; '
            'do sleep 10; n=$((n+1)); done; echo "wait ended after $n polls"',
            f"ls {m} >/dev/null 2>&1",
            f"ls {s}/*.md",
            f"cp {s}/a.md {s}/b.md",
            f"grep -n 'b$' {s}/in.md > {s}/out.md",
            f"sed -n '/^b/d' {s}/in.md",
            f"sed -n 's/^PLAN/TASK/p' {s}/in.md",
            f"sed -n '$p' {s}/in.md",
            f"sed -n '2,5{{p;}}' {s}/in.md",
            f"until ls {m}/x.md; do sleep 10; done",
            f"until grep -q done {t}/task-1.json; do sleep 30; done",
            f"head -n 15 {s}/in.md | tail -n +9 > {s}/out.md",
            f"ls {t}/*.json 2>/dev/null",
            f"cp '{s}/$literal' {s}/*.md {s}/out/",
        )
        for workers in ([], fixture["DEFAULT_WORKERS"]):
            self.r.write_instances((2,), workers)
            ctx = self.r.ctx(fixture["B"])
            for command in commands:
                self.check(ctx, command)
            rule = "orchestrator.state_write"
            for command in (f"cp {s}/x.json {t}/", f"cat {s}/x.json > {t}/task-1.json",
                            "touch ~/.local/state/session-workspace/sample/instances.json"):
                self.check(ctx, command, rule)
            for word in (f"{t.parent.parent}/sch*", "$HOME/.local/state/session-workspace/sample", "$X"):
                self.check(ctx, f"rm -rf {word}", rule, word=word)
            self.check_payload(ctx, {"tool_name": "Edit", "tool_input": {"file_path": str(t / "task-1.json")}}, rule)

    def test_configured_store(self):
        rule = "orchestrator.state_write"
        target = self.r.root / ".state/jobs/tasks"
        for override in (".state/jobs", str(target.parent)):
            self.r.cfg["stores"]["overrides"] = {"scheduler": override}
            self.r.write_config()
            ctx, failure = self.r.load(fixture["A"], SESSION_SCHEDULER_HOME=str(self.scratch))
            self.assertIsNone(failure)
            self.check(ctx, f"touch {target}/new.json", rule)
            for command in (f"echo {target}/new.json | xargs rm",
                            f"""python3 -c 'open("{target}/new.json", "w")'"""):
                self.check(ctx, command, rule)
            self.check(ctx, f"echo {self.tasks}/new.json | xargs rm")
            self.check(ctx, f"touch {self.tasks}/new.json")
            self.check(ctx, f"touch {self.scratch}/tasks/new.json")
            self.assertIsNone(ctx.scheduler_root)
            with self.assertRaises(policy.PolicyFailure) as caught:
                policy.peers_task_file(ctx, "task-1")
            self.assertEqual(caught.exception.rule, "task.scope")
        self.r.cfg["stores"].pop("overrides")
        self.r.write_config()
        self.r.write_instances((2,), fixture["DEFAULT_WORKERS"])
        self.r.task("task-1", fixture["A"])
        ctx = self.r.ctx(fixture["A"])
        self.assertEqual(policy.peers_task_file(ctx, "task-1")["assigner"], fixture["A"])
        worker = self.r.ctx(fixture["AE"])
        self.check_payload(worker, {"tool_name": "Edit", "tool_input": {"file_path": str(self.tasks / "new.json")}},
                           "executor.containment")
        self.check_payload(worker, {"tool_name": "Edit", "tool_input": {"file_path": str(worker.pane_cwd / "notes.md")}},
                           "allow")
        self.r.write_instances((2,), [])
        self.r.cfg["stores"]["pin"].remove("scheduler")
        for role in self.r.cfg["roles"].values():
            if "scheduler" in role.get("grants", []):
                role["grants"].remove("scheduler")
        self.r.write_config()
        ctx = self.r.ctx(fixture["A"])
        self.check(ctx, f"touch {target}/new.json")
        self.check(ctx, f"touch {self.tasks}/new.json")
        self.check(ctx, "touch ~/.local/state/session-workspace/sample/x", rule)

    def test_relative_paths_and_aliases(self):
        ctx = self.r.ctx(fixture["B"])
        rule = "orchestrator.state_write"
        self.check(ctx, "touch task-1.json", rule, workdir=str(self.tasks))
        self.check(ctx, "touch task-1.json", workdir=str(self.scratch))
        self.check(ctx, "rm -rf sch*", rule, cwd=str(self.tasks.parent.parent))
        self.check(ctx, "rm -rf sch*", cwd=str(self.scratch))
        self.check(ctx, f"cat {self.scratch}/in.md >{self.tasks}/x 2>/dev/null", rule)
        self.check(ctx, f"cat {self.tasks}/x > /dev/null 2>&1")
        # A match in scratch may resolve through a symlink. An ordinary file
        # with exactly the same spelling is the positive control.
        alias = self.scratch / "entry.md"
        alias.touch()
        command = f"touch {self.scratch}/entry*.md"
        self.check(ctx, command)
        alias.unlink()
        alias.symlink_to(self.tasks / "task-1.json")
        self.check(ctx, command, rule)
        alias.unlink()
        alias.symlink_to(self.r.root / "component-a/file.md")
        self.check(ctx, command, "orchestrator.child_write")

    def test_scalar_words_and_patterns(self):
        ctx = self.r.ctx(fixture["A"])
        for command in ('sleep "$n"', 'd=5; sleep "$d"', 'kill "$pid"', 'echo "count $n" >> notes.md',
                        'echo "$(date) start" >> notes.md',
                        f"find {self.scratch} -name '*.md' -exec cp {{}} {self.scratch}/out/ \\;",
                        'for f in a.md notes.md; do cat "$f" >> all.md; done', 'tail -n"$n" notes.md > out.md',
                        "touch notes@{1}", "rm -rf {a,b}", "touch '$literal'"):
            self.check(ctx, command)
        rule = "orchestrator.state_write"
        self.check(ctx, 'cp a.md "$dest"', rule, word="$dest")
        self.check(ctx, 'echo "count $n" > "$dest"', rule, word="$dest")
        self.check(ctx, "rm -rf {.tmp,notes}", rule)
        for command in ("chmod -R g+w *", f"tar czf {self.scratch}/a.tgz *",
                        "grep -c TODO * > component-a/counts.txt"):
            self.check(ctx, command, "orchestrator.child_write")
        self.check(ctx, f"grep -c TODO * > {self.scratch}/counts.txt")
        self.check(ctx, "touch *", cwd=str(self.scratch))
        (self.scratch / ".alias").symlink_to(self.tasks)
        self.check(ctx, "touch *", rule, word="*", cwd=str(self.scratch))

    def test_command_substitutions(self):
        ctx = self.r.ctx(fixture["A"])
        read_status = f"jq -r .status {self.tasks}/task-1.json"
        for command in (f'until [ "$({read_status})" = done ]; do sleep 5; done',
                        f'status="$({read_status})"; echo "$status"',
                        f'echo "status: $({read_status})"',
                        f'[ "$(cat {self.tasks}/task-1.json | jq -r .status)" = done ]',
                        f'echo "`{read_status}`"', 'wc -l "$(pwd)/notes.md"',
                        'cat "$(git rev-parse --show-toplevel)/AGENTS.md"',
                        f'ls "$(dirname "{self.scratch}/in.md")"',
                        f'echo "$(cat {self.scratch}/in.md)" > {self.scratch}/out.md',
                        f'echo "$(basename "$(dirname {self.scratch}/in.md)")"',
                        f"echo '$(touch {self.tasks}/unused)'", f"cd {self.scratch} && echo $(touch tasks)"):
            self.check(ctx, command)
        rule = "orchestrator.state_write"
        for command in (f'cd {self.tasks.parent} && echo "$(touch tasks)"',
                        f'cd {self.tasks} && echo "$(touch marker)"',
                        f'echo "`touch {self.tasks}/marker`"',
                        f'[ "$(touch {self.tasks}/marker)" = x ]',
                        f'echo "$(printf %s "$(touch {self.tasks}/marker)")"',
                        f'touch "$({read_status})"'):
            self.check(ctx, command, rule)

    def test_expanded_programs_and_options(self):
        ctx = self.r.ctx(fixture["A"])
        task = self.tasks / "task-1.json"
        for command in (f'cat {task}', f'grep -q "$status" {task}',
                        f'sort -k "$key" {task}', f'sort -- "$file" {task}',
                        f'find {self.tasks} -name "$pattern"', f"find {self.tasks} -name '*.json'",
                        f'sort "$mode" {self.scratch}/in.md'):
            self.check(ctx, command)
        for command in (f'$(printf directory)/cat {task}', f'`printf directory`/cat {task}',
                        f'sort $(printf %s "$mode") {task}', f'sort "$mode" {task}',
                        f'find {self.tasks} "$action"', f'find {self.tasks} -name "$@"'):
            self.check(ctx, command, "orchestrator.state_write")

    def test_non_peer_floor(self):
        old = fixture["V5Root"]()
        self.addCleanup(old.close)
        ctx = old.ctx("root")
        rule = "orchestrator.state_write"
        tasks = ctx.scheduler_root / "tasks"
        record = tasks / "t.json"
        outside = self.scratch / "t.json"
        sibling = tasks.with_name("tasks-archive") / record.name
        for command in (f"rm {record}", f"touch {record}", f"echo x > {record}", f"tee {record}",
                        f"sed -i '' 's/a/b/' {record}", f"mv {outside} {record}", f"cp {outside} {record}",
                        f"find {tasks} -delete", f"cd {tasks} && rm t.json", f"env -C {tasks} rm t.json",
                        f"python3 edit.py {record}", f'touch "{tasks}/$name"', f'cd {tasks} && cp t.json "$out"',
                        'touch "$SESSION_SCHEDULER_HOME/tasks/$name"', 'rm -rf "$SESSION_SCHEDULER_HOME"',
                        'touch "${SESSION_WORKSPACE_PROJECT_ROOT}/.tmp/scheduler/tasks/t.json"'):
            self.check(ctx, command, rule)
        for command in (f"cat {record}", f"cd {tasks} && ls", f"cd {tasks} && cat t.json >/dev/null",
                        f"jq . {record} > {outside}", f"cp {record} {outside}", f"touch {sibling}",
                        f"cd {tasks} && jq . t.json > {outside}", f"cd {tasks} && cp t.json {outside}",
                        f'cp "$source" {outside}', 'touch "$file"', f"python3 edit.py {sibling}"):
            self.check(ctx, command)
        for tool in ("Edit", "Write"):
            self.check_payload(ctx, {"tool_name": tool, "tool_input": {"file_path": str(record)}}, rule)
            self.check_payload(ctx, {"tool_name": tool, "tool_input": {"file_path": str(sibling)}}, "allow")
        alias = tasks / "link.json"
        alias.symlink_to(self.scratch / "in.md")
        self.check(ctx, f"rm {alias}", rule)
        self.check(ctx, f"cat {alias}")
        self.check_payload(ctx, {"tool_name": "Edit", "tool_input": {"file_path": str(alias)}}, rule)
        self.check(ctx, f"cp {self.scratch}/*.md {self.scratch}/out/")
        self.check(ctx, f"cp {self.scratch}/in.md {ctx.child_roots[0]}/result.md", "orchestrator.child_write")

        for role in old.cfg["roles"].values():
            if "scheduler" in role.get("grants", []):
                role["grants"].remove("scheduler")
        old.cfg["stores"].setdefault("overrides", {})["scheduler"] = "control-web/.ledger"
        old.path.write_text(json.dumps(old.cfg))
        pinned = old.root / "control-web/.ledger/tasks/t.json"
        ctx = old.ctx("root")
        self.assertIsNone(ctx.scheduler_root)
        self.check(ctx, f"echo {pinned} | xargs ls", rule)
        self.check(ctx, f"echo {record} | xargs ls")
        self.check(ctx, f"touch {pinned}", rule)
        self.check(ctx, f"touch {record}")
        local = old.ctx("web-master")
        self.assertTrue(local.confined_orchestrator)
        self.assertIsNone(local.scheduler_root)
        self.check(local, "touch .ledger/tasks/t.json", rule)
        self.check(local, "touch notes.json")
        self.check_payload(local, {"tool_name": "Write", "tool_input": {"file_path": ".ledger/tasks/t.json"}}, rule)
        self.check_payload(local, {"tool_name": "Write", "tool_input": {"file_path": "notes.json"}}, "allow")
        old.cfg["orchestration"] = {"enabled": False}  # Reviewed Git orchestration requires a scheduler pin.
        old.cfg["stores"]["pin"].remove("scheduler")
        del old.cfg["stores"]["overrides"]["scheduler"]
        old.path.write_text(json.dumps(old.cfg))
        ctx = old.ctx("root")
        self.check(ctx, f"touch {pinned}")
        self.check_payload(ctx, {"tool_name": "Edit", "tool_input": {"file_path": str(record)}}, "allow")

    def test_child_write_destination_and_protected_ancestors(self):
        # A peer owns each declared checkout even when it has no workers.
        self.r.cfg["harness"]["guards"]["orchestrator"]["deny_child_chdir"] = False
        self.r.write_config()
        ctx = self.r.ctx(fixture["A"])
        child = self.r.root / "component-a"
        for command in (f"jq . {child}/package.json > {self.scratch}/x.json",
                        f"cp {child}/package.json {self.scratch}/x.json",
                        f'for f in {child}/*.json; do wc -l "$f"; done',
                        f"cd {child} && ls"):
            self.check(ctx, command)
        for command in (f"jq . {self.scratch}/x.json > {child}/package.json",
                        f"cp {self.scratch}/x.json {child}/package.json",
                        f"git -C {child} config --get user.name", f"git -C {child} fetch",
                        f"pushd {child} && npm install"):
            self.check(ctx, command, "orchestrator.child_write")
        # A directory operand copies to DIR/basename. A link at that final
        # name can lead into the checkout through an otherwise safe directory.
        copy_to_dir = f"cp {child}/package.json {self.scratch}/out"
        self.check(ctx, copy_to_dir)
        (self.scratch / "out/package.json").symlink_to(child / "package.json")
        self.check(ctx, copy_to_dir, "orchestrator.child_write")
        for command in (f"mv {self.r.root} {self.scratch}/moved", f"rm -rf {self.r.root.parent}",
                        f"env -C {child} rm -rf ..", "rm -rf ~"):
            self.check(ctx, command, "shell.project_root")
        self.check(ctx, f"rm -rf {self.scratch}/build")

    def test_destructive_directory_operands(self):
        ctx = self.r.ctx(fixture["A"])
        rule = "shell.project_root"
        self.check(ctx, f"rmdir -p {self.r.root}/build/empty", rule)
        self.check(ctx, "rmdir -p build/empty")
        self.check(ctx, "rm -rf {build,.}", rule)
        self.check(ctx, "rm -rf {build,output}")

    def test_ledger_heredoc_and_feeder_scope(self):
        ctx = self.r.ctx(fixture["A"])
        task = self.tasks / "sample.json"
        source = "python3 - <<PY\nprint(1)\nPY"
        self.check(ctx, f"cat {task}; {source}")
        for program in ("xargs ls", "parallel ls"):
            self.check(ctx, f"{program} <<LIST\n{task}\nLIST", "orchestrator.state_write")
            self.check(ctx, f"{program} <<LIST\n{self.scratch}/sample.json\nLIST")

    def test_symlinked_ledger(self):
        actual = self.r.root / "task-files"
        self.tasks.rename(actual)
        self.tasks.symlink_to(actual, target_is_directory=True)
        ctx = self.r.ctx(fixture["A"])
        rule = "orchestrator.state_write"
        self.check(ctx, f"rm -rf {self.tasks.parent}", rule)
        for directory in (self.tasks, actual):
            self.check(ctx, f"touch {directory}/new.json", rule)
            self.check_payload(ctx, {"tool_name": "Edit", "tool_input": {"file_path": str(directory / "new.json")}}, rule)
            self.check(ctx, f"ls {directory}")

    def test_filesystem_case_aliases(self):
        ctx = self.r.ctx(fixture["A"])
        alternate = self.r.root / ".TMP"
        if not alternate.exists():
            (alternate / "scheduler/tasks").mkdir(parents=True)
        aliases = alternate.samefile(self.tasks.parent.parent)
        for same, identity in ((aliases, None), (False, False), (True, True)):
            # Exercise the native filesystem and both possible answers to
            # the identity lookup, including on hosts with only one volume.
            with self.subTest(same=same, native=identity is None):
                with patch.object(Path, "samefile", autospec=True,
                                  side_effect=Path.samefile if identity is None else None, return_value=identity):
                    rule = "orchestrator.state_write" if same else "allow"
                    file = alternate / "scheduler/tasks/new.json"
                    for command in (f"touch {file}", f"rm -rf {alternate}/scheduler",
                                    f"rm -rf {alternate}/SCH*", f"rm -rf {alternate}/*"):
                        self.check(ctx, command, rule)
                    self.check_payload(ctx, {"tool_name": "Edit", "tool_input": {"file_path": str(file)}}, rule)
                    child = self.r.root / "COMPONENT-A/new.md"
                    self.check_payload(ctx, {"tool_name": "Edit", "tool_input": {"file_path": str(child)}},
                                       "orchestrator.child_write" if same else "allow")
                    self.check(ctx, f"touch {self.scratch}/new.json")

    def test_decision_json(self):
        for command, decision in ((f"ls {self.messages}/*.md >/dev/null 2>&1", "allow"),
                                  (f"cp {self.scratch}/x.json {self.tasks}/", "deny")):
            payload = {"hook_event_name": "PreToolUse", "tool_name": "Bash", "cwd": str(self.r.root),
                       "tool_input": {"command": command}}
            run = subprocess.run([sys.executable, "-I", policy.__file__, "--decision-json"],
                                 input=json.dumps(payload), text=True, capture_output=True, timeout=60,
                                 env=self.r.env(fixture["B"]), check=True)
            result = json.loads(run.stdout)
            self.assertTrue(result["active"], result)
            self.assertEqual(result["decision"], decision, result)
            if decision == "deny":
                self.assertEqual(result["rule"], "orchestrator.state_write", result)


if __name__ == "__main__":
    unittest.main()
