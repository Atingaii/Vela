import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {createHash,randomBytes} from 'node:crypto';
import {verifyAsync} from '@noble/ed25519';
const {WalrusClient,WalrusError,validateProfile}=await import(process.env.VELA_WALRUS_TEST_PACKAGE??'../dist/index.js');
const {createMemoryManifest,validateMemoryManifest}=await import(process.env.VELA_WALRUS_TEST_PACKAGE??'../dist/index.js');
const manifestModule=await import(new URL('./manifest.js',process.env.VELA_WALRUS_TEST_PACKAGE??new URL('../dist/index.js',import.meta.url)));
const hex=n=>'0x'+n.repeat(64);
const metadata={apiVersion:'1.0.0',relayerVersion:'0.1.6',minSupportedSdk:{typescript:'0.0.4'}};
async function signedRow(row,seal=false){
 assert.equal(row.headers['x-account-id'],hex('4'));assert.equal(row.headers['x-delegate-key'],undefined);
 if(!seal)assert.equal(row.headers['x-seal-session'],undefined);else assert.ok(row.headers['x-seal-session']);
 const message=`${row.headers['x-timestamp']}.${row.method}.${row.path}.${createHash('sha256').update(row.body).digest('hex')}.${row.headers['x-nonce']}.${row.headers['x-account-id']}`;
 assert.equal(await verifyAsync(Buffer.from(row.headers['x-signature'],'hex'),Buffer.from(message),Buffer.from(row.headers['x-public-key'],'hex')),true);
}
async function fixture(body){
  const requests=[],clients=[];let handler;
  const server=createServer(async(req,res)=>{
    let raw='';for await(const chunk of req)raw+=chunk;
    const row={method:req.method,path:req.url,body:raw,headers:req.headers};requests.push(row);
    const send=(status,value)=>{res.writeHead(status,{'content-type':'application/json'});res.end(JSON.stringify(value));};
    try{
      if(await handler?.(row,res,send))return;
      if(req.url==='/version'){send(200,metadata);return;}
      if(req.url==='/config'){send(200,{packageId:hex('1'),network:'testnet'});return;}
      if(req.url==='/rpc'){
        const rpc=JSON.parse(raw);assert.equal(rpc.method,'sui_getObject');
        send(200,{jsonrpc:'2.0',id:rpc.id,result:{data:{objectId:hex('4'),version:'1',digest:'synthetic',content:{dataType:'moveObject',type:hex('1')+'::account::MemWalAccount',hasPublicTransfer:false,fields:{owner:hex('5'),active:true,access_counter_version:'0'}}}}});return;
      }
      assert.equal(req.headers['x-account-id'],hex('4'));
      assert.equal(req.headers['x-delegate-key'],undefined);assert.equal(req.headers['x-seal-session'],undefined);
      const message=`${req.headers['x-timestamp']}.${req.method}.${req.url}.${createHash('sha256').update(raw).digest('hex')}.${req.headers['x-nonce']}.${req.headers['x-account-id']}`;
      assert.equal(await verifyAsync(Buffer.from(req.headers['x-signature'],'hex'),Buffer.from(message),Buffer.from(req.headers['x-public-key'],'hex')),true);
      if(req.url==='/api/stats'){assert.equal(JSON.parse(raw).namespace,'isolated');send(200,{owner:hex('5')});return;}
      if(req.url.startsWith('/v1/owners/')){
        assert.ok(req.url.startsWith('/v1/owners/'+hex('5')+'/namespaces'));
        const second=req.url.includes('updated_after=cursor1');send(200,{namespaces:[{id:second?'b':'a',name:second?'other':'isolated',memory_count:1,storage_used:90,updated_at:'2026-09-13T00:00:00Z'}],has_more:!second,next_cursor:second?'cursor2':'cursor1',snapshot_version:1});return;
      }
      send(404,{error:'unexpected fixture request'});
    }catch(error){send(500,{error:String(error)});}
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));const origin=`http://127.0.0.1:${server.address().port}`;
  const profile={version:1,id:'fixture',mode:'clientEncryption',serverURL:origin,network:'testnet',fullnodeURL:origin+'/rpc',packageID:hex('1'),sealPolicyPackageID:hex('1'),registryID:hex('3'),accountID:hex('4'),expectedOwner:hex('5'),namespace:'isolated',allowedOrigins:[origin],embedding:{endpoint:origin+'/embedding',model:'fixture-only',plaintextRecipientAcknowledged:true},walrusAggregatorURL:origin+'/aggregator',writeLimits:{maxOperations:1,maxPlaintextBytes:65536},allowLoopbackHTTP:true};
  const client=(config=profile,credentials={delegateKey:new Uint8Array(randomBytes(32))})=>{const api=new WalrusClient(config,credentials);clients.push(api);return api;};
  try{await body({profile,client,requests,setHandler:value=>handler=value});}
  finally{await Promise.all(clients.map(api=>api.close()));server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}
}

