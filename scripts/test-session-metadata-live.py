#!/usr/bin/env python3
"""Opt-in integration regression against an actual isolated Codex daemon.

Requires the installed Codex CLI, no credentials or model calls. All daemon
lifecycle and fixture writes belong to this test, never the listing adapter.
Run explicitly: python3 -B scripts/test-session-metadata-live.py
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("metadata", ROOT / "codex/plugins/session-manager/scripts/session-metadata.py")
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)


def main():
    executable = shutil.which("codex")
    if not executable:
        raise RuntimeError("real-daemon regression requires codex on PATH")
    with tempfile.TemporaryDirectory(prefix="sm-live-", dir="/tmp") as temp:
        home = Path(temp) / "home"
        codex_home = home / ".codex"
        binary = codex_home / "packages/standalone/current/codex"
        binary.parent.mkdir(parents=True)
        binary.symlink_to(Path(executable).resolve())
        # Do not inherit plugin hooks, credentials, launch identities or homes.
        fixture_env = {key: value for key, value in os.environ.items()
                       if key in ("PATH", "SYSTEMROOT", "LANG", "TMPDIR")}
        fixture_env.update(HOME=str(home), CODEX_HOME=str(codex_home),
                           XDG_CONFIG_HOME=str(home / ".config"),
                           XDG_CACHE_HOME=str(home / ".cache"))
        original = dict(os.environ)
        os.environ.clear()
        os.environ.update(fixture_env)

        def daemon(action):
            result = subprocess.run([executable, "app-server", "daemon", action],
                                    text=True, capture_output=True, timeout=25)
            if result.returncode:
                raise RuntimeError(f"fixture daemon {action}: {result.stderr}")
            return result.stdout

        try:
            daemon("start")
            print("fixture daemon started", flush=True)
            rpc = M.RPC(timeout=10)
            original_message = rpc._message
            def fixture_message(deadline):
                response = original_message(deadline)
                if "error" in response:
                    print("fixture RPC error:", response["error"], flush=True)
                return response
            rpc._message = fixture_message
            try:
                rpc.call("initialize", {"clientInfo": {"name": "metadata-test", "version": "1"},
                                        "capabilities": {"experimentalApi": True}})
                rpc.send({"method": "initialized", "params": {}})
                identifiers = []
                for name in ("Fixture active", "Fixture archived"):
                    ident = str(uuid.uuid4())
                    identifiers.append(ident)
                    rollout = codex_home / "sessions" / f"rollout-2026-01-01T00-00-00-{ident}.jsonl"
                    rollout.parent.mkdir(exist_ok=True)
                    records = [
                        {"type": "session_meta", "payload": {"id": ident, "cwd": str(home),
                         "timestamp": "2026-01-01T00:00:00Z", "originator": "codex_cli_rs",
                         "cli_version": "0.154.0", "source": "cli", "model_provider": "openai"}},
                        {"type": "response_item", "payload": {"type": "message", "role": "user",
                         "content": [{"type": "input_text", "text": "Offline metadata fixture"}]}},
                        {"type": "event_msg", "payload": {"type": "user_message", "message": "Offline metadata fixture",
                         "images": [], "local_images": [], "text_elements": []}}
                    ]
                    rollout.write_text("".join(json.dumps({"timestamp": "2026-01-01T00:00:00Z", **record}) + "\n" for record in records))
                    rpc.call("thread/resume", {"threadId": ident, "path": str(rollout)})
                    rpc.call("thread/name/set", {"threadId": ident, "name": name})
                rpc.call("thread/archive", {"threadId": identifiers[1]})
            finally:
                rpc.close()
            # Import/indexing is asynchronous. Wait for fixture readiness, not
            # a timing-dependent fixed sleep; production performs no retries.
            until = time.monotonic() + 8
            while True:
                rows = M.collect(codex_home, "native", True)
                if all(rows.get(ident, {}).get("source") == "both" for ident in identifiers):
                    break
                if time.monotonic() >= until:
                    raise AssertionError(f"fixture histories were not indexed: {rows}")
                time.sleep(0.05)
            assert rows[identifiers[0]]["name"] == "Fixture active", rows
            assert rows[identifiers[1]]["name"] == "Fixture archived", rows
            assert rows[identifiers[1]]["archived"], rows
            assert all(row["source"] == "both" and row["bytes"] > 0 for row in rows.values()), rows
            assert not M.collect(codex_home, "native")[identifiers[0]]["archived"]
            assert identifiers[1] not in M.collect(codex_home, "native")
            before = {path: path.read_bytes() for directory in ("sessions", "archived_sessions")
                      for path in (codex_home / directory).rglob("*.jsonl")}
            M.collect(codex_home, "native", True)
            assert all(path.read_bytes() == data for path, data in before.items()), "listing modified history"
            # The native transport itself never invents physical sizes; the
            # adapter adds sizes only for histories observed on the filesystem.
            native_rpc = M.RPC()
            try:
                native = M.native_rows(native_rpc)[identifiers[0]]
                assert native["source"] == "native" and native["bytes"] is None, native
            finally:
                native_rpc.close()
            # Proxy cleanup must leave the fixture daemon serving requests.
            version = json.loads(daemon("version"))
            assert version["status"] == "running", version
            print("daemon version:", version, flush=True)
            print("PASS: production proxy reads active/archive names and file provenance", flush=True)
        finally:
            failed = sys.exc_info()[0] is not None
            try:
                daemon("stop")
                assert not (codex_home / "app-server-control/app-server-control.sock").exists()
                if not failed:
                    assert M.collect(codex_home, "auto"), "filesystem fallback lost fixture histories"
                    try:
                        M.collect(codex_home, "native")
                    except RuntimeError:
                        pass
                    else:
                        raise AssertionError("native-only mode succeeded with no daemon")
                print("fixture daemon stopped", flush=True)
            except Exception as error:
                if not failed:
                    raise
                print(f"fixture cleanup also failed: {error}", file=sys.stderr)
            finally:
                os.environ.clear()
                os.environ.update(original)


if __name__ == "__main__":
    main()
