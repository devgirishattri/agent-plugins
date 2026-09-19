#!/usr/bin/env python3
"""Read-only session metadata adapter with an explicit filesystem fallback.

Uses an existing local server or a temporary stdio server; never starts a daemon.
State-DB-only listing avoids the API's optional rollout repair. Legacy files fill
coverage gaps, and physical bytes remain distinct from native logical sessions.
"""
import argparse
import base64
from datetime import datetime
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import selectors
import subprocess
import sys
import tempfile
import time
sys.dont_write_bytecode = True

SOURCES = ["cli", "vscode", "exec", "appServer", "subAgent", "subAgentReview",
           "subAgentCompact", "subAgentThreadSpawn", "subAgentOther", "unknown"]
UUID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\Z")


class RPC:
    """RFC 6455 text messages over the CLI's byte-transparent Unix proxy.

    No daemon lifecycle operations: closing this object only stops our proxy.
    Both reads and writes share bounded deadlines, including the HTTP upgrade.
    """
    MAX_MESSAGE = 8_000_000

    def __init__(self, command=None, timeout=3):
        self.errors = tempfile.TemporaryFile()
        try:
            self.process = subprocess.Popen(command or ["codex", "app-server", "proxy"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.errors)
        except OSError:
            self.errors.close()
            raise
        self.selector = selectors.DefaultSelector()
        os.set_blocking(self.process.stdout.fileno(), False)
        os.set_blocking(self.process.stdin.fileno(), False)
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.writer = selectors.DefaultSelector()
        self.writer.register(self.process.stdin, selectors.EVENT_WRITE)
        self.buffer = b""
        self.sequence = 0
        self.timeout = timeout
        self.deadline = time.monotonic() + 15
        self.upgraded = False

    def _wait(self, selector, deadline):
        remaining = min(deadline, self.deadline) - time.monotonic()
        if remaining <= 0 or not selector.select(remaining):
            raise RuntimeError("native metadata timeout")

    def _write(self, data, deadline):
        data = memoryview(data)
        while data:
            self._wait(self.writer, deadline)
            try:
                count = os.write(self.process.stdin.fileno(), data)
            except BlockingIOError:
                continue
            data = data[count:]

    def _read(self, count, deadline):
        while len(self.buffer) < count:
            self._wait(self.selector, deadline)
            try:
                data = os.read(self.process.stdout.fileno(), 65536)
            except BlockingIOError:
                continue
            if not data:
                self.errors.seek(0)
                lines = self.errors.read(4096).decode(errors="replace").splitlines()
                detail = next((line.strip() for line in lines if line.startswith("Error:")),
                              next((line.strip() for line in reversed(lines) if line.strip()),
                                   "native server closed connection"))
                raise RuntimeError(detail[:500])
            self.buffer += data
        result, self.buffer = self.buffer[:count], self.buffer[count:]
        return result

    def _upgrade(self, deadline):
        if self.upgraded:
            return
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        request = ("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
                   "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
                   f"Sec-WebSocket-Key: {key}\r\n\r\n")
        self._write(request.encode("ascii"), deadline)
        header = bytearray()
        while not header.endswith(b"\r\n\r\n"):
            if len(header) >= 16384:
                raise RuntimeError("oversized native WebSocket upgrade")
            header.extend(self._read(1, deadline))
        lines = header.decode("latin-1").split("\r\n")
        headers = {}
        # Codex emits one of each handshake header; reject ambiguous duplicates.
        for line in lines[1:]:
            if not line:
                continue
            name, sep, value = line.partition(":")
            if not sep or name.lower() in headers:
                raise RuntimeError("invalid native WebSocket upgrade headers")
            headers[name.lower()] = value.strip()
        expected = base64.b64encode(hashlib.sha1(
            (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")).digest()).decode("ascii")
        if (lines[0].split()[:2] != ["HTTP/1.1", "101"]
                or headers.get("upgrade", "").lower() != "websocket"
                or "upgrade" not in [s.strip().lower() for s in headers.get("connection", "").split(",")]
                or headers.get("sec-websocket-accept") != expected
                or "sec-websocket-extensions" in headers
                or "sec-websocket-protocol" in headers):
            raise RuntimeError("invalid native WebSocket upgrade")
        self.upgraded = True

    def _frame(self, payload, opcode, deadline):
        length = len(payload)
        if length > self.MAX_MESSAGE:
            raise RuntimeError("oversized native request")
        header = bytes([0x80 | opcode])
        if length < 126:
            header += bytes([0x80 | length])
        elif length <= 65535:
            header += b"\xfe" + length.to_bytes(2, "big")
        else:
            header += b"\xff" + length.to_bytes(8, "big")
        mask = os.urandom(4)
        self._write(header + mask + bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload)), deadline)

    def _message(self, deadline):
        fragments = bytearray()
        started = False
        while True:
            first, second = self._read(2, deadline)
            final, opcode, length = bool(first & 0x80), first & 15, second & 127
            if first & 0x70 or second & 0x80:
                raise RuntimeError("invalid native WebSocket frame")
            if length == 126:
                length = int.from_bytes(self._read(2, deadline), "big")
                if length < 126:
                    raise RuntimeError("invalid native WebSocket length")
            elif length == 127:
                length = int.from_bytes(self._read(8, deadline), "big")
                if length < 65536:
                    raise RuntimeError("invalid native WebSocket length")
            if opcode >= 8:
                if not final or length > 125 or opcode not in (8, 9, 10):
                    raise RuntimeError("invalid native WebSocket control frame")
                payload = self._read(length, deadline)
                if opcode == 8:
                    raise RuntimeError("native server closed WebSocket")
                if opcode == 9:
                    self._frame(payload, 10, deadline)
                continue
            if opcode not in (0, 1) or (opcode == 0) != started:
                raise RuntimeError("invalid native WebSocket text sequence")
            if len(fragments) + length > self.MAX_MESSAGE:
                raise RuntimeError("oversized native response")
            fragments.extend(self._read(length, deadline))
            started = True
            if final:
                return json.loads(fragments.decode("utf-8"))

    def send(self, value, deadline=None):
        deadline = deadline or min(self.deadline, time.monotonic() + self.timeout)
        self._upgrade(deadline)
        self._frame(json.dumps(value).encode("utf-8"), 1, deadline)

    def call(self, method, params):
        self.sequence += 1
        ident = self.sequence
        deadline=min(self.deadline,time.monotonic()+self.timeout)
        self.send(dict(id=ident, method=method, params=params), deadline)
        while time.monotonic() < deadline:
            response = self._message(deadline)
            if not isinstance(response, dict):
                raise RuntimeError("invalid native RPC response")
            if response.get("id") != ident:
                continue
            if "error" in response:
                error = response["error"]
                detail = error.get("message", "unknown error") if isinstance(error, dict) else error
                raise RuntimeError(f"native {method}: {safe(detail)}")
            return response["result"]
        raise RuntimeError("native metadata timeout")

    def close(self):
        self.selector.close()
        self.writer.close()
        try:
            self.process.stdin.close()
        except OSError:
            pass
        try:
            self.process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.process.stdout.close()
        self.errors.close()


class StdioRPC(RPC):
    """An owned, short-lived app server using newline-delimited JSON, not WS."""

    def __init__(self, command=None, timeout=5):
        super().__init__(command or ["codex", "app-server", "--listen", "stdio://"], timeout)

    def send(self, value, deadline=None):
        deadline = deadline or min(self.deadline, time.monotonic() + self.timeout)
        data = json.dumps(value).encode("utf-8") + b"\n"
        if len(data) > self.MAX_MESSAGE:
            raise RuntimeError("oversized native request")
        self._write(data, deadline)

    def _message(self, deadline):
        message = bytearray()
        while True:
            first = self._read(1, deadline)
            chunk, separator, rest = (first + self.buffer).partition(b"\n")
            self.buffer = rest if separator else b""
            message.extend(chunk)
            if len(message) > self.MAX_MESSAGE:
                raise RuntimeError("oversized native response")
            if separator:
                return json.loads(message.decode("utf-8"))


def native_snapshot(archived=False):
    """Try the shared server first, then an owned server; always close children."""
    failures = []
    for factory in (RPC, StdioRPC):
        rpc = None
        try:
            rpc = factory()
            return native_rows(rpc, archived)
        except (OSError, ValueError, KeyError, TypeError, RuntimeError) as exc:
            failures.append(safe(exc))
        finally:
            if rpc is not None:
                rpc.close()
    raise RuntimeError("shared server: " + failures[0] + "; temporary server: " + failures[1])


def native_rows(rpc, archived=False):
    rpc.call("initialize", {"clientInfo": {"name":"session-manager", "version":"1"}})
    rpc.send({"method":"initialized", "params":{}})
    rows = {}
    for archive in ([False, True] if archived else [False]):
        cursor, seen = None, set()
        for _ in range(1000):
            result = rpc.call("thread/list", {"limit":100,"cursor":cursor,
                "archived":archive,"sourceKinds":SOURCES,"useStateDbOnly":True})
            if not isinstance(result, dict) or not isinstance(result.get("data"), list):
                raise RuntimeError("invalid native metadata result")
            for item in result["data"]:
                if not isinstance(item, dict):
                    raise RuntimeError("invalid native session identity")
                ident, cwd = item.get("id"), item.get("cwd")
                if not isinstance(ident,str) or not UUID.fullmatch(ident) or not isinstance(cwd,str):
                    raise RuntimeError("invalid native session identity")
                stamp=item.get("updatedAt",0)
                # Installed schema defines Unix seconds, not milliseconds.
                if type(stamp) not in (int,float) or not math.isfinite(stamp) or not 0<=stamp<=253402300799:
                    raise RuntimeError("invalid native timestamp")
                rows[ident] = dict(id=ident, cwd=cwd, name=item.get("name") or "(untitled)",
                                  mtime=stamp, bytes=None, archived=archive, source="native",
                                  name_present="name" in item)
            cursor = result.get("nextCursor")
            if not cursor:
                break
            if not isinstance(cursor,str) or cursor in seen:
                raise RuntimeError("invalid/repeated native pagination cursor")
            seen.add(cursor)
        else:
            raise RuntimeError("native pagination limit exceeded")
    return rows


def filesystem_rows(home, archived=False):
    spec = importlib.util.spec_from_file_location("session_names",Path(__file__).with_name("session-names.py"))
    names_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(names_module)
    try:
        with (home/"session_index.jsonl").open() as stream:
            names = names_module.latest_names(stream)
    except OSError:
        names = {}
    rows = {}
    for directory in (["sessions","archived_sessions"] if archived else ["sessions"]):
        for path in (home/directory).rglob("*.jsonl"):
            try:
                with path.open() as stream:
                    payload = json.loads(stream.readline()).get("payload",{})
                ident,cwd = payload.get("id"),payload.get("cwd")
                if not isinstance(ident,str) or not UUID.fullmatch(ident) or not isinstance(cwd,str):
                    continue
                stat=path.stat()
                old=rows.get(ident)
                if old is None or stat.st_mtime > old["mtime"]:
                    rows[ident]=dict(id=ident,cwd=cwd,name=names.get(ident) or "(untitled)",
                                    mtime=stat.st_mtime,bytes=stat.st_size+(old["bytes"] if old else 0),
                                    archived=directory!="sessions",source="filesystem")
                elif old is not None:
                    old["bytes"] += stat.st_size
            except (OSError,ValueError,TypeError,AttributeError):
                continue
    return rows


def collect(home, backend="auto", archived=False):
    if backend not in {"auto","native","filesystem"}:
        raise ValueError("SESSION_MANAGER_BACKEND must be auto, native or filesystem")
    legacy=filesystem_rows(home,archived)
    if backend=="filesystem":
        return legacy
    try:
        native=native_snapshot(archived)
    except (OSError,ValueError,KeyError,TypeError,RuntimeError) as exc:
        if backend=="native":
            raise RuntimeError(f"native metadata unavailable: {exc}") from exc
        print(f"session-manager: native metadata unavailable ({safe(exc)}); using filesystem compatibility backend",file=sys.stderr)
        return legacy
    for ident,row in native.items():
        if ident in legacy:
            row["bytes"]=legacy[ident]["bytes"]
            row["source"]="both"
            if not row["name_present"]:
                row["name"]=legacy[ident]["name"]
        row.pop("name_present",None)
        legacy[ident]=row
    print("session-manager: backend=native+filesystem; physical sizes exclude unmaterialized history",file=sys.stderr)
    return legacy


def safe(value):
    return re.sub(r"[\x00-\x1f\x7f]"," ",str(value))


def deletion_rows():
    if os.environ.get("SESSION_MANAGER_BACKEND", "auto") not in {"auto", "native"}:
        raise RuntimeError("bulk deletion requires native metadata; use SESSION_MANAGER_BACKEND=auto or native")
    try:
        return native_snapshot()
    except (OSError, ValueError, KeyError, TypeError, RuntimeError) as exc:
        raise RuntimeError(f"bulk deletion requires native metadata: {safe(exc)}; check the Codex CLI installation and retry") from exc


def deletion_plan(home, project):
    """Native preflight is mandatory, including for an empty/file-only project."""
    if not project or not os.path.isabs(project):
        raise RuntimeError("expected absolute project path")
    native = deletion_rows()
    legacy = filesystem_rows(home)
    candidates = set(ident for ident, row in native.items() if matches(row, project, "list"))
    candidates.update(ident for ident, row in legacy.items() if matches(row, project, "list"))
    for ident in sorted(candidates):
        row = native.get(ident)
        if row is None:
            state, reason = "SKIP", "missing from active native metadata (filesystem-only)"
        elif not os.path.isabs(row["cwd"]) or not matches(row, project, "list"):
            state, reason = "SKIP", "native session belongs to a different project"
        else:
            state, reason = "ELIGIBLE", "native project verified"
        row = row or legacy[ident]
        print("\t".join(map(safe, [state, ident, row["name"], reason])))


def verify_project(ident, project):
    """Fresh native-only binding check for a project-scoped mutation.

    Never use collect(): even its native backend merges unverified transcript
    rows to support read-only discovery. The filesystem backend cannot authorize
    deletion, and a native outage must not downgrade this check to transcripts.
    """
    if not UUID.fullmatch(ident) or not project or not os.path.isabs(project):
        raise RuntimeError("invalid UUID or expected absolute project path")
    rows = deletion_rows()
    row = rows.get(ident)
    if row is None:
        raise RuntimeError(f"{ident}: session missing from active native metadata; deletion refused")
    if not os.path.isabs(row["cwd"]) or os.path.realpath(row["cwd"]) != os.path.realpath(project):
        raise RuntimeError(f"{ident}: native session belongs to a different project; deletion refused")


def matches(row, query, mode):
    if mode=="list":
        return query=="all" or os.path.realpath(row["cwd"])==os.path.realpath(query)
    return not query or query.lower() in row["cwd"].lower() or (
        os.path.isabs(query) and os.path.realpath(query).lower() in os.path.realpath(row["cwd"]).lower())


def size(value):
    if value is None: return "unknown"
    if value>=1073741824: return f"{value//1073741824}.{value%1073741824*10//1073741824} GB"
    if value>=1048576: return f"{value//1048576} MB"
    if value>=1024: return f"{value//1024} KB"
    return f"{value} B"


def age(stamp):
    seconds=max(0,int(time.time()-stamp))
    if seconds<60: return "just now"
    if seconds<3600: return f"{seconds//60}m ago"
    if seconds<86400: return f"{seconds//3600}h ago"
    return f"{seconds//86400}d ago"


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("mode",choices=["list","stats","verify-project","delete-plan"])
    parser.add_argument("filter",nargs="?")
    parser.add_argument("--archived",action="store_true",help="include archived sessions")
    parser.add_argument("--json",action="store_true",help="metadata rows with source and nullable physical bytes")
    parser.add_argument("--project",help="expected absolute project for verify-project")
    args=parser.parse_args()
    if args.mode == "verify-project":
        verify_project(args.filter or "", args.project)
        return
    home=Path(os.environ.get("CODEX_HOME",str(Path.home()/".codex")))
    if args.mode == "delete-plan":
        deletion_plan(home, args.project)
        return
    rows=list(collect(home,os.environ.get("SESSION_MANAGER_BACKEND","auto"),args.archived).values())
    cwd=os.getcwd()
    logical=os.environ.get("PWD","")
    if logical and os.path.realpath(logical)==cwd:
        cwd=logical
    query=args.filter if args.filter is not None else (cwd if args.mode=="list" else "")
    rows=[r for r in rows if matches(r,query,args.mode)]
    if args.json:
        print(json.dumps({"sessions":rows,"size_semantics":"physical known files; null means unknown"}))
        return
    if args.mode=="list":
        for row in sorted(rows,key=lambda r:r["mtime"],reverse=True):
            print("\t".join(map(safe,[row["name"],row["id"],row["cwd"],size(row["bytes"]),
                datetime.fromtimestamp(row["mtime"]).strftime("%Y-%m-%d %H:%M")])))
        return
    if not rows:
        print("No sessions found" + (" matching filter: "+safe(query) if query else ""))
        return
    projects={}
    for row in rows:
        projects.setdefault(os.path.realpath(row["cwd"]),[]).append(row)
    print("PROJECT\tSESSIONS\tSIZE\tLAST-ACTIVE")
    for cwd,group in sorted(projects.items(),key=lambda item:max(r["mtime"] for r in item[1]),reverse=True):
        amount=sum(r["bytes"] or 0 for r in group)
        label=size(amount) + (" + unknown" if any(r["bytes"] is None for r in group) else "")
        print(f"{safe(cwd)}\t{len(group)}\t{label}\t{age(max(r['mtime'] for r in group))}")
    total=size(sum(r["bytes"] or 0 for r in rows))
    if any(r["bytes"] is None for r in rows): total+=" + unknown"
    print(f"\nTOTALS\t{len(projects)} projects\t{len(rows)} sessions\t{total}")
    print("\nTOP 5 LARGEST SESSIONS\nSIZE\tPROJECT\tNAME")
    for row in sorted((r for r in rows if r["bytes"] is not None),key=lambda r:r["bytes"],reverse=True)[:5]:
        print(f"{size(row['bytes'])}\t{safe(row['cwd'])}\t{safe(row['name'])}")


if __name__=="__main__":
    try:
        main()
    except (ValueError,RuntimeError,OSError) as error:
        print(f"ERROR: {error}",file=sys.stderr)
        sys.exit(2)
