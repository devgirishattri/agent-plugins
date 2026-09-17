#!/usr/bin/env python3
"""Read-only session metadata adapter with an explicit filesystem fallback.

Connects only to an already-running local server: never starts/restarts a daemon.
State-DB-only listing avoids the API's optional rollout repair. Legacy files fill
coverage gaps, and physical bytes remain distinct from native logical sessions.
"""
import argparse
from datetime import datetime
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
    def __init__(self, command=None, timeout=3):
        self.errors = tempfile.TemporaryFile()
        try:
            self.process = subprocess.Popen(command or ["codex", "app-server", "proxy"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.errors)
        except OSError:
            self.errors.close()
            raise
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = b""
        self.sequence = 0
        self.timeout = timeout
        self.deadline = time.monotonic() + 15

    def send(self, value):
        self.process.stdin.write((json.dumps(value) + "\n").encode())
        self.process.stdin.flush()

    def call(self, method, params):
        self.sequence += 1
        ident = self.sequence
        self.send(dict(id=ident, method=method, params=params))
        deadline=min(self.deadline,time.monotonic()+self.timeout)
        while time.monotonic() < deadline:
            if b"\n" not in self.buffer:
                if not self.selector.select(max(0, deadline-time.monotonic())):
                    break
                data = os.read(self.process.stdout.fileno(), 65536)
                if not data:
                    self.errors.seek(0)
                    lines=self.errors.read(4096).decode(errors="replace").splitlines()
                    detail=lines[-1][:300] if lines else "native server unavailable"
                    raise RuntimeError(detail)
                self.buffer += data
                if len(self.buffer) > 8_000_000:
                    raise RuntimeError("oversized native response")
                continue
            line, self.buffer = self.buffer.split(b"\n", 1)
            response = json.loads(line)
            if response.get("id") != ident:
                continue
            if "error" in response:
                raise RuntimeError("native metadata capability unavailable")
            return response["result"]
        raise RuntimeError("native metadata timeout")

    def close(self):
        self.selector.close()
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


def native_rows(rpc, archived=False):
    rpc.call("initialize", {"clientInfo": {"name":"session-manager", "version":"1"}})
    rpc.send({"method":"initialized", "params":{}})
    rows = {}
    for archive in ([False, True] if archived else [False]):
        cursor, seen = None, set()
        for _ in range(1000):
            result = rpc.call("thread/list", {"limit":100,"cursor":cursor,
                "archived":archive,"sourceKinds":SOURCES,"useStateDbOnly":True})
            if not isinstance(result.get("data"), list):
                raise RuntimeError("invalid native metadata result")
            for item in result["data"]:
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
    rpc=None
    try:
        rpc=RPC()
        native=native_rows(rpc,archived)
    except (OSError,ValueError,KeyError,TypeError,RuntimeError) as exc:
        if backend=="native":
            raise RuntimeError(f"native metadata unavailable: {exc}") from exc
        print(f"session-manager: native metadata unavailable ({safe(exc)}); using filesystem compatibility backend",file=sys.stderr)
        return legacy
    finally:
        if rpc is not None:
            rpc.close()
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
    parser.add_argument("mode",choices=["list","stats"])
    parser.add_argument("filter",nargs="?")
    parser.add_argument("--archived",action="store_true",help="include archived sessions")
    parser.add_argument("--json",action="store_true",help="metadata rows with source and nullable physical bytes")
    args=parser.parse_args()
    home=Path(os.environ.get("CODEX_HOME",str(Path.home()/".codex")))
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