test('construction and preparation perform no network; recipients and unknown storage terms are explicit',()=>fixture(async({profile,client,requests})=>{
  const api=client();const action=api.prepareRemember('Synthetic record selected for review.');
  assert.deepEqual(action.plaintextRecipients,[profile.embedding.endpoint]);assert.equal(action.storageEpochs,null);assert.equal(action.monetaryQuote,null);assert.equal(requests.length,0);
  assert.equal(JSON.stringify(action).includes('delegateKey'),false);
  const restore=api.prepareRestoreIndexRelayer();assert.equal(restore.arguments.trustUpgrade,'relayer-decryption-and-embedding');assert.deepEqual(restore.plaintextRecipients,[profile.serverURL]);
}));

test('published analyze signs exact namespace, returns accepted jobs and cannot reuse approval',()=>fixture(async({profile,client,requests,setHandler})=>{
 assert.throws(()=>client().prepareAnalyze('Synthetic selected conversation.'),{code:'relayer_plaintext_mode_required'});
 setHandler((row,res,send)=>{if(row.path==='/config'){send(200,{packageId:hex('1'),network:'testnet',suiTransport:'jsonrpc',suiRpcUrl:profile.fullnodeURL});return true;}if(row.path==='/rpc'){const rpc=JSON.parse(row.body);if(rpc.method==='sui_multiGetObjects'){send(200,{jsonrpc:'2.0',id:rpc.id,result:[{data:{objectId:hex('1'),version:'1',digest:'synthetic-package',owner:'Immutable'}}]});return true;}}if(row.path==='/api/analyze'){const body=JSON.parse(row.body);assert.equal(body.text,'Synthetic selected conversation.');assert.equal(body.namespace,'isolated');assert.ok(row.headers['x-signature']);const seal=JSON.parse(Buffer.from(row.headers['x-seal-session'],'base64').toString());assert.equal(seal.packageId,hex('1'));assert.ok(seal.personalMessageSignature);assert.equal(row.headers['x-delegate-key'],undefined);send(202,{owner:hex('5'),status:'accepted',facts:['Synthetic fact'],fact_count:1,job_ids:['job-1']});return true;}});
 const api=client({...profile,mode:'relayerProcessing'}),preview=api.prepareAnalyze('Synthetic selected conversation.');
 assert.deepEqual(preview.plaintextRecipients,[profile.serverURL]);assert.equal(requests.length,0);
 const result=await api.execute(preview);assert.equal(result.state,'accepted');assert.deepEqual(result.jobIDs,['job-1']);assert.equal(result.durable,false);assert.equal(result.idempotencySupported,false);
 assert.throws(()=>api.execute(preview),{code:'review_mismatch'});assert.equal(requests.filter(row=>row.path==='/api/analyze').length,1);
}));

test('official installed SDK compatibility is unauthenticated and needs no existing account',()=>fixture(async({profile,requests})=>{
  const api=new WalrusClient(profile);try{const result=await api.compatibility();assert.equal(result.authenticated,false);assert.equal(result.metadata.apiVersion,'1.0.0');assert.throws(()=>api.namespaces(),error=>error.code==='credentials_required');assert.deepEqual(requests.map(row=>row.path),['/version']);}finally{await api.close();}
}));

test('owner metadata pages preserve tombstones and cursor boundaries without plaintext or SEAL',()=>fixture(async({profile,client,requests,setHandler})=>{
 setHandler(async(row,res,send)=>{if(!row.path.startsWith('/v1/owners/'+hex('5')+'/memories?'))return false;
  await signedRow(row);const continuation=row.path.includes('updated_after=opaque-v1');
  send(200,{snapshot_version:2,memories:continuation?[]:[{memory_id:'m1',namespace_id:'isolated',blob_id:'blob1',created_at:'2026-09-01T00:00:00Z',updated_at:'2026-09-02T00:00:00Z',size:1024,content:'FORBIDDEN_PLAINTEXT'}],deleted:continuation?[{memory_id:'m1',namespace_id:'isolated',deleted_at:'2026-09-03T00:00:00Z'}]:[],must_resync:continuation,has_more:!continuation,next_cursor:continuation?'opaque-v2':'opaque-v1'});return true;
 });
 const api=client(),first=await api.ownerMemories({limit:1});assert.equal(first.hasMore,true);assert.equal(first.scope,'owner');assert.equal(JSON.stringify(first).includes('FORBIDDEN'),false);
 const second=await api.ownerMemories({limit:1,cursor:first.nextCursor});assert.equal(second.memories.length,0);assert.equal(second.deleted.length,1);assert.equal(second.mustResync,true);assert.equal(second.hasMore,false);assert.ok(second.nextCursor);
 const before=requests.length;assert.throws(()=>client({...profile,accountID:hex('6')}).ownerMemories({cursor:first.nextCursor}),{code:'invalid_cursor'});assert.equal(requests.length,before);
}));

