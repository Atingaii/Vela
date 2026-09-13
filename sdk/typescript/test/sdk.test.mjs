import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, rm, readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';

const { VelaClient, VelaError, VelaBulkError } = await import(process.env.VELA_TEST_PACKAGE ?? '../dist/index.js');
const executable = process.env.VELA_TEST_HELPER ?? resolve(dirname(fileURLToPath(import.meta.url)), '../../../.build/debug/vela');
const python = process.env.VELA_TEST_PYTHON ?? '/usr/bin/python3';
async function fixture(body) {
  const root = await mkdtemp(resolve(tmpdir(),'vela-ts-sdk-'));
  const project = resolve(root,'project'); await mkdir(project);
  const clients = [];
  const client = (helper = executable, home = resolve(root,'store')) => {
    const value = new VelaClient({transport:{type:'local', executable:helper, home}, project}); clients.push(value); return value;
  };
  try { await body({root,project,client}); }
  finally { await Promise.all(clients.map(value => value.close())); await rm(root,{recursive:true}); }
}
async function fake(root, body) {
  const path = resolve(root,'fake-helper');
  await writeFile(path, `#!${python}\nimport sys,json,time,os\nfrom pathlib import Path\nhome=Path(sys.argv[sys.argv.index('--home')+1]);home.mkdir(parents=True,exist_ok=True)\nassert '--no-watch' in sys.argv and '--no-schedule' in sys.argv\n${body}\n`, {mode:0o700}); return path;
}
async function received(root) {
  for (let i=0;i<200;i++) { if (existsSync(resolve(root,'received'))) return; await new Promise(r=>setTimeout(r,5)); }
  assert.fail('fake helper did not receive request');
}

test('real helper typed memory, bulk, archives, restart and candidate isolation', async () => fixture(async ({root,project,client}) => {
  const first = client(); await first.registerProject(project);
  const rows = await first.saveCandidates([{title:'First',content:'Original 中文 <reference>.'},{title:'Second',content:'Other preserved evidence.'}]);
  assert.equal(rows.length,2); assert.equal(rows[0].state,'candidate');
  assert.deepEqual((await first.recall('Original')).items,[]);
  const archive = await first.exportArchive(); assert.equal(archive.count,2);
  assert.equal((await first.validateArchive(archive.archive)).valid,true);
  await first.close(); await assert.rejects(first.listProjects(),error=>error instanceof VelaError && error.code==='closed' && !error.effectsUnknown);
  const second = client(); assert.equal((await second.listMemories()).length,2);
  const restored = client(executable,resolve(root,'restored'));
  await restored.registerProject(project);
  assert.equal((await restored.importArchive(archive.archive)).imported,2);
  assert.equal((await restored.importArchive(archive.archive)).skipped,2);
  assert.deepEqual(new Set((await restored.listMemories()).map(row=>row.content)),new Set(rows.map(row=>row.content)));
}));

test('unknown transport, lifecycle and invalid bulk inputs are rejected before writes', async () => fixture(async ({project,client}) => {
  assert.throws(()=>new VelaClient({transport:{type:'remote',executable,home:'/tmp'}}),VelaError);
  const api=client(); await api.registerProject(project);
  assert.throws(()=>api.saveCandidate({title:'No',content:'Must not activate',state:'active'}),VelaError);
  await assert.rejects(api.saveCandidates([{title:'Valid',content:'Never saved'}, {title:'',content:'Invalid'}]),VelaError);
  assert.deepEqual(await api.listMemories(),[]);
}));

test('installed integration SDK captures candidate namespace and reads after reopen', async () => fixture(async ({project,client})=>{
 const first=client();await first.registerProject(project);
 const records=[{id:'message-1',role:'user',content:'SQLite namespaces keep independent project agents separated.'}];
 assert.equal((await first.captureIntegration('researcher','run-1',records)).created,1);await first.close();
 const second=client();assert.equal((await second.captureIntegration('researcher','run-1',records)).skipped,1);
 assert.equal((await second.integrationStats('researcher')).observedRecords,1);
 assert.equal((await second.integrationStats('main')).observedRecords,0);
 assert.deepEqual((await second.recallIntegration('researcher','SQLite')).items,[]);
 assert.deepEqual((await second.recall('SQLite')).items,[]);
}));

test('original Walrus text converts using Core checksums and imports only as an idempotent candidate', async () => fixture(async ({root,project,client}) => {
  const api=client();await api.registerProject(project);
  const source={network:'testnet',packageID:'0x'+'1'.repeat(64),accountID:'0x'+'2'.repeat(64),owner:'0x'+'3'.repeat(64),namespace:'isolated'};
  const content='Original remote text 中文 / café',record={blobID:Buffer.alloc(32,3).toString('base64url'),title:'Remote original',content,sha256:createHash('sha256').update(content).digest('hex'),private:false};
  const result=await api.archiveFromWalrusRecords(source,[record]);assert.equal(result.authenticated,false);assert.equal(result.writesPerformed,false);assert.deepEqual(await api.listMemories(),[]);
  assert.equal((await api.validateArchive(result.archive)).valid,true);assert.equal((await api.importArchive(result.archive)).imported,1);await api.close();
  const reopened=client();assert.equal((await reopened.importArchive(result.archive)).skipped,1);assert.equal((await reopened.listMemories())[0].content,content);assert.deepEqual((await reopened.recall('remote')).items,[]);
}));

