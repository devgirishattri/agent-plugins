#!/usr/bin/env python3
"""Synthetic argv containment regressions; never accesses live stores/homes.

ARGV_SCOPE_TEST_CODEX_POLICY / _CLAUDE_POLICY can select the original policy.
Policy checks do not execute their command strings. The execution control uses
only temporary files to prove that attached options have real file semantics.
"""
import dataclasses
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


class Cases:
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="argv-scope-", dir="/tmp")
        # Keep original-code evidence deterministic: 0.7.3 mistakes a z in
        # an attached rg filename for a flag. Cover that separately below.
        while "z" in tmp.name:
            tmp.cleanup()
            tmp = tempfile.TemporaryDirectory(prefix="argv-scope-", dir="/tmp")
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()
        self.cwd = self.root / "component-a"; self.cwd.mkdir()
        self.file = self.cwd / "f.txt"; self.file.write_text("needle\n")
        (self.root / "f.txt").write_text("needle\n")
        (self.root / "root-output").mkdir()
        self.outside = self.root / "patterns"; self.outside.write_text("needle\n")
        (self.cwd / "sub").mkdir()
        (self.cwd / "-dir").mkdir()
        (self.cwd / "-dashfile").write_text("needle\n")
        (self.cwd / "escape").symlink_to(self.outside)
        script = os.environ.get("ARGV_SCOPE_TEST_" + self.provider.upper() + "_POLICY",
                                str(ROOT / self.tree / "session-workspace/scripts/harness-policy.py"))
        spec = importlib.util.spec_from_file_location("argv_policy_" + self.provider, script)
        self.policy = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = self.policy; spec.loader.exec_module(self.policy)
        self.ctx = self.policy.Context(
            mode="enforce", semantic_role="reviewer", pane_name="sample-reviewer",
            pane_cwd=self.cwd, project_root=self.root, config_path=self.root / "config.json",
            orchestrator_pane="master", executor_panes=frozenset(), reviewer_panes=frozenset(),
            child_roots=(self.cwd,), grant_roots=(), message_roots=(), guards={},
            claude_home=self.root / "claude", codex_home=self.root / "codex")

    def check(self, role, command, expected, rule=None, argv=False):
        ctx = dataclasses.replace(self.ctx, semantic_role=role,
                                  pane_cwd=self.root if role == "orchestrator" else self.cwd)
        payload = {"tool_name": "Bash", "tool_input": {"command": shlex.split(command) if argv else command}}
        with patch.object(self.policy, "load_context", return_value=(ctx, None)):
            result = self.policy.evaluate(json.dumps(payload))
        self.assertEqual(result.decision, expected, (role, command, result))
        if rule is not None:
            self.assertEqual(result.rule, rule, (role, command, result))

    def test_pattern_file_forms(self):
        for role in ("reviewer", "executor"):
            rule = "reviewer.path" if role == "reviewer" else "executor.containment"
            for cmd in ("grep", "rg --no-config"):
                for option in ("-f{}", "-nf{}", "-f {}", "--file={}", "--file {}"):
                    with self.subTest(role=role, cmd=cmd, option=option):
                        self.check(role, f"{cmd} {option.format(self.file)} f.txt", "allow")
                        self.check(role, f"{cmd} {option.format(self.outside)} f.txt", "deny", rule)

    def test_attached_symlink(self):
        for role in ("reviewer", "executor"):
            for cmd in ("grep", "rg --no-config"):
                with self.subTest(role=role, cmd=cmd):
                    self.check(role, f"{cmd} -ff.txt f.txt", "allow")
                    self.check(role, f"{cmd} -fescape f.txt", "deny")

    def test_reported_reviewer_payloads(self):
        # Evaluate only: these strings never execute or read /etc/hosts.
        for command in ("grep -f/etc/hosts pat", "rg --no-config -f/etc/hosts pat"):
            with self.subTest(command=command):
                self.check("reviewer", command.replace("/etc/hosts", "f.txt"), "allow")
                self.check("reviewer", command, "deny", "reviewer.path")

    def test_sort_outputs(self):
        for option in ("-o{}", "-uo{}", "-o {}", "--output={}", "--out={}", "-T{}", "-uT{}", "--temporary-directory={}"):
            target = self.cwd / "sub" if "T" in option or "temporary" in option else self.cwd / "sub/out"
            with self.subTest(role="reviewer", option=option):
                self.check("reviewer", "sort -u f.txt", "allow")
                self.check("reviewer", "sort " + option.format(target) + " f.txt", "deny", "reviewer.sort")
            with self.subTest(role="executor", option=option):
                self.check("executor", "sort " + option.format(target) + " f.txt", "allow")
                self.check("executor", "sort " + option.format(self.root / "out") + " f.txt", "deny", "executor.containment")

    def test_post_delimiter(self):
        for role in ("reviewer", "executor"):
            for argv in (False, True):
                with self.subTest(role=role, argv=argv):
                    self.check(role, "cat -- -dashfile", "allow", argv=argv)
                    self.check(role, "cat -- -dir/../../patterns", "deny", argv=argv)
            # After --, assignments and long-option syntax are literal names.
            (self.cwd / "--file=escape").symlink_to(self.outside)
            try:
                self.check(role, "cat -- --file=escape", "deny")
            finally:
                (self.cwd / "--file=escape").unlink()

    def test_data_controls(self):
        for role in ("reviewer", "executor"):
            for command in ("grep -e/api/ f.txt", "grep -nepattern f.txt", "grep -A3 needle f.txt",
                            "grep -n5 needle f.txt", "rg --no-config -g'*.md' needle .",
                            "rg --no-config -e/api/ f.txt", "sort -k2 f.txt", "sort -t/ f.txt"):
                with self.subTest(role=role, command=command):
                    self.check(role, command, "allow")

    def test_option_values_do_not_become_flags(self):
        flagged = self.cwd / "zLR-patterns"; flagged.write_text("needle\n")
        for cmd in ("grep", "rg --no-config"):
            for option in ("-f", "-nf"):
                with self.subTest(cmd=cmd, option=option):
                    self.check("reviewer", f"{cmd} {option}zLR-patterns f.txt", "allow")
            for pattern in ("zLR", "--pre", "--hostname-bin"):
                with self.subTest(cmd=cmd, pattern=pattern):
                    self.check("reviewer", f"{cmd} -e{pattern} f.txt", "allow")
        for option, rule in (("-z", "reviewer.search"), ("-L", "reviewer.symlink_follow"),
                             ("--pre=cat", "reviewer.search"), ("--hostname-bin=cat", "reviewer.search")):
            with self.subTest(option=option):
                self.check("reviewer", "rg --no-config needle f.txt", "allow")
                self.check("reviewer", f"rg --no-config {option} needle f.txt", "deny", rule)
        self.check("reviewer", "grep -R needle .", "deny", "reviewer.symlink_follow")
        self.check("reviewer", "grep -r needle .", "allow")

    def test_diff_post_delimiter_directory(self):
        self.check("reviewer", "diff -- -dashfile f.txt", "allow")
        self.check("reviewer", "diff -- -dir f.txt", "deny", "reviewer.symlink_follow")

    def test_unknown_command_options(self):
        for command in ("cp -t{} f.txt", "install -t{} f.txt", "tar -cf{} f.txt"):
            with self.subTest(command=command):
                target = self.cwd / "sub/archive" if command.startswith("tar") else self.cwd / "sub"
                self.check("executor", command.format(target), "allow")
                self.check("executor", command.format(self.root / "out"), "deny", "executor.containment")

    def test_wrappers(self):
        for prefix in ("env X=1 ", "nohup ", "time ", "command "):
            for command in ("grep -f{} f.txt", "sort -o{} f.txt", "cp -t{} f.txt"):
                with self.subTest(prefix=prefix, command=command):
                    target = self.cwd / "sub" if command.startswith("cp") else self.file
                    self.check("executor", prefix + command.format(target), "allow")
                    self.check("executor", prefix + command.format(self.outside), "deny", "executor.containment")
                    self.check("reviewer", prefix + command.format(self.file), "deny", "reviewer.shell")

    def test_orchestrator_child_paths(self):
        for prefix in ("", "env X=1 ", "nohup ", "time ", "command "):
            for command in ("cp -t{} f.txt", "sort -o{} f.txt", "sort -uo{} f.txt"):
                with self.subTest(prefix=prefix, command=command):
                    target = "root-output" if command.startswith("cp") else "root-output/out"
                    self.check("orchestrator", prefix + command.format(target), "allow")
                    self.check("orchestrator", prefix + command.format("component-a/out"), "deny", "orchestrator.child_write")
        self.check("orchestrator", "cp f.txt component-a/", "deny", "orchestrator.child_write")
        self.check("orchestrator", "sort component-a/f.txt", "allow")

    def test_cd_post_delimiter(self):
        self.check("executor", "cd -- -dir && cat ../f.txt", "allow")
        self.check("executor", "cd -- -dir/../.. && cat patterns", "deny", "executor.containment")

    def test_missing_option_values(self):
        for role in ("reviewer", "executor"):
            for command in ("grep -f", "rg --no-config --file", "sort -uo"):
                with self.subTest(role=role, command=command):
                    self.check(role, "cat f.txt", "allow")
                    rule = "reviewer.sort" if role == "reviewer" and command.startswith("sort") else "path.option"
                    self.check(role, command, "deny", rule)

    def test_redirect_targets_are_not_option_data(self):
        self.check("executor", ">sub/out", "allow")
        self.check("executor", f">{self.root}/out", "deny", "executor.containment")
        self.check("orchestrator", ">root-output/out", "allow")
        self.check("orchestrator", ">component-a/out", "deny", "orchestrator.child_write")
        for prefix in ("", "env X=1 ", "nohup ", "time "):
            with self.subTest(prefix=prefix):
                self.check("executor", prefix + "grep -e >sub/out needle f.txt", "allow")
                self.check("executor", prefix + f"grep -e >{self.root}/out needle f.txt", "deny", "executor.containment")
                self.check("executor", prefix + f"grep -e <{self.outside} needle f.txt", "deny", "executor.containment")
                self.check("orchestrator", prefix + "grep -e >out needle patterns", "allow")
                self.check("orchestrator", prefix + "grep -e >component-a/out needle patterns", "deny", "orchestrator.child_write")
        # Redirection belongs to the shell cwd, before env changes the cwd.
        self.check("executor", "env -C sub cat ../f.txt >out", "allow")
        self.check("executor", "env -C sub cat ../f.txt >../out", "deny", "executor.containment")


