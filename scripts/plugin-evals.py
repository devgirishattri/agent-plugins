#!/usr/bin/env python3
"""Portable scenario validation and opt-in Codex model probes.

Model results are report-only, including regex grades: model runs are stochastic.
Deterministic runtime suites remain the release gate. No report publishing.
"""
import argparse
import hashlib
import json
import os
import queue
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import tempfile
import threading
import time

ROOT=Path(__file__).resolve().parents[1]
FIXTURE_STORES={"SESSION_CONTEXT_HOME","SESSION_SCHEDULER_HOME","KNOWLEDGE_MEMORY_HOME","SESSION_CHAT_TARGET_MESSAGES_DIR"}
MAX_EVENT_BYTES=8*1024*1024
MAX_ARTIFACT_BYTES=2*1024*1024
MAX_ARTIFACT_FILES=100


def stop_group(process):
    """Also stop descendants that outlive their completed launcher."""
    process.poll()
    try: os.killpg(process.pid,signal.SIGTERM)
    except ProcessLookupError: return
    time.sleep(0.1)
    # Reap an exited leader before the second signal. On macOS a zombie-only
    # group can report EPERM; live descendants still retain this process group.
    process.poll()
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
    # Resolve the base first: macOS itself aliases /var and /tmp.
    current=base.resolve()
    for part in Path(relative).parts:
        current=current/part
        if current.is_symlink(): raise ValueError("symlink in fixture path")
    target=current.resolve()
    if not target.is_relative_to(base.resolve()):
        raise ValueError(f"fixture path escapes workspace: {relative}")
    return target


def validate_postcheck(check, path):
    if not isinstance(check,dict) or set(check)!={'script','args'}:
        raise ValueError('postcheck requires script and args')
    if not isinstance(check['script'],str) or not check['script'].endswith('.sh'):
        raise ValueError('postcheck script must be a relative shell script')
    if not inside(path.parent.parent,check['script']).is_file(): raise ValueError('missing postcheck script')
    if not isinstance(check['args'],list) or any(not isinstance(a,str) for a in check['args']):
        raise ValueError('postcheck args must be strings')


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
    if 'postcheck' in case: validate_postcheck(case['postcheck'],path)
    followups=case.get('followups',[])
    if not isinstance(followups,list) or len(followups)>5: raise ValueError('at most five followups allowed')
    for turn in followups:
        if not isinstance(turn,dict) or set(turn)-{'prompt','reply','postcheck'} or ('prompt' in turn)==('reply' in turn):
            raise ValueError('followup requires exactly one prompt or reply')
        if 'prompt' in turn and (not isinstance(turn['prompt'],str) or not turn['prompt']): raise ValueError('empty followup prompt')
        if 'reply' in turn:
            if turn['reply'] not in {'approve_manifest','mismatched_manifest','tamper_manifest_then_approve'}:
                raise ValueError('unknown reply action')
            inside(path.parent,case.get('manifest'))
        if 'postcheck' in turn: validate_postcheck(turn['postcheck'],path)
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


def fixture_baselines(workspace,names=None):
    """Pin scaffold-owned evidence before the model can alter it."""
    paths=workspace.glob('.eval-*') if names is None else (workspace/name for name in names)
    return {str(p.relative_to(workspace)):hashlib.sha256(p.read_bytes()).hexdigest()
            for p in paths if p.is_file() and not p.is_symlink()}


def require_baselines(case,baselines):
    checks=[case.get('postcheck'),*(turn.get('postcheck') for turn in case.get('followups',[]))]
    if any(checks) and '.eval-snapshot' not in baselines:
        raise ValueError('postchecks require a scaffold-owned .eval-snapshot baseline')


def probe_environment():
    # Retain only CLI execution/locale and native Claude authentication inputs.
    allowed={'PATH','HOME','LANG','LC_ALL','LC_CTYPE','TERM','USER','LOGNAME','SHELL',
             'ANTHROPIC_API_KEY','CLAUDE_CODE_OAUTH_TOKEN'}
    return {k:v for k,v in os.environ.items() if k in allowed}


def mount_plugin(source,workspace):
    installed=workspace/'.fixture-plugin'
    shutil.copytree(source,installed,ignore=shutil.ignore_patterns('evals'))
    return installed


