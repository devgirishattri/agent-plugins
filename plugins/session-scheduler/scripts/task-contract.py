#!/usr/bin/env python3
"""Opt-in task evidence and attempt admission over the existing scheduler store.

Trust boundary: the local host, selected helpers, and (when active) harness
identity. These records are not signatures and do not resist a malicious uid.
"""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import shlex
import subprocess
import tempfile
import time
import uuid

HERE=Path(__file__).resolve().parent
NAME=re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]*\Z")
NOTICE="Local helper/host trust only; no same-user tamper resistance, external runner authentication, or release authorization."


def policy_check(command,repo,actor=None):
    config=os.environ.get('SESSION_WORKSPACE_CONFIG','')
    mode=os.environ.get('SESSION_WORKSPACE_HARNESS_MODE','')
    if not config and not mode: return 'inactive-command-reviewed'
    # Resolve the policy only from the same provider cache as this installed
    # scheduler. The policy then validates its own selection and live identity.
    if HERE.parent.parent.name!='session-scheduler' or HERE.parent.parent.parent.name!='girishattri-plugins':
        fail('active harness requires an installed selected scheduler')
    market=HERE.parent.parent.parent
    provider_home=market.parents[2]
    if (HERE.parent/'.codex-plugin/plugin.json').exists():
        manifest=read_json(provider_home/'.tmp/marketplaces/girishattri-plugins/codex/plugins/session-workspace/.codex-plugin/plugin.json')
        version=manifest.get('version','')
    else:
        registry=read_json(provider_home/'plugins/installed_plugins.json')
        entries=registry.get('plugins',{}).get('session-workspace@girishattri-plugins',[])
        entries=[entry for entry in entries if entry.get('scope')=='user' or entry.get('projectPath')==os.environ.get('SESSION_WORKSPACE_PROJECT_ROOT')]
        scoped=[entry for entry in entries if entry.get('scope')!='user']
        version=(scoped or entries or [{}])[0].get('version','')
    if not isinstance(version,str) or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+',version): fail('selected harness version unavailable')
    candidates=[market/'session-workspace'/version/'scripts/harness-policy.py']
    for candidate in candidates:
        regular(candidate)
        module_spec=importlib.util.spec_from_file_location('contract_policy',candidate)
        module=importlib.util.module_from_spec(module_spec)
        # dataclasses consult sys.modules during module execution.
        import sys
        sys.modules[module_spec.name]=module;module_spec.loader.exec_module(module)
        ctx,denial=module.load_context()
        if denial: fail('harness identity unavailable')
        if ctx is None:
            if mode: fail('partial harness identity')
            return 'inactive-command-reviewed'
        if ctx.pane_name!=actor or ctx.semantic_role!='executor':
            fail('harness executor identity differs from the verification actor')
        try:
            module.trusted_script(ctx,str(candidate.with_name('harness-status.sh')))
            module.trusted_script(ctx,str(HERE/'task-contract.sh'))
        except module.PolicyFailure: continue
        decision=module.evaluate(json.dumps({'tool_name':'Bash','tool_input':{'command':shlex.join(command),'cwd':str(repo),'workdir':str(repo)}}))
        if decision.decision!='allow': fail('inner check denied by harness policy: '+decision.rule)
        return 'harness-decided'
    fail('selected harness evaluator unavailable')


def fail(message): raise ValueError(message)


def encoded(value): return json.dumps(value,sort_keys=True,separators=(',',':')).encode()


def hashed(value): return hashlib.sha256(encoded(value)).hexdigest()


def regular(path):
    path=Path(path)
    for parent in [path,*path.parents]:
        if parent.is_symlink(): fail("symlink path refused: "+str(parent))
    if not path.is_file() or path.stat().st_nlink!=1: fail("expected private regular file: "+str(path))
    return path


def read_json(path):
    data=json.loads(regular(path).read_text())
    if not isinstance(data,dict): fail("expected JSON object")
    return data


