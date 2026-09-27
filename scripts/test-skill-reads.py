#!/usr/bin/env python3
"""Synthetic skill read authorization, both providers. Never uses live homes.

SKILL_READ_TEST_CODEX_POLICY / _CLAUDE_POLICY override original policy paths.
"""
import dataclasses
import importlib.util
import json
import os
from pathlib import Path
import shlex
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


class Cases:
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="skill-reads-", dir="/tmp")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.cwd = self.root / "child"; self.cwd.mkdir()
        script = os.environ.get("SKILL_READ_TEST_" + self.provider.upper() + "_POLICY",
                                str(ROOT / self.tree / "session-workspace/scripts/harness-policy.py"))
        spec = importlib.util.spec_from_file_location("skill_policy_" + self.provider, script)
        self.policy = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = self.policy; spec.loader.exec_module(self.policy)
        self.ctx = self.policy.Context(
            mode="enforce", semantic_role="reviewer", pane_name="sample-reviewer",
            pane_cwd=self.cwd, project_root=self.root, config_path=self.root / "config.json",
            orchestrator_pane="master", executor_panes=frozenset(), reviewer_panes=frozenset(),
            child_roots=(self.cwd,), grant_roots=(), message_roots=(), guards={},
            claude_home=self.root / "claude", codex_home=self.root / "codex")
        self.system = self.ctx.codex_home / "skills/.system/official"
        self.user = self.ctx.codex_home / "skills/user-skill"
        self.claude = self.ctx.claude_home / "skills/user-skill"
        for skill in (self.system, self.user, self.claude):
            (skill / "references").mkdir(parents=True)
            (skill / "SKILL.md").write_text("# Synthetic skill\n")
            (skill / "references/topic.md").write_text("Synthetic reference\n")
        self.marker = self.system.parent / ".codex-system-skills.marker"
        self.marker.write_text("synthetic marker\n")
        self.control = self.cwd / "readme.md"; self.control.write_text("control")
        self.secret = self.ctx.codex_home / "auth.json"; self.secret.write_text("synthetic secret")

    def roles(self):
        for role in ("reviewer", "executor"):
            yield dataclasses.replace(self.ctx, semantic_role=role, pane_name="sample-" + role)

    def check(self, ctx, command, expected, tool_input=None):
        payload = {"tool_name": "Bash", "tool_input": tool_input or {"command": command}}
        with patch.object(self.policy, "load_context", return_value=(ctx, None)):
            decision = self.policy.evaluate(json.dumps(payload))
        self.assertEqual(decision.decision, expected, (command, decision))

    def cat(self, ctx, path, expected="allow"):
        self.check(ctx, "cat " + shlex.quote(str(path)), expected)

    def test_system_user_and_references(self):
        for ctx in self.roles():
            self.cat(ctx, self.control)
            for skill in (self.system, self.user, self.claude):
                for leaf in ("SKILL.md", "references/topic.md"):
                    with self.subTest(role=ctx.semantic_role, skill=str(skill), leaf=leaf):
                        self.cat(ctx, skill / leaf)
                with self.subTest(role=ctx.semantic_role, skill=str(skill), directory=True):
                    self.check(ctx, "rg --no-config --files " + str(skill), "allow")
            with self.subTest(role=ctx.semantic_role, argv=True):
                self.check(ctx, "", "allow", {"command": ["cat", str(self.system / "SKILL.md")]})

    def test_provider_state_and_missing_skill(self):
        malformed = self.ctx.codex_home / "skills/not-a-skill"
        malformed.mkdir(); (malformed / "data.md").write_text("data")
        for ctx in self.roles():
            for path in (self.secret, self.marker, self.ctx.codex_home / "config.toml",
                         malformed / "data.md", self.user.parent, self.system.parent,
                         self.ctx.codex_home / "skills/.hidden/SKILL.md"):
                self.cat(ctx, path, "deny")
            self.cat(ctx, self.system / "SKILL.md")
        self.marker.unlink()
        for ctx in self.roles():
            self.cat(ctx, self.system / "SKILL.md", "deny")
            self.cat(ctx, self.user / "SKILL.md")

    def test_links_and_traversal(self):
        escape = self.user / "escape.md"; escape.symlink_to(self.secret)
        cross = self.user / "cross.md"; cross.symlink_to(self.claude / "SKILL.md")
        linked = self.user.parent / "linked"; linked.symlink_to(self.claude, target_is_directory=True)
        hard = self.user / "hard.md"; os.link(self.secret, hard)
        for ctx in self.roles():
            for path in (escape, cross, hard, linked / "SKILL.md",
                         self.user / "references/../SKILL.md"):
                self.cat(ctx, path, "deny")
            self.check(ctx, "rg --no-config --files " + str(self.user), "deny")
            self.cat(ctx, self.user / "SKILL.md")
        for path in (escape, cross, hard, linked): path.unlink()
        for ctx in self.roles():
            self.check(ctx, "rg --no-config --files " + str(self.user), "allow")

    def test_no_execution_mutation_workdir_or_composition(self):
        path = self.user / "SKILL.md"
        for ctx in self.roles():
            for command in (f"cat {path} > {self.cwd}/copy", f"cat {path} | head -1",
                            f"cp {path} {self.cwd}/copy", f"bash {path}",
                            f"cd {self.user}", f"git -C {self.user} status",
                            f"rg --files {self.user}", f"rg --no-config -L --files {self.user}"):
                self.check(ctx, command, "deny")
            self.check(ctx, "", "deny", {"command": "cat SKILL.md", "workdir": str(self.user)})
            for tool, args in [("Write", {"file_path": str(path), "content": "changed"}),
                               ("apply_patch", {"input": f"*** Begin Patch\n*** Update File: {path}\n@@\n-old\n+new\n*** End Patch"})]:
                with patch.object(self.policy, "load_context", return_value=(ctx, None)):
                    result = self.policy.evaluate(json.dumps({"tool_name": tool, "tool_input": args}))
                self.assertEqual(result.decision, "deny", result)
            self.cat(ctx, path)

    def test_foreign_cache_stays_ungranted(self):
        skill = self.ctx.codex_home / "plugins/cache/other-market/plugin/1.0/skills/example"
        skill.mkdir(parents=True); (skill / "SKILL.md").write_text("foreign")
        for ctx in self.roles():
            self.cat(ctx, skill / "SKILL.md", "deny")
            self.cat(ctx, self.system / "SKILL.md")

    def test_invalid_entry_and_system_root(self):
        entry = self.user / "SKILL.md"
        entry.unlink(); entry.symlink_to(self.claude / "SKILL.md")
        for ctx in self.roles():
            self.cat(ctx, self.user / "references/topic.md", "deny")
            self.cat(ctx, self.claude / "SKILL.md")
        entry.unlink(); entry.write_text("restored")
        original = self.system.parent
        moved = self.root / "moved-system"
        original.rename(moved); original.symlink_to(moved, target_is_directory=True)
        for ctx in self.roles():
            self.cat(ctx, self.system / "SKILL.md", "deny")
            self.cat(ctx, self.user / "SKILL.md")
        original.unlink(); moved.rename(original)
        self.marker.unlink(); self.marker.symlink_to(entry)
        for ctx in self.roles():
            self.cat(ctx, self.system / "SKILL.md", "deny")
            self.cat(ctx, self.user / "SKILL.md")
        self.marker.unlink(); self.marker.write_text("restored")
        for ctx in self.roles(): self.cat(ctx, self.system / "SKILL.md")

    def test_hidden_and_special_directory_leaves(self):
        hidden = self.user / ".hidden"; hidden.write_text("hidden")
        for ctx in self.roles():
            self.cat(ctx, hidden, "deny")
            self.check(ctx, "rg --no-config --hidden --files " + str(self.user), "deny")
            self.cat(ctx, self.user / "SKILL.md")
        hidden.unlink()
        fifo = self.user / "pipe"; os.mkfifo(fifo)
        for ctx in self.roles():
            self.cat(ctx, fifo, "deny")
            self.check(ctx, "rg --no-config --files " + str(self.user), "deny")
            self.cat(ctx, self.user / "SKILL.md")
        fifo.unlink()
        for ctx in self.roles():
            self.check(ctx, "rg --no-config --files " + str(self.user), "allow")


class Codex(Cases, unittest.TestCase):
    provider = "codex"
    tree = "codex/plugins"


class Claude(Cases, unittest.TestCase):
    provider = "claude"
    tree = "plugins"


if __name__ == "__main__":
    unittest.main(verbosity=2)