test('owner agents and namespace statistics use authenticated metadata without granting decrypt',()=>fixture(async({client,setHandler})=>{
 setHandler(async(row,res,send)=>{
  if(row.path.endsWith('/agents')){await signedRow(row);send(200,{snapshot_version:2,agents:[{label:'researcher',sui_address:hex('7'),private_key:'FORBIDDEN'}]});return true;}
  if(row.path==='/api/stats'){await signedRow(row);send(200,{owner:hex('5'),namespace:'isolated',memory_count:4,storage_bytes:3210});return true;}
 });
 const api=client(),agents=await api.ownerAgents();assert.equal(agents.agents[0].label,'researcher');assert.equal(JSON.stringify(agents).includes('FORBIDDEN'),false);assert.equal(agents.namespaceIsACL,false);
 const stats=await api.namespaceStats();assert.equal(stats.memoryCount,4);assert.equal(stats.storageBytes,3210);
}));

test('frozen forget deletes selected index only once and keeps Blob/restore meaning explicit',()=>fixture(async({client,requests,setHandler})=>{
 setHandler(async(row,res,send)=>{if(row.path==='/api/forget'){await signedRow(row);assert.deepEqual(JSON.parse(row.body),{namespace:'isolated'});send(200,{owner:hex('5'),namespace:'isolated',deleted:3});return true;}});
 const api=client(),preview=api.prepareForgetNamespace();assert.equal(requests.length,0);assert.deepEqual(preview.plaintextRecipients,[]);assert.equal(preview.arguments.blobsRetained,true);
 const altered=structuredClone(preview);altered.arguments.namespace='foreign';assert.throws(()=>api.execute(altered),{code:'review_mismatch'});assert.equal(requests.length,0);
 const result=await api.execute(preview);assert.equal(result.deletedIndexRows,3);assert.equal(result.blobsRetained,true);assert.equal(result.permanentDeletion,false);assert.equal(result.restoreRequiresSeparateAction,true);
 assert.throws(()=>api.execute(preview),{code:'review_mismatch'});assert.equal(requests.filter(row=>row.path==='/api/forget').length,1);
}));

test('published bulk SDK freezes every item and maps accepted jobs without claiming durability',()=>fixture(async({profile,client,requests,setHandler})=>{
 setHandler(async(row,res,send)=>{
  if(row.path==='/config'){send(200,{packageId:hex('1'),network:'testnet',suiTransport:'jsonrpc',suiRpcUrl:profile.fullnodeURL});return true;}
  if(row.path==='/rpc'){const rpc=JSON.parse(row.body);if(rpc.method==='sui_multiGetObjects'){send(200,{jsonrpc:'2.0',id:rpc.id,result:[{data:{objectId:hex('1'),version:'1',digest:'synthetic-package',owner:'Immutable'}}]});return true;}}
  if(row.path==='/api/remember/bulk'){await signedRow(row,true);assert.deepEqual(JSON.parse(row.body),{items:[{text:'first',namespace:'isolated'},{text:'second',namespace:'isolated'}]});send(202,{job_ids:['job1','job2'],total:2,status:'running'});return true;}
 });
 assert.throws(()=>client().prepareRememberBulk(['first']),{code:'relayer_plaintext_mode_required'});
 const limited=client({...profile,mode:'relayerProcessing'});assert.throws(()=>limited.execute(limited.prepareRememberBulk(['first','second'])),{code:'write_limit'});assert.equal(requests.length,0);
 const api=client({...profile,mode:'relayerProcessing',writeLimits:{maxOperations:2,maxPlaintextBytes:100}}),preview=api.prepareRememberBulk(['first','second']);
 const result=await api.execute(preview);assert.deepEqual(result.items.map(item=>item.jobID),['job1','job2']);assert.equal(result.durable,false);assert.equal(result.idempotencySupported,false);
 assert.throws(()=>api.execute(preview),{code:'review_mismatch'});
}));

