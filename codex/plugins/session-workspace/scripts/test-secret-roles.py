#!/usr/bin/env python3
"""Per-key secret authorization regressions using synthetic values only."""
import copy
import json
import os
from pathlib import Path
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest

HERE = Path(os.environ.get("WORKSPACE_TEST_SCRIPTS", Path(__file__).resolve().parent)).resolve()
ENV = {k: v for k, v in os.environ.items()
       if not k.startswith(("SESSION_", "KNOWLEDGE_", "SW_TEST_"))
       and k not in ("TMUX", "TMUX_PANE")}
VALUES = {"SW_TEST_CI": "ci-sentinel-735b", "SW_TEST_MCP": "mcp-sentinel-892a",
          "SW_TEST_SHARED": "shared-sentinel-301d"}


class SecretRoles(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="wsr-", dir="/tmp")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        (self.root / ".agent-workspace").mkdir()
        self.path = self.root / ".agent-workspace/workspace.json"
        self.env_file = self.root / "secrets.env"
        self.env = dict(ENV, TMPDIR=str(self.root), TMUX_TMPDIR=str(self.root),
                        XDG_STATE_HOME=str(self.root / "state"))
        subprocess.run(["git", "init", "-q", str(self.root)], check=True, env=self.env)
        (self.root / ".gitignore").write_text("secrets.env\n")
        self.write_values(VALUES)
        roles = ["master", "executor", "reviewer", "outside"]
        self.cfg = {
            "schema_version": 1, "project": {"id": "secret-roles", "root": "."},
            "runtimes": {"codex": {"program": "codex"}},
            "roles": {r: {"runtime": "codex"} for r in roles},
            "stores": {"pin": []},
            "secrets": {"env_file": "secrets.env", "on_missing": "fail",
                        "visible_to_roles": roles[:3], "allow": [
                            {"key": "SW_TEST_CI", "roles": ["executor", "reviewer"]},
                            {"key": "SW_TEST_MCP", "roles": ["master"]},
                            "SW_TEST_SHARED"]},
            "sessions": [{"id": "s", "name": "secret-roles", "panes": [
                {"name": r, "role": r, "cwd": "."} for r in roles]}]}

    def write_values(self, values):
        self.env_file.touch(mode=0o600)
        self.env_file.write_text("".join(f"{k}={v}\n" for k, v in values.items()))
        self.env_file.chmod(0o600)

    def run_script(self, script, *args, env=None):
        self.path.write_text(json.dumps(self.cfg))
        return subprocess.run(["bash", str(HERE / script), "--config", str(self.path), *args],
                              capture_output=True, text=True, env=env or self.env, timeout=60)

    def lookup(self, role, key, env=None):
        self.path.write_text(json.dumps(self.cfg))
        return subprocess.run(["bash", str(HERE / "adapters.sh"), "secret-value",
                               "--config", str(self.path), "--pane", role, "--key", key],
                              capture_output=True, text=True, env=env or self.env, timeout=30)

    def transfer(self, role):
        self.path.write_text(json.dumps(self.cfg))
        result = subprocess.run(["bash", str(HERE / "adapters.sh"), "secret-file",
                                 "--config", str(self.path), "--pane", role],
                                capture_output=True, text=True, env=self.env, timeout=30)
        data = {}
        if result.returncode == 0 and result.stdout.strip():
            path = Path(result.stdout.strip())
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            data = dict(line.split("=", 1) for line in path.read_text().splitlines())
            path.unlink()
        return result, data

    def no_values(self, text):
        self.assertTrue(all(v not in text for v in VALUES.values()), "secret value leaked")

    def test_legacy_delivery_and_source_precedence(self):
        self.cfg["secrets"]["allow"] = list(VALUES)
        for role in ("executor", "master", "reviewer"):
            result, data = self.transfer(role)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(data == VALUES, "legacy exact delivery mismatch")
        result, data = self.transfer("outside")
        self.assertEqual((result.returncode, result.stdout, result.stderr, data), (0, "", "", {}))
        result = self.lookup("executor", "SW_TEST_CI", dict(self.env, SW_TEST_CI="caller-control"))
        self.assertEqual((result.returncode, result.stdout), (0, "caller-control"))
        del self.cfg["secrets"]["env_file"]
        result = self.lookup("executor", "SW_TEST_CI", dict(self.env, SW_TEST_CI="env-only-control"))
        self.assertEqual((result.returncode, result.stdout), (0, "env-only-control"))

    def test_exact_role_grants_and_lookup(self):
        for role, keys in (("master", ["SW_TEST_MCP", "SW_TEST_SHARED"]),
                           ("executor", ["SW_TEST_CI", "SW_TEST_SHARED"]),
                           ("reviewer", ["SW_TEST_CI", "SW_TEST_SHARED"])):
            with self.subTest(role=role):
                result, data = self.transfer(role)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(data == {k: VALUES[k] for k in keys}, "exact role delivery mismatch")
                for key in keys:
                    lookup = self.lookup(role, key)
                    self.assertEqual(lookup.returncode, 0, lookup.stderr)
                    self.assertTrue(lookup.stdout == VALUES[key], "authorized value mismatch")
                self.no_values(result.stdout + result.stderr)

    def test_denial_reason_does_not_reveal_value_presence(self):
        present = self.lookup("executor", "SW_TEST_MCP")
        self.assertNotEqual(present.returncode, 0)
        self.assertEqual(present.stdout, "")
        self.assertIn("secrets.allow entry roles", present.stderr)
        self.write_values({k: v for k, v in VALUES.items() if k != "SW_TEST_MCP"})
        absent = self.lookup("executor", "SW_TEST_MCP")
        self.assertEqual((present.returncode, present.stdout, present.stderr),
                         (absent.returncode, absent.stdout, absent.stderr))
        missing = self.lookup("master", "SW_TEST_MCP")
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("missing", missing.stderr)
        self.assertEqual(missing.stdout, "")
        unlisted = self.lookup("master", "SW_TEST_UNLISTED")
        self.assertIn("not in secrets.allow", unlisted.stderr)
        self.no_values(present.stderr + missing.stderr + unlisted.stderr)

    def test_global_ceiling_and_empty_rules(self):
        self.cfg["secrets"]["allow"][1]["roles"].append("outside")
        result = self.lookup("outside", "SW_TEST_MCP")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("secrets.visible_to_roles", result.stderr)
        result, data = self.transfer("outside")
        self.assertEqual((result.returncode, result.stdout, result.stderr, data), (0, "", "", {}))
        self.cfg["secrets"]["allow"][1]["roles"] = []
        result = self.lookup("master", "SW_TEST_MCP")
        self.assertIn("secrets.allow entry roles", result.stderr)
        for global_roles in ([], None):
            if global_roles is None:
                del self.cfg["secrets"]["visible_to_roles"]
            else:
                self.cfg["secrets"]["visible_to_roles"] = global_roles
            result, data = self.transfer("executor")
            self.assertEqual((result.returncode, result.stdout, result.stderr, data), (0, "", "", {}))

    def test_missing_checks_only_entitled_keys(self):
        self.write_values({k: v for k, v in VALUES.items() if k != "SW_TEST_MCP"})
        for mode in ("warn", "fail"):
            with self.subTest(mode=mode):
                self.cfg["secrets"]["on_missing"] = mode
                result, data = self.transfer("executor")
                self.assertEqual((result.returncode, result.stderr), (0, ""))
                self.assertEqual(set(data), {"SW_TEST_CI", "SW_TEST_SHARED"})
                result, data = self.transfer("master")
                self.assertIn("SW_TEST_MCP", result.stderr)
                self.assertIn(f"on_missing: {mode}", result.stderr)
                self.assertEqual(result.returncode, 1 if mode == "fail" else 0)
                if mode == "fail":
                    self.assertEqual(result.stdout, "")
                self.assertFalse(list(self.root.glob("sw-secret.*")), "transfer leaked after failure/cleanup")
                self.no_values(result.stdout + result.stderr)

    def structural(self, cfg):
        return subprocess.run(["jq", "-L", str(HERE), "-c", "-f", str(HERE / "validate-structural.jq")],
                              input=json.dumps(cfg), capture_output=True, text=True, env=self.env, timeout=15)

    def test_validation_types_duplicates_unknown_roles_and_injection(self):
        control = self.structural(self.cfg)
        self.assertEqual((control.returncode, json.loads(control.stdout)), (0, []))
        invalid = [
            (["SW_TEST_CI", "SW_TEST_CI"], "duplicate key"),
            (["SW_TEST_CI", {"key": "SW_TEST_CI", "roles": []}], "duplicate key"),
            ([{"key": "SW_TEST_CI", "roles": ["master"]},
              {"key": "SW_TEST_CI", "roles": ["executor"]}], "duplicate key"),
            ([{"key": "SW_TEST_CI", "roles": ["typo"]}], "unknown role"),
            ([{"key": "SW_TEST_CI", "roles": ["master", "master"]}], "duplicate roles"),
            ([{"key": "SW_TEST_CI", "roles": [] , "extra": True}], "unknown key"),
            ([{"key": "SW_TEST_CI"}], "missing required key"),
            ([{"roles": []}], "missing required key"),
            ([{"key": 1, "roles": []}], "key must be a string"),
            ([{"key": "SW_TEST_CI", "roles": None}], "roles must be an array"),
            ([{"key": "SW_TEST_CI", "roles": "master"}], "roles must be an array"),
            ([{"key": "SW_TEST_CI", "roles": [1]}], "role-name strings"),
            ([False], "entries must be strings or objects"),
            (None, "allow must be an array"),
            ({}, "allow must be an array"),
        ]
        for key in ("", "9BAD", "BAD-NAME", "BAD\n", "x[$(id)]"):
            invalid += [([key], "must match"), ([{"key": key, "roles": []}], "must match")]
        for entries, reason in invalid:
            with self.subTest(entries=entries):
                cfg = copy.deepcopy(self.cfg)
                cfg["secrets"]["allow"] = entries
                result = self.structural(cfg)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(reason, result.stdout)
        for roles, reason in ((["typo"], "unknown role"), (None, "must be an array"),
                              ("master", "must be an array"), ([1], "role-name strings")):
            cfg = copy.deepcopy(self.cfg)
            cfg["secrets"]["visible_to_roles"] = roles
            result = self.structural(cfg)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(reason, result.stdout)
        # Case is significant; normalization extracts a key but never folds it.
        self.cfg["secrets"]["allow"] = ["TOKEN", {"key": "token", "roles": []}]
        self.assertEqual(json.loads(self.structural(self.cfg).stdout), [])

    def test_object_injection_rejected_end_to_end(self):
        marker = self.root / "injection-marker"
        key = f"x[$(touch {marker})]"
        self.cfg["secrets"]["allow"] = [{"key": key, "roles": ["master"]}]
        result = self.lookup("master", key)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must match", result.stderr)
        self.assertFalse(marker.exists())
        # Positive control: the fixture's marker location really is writable.
        marker.touch()
        self.assertTrue(marker.is_file())

    def test_on_missing_requires_a_string_enum(self):
        # String-only config keeps this regression meaningful on 0.7.4 too.
        self.cfg["secrets"]["allow"] = list(VALUES)
        for mode in ("warn", "fail"):
            self.cfg["secrets"]["on_missing"] = mode
            control = self.structural(self.cfg)
            self.assertEqual(control.returncode, 0, control.stderr)
            self.assertEqual(json.loads(control.stdout), [])
        for invalid in (["warn"], ["fail"], [], ["warn", "fail"], None, {}, 1, False, "ignore"):
            with self.subTest(on_missing=invalid):
                self.cfg["secrets"]["on_missing"] = invalid
                result = self.structural(self.cfg)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("secrets.on_missing must be warn or fail", result.stdout)
                denied = self.lookup("master", "SW_TEST_MCP")
                self.assertNotEqual(denied.returncode, 0)
                self.assertEqual(denied.stdout, "")
                self.no_values(denied.stderr)

    def test_doctor_omits_empty_visibility(self):
        populated = self.run_script("workspace-doctor.sh", "--json")
        checks = {c["id"]: c for c in json.loads(populated.stdout)["checks"]}
        self.assertEqual(checks["secrets.visibility"]["status"], "INFO")
        self.cfg["secrets"]["allow"] = []
        for absent in (False, True):
            if absent:
                del self.cfg["secrets"]
            result = self.run_script("workspace-doctor.sh", "--json")
            checks = {c["id"]: c for c in json.loads(result.stdout)["checks"]}
            self.assertNotIn("secrets.visibility", checks)
            self.assertEqual(checks["secrets.env_file"]["status"], "OK")

    def test_doctor_policy_failure_is_an_error(self):
        self.cfg["secrets"]["allow"] = list(VALUES)
        control = self.run_script("workspace-doctor.sh", "--json")
        checks = {c["id"]: c for c in json.loads(control.stdout)["checks"]}
        self.assertEqual(checks["secrets.env_file"]["status"], "OK")
        copied = self.root / "scripts"
        shutil.copytree(HERE, copied)
        (copied / "secret-policy.jq").unlink(missing_ok=True)
        # Run from the copy: jq also resolves modules relative to the working
        # directory, so launching from the real scripts/ dir would find the
        # deleted secret-policy.jq there and mask the failure under test.
        result = subprocess.run(["bash", str(copied / "workspace-doctor.sh"), "--config", str(self.path), "--json"],
                                capture_output=True, text=True, env=self.env, timeout=60, cwd=str(copied))
        checks = {c["id"]: c for c in json.loads(result.stdout)["checks"]}
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(checks["secrets.visibility"]["status"], "ERROR")
        self.assertIn("cannot compute", checks["secrets.visibility"]["message"])
        self.assertNotIn("secrets.env_file", checks)
        self.no_values(result.stdout + result.stderr)

    def test_plan_doctor_names_only_and_scoped_diagnostics(self):
        self.cfg["secrets"]["allow"].append({"key": "SW_TEST_UNUSED", "roles": []})
        result = self.run_script("workspace-plan.sh", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(result.stdout)
        expected = {"master": ["SW_TEST_MCP", "SW_TEST_SHARED"],
                    "executor": ["SW_TEST_CI", "SW_TEST_SHARED"],
                    "reviewer": ["SW_TEST_CI", "SW_TEST_SHARED"], "outside": []}
        self.assertEqual(plan["secret_keys_by_role"], expected)
        for pane in plan["sessions"][0]["panes"]:
            self.assertEqual(pane["secret_keys"], expected[pane["role"]])
        self.no_values(result.stdout + result.stderr)
        human = self.run_script("workspace-plan.sh")
        self.assertEqual(human.returncode, 0, human.stderr)
        self.assertIn("secret_keys_by_role (names only)", human.stdout)
        self.no_values(human.stdout + human.stderr)
        doctor = self.run_script("workspace-doctor.sh", "--json")
        checks = {c["id"]: c for c in json.loads(doctor.stdout)["checks"]}
        self.assertEqual(checks["secrets.env_file"]["status"], "OK")
        self.assertIn("INFO no effective recipient: SW_TEST_UNUSED", checks["secrets.visibility"]["details"])
        self.no_values(doctor.stdout + doctor.stderr)
        self.write_values({k: v for k, v in VALUES.items() if k != "SW_TEST_MCP"})
        doctor = self.run_script("workspace-doctor.sh", "--json")
        checks = {c["id"]: c for c in json.loads(doctor.stdout)["checks"]}
        self.assertEqual(checks["secrets.env_file"]["status"], "ERROR")
        self.assertIn('affected roles for SW_TEST_MCP: ["master"]', checks["secrets.env_file"]["details"])
        self.assertNotIn("SW_TEST_UNUSED", " ".join(checks["secrets.env_file"]["details"]))
        self.no_values(doctor.stdout + doctor.stderr)
        self.no_values(self.run_script("workspace-doctor.sh").stdout)

    def test_legacy_doctor_still_checks_all_keys(self):
        self.cfg["secrets"]["allow"] = ["SW_TEST_CI", "SW_TEST_ABSENT"]
        self.cfg["secrets"]["visible_to_roles"] = []
        result = self.run_script("workspace-doctor.sh", "--json")
        check = next(c for c in json.loads(result.stdout)["checks"] if c["id"] == "secrets.env_file")
        self.assertEqual(check["status"], "ERROR")
        self.assertIn("ERROR unresolvable allowed key: SW_TEST_ABSENT", check["details"])

    @unittest.skipUnless(shutil.which("tmux"), "tmux required for process delivery")
    def test_lifecycle_process_delivery_and_no_tmux_or_state_leak(self):
        tmux = shutil.which("tmux")
        socket = str(self.root / "tmux.sock")
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        wrapper = bin_dir / "tmux"
        wrapper.write_text(f"#!/bin/sh\nexec {shlex.quote(tmux)} -S {shlex.quote(socket)} \"$@\"\n")
        wrapper.chmod(0o700)
        self.env["PATH"] = str(bin_dir) + os.pathsep + self.env["PATH"]
        self.addCleanup(lambda: subprocess.run([tmux, "-S", socket, "kill-server"],
                                              env=self.env, capture_output=True))
        probe = self.root / "probe.py"
        probe.write_text(
            "import json, os, pathlib, sys, time\n"
            "pathlib.Path(sys.argv[1]).write_text(json.dumps({k: v for k, v in os.environ.items() "
            "if k.startswith('SW_TEST_')}))\ntime.sleep(120)\n")
        # One session per role also proves a missing master token cannot block
        # an executor-only start. These are inert shell processes, never agents.
        self.cfg["sessions"] = []
        for role in self.cfg["roles"]:
            self.cfg["roles"][role]["runtime"] = "shell"
            self.cfg["sessions"].append({"id": role, "name": "sr-" + role, "panes": [{
                "name": role, "role": role, "cwd": ".",
                "command": [sys.executable, str(probe), str(self.root / (role + ".json"))]}]})
        self.write_values({k: v for k, v in VALUES.items() if k != "SW_TEST_MCP"})
        start = self.run_script("workspace-start.sh", "executor", "--no-attach")
        self.assertEqual(start.returncode, 0, start.stderr)
        self.assertNotIn("SW_TEST_MCP", start.stdout + start.stderr)
        missing = self.run_script("workspace-start.sh", "master", "--no-attach")
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("SW_TEST_MCP", missing.stdout + missing.stderr)
        self.assertFalse(list(self.root.glob("sw-secret.*")))
        self.write_values(VALUES)
        start_all = self.run_script("workspace-start.sh", "--no-attach")
        self.assertEqual(start_all.returncode, 0, start_all.stderr)
        expected = {"master": {"SW_TEST_MCP", "SW_TEST_SHARED"},
                    "executor": {"SW_TEST_CI", "SW_TEST_SHARED"},
                    "reviewer": {"SW_TEST_CI", "SW_TEST_SHARED"}, "outside": set()}
        deadline = time.monotonic() + 10
        while not all((self.root / (r + ".json")).exists() for r in expected) and time.monotonic() < deadline:
            time.sleep(0.1)
        for role, keys in expected.items():
            data = json.loads((self.root / (role + ".json")).read_text())
            self.assertTrue(data == {k: VALUES[k] for k in keys}, "spawned process delivery mismatch")
            metadata = subprocess.run([tmux, "-S", socket, "show-environment", "-t", "=sr-" + role],
                                      env=self.env, capture_output=True, text=True, check=True)
            self.assertFalse(any(k in metadata.stdout for k in VALUES), "secret name in tmux env")
            history = subprocess.run([tmux, "-S", socket, "capture-pane", "-p", "-t", "=sr-" + role + ":"],
                                     env=self.env, capture_output=True, text=True, check=True)
            self.no_values(metadata.stdout + history.stdout)
        self.assertFalse(list(self.root.glob("sw-secret.*")), "single-use file not removed")
        self.no_values(start.stdout + start.stderr + missing.stdout + missing.stderr + start_all.stdout + start_all.stderr)
        state = self.root / "state"
        self.assertTrue(state.exists(), "positive control: engine state was created")
        for path in state.rglob("*"):
            if path.is_file():
                self.no_values(path.read_text())


if __name__ == "__main__":
    unittest.main()
