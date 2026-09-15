// Optional acceptance against the retained, actually packed pre-AI local SDK.
import test from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {mkdtempSync,mkdirSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
import {createRequire} from 'node:module';
import {pathToFileURL} from 'node:url';
const installed=Boolean(process.env.VELA_AI_LEGACY_CONSUMER_PACKAGE);
test('actually installed legacy SDK retains read-only generation but refuses AI capture before dispatch',{skip:!installed},async()=>{
 const resolve=createRequire(process.env.VELA_AI_LEGACY_CONSUMER_PACKAGE),{generateText,wrapLanguageModel}=await import(pathToFileURL(resolve.resolve('ai'))),{createOpenAI}=await import(pathToFileURL(resolve.resolve('@ai-sdk/openai')));
 const {createVelaMemoryMiddleware}=await import(process.env.VELA_AI_LEGACY_TEST_PACKAGE),legacy=await import(process.env.VELA_AI_LEGACY_LOCAL_SDK_PACKAGE);assert.equal(legacy.MEMORY_INTEGRATIONS,undefined);
 const root=mkdtempSync(join(tmpdir(),'vela-ai-old-sdk-')),project=join(root,'project'),home=join(root,'store');mkdirSync(project);
 const rpc=(method,params)=>{const r=spawnSync(process.env.VELA_TEST_HELPER,['rpc','--no-watch','--no-schedule','--home',home],{input:JSON.stringify({id:1,method,params})+'\n',encoding:'utf8',timeout:10000});assert.equal(r.status,0);const row=JSON.parse(r.stdout.trim());assert.ok(!row.error,JSON.stringify(row));return row.result;};
 let manager,requests=0;const sockets=new Set();
 const server=createServer(async(req,res)=>{let body='';for await(const chunk of req)body+=chunk;requests++;assert.ok(body.includes('SQLite retained legacy SDK reference.'));res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({id:'legacy',object:'chat.completion',created:1,model:'synthetic',choices:[{index:0,message:{role:'assistant',content:'Legacy read complete.'},finish_reason:'stop'}],usage:{prompt_tokens:3,completion_tokens:3,total_tokens:6}}));});server.on('connection',s=>{sockets.add(s);s.on('close',()=>sockets.delete(s));});
 try{
  rpc('projects.add',{path:project});rpc('memory.save',{id:'legacy-reference',project,namespace:'main',scope:'namespace',state:'active',private:false,title:'SQLite',content:'SQLite retained legacy SDK reference.'});
  await new Promise(r=>server.listen(0,'127.0.0.1',r));const origin=`http://127.0.0.1:${server.address().port}`,model=createOpenAI({apiKey:'synthetic-local-only',baseURL:origin+'/v1'}).chat('synthetic');
  const config={project,namespace:'main',helperPath:process.env.VELA_TEST_HELPER,storeHome:home,modelRecipient:{provider:model.provider,model:model.modelId,origin},acknowledgeMemoryDisclosure:true};
  assert.throws(()=>createVelaMemoryMiddleware({...config,autoCapture:true}),{code:'capture_integration_unavailable'});assert.equal(requests,0);assert.equal(rpc('memory.list',{project}).length,1);
  manager=createVelaMemoryMiddleware(config);const turn=manager.forTurn({sessionID:'legacy',turnID:'read-only'});const result=await generateText({model:wrapLanguageModel({model,middleware:turn.middleware}),prompt:'SQLite storage reference?',maxRetries:0});assert.equal(result.text,'Legacy read complete.');assert.equal((await turn.settled()).capture.state,'disabled');assert.equal(requests,1);assert.equal(rpc('memory.list',{project}).length,1);
 }finally{await manager?.close();for(const s of sockets)s.destroy();server.closeAllConnections();await new Promise(r=>server.close(r));rmSync(root,{recursive:true,force:true});}
});