test('real installed Apple semantic index, resumed pages, reopen and hybrid recall', async () => fixture(async ({root,project,client}) => {
  const first=client(); await first.registerProject(project);
  const rows=await first.saveCandidates([{title:'Transport',content:'The automobile requires maintenance.'},{title:'Dessert',content:'Bake a chocolate cake for the birthday party.'}]);
  await first.close();
  // Activation is a separate explicit Core review, not an SDK write capability.
  for (const row of rows) execFileSync(executable,['call','memory.transition',JSON.stringify({id:row.id,state:'active'}),'--home',resolve(root,'store')],{env:{...process.env,VELA_DISABLE_DISCOVERY:'1'}});
  const api=client(); const status=await api.semanticStatus({language:'en'});
  if (status.status==='unavailable') {
    assert.equal(status.model,null); assert.equal((await api.recall('automobile',{retrievalMode:'hybrid'})).retrievalMode,'lexical'); return;
  }
  assert.equal(status.indexed,0); assert.equal(status.indexIncomplete,true);
  const page=await api.semanticIndex({language:'en',batchSize:1}); assert.equal(page.indexed,1);assert.equal(page.hasMore,true);
  assert.equal((await api.semanticIndex({language:'en',batchSize:1,cursor:page.nextCursor})).hasMore,false);
  await api.close(); const reopened=client();
  assert.equal((await reopened.semanticStatus()).indexIncomplete,false);
  const result=await reopened.recall('The vehicle needs repair.',{retrievalMode:'semantic',language:'en',minSimilarity:0,limit:2,scoringWeights:{semantic:1,recency:0,importance:0}});
  assert.equal(result.items[0].id,rows[0].id);assert.equal(result.items[0].retrievalSource,'semantic');assert.ok(result.items[0].semanticSimilarity>=0); if (result.items.length>1) assert.ok(result.items[0].semanticSimilarity>result.items[1].semanticSimilarity);
  assert.equal((await reopened.recall('automobile',{retrievalMode:'hybrid'})).retrievalMode,'hybrid');
  assert.throws(()=>reopened.semanticIndex({batchSize:true}),VelaError);
  assert.throws(()=>reopened.recall('query',{retrievalMode:'semantic',minSimilarity:NaN}),VelaError);
}));

test('out of order responses correlate by request ID', async () => fixture(async ({root,client}) => {
  const helper=await fake(root,"a=json.loads(sys.stdin.readline());b=json.loads(sys.stdin.readline())\nprint(json.dumps({'id':b['id'],'result':[{'id':'second'}]}),flush=True)\nprint(json.dumps({'id':a['id'],'result':[{'id':'first'}]}),flush=True)\ntime.sleep(30)");
  const api=client(helper); const [a,b]=await Promise.all([api.listProjects(),api.listProjects()]);
  assert.equal(a[0].id,'first');assert.equal(b[0].id,'second');
}));

for (const [name,body,code] of [
  ['malformed','sys.stdin.readline()\nprint("SECRET_PRIVATE_CONTENT",flush=True)\ntime.sleep(30)','protocol_error'],
  ['stdout overflow','sys.stdin.readline()\nsys.stdout.write("S"*(2*1024*1024+1));sys.stdout.flush()\ntime.sleep(30)','output_limit'],
  ['stderr overflow','sys.stdin.readline()\nsys.stderr.write("SECRET"*12000);sys.stderr.flush()\ntime.sleep(30)','output_limit'],
]) test(name+' closes the helper and never exposes raw output', async () => fixture(async ({root,client}) => {
  const api=client(await fake(root,body));
  await assert.rejects(api.listProjects(),error=>error.code===code && !error.effectsUnknown && !String(error).includes('SECRET'));
  await api.close();
}));

test('write timeout is uncertain and cannot automatically retry', async () => fixture(async ({root,client}) => {
  const api=client(await fake(root,"ready=json.loads(sys.stdin.readline())\nprint(json.dumps({'id':ready['id'],'result':[]}),flush=True)\nr=json.loads(sys.stdin.readline())\n(home/'received').write_text(str(r['id']))\ntime.sleep(30)"),root);
  await api.listProjects();
  await assert.rejects(api.saveCandidate({title:'Timeout',content:'Potentially saved'}, {timeoutMs:200}),error=>error.code==='timeout' && error.effectsUnknown && Number.isInteger(error.requestId));
  await api.close();assert.equal(await readFile(resolve(root,'received'),'utf8'),'2');
  await assert.rejects(api.listProjects(),error=>error.code==='closed');
}));

test('caller abort preserves unknown-write status and closes helper', async () => fixture(async ({root,client}) => {
  const api=client(await fake(root,"r=json.loads(sys.stdin.readline())\n(home/'received').write_text(str(r['id']))\ntime.sleep(30)"),root);
  const signal=new AbortController();
  const result=api.saveCandidate({title:'Abort',content:'Potentially saved'}, {signal:signal.signal});
  const assertion=assert.rejects(result,error=>error.code==='cancelled' && error.effectsUnknown);
  await received(root); signal.abort(); await assertion; await api.close();
}));

test('bulk failure preserves completed records and does not attempt trailing writes', async () => fixture(async ({root,client}) => {
  const helper=await fake(root,"a=json.loads(sys.stdin.readline())\nprint(json.dumps({'id':a['id'],'result':{'id':'first','title':'One','content':'Saved','project':'/example','state':'candidate'}}),flush=True)\nb=json.loads(sys.stdin.readline());(home/'received').write_text(str(b['id']))\nprint(json.dumps({'id':b['id'],'error':{'message':'SECRET_PRIVATE_CONTENT'}}),flush=True)\ntime.sleep(30)");
  const api=client(helper,root);
  await assert.rejects(api.saveCandidates([{title:'One',content:'Saved'},{title:'Two',content:'Uncertain'},{title:'Three',content:'Never sent'}]),error=>error instanceof VelaBulkError && error.completed.length===1 && error.failedIndex===1 && error.unattempted===1 && error.effectsUnknown && !String(error).includes('SECRET'));
  assert.equal(await readFile(resolve(root,'received'),'utf8'),'2');
}));
