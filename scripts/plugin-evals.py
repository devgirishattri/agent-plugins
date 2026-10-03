#!/usr/bin/env python3
"""Portable scenario validation and opt-in Codex model probes.

Model results are report-only, including regex grades: model runs are stochastic.
Deterministic runtime suites remain the release gate. No report publishing.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
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
    executions=expects.get("executions",[])
    if not isinstance(executions,list): raise ValueError("executions must be an array")
    for check in executions:
        if not isinstance(check,dict) or set(check)-{"script","exit_code","min_count","max_count","args","args_prefix"}:
            raise ValueError("invalid execution expectation")
        if not isinstance(check.get("script"),str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*\.sh",check["script"]):
            raise ValueError("execution script must be a literal .sh basename")
        if type(check.get("exit_code")) is not int: raise ValueError("execution exit_code must be an integer")
        if 'args' in check and 'args_prefix' in check: raise ValueError('choose exact args or args_prefix')
        for field in ['args','args_prefix']:
            if field in check and (not isinstance(check[field],list) or any(not isinstance(arg,str) for arg in check[field])):
                raise ValueError('execution arguments must be string arrays')
        lower=check.get("min_count",1); upper=check.get("max_count",lower)
        if type(lower) is not int or type(upper) is not int or lower<0 or upper<lower:
            raise ValueError("invalid execution count bounds")
    artifacts=expects.get("json_contains",{})
    if not isinstance(artifacts,dict): raise ValueError("json_contains must be an object")
    for name,expected in artifacts.items():
        inside(path.parent,name)
        if not isinstance(expected,dict) or not expected: raise ValueError("JSON artifact expectation must be a nonempty object")
    if case.get("scaffold"):
        if not inside(path.parent,case["scaffold"]).is_file(): raise ValueError("missing scaffold")
    unset=case.get("unset_env",[])
    if not isinstance(unset,list) or any(not isinstance(name,str) or name not in FIXTURE_STORES for name in unset):
        raise ValueError("unset_env may contain only fixture store variables")
    return case


def literal_script(command,wrapped=False):
    """Recognize direct literal Bash calls only; compositions are not receipts."""
    if not isinstance(command,str) or '\n' in command or '\r' in command: return None
    try:
        lexer=shlex.shlex(command,posix=True,punctuation_chars=";&|<>()")
        lexer.whitespace_split=True; lexer.commenters=""
        tokens=list(lexer)
    except ValueError: return None
    # Codex command events can retain the runtime's single shell wrapper.
    if len(tokens)==3 and tokens[0] in {'/bin/bash','/bin/zsh'} and tokens[1] in {'-lc','-c'}:
        if wrapped: return None
        return literal_script(tokens[2],wrapped=True)
    if len(tokens)<2 or tokens[0] not in {"bash","/bin/bash"}: return None
    if any(all(c in ";&|<>()" for c in token) or "$" in token or "`" in token for token in tokens): return None
    script=tokens[1]
    if script.startswith("-") or not script.endswith(".sh"): return None
    path=Path(script)
    if not path.is_absolute() or '..' in path.parts: return None
    return path,tokens[2:]


def tree_digest(root):
    """Detect persistent installed-plugin drift, including sourced/imported code."""
    files={}
    for path in sorted(root.rglob('*')):
        if path.name=='.in_use': continue
        if path.is_symlink(): raise ValueError('symlink in trusted plugin tree')
        if path.is_file(): files[str(path.relative_to(root))]=hashlib.sha256(path.read_bytes()).hexdigest()
    return hashlib.sha256(json.dumps(files,sort_keys=True).encode()).hexdigest()


def trust_tree(root):
    root=root.resolve();digest=tree_digest(root)
    return {str(p.resolve()):{'root':str(root),'tree_sha256':digest} for p in root.rglob('*.sh') if p.is_file() and not p.is_symlink()}


def contains_json(actual,expected):
    if isinstance(expected,dict):
        return isinstance(actual,dict) and all(k in actual and contains_json(actual[k],v) for k,v in expected.items())
    return type(actual) is type(expected) and actual==expected


def grade(case,events,workspace,trusted_scripts=None):
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
    for index,wanted in enumerate(expected.get("executions",[])):
        count=0
        for event in events:
            item=event.get("item",{})
            if event.get("type")!="item.completed" or item.get("type")!="command_execution": continue
            code=item.get("exit_code")
            invocation=literal_script(item.get('command'))
            script,arguments=invocation if invocation is not None else (None,[])
            trusted=False
            if script is not None and trusted_scripts and str(script.resolve()) in trusted_scripts:
                try:
                    identity=trusted_scripts[str(script.resolve())]
                    trusted=not script.is_symlink() and script.is_file() and tree_digest(Path(identity['root']))==identity['tree_sha256']
                except (OSError,ValueError,KeyError): pass
            args_match=('args' not in wanted or arguments==wanted['args']) and ('args_prefix' not in wanted or arguments[:len(wanted['args_prefix'])]==wanted['args_prefix'])
            if type(code) is int and code==wanted["exit_code"] and trusted and script.name==wanted["script"] and args_match:
                count+=1
        checks[f"execution:{index}:{wanted['script']}"]=wanted.get("min_count",1)<=count<=wanted.get("max_count",wanted.get("min_count",1))
    for name,wanted in expected.get("json_contains",{}).items():
        try:
            path=inside(workspace,name)
            if path.is_symlink() or not path.is_file(): raise ValueError("unsafe artifact")
            actual=json.loads(path.read_text())
            checks["json:"+name]=contains_json(actual,wanted)
        except (OSError,ValueError): checks["json:"+name]=False
    return checks


def probe(case,path,timeout,auth_home):
    # Neutral visible paths avoid telling candidates that they are being graded.
    with tempfile.TemporaryDirectory(prefix="workspace-") as temp:
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
        trusted_scripts={}
        for installed in (codex_home/'plugins/cache/girishattri-plugins').glob('*/*'):
            if installed.is_dir(): trusted_scripts.update(trust_tree(installed))
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
            seconds=round(time.monotonic()-started,2),checks=grade(case,events,workspace,trusted_scripts),
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
