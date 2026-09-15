#!/usr/bin/env python3
"""Exercise Lab Recall OFF/ON through the actual local RPC, approval, worktree and JSONL-agent path; no provider is called."""
import argparse, hashlib, json, os, shutil, subprocess, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def call(binary, home, method, params):
    result = subprocess.run([str(binary), 'call', method, json.dumps(params), '--home', str(home)], text=True, capture_output=True, timeout=45)
    if result.returncode != 0:
        raise RuntimeError(f'{method}: {result.stderr.strip() or result.stdout.strip()}')
    return json.loads(result.stdout)

def git(project, args, env):
    subprocess.run(['git', '-c', 'core.hooksPath=/dev/null', *args], cwd=project, env=env, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def agent_context(row):
    values = row.get('agentCommand', [])
    encoded = next((value.split('=', 1)[1] for value in values if value.startswith('developer_instructions=')), None)
    if encoded is None:
        return ''  # Explicit Recall-OFF with no direct context correctly omits the Codex config flag.
    return json.loads(encoded)

def spec(project, agent, baseline, candidate):
    return {'title':'synthetic Lab Recall receipt','project':str(project),'kind':'memory',
            'agent':{'provider':'codex','executable':str(agent),'model':'fixed-local-jsonl','reasoningEffort':'high'},
            'task':'Write the approved local context to the allowed output file.','verificationCommand':['/usr/bin/python3','verify.py'],
            'verificationFiles':['verify.py'],'outputFiles':['observed-context.txt'],'timeoutSeconds':20,'repetitions':1,
            'baseline':baseline,'candidate':candidate}

def make_agent(path):
    path.write_text('''#!/usr/bin/env python3 -I
import json, pathlib, sys
if '--version' in sys.argv:
 print('fixed-lab-recall-agent 1'); raise SystemExit(0)
encoded = next((arg.split('=', 1)[1] for arg in sys.argv if arg.startswith('developer_instructions=')), None)
pathlib.Path('observed-context.txt').write_text('' if encoded is None else json.loads(encoded))
print(json.dumps({'type':'thread.started','thread_id':'fixed-lab-recall'}), flush=True)
print(json.dumps({'type':'item.completed','item':{'id':'message','type':'agent_message','text':'fixed fixture only'}}), flush=True)
print(json.dumps({'type':'turn.completed','usage':{'input_tokens':1,'output_tokens':1}}), flush=True)
''')
    path.chmod(0o700)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=ROOT/'.build/debug/vela')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(); binary = args.binary.resolve(strict=True)
    base = Path(tempfile.mkdtemp(prefix='vela-lab-recall-rpc-'))
    receipt = {'format':'vela-lab-recall-variant-rpc-v1','providerRuns':0,'helperSHA256':hashlib.sha256(binary.read_bytes()).hexdigest(),
               'fixture':'isolated Git + store + fixed JSONL agent','checks':[],'temporaryFixturesRemoved':False}
    try:
        project, other, home = base/'Harbor', base/'Beacon', base/'store'; project.mkdir(); other.mkdir(); (base/'empty-template').mkdir()
        env = os.environ | {'GIT_CONFIG_NOSYSTEM':'1','GIT_CONFIG_GLOBAL':'/dev/null','GIT_TEMPLATE_DIR':str(base/'empty-template')}
        (project/'verify.py').write_text('assert True\n'); git(project,['init','-q'],env); git(project,['add','.'],env); git(project,['-c','user.name=fixture','-c','user.email=fixture@example.invalid','commit','-qm','fixture'],env)
        agent = base/'fixed-agent.py'; make_agent(agent)
        call(binary,home,'projects.add',{'path':str(project)}); call(binary,home,'projects.add',{'path':str(other)})
        active = call(binary,home,'memory.save',{'id':'active-hit','project':str(project),'scope':'project','state':'active','title':'Recall needle','content':'RECALL_ACTIVE_SENTINEL bounded guidance'})
        call(binary,home,'memory.save',{'id':'candidate-hit','project':str(project),'scope':'project','state':'candidate','title':'Recall candidate','content':'RECALL_CANDIDATE_SENTINEL'})
        call(binary,home,'memory.save',{'id':'private-hit','project':str(project),'scope':'project','state':'active','private':True,'title':'Recall private','content':'RECALL_PRIVATE_SENTINEL'})
        call(binary,home,'memory.save',{'id':'source-labeled-hit','project':str(project),'scope':'project','state':'active','private':False,'sourceLabeledPrivate':True,'title':'Recall source-labeled','content':'RECALL_SOURCE_LABELED_SENTINEL'})
        call(binary,home,'memory.save',{'id':'cross-hit','project':str(other),'scope':'project','state':'active','title':'Recall cross','content':'RECALL_CROSS_SENTINEL'})
        created = call(binary,home,'lab.run',spec(project,agent,{'files':[],'recall':{'enabled':False,'strictOff':True}}, {'files':[],'recall':{'enabled':True,'query':'recall needle','mode':'lexical','scope':'project','budget':500}}))
        frozen = created['candidate']; recall = frozen['recall']; ids = [item['id'] for item in recall['items']]
        assert ids == [active['id']], (ids,recall)
        assert frozen['memoryInjection'] == 'recall' and recall['usedTokens'] <= 500
        assert 'RECALL_ACTIVE_SENTINEL' in frozen['context'], frozen
        approval = next(item for item in call(binary,home,'inbox.list',{'project':str(project)}) if item['id'] == created['approvalId'])
        before_hash = approval['snapshotHash']
        decision = call(binary,home,'approvals.decide',{'id':approval['id'],'decision':'approve','snapshotHash':before_hash})
        assert decision['state'] == 'executed', decision
        completed = call(binary,home,'lab.compare',{'id':created['id']})
        assert completed['state'] == 'completed', completed
        contexts = {row['variant']:agent_context(row) for row in completed['results']}
        assert 'RECALL_ACTIVE_SENTINEL' not in contexts['baseline']
        assert 'RECALL_ACTIVE_SENTINEL' in contexts['candidate']
        assert 'RECALL_PRIVATE_SENTINEL' not in contexts['candidate'] and 'RECALL_CROSS_SENTINEL' not in contexts['candidate'] and 'RECALL_CANDIDATE_SENTINEL' not in contexts['candidate'] and 'RECALL_SOURCE_LABELED_SENTINEL' not in contexts['candidate']
        assert not (home/'lab-worktrees'/created['id']).exists()
        receipt['checks'].append({'name':'off-on-agent-context','passed':True,'approvalHash':before_hash,'recalledIDs':ids,'budget':recall['budget'],'usedTokens':recall['usedTokens'],'agentContextsObserved':['baseline','candidate'],'privateCrossCandidateExcluded':True,'sourceLabeledPrivateExcluded':True,'cleanup':True})
        try:
            call(binary,home,'lab.run',spec(project,agent,{'files':[],'memoryIds':['active-hit'],'recall':{'enabled':False,'strictOff':True}}, {'files':[]}))
            raise AssertionError('strict OFF accepted explicit memory IDs')
        except RuntimeError as error:
            assert 'strict Recall-OFF' in str(error), error
        receipt['checks'].append({'name':'strict-off-rejects-explicit-memoryids','passed':True})
        try:
            call(binary,home,'lab.run',spec(project,agent,{'files':[]}, {'files':[],'memoryIds':['source-labeled-hit']}))
            raise AssertionError('explicit Lab memory accepted a source-labeled-private record')
        except RuntimeError as error:
            assert 'excluded' in str(error), error
        receipt['checks'].append({'name':'explicit-source-labeled-memory-rejected-at-freeze','passed':True})
        stale = call(binary,home,'lab.run',spec(project,agent,{'files':[],'recall':{'enabled':False,'strictOff':True}}, {'files':[],'recall':{'enabled':True,'query':'recall needle','mode':'lexical','scope':'project','budget':500}}))
        call(binary,home,'memory.save',{'id':'active-hit','project':str(project),'scope':'project','state':'active','title':'Recall needle','content':'changed after frozen approval'})
        stale_approval = next(item for item in call(binary,home,'inbox.list',{'project':str(project)}) if item['id'] == stale['approvalId'])
        stale_decision = call(binary,home,'approvals.decide',{'id':stale_approval['id'],'decision':'approve','snapshotHash':stale_approval['snapshotHash']})
        assert stale_decision['state'] == 'failed' and 'Frozen Lab Recall source changed' in stale_decision['result']['output'], stale_decision
        stale_eval = call(binary,home,'lab.compare',{'id':stale['id']})
        assert stale_eval['state'] == 'failed' and [row['variant'] for row in stale_eval['results']] == ['baseline'] and not (home/'lab-worktrees'/stale['id']).exists(), stale_eval
        receipt['checks'].append({'name':'changed-source-rejected-before-agent','passed':True,'approvalState':stale_decision['state'],'agentResults':1,'staleCandidateAgentStarted':False,'cleanup':True})
        private_stale = call(binary,home,'lab.run',spec(project,agent,{'files':[],'recall':{'enabled':False,'strictOff':True}}, {'files':[],'recall':{'enabled':True,'query':'recall needle','mode':'lexical','scope':'project','budget':500}}))
        call(binary,home,'memory.save',{'id':'active-hit','project':str(project),'scope':'project','state':'active','private':True,'title':'Recall needle','content':'changed after frozen approval'})
        private_approval = next(item for item in call(binary,home,'inbox.list',{'project':str(project)}) if item['id'] == private_stale['approvalId'])
        private_decision = call(binary,home,'approvals.decide',{'id':private_approval['id'],'decision':'approve','snapshotHash':private_approval['snapshotHash']})
        assert private_decision['state'] == 'failed' and 'became private' in private_decision['result']['output'], private_decision
        private_eval = call(binary,home,'lab.compare',{'id':private_stale['id']})
        assert private_eval['state'] == 'failed' and [row['variant'] for row in private_eval['results']] == ['baseline'] and not (home/'lab-worktrees'/private_stale['id']).exists(), private_eval
        receipt['checks'].append({'name':'private-lifecycle-revocation-rejected-before-agent','passed':True,'agentResults':1,'staleCandidateAgentStarted':False,'cleanup':True})
        call(binary,home,'memory.save',{'id':'active-hit','project':str(project),'scope':'project','state':'active','private':False,'sourceLabeledPrivate':False,'title':'Recall needle','content':'RECALL_ACTIVE_SENTINEL bounded guidance'})
        labeled_stale = call(binary,home,'lab.run',spec(project,agent,{'files':[],'recall':{'enabled':False,'strictOff':True}}, {'files':[],'recall':{'enabled':True,'query':'recall needle','mode':'lexical','scope':'project','budget':500}}))
        call(binary,home,'memory.save',{'id':'active-hit','project':str(project),'scope':'project','state':'active','private':False,'sourceLabeledPrivate':True,'title':'Recall needle','content':'RECALL_ACTIVE_SENTINEL bounded guidance'})
        labeled_approval = next(item for item in call(binary,home,'inbox.list',{'project':str(project)}) if item['id'] == labeled_stale['approvalId'])
        labeled_decision = call(binary,home,'approvals.decide',{'id':labeled_approval['id'],'decision':'approve','snapshotHash':labeled_approval['snapshotHash']})
        assert labeled_decision['state'] == 'failed', labeled_decision
        labeled_eval = call(binary,home,'lab.compare',{'id':labeled_stale['id']})
        assert labeled_eval['state'] == 'failed' and [row['variant'] for row in labeled_eval['results']] == ['baseline'] and not (home/'lab-worktrees'/labeled_stale['id']).exists(), labeled_eval
        receipt['checks'].append({'name':'source-labeled-revocation-rejected-before-candidate-agent','passed':True,'approvalState':labeled_decision['state'],'agentResults':1,'staleCandidateAgentStarted':False,'cleanup':True})
    finally:
        shutil.rmtree(base, ignore_errors=True)
        receipt['temporaryFixturesRemoved'] = not base.exists()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps({'passed':len(receipt['checks']),'output':str(args.output)}))
if __name__ == '__main__': main()
