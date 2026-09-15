#!/usr/bin/env python3
"""Actual helper acceptance for project-scoped, ledger-only workflow health."""
import json, os, pathlib, subprocess, tempfile
os.environ["VELA_DISABLE_DISCOVERY"] = "1"
ROOT = pathlib.Path(__file__).resolve().parents[1]
BINARY = (ROOT / ".build/debug/vela").resolve(strict=True)
def call(home, method, params):
    item = subprocess.run([str(BINARY),"rpc","--home",str(home),"--no-watch","--no-schedule"],input=json.dumps({"id":1,"method":method,"params":params})+"\n",text=True,capture_output=True,timeout=30)
    assert item.returncode == 0, item.stderr
    return json.loads(item.stdout)
with tempfile.TemporaryDirectory(prefix="vela-health-rpc-") as temp:
    base=pathlib.Path(temp); home=base/'store'; project=base/'project'; project.mkdir()
    assert 'result' in call(home,'projects.add',{'path':str(project)})
    workflow=call(home,'workflows.save',{'project':str(project),'title':'Health fixture','steps':[{'tool':'git.status'}]})['result']
    dry=call(home,'workflows.run',{'id':workflow['id'],'dryRun':True})['result']
    real=call(home,'workflows.run',{'id':workflow['id'],'dryRun':False})['result']
    report=call(home,'workflows.health',{'project':str(project),'id':workflow['id'],'limit':1})['result']
    assert report['runs']==1 and report['window']['dryRunsExcluded']==1 and report['items'][0]['id']==real['id'], report
    assert report['sourceScan']['scope']=='project' and report['aggregateIncomplete'] is False, report
    assert report['items'][0]['stepStates'][0]['timedOut'] is False and report['items'][0]['stepStates'][0]['truncated'] is False, report
    assert 'output' not in json.dumps(report) and report['tokensAvailable'] is False, report
print('Workflow health JSON-RPC passed: ledger evidence, explicit coverage, dry-run exclusion, and redacted page')