class Codex(Cases, unittest.TestCase):
    provider = "codex"
    tree = "codex/plugins"


class Claude(Cases, unittest.TestCase):
    provider = "claude"
    tree = "plugins"


class ExecutionControls(unittest.TestCase):
    def test_real_attached_file_semantics(self):
        with tempfile.TemporaryDirectory(prefix="argv-execution-", dir="/tmp") as tmp:
            root = Path(tmp); child = root / "child"; child.mkdir()
            patterns = root / "patterns"; patterns.write_text("needle\n")
            source = child / "f.txt"; source.write_text("needle\nother\n")
            for executable in ("grep", "rg"):
                if not shutil.which(executable):
                    if executable == "rg":
                        continue  # Optional executable; policy cases always run.
                    self.fail("grep required for the execution control")
                argv = [executable] + (["--no-config"] if executable == "rg" else [])
                result = subprocess.run(argv + ["-f" + str(patterns), "f.txt"], cwd=child, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "needle\n")
            out = root / "out"
            result = subprocess.run(["sort", "-uo" + str(out), "f.txt"], cwd=child, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(out.read_text(), "needle\nother\n")
            (child / "-dir").mkdir()
            result = subprocess.run(["cat", "--", "-dir/../../patterns"], cwd=child, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "needle\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
