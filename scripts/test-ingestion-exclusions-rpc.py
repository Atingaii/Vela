#!/usr/bin/env python3
"""Real isolated helper RPC acceptance for ingestion policy; no provider/model execution."""
import argparse, datetime, hashlib, json, os, select, shutil, sqlite3, subprocess, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def source_hashes():
    paths = sorted((ROOT/'Sources').rglob('*.swift')) + [Path(__file__).resolve()]
    return {str(p.relative_to(ROOT)):digest(p) for p in paths}
def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=ROOT/'.build/debug/vela')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(); binary = args.binary.resolve(strict=True); out = args.output.resolve()
    if out.exists(): parser.error('Choose a new output file')
    out.parent.mkdir(parents=True, exist_ok=True); (ROOT/'.task-tmp').mkdir(exist_ok=True)
    base = Path(tempfile.mkdtemp(prefix='ingestion-exclusions-rpc-', dir=ROOT/'.task-tmp')).resolve()
    helper = base/'vela'; shutil.copy2(binary, helper)
    ev = {'format':'vela-ingestion-exclusion-rpc-v1','status':'failed','providerRuns':0,'nativeClaimed':False,'checks':[], 'helperBefore':digest(binary),'sourceBefore':source_hashes(),'startedAt':datetime.datetime.now(datetime.timezone.utc).isoformat()}; proc = None; transcript=[]
    project, other, logs, home = base/'project', base/'other', base/'logs', base/'home'
    for p in [project,other,home,*[logs/n for n in ('claude','codex','pi','omp','cursor')]]: p.mkdir(parents=True)
    env = dict(os.environ, VELA_HOME=str(home), VELA_SESSION_ROOT=str(logs), VELA_DISABLE_DISCOVERY='1', GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
    def start():
        return subprocess.Popen([str(helper),'rpc','--no-watch','--no-schedule'],cwd=project,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    def call(method, params=None, reject=False):
        request={'id':len(transcript)+1,'method':method,'params':params or {}}
        proc.stdin.write(json.dumps(request)+'\n');proc.stdin.flush()
        if not select.select([proc.stdout],[],[],20)[0]: raise AssertionError('RPC timed out: '+method)
        response=json.loads(proc.stdout.readline());transcript.append({'request':request,'response':response})
        if reject:
            assert 'error' in response, method+' unexpectedly accepted';return response['error']
        assert 'error' not in response, response
        return response['result']
    def stop():
        if proc and proc.poll() is None:
            proc.stdin.close()
            try: proc.wait(timeout=10)
            except subprocess.TimeoutExpired: proc.kill();proc.wait(timeout=5)
    try:
        stamp='2026-09-14T00:00:00Z'; text='isolated-ingestion-marker'
        def jsonl(provider, rows, name='fixture.jsonl'):
            (logs/provider/name).write_text(''.join(json.dumps(row)+'\n' for row in rows))
        jsonl('claude',[{'type':'user','uuid':'c','cwd':str(project),'message':{'role':'user','content':text}}])
        jsonl('claude',[{'type':'user','uuid':'b','cwd':str(other),'message':{'role':'user','content':'other-project-marker'}}], 'other.jsonl')
        jsonl('codex',[{'type':'session_meta','payload':{'id':'rpc-source','cwd':str(project)}},{'type':'response_item','payload':{'id':'rpc-message','type':'message','role':'user','content':[{'type':'input_text','text':text}]}}])
        for provider in ('pi','omp'):
            jsonl(provider,[{'type':'session','version':3,'id':provider,'cwd':str(project),'timestamp':stamp},{'type':'message','id':'m','parentId':None,'timestamp':stamp,'message':{'role':'user','content':text}}])
        cursor={'cwd':str(project),'name':'Owned Cursor export','conversation':[{'type':1,'text':text}]}
        (logs/'cursor/fixture.json').write_text(json.dumps(cursor))
        with sqlite3.connect(logs/'cursor/state.vscdb') as db:
            db.execute('CREATE TABLE ItemTable(key TEXT PRIMARY KEY,value TEXT)');db.execute('INSERT INTO ItemTable VALUES(?,?)',('composerData:fixture',json.dumps(cursor)))
        files={str(p.relative_to(base)):digest(p) for p in logs.rglob('*') if p.is_file()}
        proc=start(); call('projects.add',{'path':str(project)});call('projects.add',{'path':str(other)});call('sessions.refresh')
        original=call('sessions.list',{'project':str(project)}); assert len(original)==6, original
        assert len(call('sessions.list',{'project':str(other)}))==1
        codex=next(x for x in original if x['provider']=='codex'); detail=call('sessions.get',{'id':codex['id']});message=detail['messages'][0]
        prepared=call('memory.capture.prepare',{'project':str(project),'sessionId':codex['id'],'messageId':message['id']})
        narrow=call('ingestion.exclusions.upsert',{'project':str(project),'provider':'codex','pathGlob':'fixture.jsonl'})
        assert narrow['derivedSessionsRemoved']==1 and len(call('sessions.list',{'project':str(project)}))==5
        assert call('ingestion.exclusions.upsert',{'project':str(project),'provider':'codex','pathGlob':'fixture.jsonl'})['id']==narrow['id']
        call('memory.capture',{'project':str(project),'sessionId':codex['id'],'messageId':message['id'],'sourceIdentity':prepared['sourceIdentity'],'expectedSourceHash':prepared['expectedSourceHash']},reject=True)
        ev['checks'].append({'check':'source-scope-and-stale-capture','passed':True})
        invalid=[{'provider':'codex','pathGlob':True},{'provider':'codex','pathGlob':'../fixture.jsonl'},{'provider':'codex','pathGlob':'abs//file'},{'provider':'codex','pathGlob':'unknown.jsonl'},{'project':'relative/project'}]
        for values in invalid: call('ingestion.exclusions.upsert',{'project':str(project),**values},reject=True)
        call('ingestion.exclusions.upsert',{'project':str(other),'id':narrow['id']},reject=True)
        call('ingestion.exclusions.remove',{'project':str(other),'id':narrow['id']},reject=True)
        ev['checks'].append({'check':'malformed-and-cross-project-rejections','passed':True,'rejections':7})
        whole=call('ingestion.exclusions.upsert',{'project':str(project)})
        assert whole['derivedSessionsRemoved']==5
        call('sessions.refresh');assert call('sessions.list',{'project':str(project)})==[]
        assert len(call('sessions.list',{'project':str(other)}))==1
        assert call('search',{'project':str(project),'query':text})==[]
        ev['checks'].append({'check':'whole-project-all-providers-and-search-withdrawn','passed':True,'formats':6})
        stop();proc=start();call('sessions.refresh');assert call('sessions.list',{'project':str(project)})==[]
        assert len(call('ingestion.exclusions.list',{'project':str(project)}))==2
        ev['checks'].append({'check':'policy-survives-helper-restart','passed':True})
        for rule in (narrow,whole): assert call('ingestion.exclusions.remove',{'project':str(project),'id':rule['id']})['automaticReingestion'] is False
        assert call('sessions.list',{'project':str(project)})==[]
        call('sessions.refresh');assert len(call('sessions.list',{'project':str(project)}))==6
        assert files=={str(p.relative_to(base)):digest(p) for p in logs.rglob('*') if p.is_file()}
        ev['checks'].append({'check':'explicit-refresh-restores-and-source-bytes-unchanged','passed':True})
        ev['status']='passed'
    except Exception as error:
        ev['failure']=str(error)
    finally:
        stop();ev['helperAfter']=digest(binary);ev['sourceAfter']=source_hashes()
        ev['sourceUnchanged']=ev['helperBefore']==ev['helperAfter']==digest(helper) and ev['sourceBefore']==ev['sourceAfter']
        ev['finishedAt']=datetime.datetime.now(datetime.timezone.utc).isoformat()
        if not ev['sourceUnchanged']:ev['status']='failed'
        ev['helperStopped']=proc is None or proc.poll() is not None
        out.with_suffix('.rpc.json').write_text(json.dumps(transcript,ensure_ascii=False,indent=2)+'\n')
        shutil.rmtree(base);ev['fixtureRemoved']=not base.exists()
        out.write_text(json.dumps(ev,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(ev,ensure_ascii=False));return 0 if ev['status']=='passed' else 1
if __name__=='__main__': raise SystemExit(main())
