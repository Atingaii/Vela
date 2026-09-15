#!/usr/bin/env python3
"""Real-CLI regression for a rewrite inside an already indexed growing JSONL source."""
import argparse, hashlib, json, os, queue, shutil, subprocess, tempfile, threading
from pathlib import Path

def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    parser=argparse.ArgumentParser(description=__doc__); parser.add_argument('--binary',required=True); parser.add_argument('--output',required=True); args=parser.parse_args()
    binary=Path(args.binary).resolve(); output=Path(args.output)
    if not binary.is_file() or output.exists() or output.parent.name != 'parity' or output.parent.parent.name != 'output': raise SystemExit('binary must exist and output must be a new output/parity receipt')
    output.parent.mkdir(parents=True, exist_ok=True)
    base=Path(tempfile.mkdtemp(prefix='vela-growing-rewrite-',dir=str(output.parent))); project=base/'project'; logs=base/'logs'; home=base/'home'; (logs/'claude').mkdir(parents=True); (logs/'codex').mkdir(); project.mkdir()
    transcript=[]; process=None
    def rows(provider,user,later=False):
        if provider=='claude':
            values=[{'type':'user','uuid':'user','sessionId':'claude-source','cwd':str(project),'timestamp':'2026-09-14T00:00:00Z','message':{'role':'user','content':user}}, {'type':'assistant','uuid':'initial','timestamp':'2026-09-14T00:00:01Z','message':{'id':'initial','role':'assistant','content':[{'type':'text','text':'initial'}]}}]
            if later: values.append({'type':'assistant','uuid':'later','timestamp':'2026-09-14T00:00:02Z','message':{'id':'later','role':'assistant','content':[{'type':'text','text':'appended'}]}})
            return values
        values=[{'type':'session_meta','timestamp':'2026-09-14T00:00:00Z','payload':{'id':'codex-source','cwd':str(project),'git':{'branch':'main'}}}, {'type':'response_item','timestamp':'2026-09-14T00:00:01Z','payload':{'id':'user','type':'message','role':'user','content':[{'type':'input_text','text':user}]}}]
        if later: values.append({'type':'response_item','timestamp':'2026-09-14T00:00:02Z','payload':{'id':'later','type':'message','role':'assistant','content':[{'type':'output_text','text':'appended'}]}})
        return values
    def write(path,value): path.write_text(''.join(json.dumps(row,separators=(',',':'))+'\n' for row in value))
    env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(base),'LANG':'en_US.UTF-8','VELA_HOME':str(home),'VELA_SESSION_ROOT':str(logs),'VELA_DISABLE_DISCOVERY':'1','GIT_CONFIG_NOSYSTEM':'1','GIT_CONFIG_GLOBAL':os.devnull}
    try:
        process=subprocess.Popen([str(binary),'rpc','--no-schedule','--home',str(home)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,env=env,cwd=base)
        replies=queue.Queue()
        def read():
            for line in process.stdout:
                try:
                    item=json.loads(line)
                    if 'id' in item: replies.put(item)
                except ValueError: pass
        threading.Thread(target=read,daemon=True).start(); sequence=0
        def rpc(method,params):
            nonlocal sequence
            sequence+=1; request={'id':str(sequence),'method':method,'params':params}; process.stdin.write(json.dumps(request)+'\n'); process.stdin.flush(); response=replies.get(timeout=20)
            if response.get('id')!=request['id'] or 'error' in response: raise RuntimeError(response)
            transcript.append(request); return response['result']
        rpc('projects.add',{'path':str(project)})
        evidence={'format':'vela-session-growing-rewrite-rpc-v1','synthetic':True,'providerCalls':0,'helperSHA256':digest(binary),'checks':[]}
        for provider in ('claude','codex'):
            source=logs/provider/'rewrite.jsonl'; old='O'*40; rewritten='R'*40; assert len(old.encode())==len(rewritten.encode())
            write(source,rows(provider,old)); first=rpc('sessions.refresh',{}); sessions=rpc('sessions.list',{'project':str(project)}); item=next(x for x in sessions if x.get('provider')==provider); before=rpc('sessions.get',{'id':item['id']})
            before_sha,before_offset=digest(source),before['indexedBytes']; write(source,rows(provider,rewritten,True)); second=rpc('sessions.refresh',{}); after=rpc('sessions.get',{'id':item['id']})
            messages=after.get('messages',[]); assert any(x.get('id')=='user' and x.get('content')==rewritten for x in messages); assert any(x.get('id')=='later' and x.get('content')=='appended' for x in messages)
            if provider=='claude':
                partial=json.dumps({'type':'assistant','uuid':'partial','message':{'id':'partial','role':'assistant','content':[{'type':'text','text':'partial completed'}]}},separators=(',',':'))
                with source.open('a') as handle: handle.write(partial[:30])
                rpc('sessions.refresh',{}); interim=rpc('sessions.get',{'id':item['id']}); assert not any(x.get('id')=='partial' for x in interim.get('messages',[]))
                with source.open('a') as handle: handle.write(partial[30:]+'\n')
                rpc('sessions.refresh',{}); completed=rpc('sessions.get',{'id':item['id']}); assert sum(x.get('id')=='partial' for x in completed.get('messages',[]))==1
            evidence['checks'].append({'provider':provider,'beforeSHA256':before_sha,'afterSHA256':digest(source),'beforeOffset':before_offset,'afterOffset':after['indexedBytes'],'sourcesUpdated':second['sourcesUpdated'],'rewrittenIndexed':True,'appendedIndexed':True})
        evidence['passed']=True; evidence['requests']=transcript; output.write_text(json.dumps(evidence,indent=2)+'\n'); print(json.dumps({'passed':True,'checks':len(evidence['checks']),'output':str(output)}))
    finally:
        if process:
            process.stdin.close()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
        shutil.rmtree(base)
if __name__=='__main__': main()
