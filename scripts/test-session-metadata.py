#!/usr/bin/env python3
import importlib.util
import base64
import hashlib
import json
import os
from pathlib import Path
import tempfile
import sys
import struct
import subprocess
import time
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
SPEC=importlib.util.spec_from_file_location("metadata",ROOT/"codex/plugins/session-manager/scripts/session-metadata.py")
M=importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)
SID="11111111-1111-4111-8111-111111111111"
OTHER="22222222-2222-4222-8222-222222222222"

class Fake:
    def __init__(self,pages): self.pages=iter(pages); self.calls=[]
    def call(self,method,params):
        self.calls.append((method,params))
        return {} if method=="initialize" else next(self.pages)
    def send(self,value): pass
    def close(self): pass

def row(ident=SID): return dict(id=ident,cwd="/project",name="Native title",updatedAt=123)

class Metadata(unittest.TestCase):
    def test_raw_jsonl_is_not_websocket(self):
        result = subprocess.run([sys.executable, "-u", __file__, "--wire-fixture", "normal"],
                                input=b'{"id":1,"method":"initialize","params":{}}\n',
                                capture_output=True, timeout=2)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"missing upgrade", result.stderr)

    def wire(self, mode):
        return M.RPC([sys.executable, "-u", __file__, "--wire-fixture", mode], timeout=0.3)

    def test_websocket_wire(self):
        for mode in ("normal", "extended16", "extended64", "fragment_ping", "notification"):
            with self.subTest(mode=mode):
                rpc = self.wire(mode)
                try:
                    self.assertEqual(rpc.call("initialize", {})["ok"], True)
                finally:
                    rpc.close()
                self.assertEqual(rpc.process.returncode, 0)

    def test_bad_websocket_wire(self):
        for mode, error in (("bad_accept", "upgrade"), ("http_error", "upgrade"),
                            ("masked", "frame"), ("rsv", "frame"),
                            ("oversized", "oversized"), ("orphan", "sequence"),
                            ("close", "closed"), ("partial", "timeout"),
                            ("binary", "sequence"), ("bad_control", "control"),
                            ("bad_length", "length"), ("invalid_json", "Expecting")):
            with self.subTest(mode=mode):
                rpc = self.wire(mode)
                try:
                    with self.assertRaisesRegex((RuntimeError, ValueError), error):
                        rpc.call("initialize", {})
                finally:
                    rpc.close()
                self.assertIsNotNone(rpc.process.poll())

    def test_client_extended_lengths_are_masked(self):
        for length in (200, 70000):
            rpc = self.wire("normal")
            try:
                self.assertTrue(rpc.call("initialize", {"padding": "x" * length})["ok"])
            finally:
                rpc.close()
            self.assertEqual(rpc.process.returncode, 0)

    def test_blocked_proxy_write_is_bounded(self):
        rpc = self.wire("no_read")
        try:
            with self.assertRaisesRegex(RuntimeError, "timeout"):
                rpc.call("initialize", {"padding": "x" * 1_000_000})
        finally:
            rpc.close()
        self.assertIsNotNone(rpc.process.poll())

    def test_proxy_timeout_closes_child(self):
        rpc=M.RPC([sys.executable,"-u","-c","import time; time.sleep(30)"],timeout=0.05)
        try:
            with self.assertRaisesRegex(RuntimeError,"timeout"):
                rpc.call("initialize",{})
        finally:
            rpc.close()
        self.assertIsNotNone(rpc.process.poll())
    def test_proxy_failure_diagnostic(self):
        rpc=M.RPC([sys.executable,"-u","-c","import sys; sys.stdin.readline(); print('no daemon fixture',file=sys.stderr)"],timeout=1)
        try:
            with self.assertRaisesRegex(RuntimeError,"no daemon fixture"):
                rpc.call("initialize",{})
        finally:
            rpc.close()
    def test_pagination_sources_and_archives(self):
        rpc=Fake([dict(data=[row()],nextCursor="next"),dict(data=[row(OTHER)],nextCursor=None),dict(data=[],nextCursor=None)])
        result=M.native_rows(rpc,True)
        self.assertEqual(len(result),2)
        self.assertIsNone(result[SID]["bytes"])
        self.assertEqual([c[1]["archived"] for c in rpc.calls[1:]],[False,False,True])
        self.assertTrue(all(c[1]["useStateDbOnly"] for c in rpc.calls[1:]))
        self.assertTrue(all(c[1]["sourceKinds"]==M.SOURCES for c in rpc.calls[1:]))
    def test_repeated_cursor(self):
        with self.assertRaises(RuntimeError): M.native_rows(Fake([dict(data=[],nextCursor="x")]*2))
    def test_bad_identity(self):
        with self.assertRaises(RuntimeError): M.native_rows(Fake([dict(data=[dict(id="bad",cwd="/project")])]))
        with self.assertRaises(RuntimeError): M.native_rows(Fake([dict(data=[None])]))
        with self.assertRaises(RuntimeError): M.native_rows(Fake([[]]))
    def test_bad_stamp(self):
        with self.assertRaises(RuntimeError): M.native_rows(Fake([dict(data=[dict(row(),updatedAt="bad")])]))
    def test_legacy_and_native_merge(self):
        with tempfile.TemporaryDirectory() as temp:
            home=Path(temp); (home/"sessions").mkdir()
            (home/"sessions/fixture.jsonl").write_text(json.dumps(dict(payload=dict(id=SID,cwd="/legacy")))+"\n")
            rpc=Fake([dict(data=[row(),row(OTHER)],nextCursor=None)])
            with patch.object(M,"RPC",return_value=rpc): result=M.collect(home)
            self.assertEqual(result[SID]["name"],"Native title")
            self.assertEqual(result[SID]["cwd"],"/project")
            self.assertEqual(result[SID]["source"],"both")
            self.assertGreater(result[SID]["bytes"],0)
            self.assertIsNone(result[OTHER]["bytes"])
    def test_unavailable_fallback(self):
        with tempfile.TemporaryDirectory() as temp,patch.object(M,"RPC",side_effect=OSError("missing")):
            self.assertEqual(M.collect(Path(temp)),{})
            with self.assertRaises(RuntimeError): M.collect(Path(temp),"native")
    def test_filesystem_never_connects(self):
        with tempfile.TemporaryDirectory() as temp,patch.object(M,"RPC",side_effect=AssertionError("should not connect")):
            self.assertEqual(M.collect(Path(temp),"filesystem"),{})
    def test_sizes_unknown(self):
        self.assertEqual(M.size(None),"unknown")
        self.assertEqual(M.size(0),"0 B")
    def test_ms_timestamp_rejected(self):
        with self.assertRaises(RuntimeError): M.native_rows(Fake([dict(data=[dict(row(),updatedAt=1789591003000)])]))
    def test_cwd_alias(self):
        with tempfile.TemporaryDirectory() as temp:
            real=Path(temp)/"physical"; real.mkdir()
            alias=Path(temp)/"logical"; alias.symlink_to(real,target_is_directory=True)
            self.assertTrue(M.matches(dict(cwd=str(real)),str(alias),"list"))
            self.assertTrue(M.matches(dict(cwd=str(real)),str(alias),"stats"))
            self.assertFalse(M.matches(dict(cwd=str(real/"subdir")),str(alias),"list"))
    def test_missing_name_falls_back_but_null_clears(self):
        legacy={SID:dict(id=SID,cwd="/project",name="Legacy",mtime=1,bytes=3,source="filesystem")}
        for present in (True,False):
            item=row()
            if present: item["name"]=None
            else: del item["name"]
            with patch.object(M,"filesystem_rows",return_value={k:dict(v) for k,v in legacy.items()}),patch.object(M,"RPC",return_value=Fake([dict(data=[item])])):
                result=M.collect(Path("/unused"))
                self.assertEqual(result[SID]["name"],"(untitled)" if present else "Legacy")

