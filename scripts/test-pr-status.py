#!/usr/bin/env python3
"""Offline PR blocker policy and query consistency controls, both providers."""
import copy
import contextlib
import io
import json
import sys
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]


def snapshot():
    return {'pr':{'number':1,'url':'https://github.com/example/sample/pull/1',
                  'headRefOid':'a'*40,'baseRefOid':'b'*40,'state':'OPEN','isDraft':False,
                  'mergeable':'MERGEABLE','mergeStateStatus':'CLEAN','reviewDecision':'APPROVED',
                  'statusCheckRollup':[{'__typename':'CheckRun','name':'unit','status':'COMPLETED','conclusion':'SUCCESS'}]},
            'threads':[],'observed_head':'a'*40}


class Cases:
    def setUp(self):
        path=ROOT/self.tree/'session-workspace/scripts/pr-status.py'
        spec=importlib.util.spec_from_file_location('pr_status',path)
        self.module=importlib.util.module_from_spec(spec);spec.loader.exec_module(self.module)

    def test_unexpected_errors_are_unavailable_with_ready_control(self):
        for result in [snapshot(),AttributeError('private upstream text'),RecursionError('private upstream text')]:
            output=io.StringIO()
            kwargs={'side_effect':result} if isinstance(result,Exception) else {'return_value':result}
            with patch.object(sys,'argv',['pr-status.py','--repo','example/sample','--pr','1']), patch.object(self.module,'collect',**kwargs), contextlib.redirect_stdout(output):
                code=self.module.main()
            data=json.loads(output.getvalue())
            self.assertEqual((code,data['result']),(2,'unavailable') if isinstance(result,Exception) else (0,'ready'))
            self.assertNotIn('private upstream text',output.getvalue())

    def test_clean_and_blockers(self):
        self.assertEqual(self.module.classify(snapshot())['result'],'ready')
        for changes in [{'mergeStateStatus':'BLOCKED'},{'reviewDecision':'REVIEW_REQUIRED'},
                        {'reviewDecision':'CHANGES_REQUESTED'},{'isDraft':True},
                        {'mergeable':'CONFLICTING'},{'state':'CLOSED'},{'mergeStateStatus':'BEHIND'}]:
            data=snapshot();data['pr'].update(changes)
            with self.subTest(changes=changes): self.assertEqual(self.module.classify(data)['result'],'blocked')
        for outdated in (True,False):
            data=snapshot();data['threads']=[{'isResolved':False,'isOutdated':outdated}]
            self.assertEqual(self.module.classify(data)['result'],'blocked')
            data['threads'][0]['isResolved']=True
            self.assertEqual(self.module.classify(data)['result'],'ready')

    def test_unknown_never_ready(self):
        for changes in [{'mergeStateStatus':'UNKNOWN'},{'mergeable':'UNKNOWN'},
                        {'reviewDecision':None},{'statusCheckRollup':[]},{'statusCheckRollup':None}]:
            data=snapshot();data['pr'].update(changes)
            self.assertEqual(self.module.classify(data)['result'],'inconclusive')
        data=snapshot();del data['threads']
        self.assertEqual(self.module.classify(data)['result'],'inconclusive')
        self.assertEqual(self.module.classify(snapshot(),'c'*40)['result'],'inconclusive')
        data=snapshot();data['observed_head']='c'*40
        self.assertEqual(self.module.classify(data)['result'],'inconclusive')

    def test_checks(self):
        for check,outcome in [
            ({'__typename':'CheckRun','status':'QUEUED'},'waiting'),
            ({'__typename':'CheckRun','status':'COMPLETED','conclusion':'FAILURE'},'blocked'),
            ({'__typename':'StatusContext','state':'SUCCESS'},'ready'),
            ({'__typename':'StatusContext','state':'ERROR'},'blocked'),
            ({'__typename':'StatusContext','state':'PENDING'},'waiting'),
            ({'__typename':'CheckRun','status':'COMPLETED','conclusion':'future'},'inconclusive')]:
            data=snapshot();data['pr']['statusCheckRollup']=[check]
            self.assertEqual(self.module.classify(data)['result'],outcome)

    def test_query_pages_and_moving_subject(self):
        data=snapshot();pr=data['pr']
        page=lambda head,more,cursor: {'data':{'repository':{'pullRequest':{'headRefOid':head,
            'reviewThreads':{'nodes':[],'pageInfo':{'hasNextPage':more,'endCursor':cursor}}}}}}
        with patch.object(self.module,'gh',side_effect=[pr,page('a'*40,True,'next'),page('a'*40,False,None),pr]) as gh:
            self.assertEqual(self.module.collect('example/sample',1),data)
            self.assertIn('after=next',gh.call_args_list[2].args[0])
        changed=copy.deepcopy(pr);changed['reviewDecision']='REVIEW_REQUIRED'
        with patch.object(self.module,'gh',side_effect=[pr,page('a'*40,False,None),changed]):
            with self.assertRaisesRegex(ValueError,'state changed'): self.module.collect('example/sample',1)
        with patch.object(self.module,'gh',side_effect=[pr,page('c'*40,False,None)]):
            with self.assertRaisesRegex(ValueError,'head changed'): self.module.collect('example/sample',1)


class Codex(Cases,unittest.TestCase): tree=Path('codex/plugins')
class Claude(Cases,unittest.TestCase): tree=Path('plugins')

if __name__=='__main__': unittest.main()
