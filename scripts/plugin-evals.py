#!/usr/bin/env python3
"""Portable scenario validation and opt-in Codex model probes.

Model results are report-only, including regex grades: model runs are stochastic.
Deterministic runtime suites remain the release gate. No report publishing.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import time

ROOT=Path(__file__).resolve().parents[1]
FIXTURE_STORES={"SESSION_CONTEXT_HOME","SESSION_SCHEDULER_HOME","KNOWLEDGE_MEMORY_HOME","SESSION_CHAT_TARGET_MESSAGES_DIR"}


def stop_group(process):
    """Also stop descendants that outlive their completed launcher."""
    try: os.killpg(process.pid,signal.SIGTERM)
    except ProcessLookupError: return
    time.sleep(0.1)
    try: os.killpg(process.pid,signal.SIGKILL)
    except ProcessLookupError: pass


def setup_command(command,env,cwd):
    process=subprocess.Popen(command,env=env,cwd=cwd,stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
    try:
        out,err=process.communicate(timeout=30)
        if process.returncode: raise RuntimeError(err.decode(errors="replace")[-2000:])
    finally:
        stop_group(process)
        process.wait()


def inside(base, relative):
    if not isinstance(relative,str) or not relative or Path(relative).is_absolute():
        raise ValueError("fixture path must be a non-empty relative path")
    target=(base/relative).resolve()
    if not target.is_relative_to(base.resolve()):
        raise ValueError(f"fixture path escapes workspace: {relative}")
    return target


def validate(path):
    case=json.loads(path.read_text())
    if not isinstance(case,dict): raise ValueError(f"{path}: scenario must be an object")
    for key in ("id","prompt","kind"):
        if not isinstance(case.get(key),str) or not case[key]:
            raise ValueError(f"{path}: {key} required")
    if case["id"]!=path.parent.name or case["kind"] not in {"positive","negative","contract"}:
        raise ValueError(f"{path}: invalid case identity/kind")
    expects=case.get("expectations",{})
    if not isinstance(expects,dict): raise ValueError("expectations must be an object")
    for key in ("regex","tool_used","tool_used_any","forbidden_skills"):
        values=expects.get(key,[])
        if not isinstance(values,list) or not all(isinstance(v,str) for v in values):
            raise ValueError(f"{path}: {key} must be string array")
    for pattern in expects.get("regex",[]): re.compile(pattern)
    files=expects.get("files",{})
    if not isinstance(files,dict): raise ValueError("files must be an object")
    for name,present in files.items():
        inside(path.parent,name)
        if type(present) is not bool: raise ValueError("file expectation must be boolean")
    if case.get("scaffold"):
        if not inside(path.parent,case["scaffold"]).is_file(): raise ValueError("missing scaffold")
    unset=case.get("unset_env",[])
    if not isinstance(unset,list) or any(not isinstance(name,str) or name not in FIXTURE_STORES for name in unset):
        raise ValueError("unset_env may contain only fixture store variables")
    return case


def grade(case,events,workspace):
    commands=[]; messages=[]
    for event in events:
        if event.get("type")!="item.completed": continue
        item=event.get("item",{})
        if item.get("type")=="command_execution": commands.append(item.get("command",""))
        if item.get("type")=="agent_message": messages.append(item.get("text",""))
    transcript="\n".join(commands)
    final="\n".join(messages)
    checks={}
    expected=case.get("expectations",{})
    for pattern in expected.get("regex",[]): checks["regex:"+pattern]=bool(re.search(pattern,final,re.MULTILINE))
    for script in expected.get("tool_used",[]): checks["tool:"+script]=script in transcript
    if expected.get("tool_used_any"):
        checks["tool:any"] = any(script in transcript for script in expected["tool_used_any"])
    for skill in expected.get("forbidden_skills",[]):
        checks["no-skill:"+skill]=not bool(re.search(r"/skills/"+re.escape(skill)+r"/SKILL\.md",transcript))
    for name,present in expected.get("files",{}).items(): checks["file:"+name]=inside(workspace,name).exists()==present
    return checks


def probe(case,path,timeout,auth_home):
    with tempfile.TemporaryDirectory(prefix="plugin-eval-") as temp:
        base=Path(temp); workspace=base/"workspace"; workspace.mkdir()
        home=base/"home"; home.mkdir(); codex_home=home/".codex"; codex_home.mkdir()
        # Keep authentication private and ephemeral; never copy user config,
        # memories, session histories, launch variables or message stores.
        auth=auth_home/"auth.json"
        if auth.is_file():
            shutil.copyfile(auth,codex_home/"auth.json")
            (codex_home/"auth.json").chmod(0o600)
        env={k:v for k,v in os.environ.items() if not k.startswith(("CODEX_","SESSION_","KNOWLEDGE_","TMUX","CLAUDE_"))}
        env.update(HOME=str(home),CODEX_HOME=str(codex_home),PYTHONDONTWRITEBYTECODE="1",
            SESSION_CONTEXT_HOME=str(base/"context"),SESSION_SCHEDULER_HOME=str(base/"scheduler"),
            KNOWLEDGE_MEMORY_HOME=str(workspace/".agents/memory"),SESSION_CHAT_TARGET_MESSAGES_DIR=str(base/"messages"),
            TMUX_TMPDIR=str(base/"tmux"),SESSION_MANAGER_BACKEND="filesystem")
        for key in ("SESSION_CONTEXT_HOME","SESSION_SCHEDULER_HOME","SESSION_CHAT_TARGET_MESSAGES_DIR","TMUX_TMPDIR"):
            Path(env[key]).mkdir()
        for key in case.get("unset_env",[]): env.pop(key,None)
        market=base/"market"
        shutil.copytree(ROOT/".agents/plugins",market/".agents/plugins")
        shutil.copytree(ROOT/"codex",market/"codex")
        plugin=path.parents[2].name
        for args in (["marketplace","add",str(market),"--json"],["add",plugin+"@girishattri-plugins","--json"]):
            setup_command(["codex","plugin",*args],env,workspace)
        if case.get("scaffold"):
            setup_command(["bash",str(inside(path.parent,case["scaffold"])),str(workspace)],env,workspace)
        # Load only this disposable home's native-generated plugin config.
        # Ignoring it would silently disable the plugin under test.
        command=["codex","exec","--ephemeral","--json","--skip-git-repo-check",
                 "--disable","apps","--disable","remote_plugin","--disable","browser_use",
                 "--disable","computer_use","--disable","multi_agent",
                 "--sandbox","workspace-write","-C",str(workspace),case["prompt"]]
        started=time.monotonic()
        process=subprocess.Popen(command,env=env,cwd=workspace,text=True,stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
        try:
            out,err=process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            stop_group(process)
            out,err=process.communicate()
            return dict(id=case["id"],status="timeout",seconds=round(time.monotonic()-started,2))
        finally:
            stop_group(process)
        events=[]
        for line in out.splitlines():
            try: events.append(json.loads(line))
            except ValueError: pass
        return dict(id=case["id"],status="completed" if process.returncode==0 else "execution_error",
            seconds=round(time.monotonic()-started,2),checks=grade(case,events,workspace),
            events=events,stderr=err[-2000:])


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plugin")
    parser.add_argument("--case")
    parser.add_argument("--run",action="store_true",help="opt in to paid model probes; otherwise validate only")
    parser.add_argument("--max-cases",type=int,default=1)
    parser.add_argument("--timeout",type=int,default=90,help="wall-clock seconds per model probe")
    parser.add_argument("--output",type=Path)
    args=parser.parse_args()
    if args.max_cases<1 or not 1<=args.timeout<=600: parser.error("invalid run budget")
    paths=sorted((ROOT/"plugins").glob("*/evals/*/case.json"))
    if args.plugin: paths=[p for p in paths if p.parents[2].name==args.plugin]
    if args.case: paths=[p for p in paths if p.parent.name==args.case]
    if not paths: parser.error("no matching portable scenarios")
    cases=[(p,validate(p)) for p in paths]
    if not args.run:
        print(f"PASS: {len(cases)} portable scenarios validated; no model calls")
        return
    if args.output is None: parser.error("--run requires --output for local evidence")
    auth_home=Path(os.environ.get("CODEX_HOME",str(Path.home()/".codex")))
    results=[]
    args.output.parent.mkdir(parents=True,exist_ok=True)
    for path,case in cases[:args.max_cases]:
        try:
            result=probe(case,path,args.timeout,auth_home)
        except (OSError,RuntimeError,subprocess.SubprocessError) as exc:
            result=dict(id=case["id"],status="infrastructure_error",error=str(exc))
        results.append(result)
        args.output.write_text(json.dumps({"report_only":True,"provider":"codex","runs":results},indent=2)+"\n")
        print(case["id"],result["status"],flush=True)

if __name__=="__main__": main()