test('reviewed bulk input remains frozen when the caller mutates its original array',()=>fixture(async({profile,client,setHandler,requests})=>{
 setHandler(async(row,res,send)=>{
  if(row.path==='/config'){send(200,{packageId:hex('1'),network:'testnet',suiTransport:'jsonrpc',suiRpcUrl:profile.fullnodeURL});return true;}
  if(row.path==='/rpc'){const rpc=JSON.parse(row.body);if(rpc.method==='sui_multiGetObjects'){send(200,{jsonrpc:'2.0',id:rpc.id,result:[{data:{objectId:hex('1'),version:'1',digest:'synthetic-package',owner:'Immutable'}}]});return true;}}
  if(row.path==='/api/remember/bulk'){await signedRow(row,true);const items=JSON.parse(row.body).items;send(202,{job_ids:items.map((_,index)=>`job${index+1}`),total:items.length,status:'running'});return true;}
 });
 const api=client({...profile,mode:'relayerProcessing',writeLimits:{maxOperations:2,maxPlaintextBytes:100}});
 const originals=['selected first','selected second'],preview=api.prepareRememberBulk(originals);
 originals[0]='unreviewed replacement';originals.pop();
 assert.deepEqual(preview.arguments.texts,['selected first','selected second']);
 await api.execute(preview);
 const posted=requests.filter(row=>row.path==='/api/remember/bulk');assert.equal(posted.length,1);
 assert.deepEqual(JSON.parse(posted[0].body),{items:[{text:'selected first',namespace:'isolated'},{text:'selected second',namespace:'isolated'}]});
}));

test('bulk status restores requested order and separates failed missing and incomplete polling',()=>fixture(async({client,setHandler,requests})=>{
 setHandler(async(row,res,send)=>{if(row.path==='/api/remember/bulk/status'){await signedRow(row);send(200,{results:[{job_id:'job3',status:'not_found'},{job_id:'job2',status:'failed',error:'FORBIDDEN_REMOTE_DIAGNOSTIC'},{job_id:'job1',status:'done',blob_id:'stored-blob'}]});return true;}});
 const api=client(),result=await api.rememberBulkStatus(['job1','job2','job3']);assert.deepEqual(result.results.map(row=>row.jobID),['job1','job2','job3']);assert.equal(result.succeeded,1);assert.equal(result.failed,1);assert.equal(result.missing,1);assert.equal(JSON.stringify(result).includes('FORBIDDEN'),false);
 // Allow authenticated read latency under concurrent CI load; one deliberate deadline wait is enough.
 const waited=await api.waitForRememberJobs(['job1','job2','job3'],{maxWaitMs:3000,pollIntervalMs:3000});assert.equal(waited.waitState,'timeout');assert.equal(waited.writesCancelled,false);assert.equal(waited.missing,1);
 assert.ok(requests.filter(row=>row.path==='/api/remember/bulk/status').length<=3);
}));

test('metadata rejects unknown version, missing counters and malformed job correlation',()=>fixture(async({client,setHandler})=>{
 setHandler((row,res,send)=>{
  if(row.path.includes('/memories?')){send(200,{snapshot_version:999,memories:[],deleted:[],must_resync:false,has_more:false,next_cursor:null});return true;}
  if(row.path==='/api/stats'){send(200,{owner:hex('5'),namespace:'isolated',memory_count:4});return true;}
  if(row.path==='/api/remember/bulk/status'){send(200,{results:[{job_id:'foreign',status:'done',blob_id:'blob'}]});return true;}
 });
 await assert.rejects(client().ownerMemories(),{code:'unsupported_metadata_shape'});await assert.rejects(client().namespaceStats(),{code:'protocol_error'});await assert.rejects(client().rememberBulkStatus(['job']),{code:'protocol_error'});
}));

test('status can resume after reopen without decrypt credentials and read rate limits never retry',()=>fixture(async({client,setHandler,requests})=>{
 let rateLimited=false;
 setHandler(async(row,res,send)=>{if(row.path==='/api/remember/job1'){
  await signedRow(row);if(rateLimited){send(429,{error:'FORBIDDEN_REMOTE_BODY'});return true;}
  send(200,{job_id:'job1',status:'done',blob_id:'stored-blob',owner:hex('5'),namespace:'isolated'});return true;
 }});
 const initial=client();await initial.close();const reopened=client();const result=await reopened.rememberStatus('job1');assert.equal(result.status,'done');assert.equal(result.blobID,'stored-blob');assert.equal(result.scope,'owner');
 rateLimited=true;const before=requests.length;await assert.rejects(reopened.rememberStatus('job1'),error=>error.code==='rate_limited'&&error.httpStatus===429&&!error.effectsUnknown&&!String(error).includes('FORBIDDEN'));
 assert.equal(requests.slice(before).filter(row=>row.path==='/api/remember/job1').length,1);
}));

