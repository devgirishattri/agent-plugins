#!/usr/bin/env python3
"""Conservative GitHub PR blocker report. A ready observation is not permission."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess

FIELDS = "number,url,headRefOid,baseRefOid,state,isDraft,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup"
THREADS = """query($owner:String!,$name:String!,$number:Int!,$after:String){
repository(owner:$owner,name:$name){pullRequest(number:$number){headRefOid
reviewThreads(first:100,after:$after){nodes{isResolved isOutdated}
pageInfo{hasNextPage endCursor}}}}}"""


def classify(snapshot, expected_head=None):
    if not isinstance(snapshot,dict) or not isinstance(snapshot.get("pr"),dict):
        raise ValueError("snapshot requires pr object")
    pr=snapshot["pr"]; blockers=[]; pending=[]; unknown=[]
    head=pr.get("headRefOid")
    if not isinstance(head,str) or not re.fullmatch(r"[a-f0-9]{40}",head):
        raise ValueError("missing valid PR head SHA")
    if expected_head is not None and expected_head!=head: unknown.append("unexpected-head")
    if snapshot.get("observed_head")!=head: unknown.append("head-changed-during-observation")
    if pr.get("state")!="OPEN": blockers.append("not-open")
    if pr.get("isDraft") is True: blockers.append("draft")
    elif pr.get("isDraft") is not False: unknown.append("draft-state-unavailable")
    if pr.get("mergeable")=="CONFLICTING": blockers.append("merge-conflicts")
    elif pr.get("mergeable")!="MERGEABLE": unknown.append("mergeability-unavailable")
    state=pr.get("mergeStateStatus")
    if state in {"BLOCKED","DIRTY","BEHIND","UNSTABLE","DRAFT"}: blockers.append("forge-"+state.lower())
    elif state!="CLEAN": unknown.append("forge-state-unavailable")
    review=pr.get("reviewDecision")
    if review in {"CHANGES_REQUESTED","REVIEW_REQUIRED"}: blockers.append("review-"+review.lower())
    elif review not in {"APPROVED",""}: unknown.append("review-decision-unavailable")
    threads=snapshot.get("threads")
    if not isinstance(threads,list): unknown.append("review-threads-unavailable")
    else:
        for thread in threads:
            if not isinstance(thread,dict) or type(thread.get("isResolved")) is not bool:
                unknown.append("malformed-review-thread")
            elif not thread["isResolved"]: blockers.append("unresolved-review-thread")
    checks=pr.get("statusCheckRollup")
    if not isinstance(checks,list) or not checks: unknown.append("checks-unavailable-or-empty")
    else:
        for check in checks:
            if not isinstance(check,dict): unknown.append("malformed-check"); continue
            kind=check.get("__typename");name=check.get("name",check.get("context","unnamed"))
            if kind=="CheckRun":
                status=check.get("status");result=check.get("conclusion")
                if status in {"QUEUED","IN_PROGRESS","WAITING","PENDING","REQUESTED"}: pending.append(name); continue
                if status!="COMPLETED": unknown.append("unknown-check-status:"+str(name)); continue
                if result in {"FAILURE","TIMED_OUT","CANCELLED","ACTION_REQUIRED","STARTUP_FAILURE","STALE"}: blockers.append("check-failed:"+str(name))
                elif result not in {"SUCCESS","NEUTRAL","SKIPPED"}: unknown.append("unknown-check-result:"+str(name))
            elif kind=="StatusContext":
                result=check.get("state")
                if result=="PENDING": pending.append(name)
                elif result in {"ERROR","FAILURE"}: blockers.append("check-failed:"+str(name))
                elif result!="SUCCESS": unknown.append("unknown-status-context:"+str(name))
            else: unknown.append("unknown-check-type:"+str(name))
    outcome="blocked" if blockers else "inconclusive" if unknown else "waiting" if pending else "ready"
    return {"schema_version":1,"result":outcome,"head":head,"pr":pr.get("number"),
            "url":pr.get("url"),"blockers":sorted(set(blockers)),"pending":sorted(set(pending)),
            "unknown":sorted(set(unknown)),"observed_at":datetime.now(timezone.utc).isoformat(),
            "notice":"Read-only observation; not approval or permission to merge. Recheck before any separately authorized effect."}


def gh(args):
    result=subprocess.run(["gh",*args],capture_output=True,text=True,timeout=30,check=True)
    return json.loads(result.stdout)


def collect(repo, number):
    before=gh(["pr","view",str(number),"--repo",repo,"--json",FIELDS])
    owner,name=repo.split("/");threads=[];cursor=None;seen=set()
    for _ in range(50):
        args=["api","graphql","-f","query="+THREADS,"-f","owner="+owner,
              "-f","name="+name,"-F","number="+str(number)]
        if cursor is not None: args += ["-f","after="+cursor]
        response=gh(args)
        if response.get("errors"): raise ValueError("review thread query failed")
        current=response["data"]["repository"]["pullRequest"]
        if current["headRefOid"]!=before["headRefOid"]: raise ValueError("PR head changed during thread pagination")
        page=current["reviewThreads"];threads.extend(page["nodes"])
        info=page["pageInfo"]
        if info["hasNextPage"] is False: break
        cursor=info["endCursor"]
        if not isinstance(cursor,str) or not cursor or cursor in seen: raise ValueError("invalid thread pagination")
        seen.add(cursor)
    else: raise ValueError("review thread pagination limit exceeded")
    after=gh(["pr","view",str(number),"--repo",repo,"--json",FIELDS])
    # Check the whole observed state, not only HEAD: reviews, base, and checks can
    # change without a new commit. Fail closed on a moving snapshot.
    if before!=after: raise ValueError("PR state changed during observation; take a fresh snapshot")
    return {"pr":after,"threads":threads,"observed_head":after["headRefOid"]}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo");parser.add_argument("--pr",type=int)
    parser.add_argument("--snapshot",type=Path)
    parser.add_argument("--expected-head")
    args=parser.parse_args()
    if args.expected_head and not re.fullmatch(r"[a-f0-9]{40}",args.expected_head): parser.error("expected-head must be a full SHA")
    if args.snapshot:
        if args.repo or args.pr: parser.error("snapshot cannot be combined with repo/pr")
    elif not args.repo or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*",args.repo) or not args.pr or args.pr<1:
        parser.error("provide --repo OWNER/NAME --pr NUMBER, or --snapshot FILE")
    try:
        if args.snapshot:
            if args.snapshot.is_symlink() or not args.snapshot.is_file(): raise ValueError("snapshot must be a regular file")
            snapshot=json.loads(args.snapshot.read_text())
        else: snapshot=collect(args.repo,args.pr)
        result=classify(snapshot,args.expected_head)
        if args.snapshot:
            result["source"]="offline-snapshot"
            result["notice"] += " Offline data is untrusted and does not establish current GitHub state."
        else: result["source"]="github"
        print(json.dumps(result,indent=2))
        return 0 if result["result"]=="ready" else 1
    except Exception:
        # Any failure (gh, input, a malformed or deeply nested response) is
        # unavailable, never a blocked/waiting verdict. Raw errors can contain
        # local account/config details; keep stdout machine-readable and do not
        # echo credentials or untrusted server text.
        print(json.dumps({"schema_version":1,"result":"unavailable","reason":"query, input, or snapshot validation failed; no readiness established"}))
        return 2


if __name__=="__main__": raise SystemExit(main())