def artifact_evidence(workspace):
    hashes={};texts={};omitted=[];total=0;truncated=False
    for index,path in enumerate(workspace.rglob('*')):
        if index>=1000:truncated=True;break
        relative=str(path.relative_to(workspace))
        if '.git' in path.parts or '.fixture-plugin' in path.parts or not path.is_file() or path.is_symlink():continue
        size=path.stat().st_size
        if len(hashes)>=MAX_ARTIFACT_FILES or size>100000 or total+size>MAX_ARTIFACT_BYTES:
            omitted.append(relative);continue
        data=path.read_bytes();total+=len(data)
        hashes[relative]=hashlib.sha256(data).hexdigest();texts[relative]=data.decode(errors='replace')
    return {'artifact_hashes':hashes,'artifacts':texts,'omitted_artifacts':omitted,'artifact_bytes_read':total,'artifact_scan_truncated':truncated}


def output_allowed(path):
    resolved=path.resolve()
    if not resolved.is_relative_to(ROOT.resolve()):return True
    result=subprocess.run(['git','check-ignore','--quiet','--',str(resolved)],cwd=ROOT,
                          stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10)
    return result.returncode==0


def postcheck(check,path,workspace,env,subject,baselines):
    if tree_digest(path.parent.parent)!=subject:
        return {'passed':False,'error':'eval source changed during the run'}
    if fixture_baselines(workspace,baselines)!=baselines:
        return {'passed':False,'error':'scaffold baseline changed during the run'}
    script=inside(path.parent.parent,check['script'])
    process=subprocess.Popen(['bash',str(script),*check['args'],str(workspace)],env=env,cwd=workspace,
                             stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
    try:
        out,err=process.communicate(timeout=30)
        return {'passed':process.returncode==0,'exit_code':process.returncode,'stdout':out[-4000:],'stderr':err[-4000:]}
    except subprocess.TimeoutExpired:
        return {'passed':False,'error':'postcheck timeout'}
    finally:
        stop_group(process);process.wait()


def manifest_reply(action,case,workspace,displayed):
    """Create a real later user turn, bound to bytes displayed in the last turn."""
    manifest=inside(workspace,case['manifest'])
    if not manifest.is_file() or manifest.stat().st_size>100000:
        raise ValueError('missing or oversized manifest')
    digest=hashlib.sha256(manifest.read_bytes()).hexdigest()
    if digest not in re.findall(r'\b[0-9a-f]{64}\b',displayed):
        raise ValueError('manifest hash was not displayed by the previous turn')
    selected=digest
    if action=='mismatched_manifest': selected=('0' if digest[0]!='0' else '1')+digest[1:]
    elif action=='tamper_manifest_then_approve':
        manifest.write_bytes(manifest.read_bytes()+b'\nFixture operator changed these bytes after review.\n')
    elif action!='approve_manifest': raise ValueError('unknown approval action')
    return 'I approve manifest SHA-256 '+selected+'. Apply that exact reviewed batch.',{'displayed_hash':digest,'reply_hash':selected,'action':action}


def claude_events(events):
    """Adapt correlated native tool results; proposed or failed calls do not pass."""
    calls={};normalized=[]
    for event in events:
        content=event.get('message',{}).get('content',[])
        if not isinstance(content,list): continue
        if event.get('type')=='assistant':
            for item in content:
                if item.get('type')=='tool_use': calls[item.get('id')]=item
                elif item.get('type')=='text': normalized.append({'type':'item.completed','item':{'type':'agent_message','text':item.get('text','')}})
        elif event.get('type')=='user':
            for item in content:
                call=calls.pop(item.get('tool_use_id'),None) if item.get('type')=='tool_result' else None
                if call is None: continue
                result=event.get('tool_use_result',{})
                if call.get('name')=='Bash' and isinstance(result,dict):
                    # Native Bash omits numeric status on success; require its explicit
                    # non-error receipt and non-interruption, never parse printed text.
                    success=item.get('is_error') is False and result.get('interrupted') is False
                    normalized.append({'type':'item.completed','item':{'type':'command_execution',
                        'command':call.get('input',{}).get('command',''),'exit_code':0 if success else None}})
                elif call.get('name')=='Skill' and isinstance(result,dict) and result.get('success') is True:
                    skill=call.get('input',{}).get('skill','').split(':')[-1]
                    normalized.append({'type':'item.completed','item':{'type':'command_execution',
                        'command':'Skill /skills/'+skill+'/SKILL.md','exit_code':None}})
    return normalized


class ClaudeConversation:
    def __init__(self,command,env,workspace):
        self.process=subprocess.Popen(command,env=env,cwd=workspace,text=True,stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
        self.queue=queue.Queue();self.events=[];self.errors=[]
        def read():
            total=0
            while True:
                line=self.process.stdout.readline(MAX_EVENT_BYTES+1)
                if not line:break
                total+=len(line.encode())
                if total>MAX_EVENT_BYTES:
                    self.queue.put({'probe_error':'event byte limit exceeded'});break
                try: self.queue.put(json.loads(line))
                except ValueError: pass
            self.queue.put(None)
        def errors():
            while True:
                chunk=self.process.stderr.read(1024)
                if not chunk:break
                self.errors[:]=[(''.join(self.errors)+chunk)[-4000:]]
        self.reader=threading.Thread(target=read,daemon=True);self.reader.start()
        self.err_reader=threading.Thread(target=errors,daemon=True);self.err_reader.start()

    def turn(self,prompt,timeout):
        self.events.append({'probe_input':{'role':'user','content':prompt}})
        self.process.stdin.write(json.dumps({'type':'user','message':{'role':'user','content':prompt}})+'\n')
        self.process.stdin.flush();end=time.monotonic()+timeout;phase=[]
        while True:
            try: event=self.queue.get(timeout=max(0,end-time.monotonic()))
            except queue.Empty: raise TimeoutError('model turn timed out') from None
            if event is None: raise RuntimeError('model exited before its turn result')
            if 'probe_error' in event: raise RuntimeError(event['probe_error'])
            self.events.append(event);phase.append(event)
            if event.get('type')=='result': return phase,event

    def close(self):
        try:
            try:self.process.stdin.close()
            except OSError:pass
            stop_group(self.process)
        finally:
            self.process.wait(timeout=5)
            self.reader.join(timeout=1);self.err_reader.join(timeout=1)
            self.process.stdout.close();self.process.stderr.close()


def probe_claude(case,path,timeout,max_cost):
    """Sandboxed native Claude, no ambient hooks, MCP servers, or persisted session."""
    with tempfile.TemporaryDirectory(prefix='workspace-',dir='/private/tmp' if Path('/private/tmp').is_dir() else None) as temp:
        base=Path(temp);workspace=base/'workspace';workspace.mkdir();(base/'tmp').mkdir()
        # Put the plugin within the fixture checkout so native file tools can read
        # every sibling skill under the same workspace permission boundary.
        installed=mount_plugin(path.parents[2],workspace)
        env=probe_environment()
        env.update(TMPDIR=str(base/'tmp'),KNOWLEDGE_MEMORY_HOME=str(workspace/'.agents/memory'),
                   SESSION_CONTEXT_HOME=str(workspace/'.tmp/contexts'),KNOWLEDGE_PANE_NAME='fixture-executor',
                   CLAUDE_CODE_DISABLE_AUTO_MEMORY='1',PYTHONDONTWRITEBYTECODE='1')
        for key in case.get('unset_env',[]):env.pop(key,None)
        setup_command(['git','init','-q',str(workspace)],env,workspace)
        if case.get('scaffold'):setup_command(['bash',str(inside(path.parent,case['scaffold'])),str(workspace)],env,workspace)
        trusted=trust_tree(installed);subject=tree_digest(path.parent.parent);baselines=fixture_baselines(workspace)
        require_baselines(case,baselines)
        settings={'disableAllHooks':True,'autoMemoryEnabled':False,'sandbox':{'enabled':True,'autoAllowBashIfSandboxed':True}}
        command=['claude','-p','--restricted','--setting-sources','','--settings',json.dumps(settings),
                 '--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--plugin-dir',str(installed),
                 '--tools','Read,Glob,Grep,Bash,Write,Edit,Skill','--allowedTools','Read','Glob','Grep','Bash','Write','Edit','Skill',
                 '--permission-mode','acceptEdits','--permission-prompts','none','--no-session-persistence',
                 '--input-format','stream-json','--output-format','stream-json','--verbose','--max-budget-usd',str(max_cost)]
        conversation=ClaudeConversation(command,env,workspace);started=time.monotonic()
        report={'id':case['id'],'status':'completed','turns':[],'plugin_sha256':tree_digest(installed),'eval_sha256':subject}
        try:
            displayed=''
            for index,turn in enumerate([{'prompt':case['prompt'],'postcheck':case.get('postcheck')},*case.get('followups',[])]):
                binding=None
                if 'reply' in turn:prompt,binding=manifest_reply(turn['reply'],case,workspace,displayed)
                else:prompt=turn['prompt']
                phase,result=conversation.turn(prompt,timeout)
                record={'index':index,'input':prompt,'result':result,'binding':binding}
                if turn.get('postcheck'):record['postcheck']=postcheck(turn['postcheck'],path,workspace,env,subject,baselines)
                report['turns'].append(record);displayed=result.get('result','')
                if result.get('is_error') or result.get('subtype')!='success':
                    report['status']='execution_error';break
                if record.get('postcheck',{}).get('passed') is False:
                    report['status']='check_failed';break
            report['checks']=grade(case,claude_events(conversation.events),workspace,trusted)
        except (OSError,ValueError,RuntimeError,TimeoutError) as exc:
            report.update(status='infrastructure_error',error=str(exc))
        finally:
            try:conversation.close()
            except (OSError,subprocess.SubprocessError) as exc:report.update(status='infrastructure_error',cleanup_error=str(exc))
            report.update(events=conversation.events,stderr=''.join(conversation.errors)[-4000:],seconds=round(time.monotonic()-started,2),
                          reported_cost_usd=max([e.get('total_cost_usd',0) for e in conversation.events if e.get('type')=='result'] or [0]))
            report.update(artifact_evidence(workspace))
        return report


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
        subject=tree_digest(path.parent.parent);baselines=fixture_baselines(workspace)
        require_baselines(case,baselines)
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
        result=dict(id=case["id"],status="completed" if process.returncode==0 else "execution_error",
            seconds=round(time.monotonic()-started,2),checks=grade(case,events,workspace,trusted_scripts),
            events=events,stderr=err[-2000:])
        if case.get('postcheck'): result['postcheck']=postcheck(case['postcheck'],path,workspace,env,subject,baselines)
        return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plugin")
    parser.add_argument("--case")
    parser.add_argument("--run",action="store_true",help="opt in to paid model probes; otherwise validate only")
    parser.add_argument('--provider',choices=['codex','claude'],default='codex')
    parser.add_argument('--max-cost-usd',type=float,help='explicit total native model budget for this command')
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
    if args.max_cost_usd is None or not 0<args.max_cost_usd<1000: parser.error('--run requires a positive --max-cost-usd ceiling below 1000')
    if args.provider=='codex':
        parser.error('bounded Codex model execution is unavailable: native exec has no enforceable cost ceiling; static validation remains available')
    if not output_allowed(args.output):parser.error('model evidence inside this repository must use a git-ignored output path')
    results=[]
    args.output.parent.mkdir(parents=True,exist_ok=True)
    for path,case in cases[:args.max_cases]:
        try:
            # Split the ceiling conservatively. Unspent case allocations are not
            # automatically reused, even if a failed process has no cost receipt.
            budget=args.max_cost_usd/min(len(cases),args.max_cases)
            result=probe_claude(case,path,args.timeout,budget)
        except (OSError,ValueError,RuntimeError,subprocess.SubprocessError) as exc:
            result=dict(id=case["id"],status="infrastructure_error",error=str(exc))
        results.append(result)
        args.output.write_text(json.dumps({"report_only":True,"provider":args.provider,'max_cost_usd':args.max_cost_usd,"runs":results},indent=2)+"\n")
        print(case["id"],result["status"],flush=True)
        if sum(r.get('reported_cost_usd',0) for r in results)>=args.max_cost_usd:
            print('Reported cost reached the ceiling; no more cases will start.',flush=True);break

if __name__=="__main__": main()