test('real official SDK signs owner scoped metadata pages with bound body path nonce and account',()=>fixture(async({client,requests})=>{
  const api=client();const connected=await api.connect();assert.equal(connected.authenticated,true);assert.equal(connected.namespaceIsACL,false);
  const first=await api.namespaces({limit:1});assert.equal(first.page.has_more,true);
  const second=await api.namespaces({limit:1,cursor:first.page.next_cursor});assert.equal(second.page.has_more,false);assert.equal(second.page.namespaces[0].id,'b');
  const signed=requests.filter(row=>row.headers['x-nonce']);assert.equal(new Set(signed.map(row=>row.headers['x-nonce'])).size,signed.length);
  await api.close();const reopened=client();assert.equal((await reopened.namespaces()).owner,hex('5'));
}));

test('wrong owner and inactive accounts cannot issue protected relayer requests',()=>fixture(async({client,profile,requests,setHandler})=>{
  const wrong=client({...profile,expectedOwner:hex('6')});await assert.rejects(wrong.connect(),error=>error.code==='owner_mismatch');assert.deepEqual(requests.map(row=>row.path),['/config','/rpc']);
  setHandler((row,res,send)=>{if(row.path==='/rpc'){const rpc=JSON.parse(row.body);send(200,{jsonrpc:'2.0',id:rpc.id,result:{data:{objectId:hex('4'),content:{dataType:'moveObject',type:hex('1')+'::account::MemWalAccount',fields:{owner:hex('5'),active:false}}}}});return true;}});
  await assert.rejects(client().connect(),error=>error.code==='account_inactive');
}));

test('401 is typed and never includes raw secret response bodies',()=>fixture(async({client,setHandler})=>{
  setHandler((row,res,send)=>{if(row.path==='/api/stats'){send(401,{error:'SECRET_RAW_RESPONSE'});return true;}});
  await assert.rejects(client().connect(),error=>error instanceof WalrusError&&error.code==='http_error'&&error.httpStatus===401&&!error.effectsUnknown&&!String(error).includes('SECRET'));
}));

for(const scenario of ['incompatible','overflow','redirect'])test(scenario+' response is rejected without following another destination',()=>fixture(async({client,setHandler,requests})=>{
  setHandler((row,res,send)=>{if(row.path!=='/version')return false;
    if(scenario==='incompatible')send(200,{...metadata,apiVersion:'2.0.0'});
    else if(scenario==='overflow'){res.writeHead(200);res.end('X'.repeat(2*1024*1024+1));}
    else{res.writeHead(302,{location:'http://127.0.0.1:1/forbidden'});res.end();}return true;
  });
  await assert.rejects(client().compatibility(),error=>error.code===({incompatible:'incompatible_relayer',overflow:'response_limit',redirect:'redirect_rejected'}[scenario]));
  assert.equal(requests.length,1);
}));

test('timeout terminates worker and consumes a started write approval without pretending rollback',()=>fixture(async({client,setHandler})=>{
  const api=client();await api.compatibility();setHandler(row=>row.path==='/rpc');
  const action=api.prepareRemember('Synthetic uncertain record');
  await assert.rejects(api.execute(action,{timeoutMs:100}),error=>error.code==='timeout'&&error.effectsUnknown&&typeof error.requestID==='string');
  await api.close();assert.throws(()=>api.execute(action),error=>['review_mismatch','closed'].includes(error.code));
}));

test('frozen action rejects changed arguments and write limits before network',()=>fixture(async({client,profile,requests})=>{
  const api=client();const action=api.prepareRemember('Selected original');const changed=structuredClone(action);changed.arguments.text='Changed';assert.throws(()=>api.execute(changed),error=>error.code==='review_mismatch');
  const capped=client({...profile,writeLimits:{maxOperations:0,maxPlaintextBytes:0}});assert.throws(()=>capped.execute(capped.prepareRemember('Record')),error=>error.code==='write_limit');assert.equal(requests.length,0);
}));

test('credentials and egress configuration reject ambiguous or unsafe inputs',()=>fixture(async({profile})=>{
  assert.throws(()=>validateProfile({...profile,serverURL:'http://remote.example'}),WalrusError);
  assert.throws(()=>validateProfile({...profile,unknown:true}),WalrusError);
  assert.throws(()=>validateProfile({...profile,embedding:undefined}),WalrusError);
  assert.throws(()=>new WalrusClient(profile,{delegateKey:new Uint8Array(31)}),WalrusError);
}));


