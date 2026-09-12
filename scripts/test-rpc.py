"""Black-box JSONL/MCP tests with disposable Vela stores and synthetic data."""
import json, pathlib, subprocess, tempfile, os
os.environ['VELA_DISABLE_DISCOVERY']='1'

root=pathlib.Path(__file__).resolve().parents[1]
binary=root/'.build/debug/vela'
assert binary.exists(), 'Run swift build first'

def invoke(home, method, params=None):
    result=subprocess.run([str(binary),'call',method,json.dumps(params or {}),'--home',str(home)],capture_output=True,text=True,timeout=30)
    assert result.returncode == 0, (method,result.stderr)
    return json.loads(result.stdout)

def exchange(home, mode, requests, *options):
    result=subprocess.run([str(binary),mode,'--home',str(home),'--no-watch',*options],input=''.join(json.dumps(r)+'\n' for r in requests),text=True,capture_output=True,timeout=30)
    assert result.returncode == 0, (result.returncode,result.stderr)
    return {r.get('id'):r for r in map(json.loads,result.stdout.splitlines())}

with tempfile.TemporaryDirectory(prefix='vela-rpc-') as tmp:
    base=pathlib.Path(tmp); home=base/'store'; project=base/'project'; project.mkdir()
    added=invoke(home,'projects.add',{'path':str(project)})
    result=exchange(home,'rpc',[
        {'id':1,'method':'settings.save','params':{'notifications':False,'notificationSound':False,'notifyCompleted':False}},
        {'id':2,'method':'settings.get','params':{}},
        {'id':3,'method':'arbitrary.exec','params':{'command':'touch should-not-exist'}},
        {'id':4,'method':'settings.save','params':{'notifications':1}},
        {'id':5,'method':'dashboard.get','params':{}},
    ])
    assert result[2]['result']['telemetry'] is False
    assert result[2]['result']['notificationSound'] is False
    assert result[2]['result']['notifyCompleted'] is False
    assert result[2]['result']['notifyApprovals'] is True
    assert result[5]['result']['notificationScope'] == '*'
    assert result[5]['result']['settings']['notificationSound'] is False
    assert 'error' in result[4], 'Numeric 1 must not authorize notifications'
    assert 'error' in result[3]
    memory=invoke(home,'memory.save',{'title':'Synthetic safety constraint','content':'velatestactive evidence','type':'Constraint','scope':'Project','project':str(project),'state':'Active'})
    hidden=invoke(home,'memory.save',{'title':'Private memory','content':'velatestprivatememory evidence','type':'Fact','scope':'Project','project':str(project),'private':True})
    invoke(home,'memory.save',{'title':'Scoped memory','content':'velatestsession evidence','type':'Fact','scope':'Session','project':str(project),'sourceSession':'session-fixture','state':'Active'})
    invoke(home,'library.add',{'title':'Private fixture','content':'velatestprivate secret evidence','project':str(project),'private':True})
    results=exchange(home,'mcp',[
        {'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2024-11-05','clientInfo':{'name':'test','version':'1'},'capabilities':{}}},
        {'jsonrpc':'2.0','id':2,'method':'tools/list'},
        {'jsonrpc':'2.0','id':3,'method':'tools/call','params':{'name':'vela_search','arguments':{'query':'velatestprivate','project':str(project),'includePrivate':True}}},
        {'jsonrpc':'2.0','id':4,'method':'tools/call','params':{'name':'vela_recall','arguments':{'query':'velatestactive','project':str(project),'budget':1000}}},
        {'jsonrpc':'2.0','id':5,'method':'tools/call','params':{'name':'vela_memory_contribute','arguments':{'title':'nope'}}},
        {'jsonrpc':'2.0','id':6,'method':'tools/call','params':{'name':'vela_memory_list','arguments':{'project':str(project)}}},
        {'jsonrpc':'2.0','id':7,'method':'tools/call','params':{'name':'vela_setup_list','arguments':{}}},
        {'jsonrpc':'2.0','id':9,'method':'tools/call','params':{'name':'vela_recall','arguments':{'query':'velatestsession','project':str(project),'sessionId':'session-fixture','budget':1000}}},
        {'jsonrpc':'2.0','id':8,'method':'tools/call','params':{'name':'vela_memory_list','arguments':{'project':str(base/'unregistered')}}},
    ])
    assert results[1]['result']['serverInfo']['name']=='Vela'
    names={t['name'] for t in results[2]['result']['tools']}
    assert 'vela_memory_contribute' not in names
    assert not any('run' in name or 'apply' in name for name in names)
    assert 'velatestprivate' not in json.dumps(results[3]['result'])
    assert 'velatestactive' in json.dumps(results[4]['result'])
    assert 'error' in results[5]
    assert 'velatestprivatememory' not in json.dumps(results[6]['result'])
    assert 'error' in results[7] and 'error' in results[8]
    assert 'velatestsession' in json.dumps(results[9]['result'])
    contributed=exchange(home,'mcp',[
        {'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':'vela_memory_contribute','arguments':{'id':memory['id'],'title':'Candidate','content':'New proposed evidence','type':'Fact','scope':'Project','project':str(project),'state':'Active'}}}
    ],'--contribute')
    assert 'error' not in contributed[1], contributed
    records=invoke(home,'memory.list',{'project':str(project)})
    assert any(r['id']==memory['id'] and r['state'].lower()=='active' for r in records)
    assert any(r['title']=='Candidate' and r['state'].lower()=='candidate' for r in records)
    workflow=invoke(home,'workflows.save',{'title':'Safe fixture','project':str(project),'description':'Write after review','trigger':'manual','steps':[{'title':'Write fixture','tool':'file.write','arguments':{'path':'approved.txt','content':'frozen value'}}]})
    run=invoke(home,'workflows.run',{'id':workflow['id'],'dryRun':True})
    assert not (project/'approved.txt').exists(), 'Dry run wrote a file'
    assert run.get('dryRun') is True
print('RPC/MCP integration passed: persisted settings, private retrieval, candidate-only contribution, dry run')
