#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import sys
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

if __name__=="__main__": unittest.main()