test('public deployment metadata is distinct from auth and profile changes stop protected operations',()=>fixture(async({client,setHandler,requests})=>{
  const api=client();assert.equal((await api.deployment()).authenticated,false);
  setHandler((row,res,send)=>{if(row.path==='/config'){send(200,{packageId:hex('6'),network:'testnet'});return true;}});
  await assert.rejects(api.connect(),error=>error.code==='deployment_mismatch');assert.ok(requests.every(row=>row.path==='/config'));
}));

test('a relayer owner substitution is rejected before signing metadata for a different owner',()=>fixture(async({client,setHandler,requests})=>{
  setHandler((row,res,send)=>{if(row.path==='/api/stats'){send(200,{owner:hex('6')});return true;}});
  await assert.rejects(client().connect(),error=>error.code==='owner_mismatch');assert.ok(requests.every(row=>!row.path.startsWith('/v1/owners/')));
}));


test('SDK refetch cannot silently change the frozen SEAL package after initial preflight',()=>fixture(async({client,profile,setHandler,requests})=>{
  let configs=0;setHandler((row,res,send)=>{if(row.path==='/config'&&++configs>1){send(200,{packageId:hex('6'),network:'testnet'});return true;}});
  const api=client({...profile,mode:'relayerProcessing'});
  await assert.rejects(api.execute(api.prepareRemember('Synthetic reviewed text')),error=>error.code==='deployment_mismatch'&&error.effectsUnknown);
  assert.equal(configs,2);assert.ok(requests.every(row=>row.path!=='/api/remember'));
}));


test('official owner builders capture exact account commands without signing or network',()=>fixture(async({profile,requests})=>{
  const {captureOwnerTransaction}=await import(new URL('./owner.js',process.env.VELA_WALRUS_TEST_PACKAGE??new URL('../dist/index.js',import.meta.url)));
  for(const input of [{operation:'createAccount',maxGasBudgetMIST:'1000000'},{operation:'addDelegate',publicKey:'11'.repeat(32),label:'Synthetic delegate',maxGasBudgetMIST:'1000000'},{operation:'removeDelegate',publicKey:'11'.repeat(32),maxGasBudgetMIST:'1000000'}]){
    const transaction=await captureOwnerTransaction(profile,input,{});const data=transaction.getData();assert.equal(data.commands.length,1);
    const call=data.commands[0].MoveCall;assert.equal(call.package,profile.sealPolicyPackageID);assert.equal(call.module,'account');assert.equal(call.function,({createAccount:'create_account',addDelegate:'add_delegate_key',removeDelegate:'remove_delegate_key'})[input.operation]);
    assert.equal(data.gasData.budget,null);assert.equal(data.gasData.payment,null);
  }
  assert.equal(requests.length,0);
}));

test('serialized owner signature verifies exact bytes owner gas cap and digest with newly generated test keys',()=>fixture(async({profile,requests})=>{
  const {verifyOwnerSignature}=await import(new URL('./owner.js',process.env.VELA_WALRUS_TEST_PACKAGE??new URL('../dist/index.js',import.meta.url)));
  const {Transaction}=await import('@mysten/sui/transactions');const {Ed25519Keypair}=await import('@mysten/sui/keypairs/ed25519');
  const signer=Ed25519Keypair.generate(),owner=signer.toSuiAddress();const selected={...profile,expectedOwner:owner};
  const transaction=new Transaction();transaction.setSender(owner);transaction.setGasBudget('1000000');transaction.setGasPrice(1);transaction.setGasPayment([{objectId:hex('9'),version:'1',digest:'1'.repeat(32)}]);transaction.setExpiration({Epoch:'99'});
  transaction.moveCall({target:profile.packageID+'::account::create_account',arguments:[transaction.sharedObjectRef({objectId:profile.registryID,initialSharedVersion:'1',mutable:true}),transaction.sharedObjectRef({objectId:'0x6',initialSharedVersion:'1',mutable:false})]});
  const bytes=await transaction.build();const {signature}=await signer.signTransaction(bytes);
  const prepared={operation:'createAccount',input:{operation:'createAccount',maxGasBudgetMIST:'1000000'},transactionBytes:Buffer.from(bytes).toString('base64'),digest:await transaction.getDigest(),owner,network:'testnet',maxGasBudgetMIST:'1000000',expiresAfterEpoch:'99'};
  assert.deepEqual(Buffer.from(await verifyOwnerSignature(selected,prepared,signature)),Buffer.from(bytes));
  await assert.rejects(verifyOwnerSignature(selected,{...prepared,maxGasBudgetMIST:'2000000'},signature));
  const other=await Ed25519Keypair.generate().signTransaction(bytes);await assert.rejects(verifyOwnerSignature(selected,prepared,other.signature));assert.equal(requests.length,0);
}));