def atomic(path,data):
    tmp=path.with_name(path.name+'.'+uuid.uuid4().hex+'.tmp')
    try:
        with tmp.open('xb') as handle:
            os.chmod(tmp,0o600);handle.write(encoded(data)+b'\n');handle.flush();os.fsync(handle.fileno())
        os.replace(tmp,path)
    finally:
        if tmp.exists(): tmp.unlink()


def git(repo,*args):
    result=subprocess.run(['git','-C',str(repo),*args],capture_output=True,check=True,timeout=30)
    return result.stdout


def repo_file(repo,name):
    if not isinstance(name,str) or not name or Path(name).is_absolute() or '..' in Path(name).parts:
        fail("repository paths must be relative and traversal-free")
    path=repo/name
    regular(path)
    if not path.resolve().is_relative_to(repo): fail("repository file escapes root")
    return path


def subject(spec):
    repo=Path(spec['repository'])
    if repo.is_symlink() or not repo.is_dir() or repo.resolve()!=repo: fail("repository must be a canonical directory")
    if Path(git(repo,'rev-parse','--show-toplevel').decode().strip()).resolve()!=repo: fail("repository binding is not a Git root")
    names=set(git(repo,'ls-files','--cached','--others','--exclude-standard','-z').decode().split('\0'))-{''}
    names.update(check['script'] for check in spec['checks'])
    config=repo/'.agent-workspace/workspace.json'
    if config.exists(): names.add('.agent-workspace/workspace.json')
    if len(names)>20000: fail("source inventory exceeds 20000 files")
    files={};size=0
    for name in sorted(names):
        path=repo/name
        if not path.exists() and not path.is_symlink():
            files[name]=None;continue
        path=repo_file(repo,name);size+=path.stat().st_size
        if size>1024**3: fail("source inventory exceeds 1 GiB")
        files[name]={'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'executable':bool(path.stat().st_mode & 0o111)}
    configured=os.environ.get('SESSION_WORKSPACE_CONFIG','')
    configuration=None
    if configured:
        path=Path(configured).resolve()
        configuration={'path':str(path),'sha256':hashlib.sha256(regular(path).read_bytes()).hexdigest()}
    return {'head':git(repo,'rev-parse','HEAD').decode().strip(),'files':files,'configuration':configuration,
            'index':hashlib.sha256(git(repo,'ls-files','--stage','-z')).hexdigest(),
            'spec':hashed(spec)}


def validate_spec(data):
    if set(data)!={'schema_version','repository','checks','ttl_seconds','max_attempts'} or type(data['schema_version']) is not int or data['schema_version']!=1:
        fail("contract spec requires schema_version=1, repository, checks, ttl_seconds, max_attempts")
    for key,limit in [('ttl_seconds',86400),('max_attempts',10)]:
        if type(data[key]) is not int or not 1<=data[key]<=limit: fail("invalid "+key)
    if not isinstance(data['repository'],str): fail("invalid repository")
    checks=data['checks']
    if not isinstance(checks,list) or not 1<=len(checks)<=20: fail("checks requires 1..20 definitions")
    ids=set()
    for check in checks:
        if not isinstance(check,dict) or set(check)!={'id','script','args','timeout_seconds'}: fail("invalid check definition")
        if not isinstance(check['id'],str) or not NAME.fullmatch(check['id']) or check['id'] in ids: fail("invalid/duplicate check id")
        ids.add(check['id'])
        if not isinstance(check['script'],str) or Path(check['script']).suffix not in {'.sh','.py'}: fail("check must be an existing .sh or .py script")
        path=repo_file(Path(data['repository']),check['script'])
        baseline=git(Path(data['repository']),'show','HEAD:'+check['script'])
        if baseline!=path.read_bytes(): fail("check scripts must match tracked HEAD bytes at attachment")
        if not isinstance(check['args'],list) or any(not isinstance(a,str) or '\x00' in a for a in check['args']): fail("check args must be literal strings")
        if type(check['timeout_seconds']) is not int or not 1<=check['timeout_seconds']<=600: fail("check timeout must be 1..600")
    subject(data)
    return data


LOCK_PROGRAM='''
source "$1" || exit 1
if declare -F lock_task_for_command >/dev/null; then
  lock_task_for_command "$2" || exit 1
else
  task_lock "$2" || exit 1
  CONTRACT_LOCK_ID="$2"
  trap 'task_unlock "$CONTRACT_LOCK_ID"' EXIT
fi
printf 'locked\\n'
IFS= read -r release || true
'''


class Store:
    def __init__(self,task_id,actor='',chat_root=''):
        if not NAME.fullmatch(task_id): fail("invalid task id")
        raw=os.environ.get('SESSION_SCHEDULER_HOME','')
        if not raw or not Path(raw).is_absolute(): fail("SESSION_SCHEDULER_HOME must be inherited and absolute")
        self.home=Path(raw);self.id=task_id;self.actor=actor;self.chat=Path(chat_root) if chat_root else None
        self.path=self.home/'tasks'/f'{task_id}.json'
        self.artifacts=self.home/'handoffs'/task_id
        regular(self.path)

    def read(self):
        data=read_json(self.path)
        if data.get('id')!=self.id: fail("task identity mismatch")
        return data

    @contextmanager
    def locked(self):
        process=subprocess.Popen(['bash','-c',LOCK_PROGRAM,'contract-lock',str(HERE/'lib.sh'),self.id],
                                 stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            if process.stdout.readline().strip()!='locked':
                _,err=process.communicate(timeout=15);fail("task lock unavailable: "+err.strip())
            yield self.read()
        finally:
            if process.poll() is None:
                try: process.communicate('release\n',timeout=15)
                except subprocess.TimeoutExpired: process.kill();process.communicate()

    def save(self,data): atomic(self.path,data)

    def change(self,data,event,note):
        data['contract']['revision']+=1
        self.event(data,event,note);self.save(data)

    def event(self,data,event,note):
        stamp=datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        data['updated_at']=stamp
        data.setdefault('history',[]).append({'ts':stamp,'event':event,'actor':self.actor,'note':note})

    def contract(self,data):
        contract=data.get('contract')
        if not isinstance(contract,dict) or type(contract.get('version')) is not int or contract.get('version')!=1: fail("missing or unsupported contract")
        if contract.get('owner')!=data.get('assigner') or contract.get('reviewer')!=data.get('reviewer'):
            fail("contract roles changed")
        for key in ['generation','attempts','revision']:
            if type(contract.get(key)) is not int or contract[key]<0: fail('invalid contract '+key)
        if not isinstance(contract.get('spec'),dict) or not isinstance(contract.get('pinned_checks'),dict): fail('invalid contract spec')
        if not isinstance(data.get('history'),list): fail('invalid task history')
        return contract

    def require_actor(self,expected):
        if not NAME.fullmatch(self.actor) or self.actor!=expected: fail("operation requires the bound task actor")

    def require_generation(self,contract,generation):
        if type(generation) is not int or generation<1 or generation!=contract.get('generation'):
            fail("missing or obsolete assignment generation")

    def artifact(self,name):
        if not NAME.fullmatch(name): fail("invalid artifact name")
        for parent in [self.artifacts,*self.artifacts.parents]:
            if parent.is_symlink(): fail('unsafe artifact parent')
        if self.artifacts.exists():
            if self.artifacts.is_symlink() or not self.artifacts.is_dir(): fail("unsafe task artifact directory")
        else: self.artifacts.mkdir(mode=0o700)
        return self.artifacts/name

    def attach(self,spec_path):
        spec=validate_spec(read_json(spec_path))
        with self.locked() as data:
            self.require_actor(data.get('assigner'))
            reviewer=data.get('reviewer')
            if not isinstance(reviewer,str) or not NAME.fullmatch(reviewer) or reviewer==self.actor: fail("a distinct reviewer is required")
            if data.get('status')!='created' or 'contract' in data: fail("attach requires a new, uncontracted task")
            data['contract']={'version':1,'owner':self.actor,'reviewer':reviewer,'spec':spec,
                              'generation':0,'attempts':0,'revision':0,'phase':'idle','reconciled':True,
                              'pinned_checks':{check['script']:hashlib.sha256(repo_file(Path(spec['repository']),check['script']).read_bytes()).hexdigest() for check in spec['checks']}}
            self.event(data,'contract-attached','local verification contract v1');self.save(data)
        return {'state':'attached','task':self.id,'spec_digest':hashed(spec),'notice':NOTICE}

    def receipt(self,data,committed=False,admitted_at=None):
        c=self.contract(data)
        record=c.get('receipt')
        if not isinstance(record,dict) or not NAME.fullmatch(record.get('name','')): fail("verification receipt missing")
        path=self.artifacts/record['name'];receipt=read_json(path)
        if hashed(receipt)!=record.get('sha256'): fail("verification receipt changed")
        if receipt.get('task')!=self.id or receipt.get('generation')!=c['generation'] or receipt.get('result')!='passed':
            fail("receipt is not a passing result for this assignment")
        now=int(time.time()) if admitted_at is None else admitted_at
        if type(receipt.get('finished_at')) is not int or receipt['finished_at']>now or now-receipt['finished_at']>c['spec']['ttl_seconds']:
            fail("verification receipt expired or future-dated")
        if receipt.get('actor')!=data.get('assignee'): fail("receipt actor mismatch")
        recorded=receipt.get('source')
        if not isinstance(recorded,dict) or recorded.get('spec')!=hashed(c['spec']): fail('receipt spec mismatch')
        current=subject(c['spec']) if admitted_at is None else None
        if committed:
            repo=Path(c['spec']['repository'])
            if git(repo,'status','--porcelain','--untracked-files=all'): fail("committed admission requires a clean worktree")
            if not isinstance(recorded,dict) or current['files']!=recorded.get('files') or current['spec']!=recorded.get('spec') or current['configuration']!=recorded.get('configuration'):
                fail("committed source differs from verified content")
            git(repo,'merge-base','--is-ancestor',recorded['head'],current['head'])
        elif admitted_at is None and current!=recorded: fail("verification source is stale")
        checks=receipt.get('checks')
        if not isinstance(checks,list) or len(checks)!=len(c['spec']['checks']): fail("incomplete checks")
        for definition,result in zip(c['spec']['checks'],checks):
            if not isinstance(result,dict) or result.get('id')!=definition['id'] or type(result.get('exit_code')) is not int or result.get('exit_code')!=0 or result.get('result')!='passed': fail("required check did not pass")
            name=result.get('log')
            if not isinstance(name,str) or not NAME.fullmatch(name): fail("invalid log reference")
            if hashlib.sha256(regular(self.artifacts/name).read_bytes()).hexdigest()!=result.get('log_sha256'): fail("verification log changed")
        return receipt

    def inspect(self,committed=False,fresh=False):
        data=self.read();c=self.contract(data)
        if data.get('status')!='done': return {'state':'active','status':data.get('status'),'generation':c['generation'],'phase':c['phase'],'spec':c['spec'],'spec_digest':hashed(c['spec']),'pinned_checks':c['pinned_checks'],'notice':NOTICE}
        admission=c.get('admission')
        if not isinstance(admission,dict) or admission.get('generation')!=c['generation'] or admission.get('reviewer')!=c['reviewer']:
            fail("closed-unadmitted: matching reviewer admission missing")
        if admission.get('history')!=hashed(data.get('history')) or admission.get('receipt')!=c.get('receipt'):
            fail("closed-unadmitted: task changed after admission")
        admitted_at=admission.get('admitted_at')
        if type(admitted_at) is not int or admitted_at>time.time(): fail('invalid admission time')
        receipt=self.receipt(data,admitted_at=admitted_at)
        if committed or fresh: receipt=self.receipt(data,committed)
        if self.read()!=data: fail("task changed during admission inspection")
        return {'state':'admitted','task':self.id,'generation':c['generation'],'reviewer':c['reviewer'],
                'source':receipt['source'],'admitted_at':admitted_at,'freshness_checked':bool(committed or fresh),'notice':NOTICE}

    def reserve(self,data,phase,seconds):
        c=self.contract(data)
        c['phase']=phase
        c['reservation']={'actor':self.actor,'pid':os.getpid(),'expires_at':int(time.time())+seconds}
        self.change(data,phase,'operation reserved; interrupted operations require reconciliation')
        return c['revision']

    def finish(self,revision,change):
        with self.locked() as data:
            c=self.contract(data)
            if c['revision']!=revision: fail("late result rejected: reservation changed")
            change(data,c)
            c.pop('reservation',None)
            self.change(data,'contract-operation-finished',c['phase'])
        return data

    def dependencies(self,data):
        for dep in data.get('depends_on',[]):
            other=Store(dep);value=other.read()
            if value.get('status')!='done': fail('dependency not done: '+dep)
            if 'contract' in value and other.inspect()['state']!='admitted': fail('dependency not admitted: '+dep)

    def dispatch(self,target,text):
        if self.chat is None: fail('session-chat is unavailable')
        script=regular(self.chat/'scripts/dispatch-to-session.sh')
        prompt=self.artifact('dispatch-'+uuid.uuid4().hex)
        with prompt.open('x') as handle:
            os.chmod(prompt,0o600);handle.write(text+'\n')
        process=subprocess.Popen(['bash',str(script),target,str(prompt)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
        try:
            process.communicate(timeout=60)
            return process.returncode==0
        except subprocess.TimeoutExpired: return False
        finally: stop_group(process)

    def assign(self,pane,prompt):
        if not NAME.fullmatch(pane) or not prompt or prompt.startswith('--'): fail('contract assign requires pane id literal-prompt without legacy options')
        with self.locked() as data:
            c=self.contract(data);self.require_actor(c['owner']);self.dependencies(data)
            if pane in {c['owner'],c['reviewer']}: fail('executor must be distinct from owner and reviewer')
            if data.get('status') not in {'created','blocked'} or c['phase']!='idle' or not c['reconciled']: fail('assignment requires idle reconciled created/blocked task')
            if c['attempts']>=c['spec']['max_attempts']: fail('assignment attempt budget exhausted')
            c['generation']+=1;c['attempts']+=1;c['reconciled']=False
            c.pop('receipt',None);c.pop('admission',None)
            data['assignee']=pane;data['status']='assigned';data['prompt']=prompt
            generation=c['generation'];revision=self.reserve(data,'dispatching',75)
        delivered=self.dispatch(pane,f"Task {self.id}, generation {generation}.\n{prompt}\nUse task-contract verify {self.id} --generation {generation}; then task-review {self.id} --generation {generation} <note>. Do not run task-done as executor. Shared task: {self.path}. Store paths are inherited; never export replacements.")
        def update(data,c):
            c['phase']='idle' if delivered else 'uncertain'
            c['delivery']='delivered' if delivered else 'unknown'
            if not delivered: data['status']='blocked'
        self.finish(revision,update)
        return {'state':'assigned' if delivered else 'uncertain','generation':generation,'attempts':c['attempts']}

    def verify(self,generation,spec_digest):
        with self.locked() as data:
            c=self.contract(data);self.require_actor(data.get('assignee'));self.require_generation(c,generation)
            if data.get('status')!='assigned' or c['phase']!='idle': fail('verification requires idle assigned task')
            spec=c['spec']
            if spec_digest!=hashed(spec): fail('verification requires the exact displayed spec digest')
            for name,digest in c['pinned_checks'].items():
                if hashlib.sha256(repo_file(Path(spec['repository']),name).read_bytes()).hexdigest()!=digest: fail('pinned check script changed')
            before=subject(spec)
            decisions=[policy_check(['bash' if check['script'].endswith('.sh') else 'python3',str(Path(spec['repository'])/check['script']),*check['args']],Path(spec['repository']),self.actor) for check in spec['checks']]
            revision=self.reserve(data,'verifying',sum(x['timeout_seconds'] for x in spec['checks'])+60)
        results=[]
        # Checks receive no launcher identity, credentials or canonical stores.
        # This is environment isolation, not an OS/network sandbox.
        with tempfile.TemporaryDirectory(prefix='task-check-') as temp:
            env={'PATH':os.environ.get('PATH','/usr/bin:/bin'),'HOME':temp,'TMPDIR':temp,'PYTHONDONTWRITEBYTECODE':'1','LC_ALL':'C'}
            for check in spec['checks']:
                name='log-'+uuid.uuid4().hex;log=self.artifact(name)
                command=['bash' if check['script'].endswith('.sh') else 'python3',str(Path(spec['repository'])/check['script']),*check['args']]
                if hashlib.sha256(repo_file(Path(spec['repository']),check['script']).read_bytes()).hexdigest()!=c['pinned_checks'][check['script']]: fail('pinned check changed before execution')
                policy_check(command,Path(spec['repository']),self.actor)
                with log.open('xb') as output:
                    os.chmod(log,0o600)
                    process=subprocess.Popen(command,cwd=spec['repository'],env=env,stdin=subprocess.DEVNULL,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
                    state='passed'
                    try:
                        code=process.wait(timeout=check['timeout_seconds'])
                        if code!=0: state='failed'
                    except subprocess.TimeoutExpired: code=None;state='inconclusive'
                    finally: stop_group(process)
                results.append({'id':check['id'],'exit_code':code,'result':state,'log':name,'log_sha256':hashlib.sha256(log.read_bytes()).hexdigest()})
        after=subject(spec)
        state='passed' if before==after and all(x['result']=='passed' for x in results) else 'failed'
        if before!=after: state='stale'
        if any(x['result']=='inconclusive' for x in results): state='inconclusive'
        receipt={'schema_version':1,'task':self.id,'generation':generation,'actor':self.actor,'source':before,'checks':results,'policy_decisions':decisions,'result':state,'finished_at':int(time.time())}
        name='receipt-'+uuid.uuid4().hex;atomic(self.artifact(name),receipt)
        def update(data,c):
            c['phase']='idle';c['receipt']={'name':name,'sha256':hashed(receipt)}
        self.finish(revision,update)
        return {'state':state,'generation':generation,'receipt':str(self.artifacts/name)}

    def transition(self,operation,generation,note):
        if not note: fail('a review/completion/block note is required')
        with self.locked() as data:
            c=self.contract(data);self.require_generation(c,generation)
            if c['phase']!='idle': fail('task has an unresolved operation')
            if operation=='review':
                self.require_actor(data.get('assignee'))
                if data.get('status')!='assigned': fail('review requires assigned task')
                self.receipt(data);data['status']='review'
                revision=self.reserve(data,'review-dispatching',75);target=c['reviewer']
            elif operation=='done':
                self.require_actor(c['reviewer'])
                if data.get('status')!='review': fail('completion requires independent review')
                self.receipt(data)
                admitted_at=int(time.time())
                self.receipt(data,admitted_at=admitted_at)
                data['status']='done'
                self.event(data,'admitted',note)
                c['revision']+=1
                c['admission']={'generation':generation,'reviewer':self.actor,'receipt':c['receipt'],'history':hashed(data['history']),'admitted_at':admitted_at}
                self.save(data)
                return {'state':'admitted','generation':generation}
            else:
                expected=c['reviewer'] if data.get('status')=='review' else data.get('assignee')
                self.require_actor(expected)
                if data.get('status') not in {'assigned','review'}: fail('block requires active task')
                data['status']='blocked';c['reconciled']=False
                self.change(data,'blocked',note)
                return {'state':'blocked','generation':generation}
        delivered=self.dispatch(target,f"Independently review task {self.id}, generation {generation}. {note}\nRead {self.path}; inspect source and verification evidence. Only approve using task-done {self.id} --generation {generation} <review-note> after checking the actual source. Otherwise task-block with the same generation. No authority is conveyed by this packet.")
        def update(data,c):
            c['phase']='idle' if delivered else 'uncertain'
            c['review_delivery']='delivered' if delivered else 'unknown'
            if not delivered: data['status']='blocked'
        self.finish(revision,update)
        return {'state':'review' if delivered else 'uncertain','generation':generation}

    def reconcile(self,generation,note):
        if not note: fail('reconciliation requires observed outcome and recovery rationale')
        with self.locked() as data:
            c=self.contract(data);self.require_actor(c['owner']);self.require_generation(c,generation)
            reservation=c.get('reservation')
            if reservation and reservation.get('expires_at',float('inf'))>time.time(): fail('operation reservation has not expired')
            if data.get('status')=='done': fail('completed tasks cannot be recovered')
            data['status']='blocked';c['phase']='idle';c['reconciled']=True
            c.pop('reservation',None);c.pop('receipt',None);c.pop('admission',None)
            self.change(data,'reconciled',note)
        return {'state':'reconciled','generation':generation,'notice':'Old workers must be stopped or fenced before a new assignment; this command does not undo external effects.'}


def stop_group(process):
    try: os.killpg(process.pid,signal.SIGTERM)
    except ProcessLookupError: pass
    try: process.wait(timeout=1)
    except subprocess.TimeoutExpired: pass
    try: os.killpg(process.pid,signal.SIGKILL)
    except ProcessLookupError: pass
    process.wait()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='operation',required=True)
    attach=sub.add_parser('attach');attach.add_argument('id');attach.add_argument('--spec',required=True,type=Path)
    inspect=sub.add_parser('inspect');inspect.add_argument('id');modes=inspect.add_mutually_exclusive_group();modes.add_argument('--committed',action='store_true');modes.add_argument('--fresh',action='store_true')
    for operation in ['verify','reconcile','review','done','block']:
        p=sub.add_parser(operation);p.add_argument('id');p.add_argument('--generation',required=True,type=int)
        if operation=='verify': p.add_argument('--spec-digest',required=True)
        if operation!='verify': p.add_argument('--note',required=True)
    assign=sub.add_parser('assign');assign.add_argument('pane');assign.add_argument('id');assign.add_argument('prompt')
    args=parser.parse_args()
    try:
        store=Store(args.id,os.environ.get('TASK_CONTRACT_ACTOR',''),os.environ.get('TASK_CONTRACT_CHAT_ROOT',''))
        if args.operation=='attach': result=store.attach(args.spec)
        elif args.operation=='inspect': result=store.inspect(args.committed,args.fresh)
        elif args.operation=='assign': result=store.assign(args.pane,args.prompt)
        elif args.operation=='verify': result=store.verify(args.generation,args.spec_digest)
        elif args.operation=='reconcile': result=store.reconcile(args.generation,args.note)
        else: result=store.transition(args.operation,args.generation,args.note)
        print(json.dumps(result,sort_keys=True))
        return 1 if result['state'] in {'active','uncertain','failed','stale','inconclusive'} else 0
    except (OSError,ValueError,KeyError,TypeError,subprocess.SubprocessError) as exc:
        state='invalid'
        if args.operation=='inspect':
            try:
                if store.read().get('status')=='done': state='closed-unadmitted'
            except (OSError,ValueError,UnboundLocalError): pass
        print(json.dumps({'state':state,'error':str(exc),'notice':NOTICE},sort_keys=True))
        return 1 if state=='closed-unadmitted' else 2


if __name__=='__main__': raise SystemExit(main())