def wire_fixture(mode):
    """Independent stdio peer: proxy is a byte pipe, not a JSONL RPC endpoint."""
    incoming, outgoing = sys.stdin.buffer, sys.stdout.buffer
    header = bytearray()
    while not header.endswith(b"\r\n\r\n"):
        byte = incoming.read(1)
        if not byte:
            raise RuntimeError("missing upgrade")
        header.extend(byte)
    assert header.startswith(b"GET / HTTP/1.1\r\n")
    headers = dict(line.split(b": ", 1) for line in bytes(header).split(b"\r\n")[1:] if line)
    assert headers[b"Upgrade"] == b"websocket" and headers[b"Sec-WebSocket-Version"] == b"13"
    assert len(base64.b64decode(headers[b"Sec-WebSocket-Key"])) == 16
    accept = base64.b64encode(hashlib.sha1(headers[b"Sec-WebSocket-Key"] + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
    if mode == "bad_accept": accept = b"incorrect"
    status = b"403 Forbidden" if mode == "http_error" else b"101 Switching Protocols"
    outgoing.write(b"HTTP/1.1 " + status + b"\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")
    outgoing.flush()
    if mode in ("bad_accept", "http_error"): return
    if mode == "no_read": time.sleep(5); return

    def read_frame():
        first, second = incoming.read(2)
        assert second & 128, "client frame must be masked"
        length = second & 127
        if length == 126: length = struct.unpack("!H", incoming.read(2))[0]
        elif length == 127: length = struct.unpack("!Q", incoming.read(8))[0]
        mask = incoming.read(4)
        payload = incoming.read(length)
        assert len(payload) == length
        return first, bytes(b ^ mask[i % 4] for i, b in enumerate(payload))

    def frame(payload, first=129):
        length = len(payload)
        suffix = bytes([length]) if length < 126 else (b"\x7e" + struct.pack("!H", length) if length < 65536 else b"\x7f" + struct.pack("!Q", length))
        outgoing.write(bytes([first]) + suffix + payload)
        outgoing.flush()

    first, payload = read_frame()
    assert first == 129
    request = json.loads(payload)
    result = {"ok": True}
    if mode in ("extended16", "extended64"): result["padding"] = "x" * (200 if mode == "extended16" else 70000)
    response = json.dumps({"id": request["id"], "result": result}).encode()
    if mode == "masked": outgoing.write(b"\x81\x80"); outgoing.flush()
    elif mode == "rsv": frame(b"", 193)
    elif mode == "oversized": outgoing.write(b"\x81\x7f" + struct.pack("!Q", 8_000_001)); outgoing.flush()
    elif mode == "orphan": frame(response, 128)
    elif mode == "binary": frame(response, 130)
    elif mode == "bad_control": frame(b"", 9)
    elif mode == "bad_length": outgoing.write(b"\x81\x7e\x00\x01"); outgoing.flush()
    elif mode == "close": frame(b"", 136)
    elif mode == "partial": outgoing.write(b"\x81\x05{"); outgoing.flush(); time.sleep(5)
    elif mode == "invalid_json": frame(b"oops")
    elif mode == "fragment_ping":
        frame(response[:10], 1); frame(b"pulse", 137)
        opcode, pong = read_frame()
        assert opcode == 138 and pong == b"pulse"
        frame(response[10:], 128)
    else:
        if mode == "notification": frame(b'{"method":"event"}'); frame(b'{"id":999,"result":{}}')
        frame(response)


if __name__=="__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--wire-fixture": wire_fixture(sys.argv[2])
    else: unittest.main()