test('owner preparation requires explicit positive gas cap and a real matching registry before build',()=>fixture(async({profile,requests})=>{
  const api=new WalrusClient(profile);try{
    await assert.rejects(api.prepareOwnerAction({operation:'createAccount',maxGasBudgetMIST:'0'}),error=>error.code==='invalid_input');
    await assert.rejects(api.prepareOwnerAction({operation:'createAccount',maxGasBudgetMIST:'1000000'}),error=>error.code==='registry_mismatch');
    assert.ok(requests.every(row=>['/config','/rpc'].includes(row.path)));
  }finally{await api.close();}
}));


test('official Manual swallowed decrypt errors become explicit partial results without raw logs',()=>fixture(async({client,setHandler})=>{
  const {Ed25519Keypair}=await import('@mysten/sui/keypairs/ed25519');
  setHandler((row,res,send)=>{
    if(row.path==='/embedding/embeddings'){send(200,{data:[{embedding:[1,0]}]});return true;}
    if(row.path==='/api/recall/manual'){send(200,{results:[{blob_id:'syntheticCiphertext',distance:0.1}],total:1});return true;}
    if(row.path==='/aggregator/v1/blobs/syntheticCiphertext'){res.writeHead(200);res.end('INVALID_SYNTHETIC_CIPHERTEXT');return true;}
  });
  const api=client(undefined,{delegateKey:new Uint8Array(randomBytes(32)),suiPrivateKey:Ed25519Keypair.generate().getSecretKey(),embeddingApiKey:'synthetic-test-key'});
  const result=await api.recall('Synthetic query');assert.equal(result.status,'partial');assert.ok(result.suppressedDiagnosticCount>0);assert.deepEqual(result.memory.results,[]);
  assert.equal(JSON.stringify(result).includes('INVALID_SYNTHETIC_CIPHERTEXT'),false);
}));

const manifestSource=()=>({network:'testnet',packageID:hex('1'),accountID:hex('4'),owner:hex('5'),namespace:'isolated'});
const manifestEntry=()=>({blobID:Buffer.alloc(32,3).toString('base64url'),encoding:'utf8-memory-v1',title:'Original remote record',plaintextSHA256:null,plaintextBytes:null});
test('manifest supports original raw text and Vela archives with strict checksum/version/identity validation',()=>{
  const manifest=createMemoryManifest(manifestSource(),[manifestEntry()]);assert.equal(validateMemoryManifest(manifest).sha256,manifest.sha256);
  for(const changed of [{...manifest,version:2},{...manifest,extra:true},{...manifest,entries:[{...manifest.entries[0],title:'Changed'}]}])assert.throws(()=>validateMemoryManifest(changed),WalrusError);
  assert.throws(()=>createMemoryManifest(manifestSource(),[manifestEntry(),manifestEntry()]),WalrusError);
  assert.throws(()=>createMemoryManifest(manifestSource(),[{...manifestEntry(),blobID:'A'.repeat(42)+'B'}]),WalrusError);
  assert.throws(()=>createMemoryManifest(manifestSource(),[{...manifestEntry(),plaintextSHA256:'a'.repeat(64),plaintextBytes:null}]),WalrusError);
  assert.throws(()=>createMemoryManifest(manifestSource(),Array.from({length:1001},manifestEntry)),WalrusError);
});
test('manifest cursors bind snapshot and explicit scope; no cross-owner or namespace recovery',()=>{
  const manifest=createMemoryManifest(manifestSource(),[manifestEntry()]);
  assert.deepEqual(manifestModule.manifestPage(manifest,{limit:1}),{start:0,end:1});
  assert.deepEqual(manifestModule.manifestPage(manifest,{cursor:manifest.sha256+':1'}),{start:1,end:1});
  for(const cursor of ['bad:0',manifest.sha256+':-1',manifest.sha256+':2',manifest.sha256+':true'])assert.throws(()=>manifestModule.manifestPage(manifest,{cursor}),WalrusError);
  assert.throws(()=>manifestModule.manifestMatchesProfile(manifest,{...manifestSource(),expectedOwner:hex('6')}),WalrusError);
});
test('SEAL identity matches exact namespace owner and a nonfuture rotation counter',()=>{
  const manifest=createMemoryManifest(manifestSource(),[manifestEntry()]);const counter=Buffer.alloc(8);counter.writeBigUInt64LE(2n);
  const id=Buffer.concat([Buffer.from('isolated'),Buffer.from('5'.repeat(64),'hex'),counter]).toString('hex');
  manifestModule.validateSealIdentity(id,manifest,'3');
  for(const [changed,version] of [[id,'1'],[id.slice(2),'3'],[id+'00','3'],[id.replace(/^69/,'70'),'3']])assert.throws(()=>manifestModule.validateSealIdentity(changed,manifest,version),error=>error.code==='seal_identity_mismatch');
});
test('recovered raw UTF8 records distinguish expected checksum verification from a newly computed digest',()=>{
  const data=Buffer.from('MemWal original 中文 café'),entry=manifestEntry();
  const unpinned=manifestModule.validateRecoveredPlaintext(entry,data);assert.equal(unpinned.expectedChecksumVerified,false);assert.equal(unpinned.text,data.toString());
  const pinned={...entry,plaintextSHA256:unpinned.sha256,plaintextBytes:data.length};assert.equal(manifestModule.validateRecoveredPlaintext(pinned,data).expectedChecksumVerified,true);
  assert.throws(()=>manifestModule.validateRecoveredPlaintext(pinned,Buffer.from('changed')),error=>error.code==='plaintext_checksum_mismatch');
  assert.throws(()=>manifestModule.validateRecoveredPlaintext(entry,Buffer.from([0xc0,0xaf])),error=>error.code==='invalid_utf8');
  assert.throws(()=>manifestModule.validateRecoveredPlaintext({...entry,encoding:'vela-memory-archive-v1'},data),error=>error.code==='invalid_archive');
  const archive=Buffer.from(JSON.stringify({format:'vela.memory-archive',version:1}));assert.equal(manifestModule.validateRecoveredPlaintext({...entry,encoding:'vela-memory-archive-v1'},archive).text,archive.toString());
});
test('client-side manifest recovery uses chain/aggregator only and surfaces bad ciphertext per item',()=>fixture(async({client,profile,requests,setHandler})=>{
  const {Ed25519Keypair}=await import('@mysten/sui/keypairs/ed25519');const signer=Ed25519Keypair.generate();
  const selected={...profile,expectedOwner:signer.toSuiAddress(),sealServerConfigs:[{objectID:hex('7'),weight:1}]};
  const manifest=createMemoryManifest({...manifestSource(),owner:selected.expectedOwner},[manifestEntry()]);
  setHandler((row,res,send)=>{
    if(row.path==='/rpc'){
      const rpc=JSON.parse(row.body),registry=rpc.params[0]===selected.registryID;
      send(200,{jsonrpc:'2.0',id:rpc.id,result:{data:{content:{dataType:'moveObject',type:hex('1')+'::account::'+(registry?'AccountRegistry':'MemWalAccount'),fields:registry?{}:{owner:selected.expectedOwner,active:true,access_counter_version:'0',delegate_keys:[]}}}}});return true;
    }
    if(row.path.startsWith('/aggregator/v1/blobs/')){res.writeHead(200);res.end('bad-ciphertext-synthetic');return true;}
  });
  const api=client(selected,{delegateKey:new Uint8Array(randomBytes(32)),suiPrivateKey:signer.getSecretKey()});
  const result=await api.restoreManifestPage(manifest,{limit:1});
  assert.deepEqual(result.recovered,[]);assert.equal(result.failures[0].code,'invalid_ciphertext');assert.equal(result.failures[0].retryable,false);
  assert.equal(result.relayerUsed,false);assert.equal(result.embeddingUsed,false);assert.equal(result.pageAllRecovered,false);assert.equal(result.manifestTraversalComplete,true);assert.equal(result.coverage.accountInventoryComplete,'unknown');
  assert.deepEqual(requests.map(row=>row.path),['/rpc','/rpc','/aggregator/v1/blobs/'+manifest.entries[0].blobID]);
}));
test('manifest restoration validates explicit configuration and scope before touching network',()=>fixture(async({profile,requests})=>{
  const manifest=createMemoryManifest(manifestSource(),[manifestEntry()]),api=new WalrusClient(profile);
  try{assert.throws(()=>api.restoreManifestPage(manifest),error=>error.code==='credentials_required');
    const other=createMemoryManifest({...manifestSource(),namespace:'other'},[manifestEntry()]);assert.throws(()=>api.restoreManifestPage(other),error=>error.code==='manifest_scope_mismatch');assert.equal(requests.length,0);
  }finally{await api.close();}
}));
