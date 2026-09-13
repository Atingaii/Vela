import { parentPort, workerData } from 'node:worker_threads';
import { randomBytes } from 'node:crypto';
import { MemWal } from '@mysten-incubation/memwal';
import { MemWalManual } from '@mysten-incubation/memwal/manual';
import {buildOwnerTransaction,verifyOwnerSignature,type OwnerActionInput,type OwnerTransaction} from './owner.js';
import {WalrusError,type ObjectValue,type RemoteCredentials,type RemoteProfile} from './index.js';
import {restoreManifestPage} from './manifest-reader.js';
import {ownerMemories,ownerAgents,namespaceStats,forgetNamespace,bulkStatus,jobIDs,signedMetadata} from './metadata.js';

const {profile,credentials}=workerData as {profile:RemoteProfile;credentials?:RemoteCredentials};
const nativeFetch=globalThis.fetch;
const FRAME_LIMIT=2*1024*1024;
let enforceProfile=false;
let suppressedDiagnostics=0;
// The official Manual SDK logs some failures and then returns an empty result.
// Record a count without formatting/retaining any raw secret-bearing arguments.
const diagnostic=()=>{if(++suppressedDiagnostics>1024)throw new BoundaryError('output_limit');};
console.error=diagnostic;console.warn=diagnostic;
class BoundaryError extends Error { constructor(readonly code:string){super(code);} }
// This isolated worker installs an egress/body guard around the public fetch API.
// It never changes SDK private methods or the caller's global fetch implementation.
globalThis.fetch=async(input,init)=>{
  const request=new Request(input,init),url=new URL(request.url);
  if(!profile.allowedOrigins.includes(url.origin)||url.username||url.password)throw new BoundaryError('egress_not_allowed');
  if(request.body){const data=await request.clone().arrayBuffer();if(data.byteLength>FRAME_LIMIT)throw new BoundaryError('request_limit');}
  const response=await nativeFetch(request,{redirect:'manual'});
  if(response.status>=300&&response.status<400){await response.body?.cancel();throw new BoundaryError('redirect_rejected');}
  const reader=response.body?.getReader();const chunks:Uint8Array[]=[];let bytes=0;
  if(reader)while(true){const next=await reader.read();if(next.done)break;bytes+=next.value.byteLength;if(bytes>FRAME_LIMIT){await reader.cancel();throw new BoundaryError('response_limit');}chunks.push(next.value);}
  const data=new Uint8Array(bytes);let offset=0;for(const chunk of chunks){data.set(chunk,offset);offset+=chunk.length;}
  if(enforceProfile&&url.href===profile.serverURL+'/config'&&response.ok){
    let config:ObjectValue;try{config=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(data));}catch{throw new BoundaryError('protocol_error');}
    if(config.packageId!==profile.packageID||config.network!==profile.network)throw new BoundaryError('deployment_mismatch');
  }
  if(url.href===profile.serverURL+'/api/stats'&&response.ok){
    let stats:ObjectValue;try{stats=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(data));}catch{throw new BoundaryError('protocol_error');}
    if(stats.owner!==profile.expectedOwner)throw new BoundaryError('owner_mismatch');
  }
  return new Response([204,205,304].includes(response.status)?null:data,{status:response.status,statusText:response.statusText,headers:response.headers});
};
const key=credentials?.delegateKey??new Uint8Array(randomBytes(32));
const sdk=MemWal.create({key,accountId:profile.accountID,serverUrl:profile.serverURL,namespace:profile.namespace});
let manual:MemWalManual|undefined;
let suiClient:any;
async function chainClient():Promise<any>{
  if(!suiClient){
    const legacy=await import('@mysten/sui/client') as any;
    if(typeof legacy.SuiClient==='function')suiClient=new legacy.SuiClient({url:profile.fullnodeURL});
    else {const {SuiJsonRpcClient}=await import('@mysten/sui/jsonRpc');suiClient=new SuiJsonRpcClient({url:profile.fullnodeURL,network:profile.network});}
  }
  return suiClient;
}
async function deployment():Promise<ObjectValue>{
  const response=await fetch(profile.serverURL+'/config');
  if(!response.ok)throw new BoundaryError('deployment_unavailable');
  const raw=object(await response.json());
  if(typeof raw.packageId!=='string'||typeof raw.network!=='string')throw new BoundaryError('protocol_error');
  return Object.fromEntries(['packageId','network','suiRpcUrl','suiGrpcUrl','suiTransport','sealPolicyPackageId','registryId','walrusAggregatorUrl'].filter(key=>typeof raw[key]==='string').map(key=>[key,raw[key]]));
}
async function verifyDeployment():Promise<void>{
  const config=await deployment();
  if(config.packageId!==profile.packageID||config.network!==profile.network)throw new BoundaryError('deployment_mismatch');
}
async function verifyOwner():Promise<void>{
  const client=await chainClient();
  const result=await client.getObject({id:profile.accountID,options:{showContent:true}});
  const content=result?.data?.content;
  if(content?.dataType!=='moveObject'||content.fields?.owner!==profile.expectedOwner||content.type!==`${profile.packageID}::account::MemWalAccount`)throw new BoundaryError('owner_mismatch');
  // A new read occurs for every protected operation; no stale owner/active cache here.
  if(content.fields?.active!==true)throw new BoundaryError('account_inactive');
}
async function verifyRegistry():Promise<void>{
  const result=await(await chainClient()).getObject({id:profile.registryID,options:{showContent:true}});
  if(result?.data?.content?.dataType!=='moveObject'||result.data.content.type!==`${profile.packageID}::account::AccountRegistry`)throw new BoundaryError('registry_mismatch');
}
function transactionResult(value:any,expectedDigest:string):ObjectValue{
  if(value?.digest!==expectedDigest)throw new BoundaryError('transaction_mismatch');
  const status=value.effects?.status?.status;
  const gas=value.effects?.gasUsed;
  const gasUsed=gas&&['computationCost','storageCost','storageRebate'].every(key=>typeof gas[key]==='string'&&/^\d+$/.test(gas[key]))?Object.fromEntries(['computationCost','storageCost','storageRebate'].map(key=>[key,gas[key]])):null;
  const createdAccounts=Array.isArray(value.objectChanges)?value.objectChanges.filter((change:any)=>change.type==='created'&&change.objectType===`${profile.packageID}::account::MemWalAccount`&&typeof change.objectId==='string').map((change:any)=>change.objectId):null;
  return {digest:value.digest,createdAccountIDs:createdAccounts,state:status==='success'?'succeeded':status==='failure'?'failed':'submitted',gasUsed,...(status==='failure'?{errorCode:'chain_execution_failed'}:{})};
}
async function manualClient():Promise<MemWalManual>{
  if(!credentials?.suiPrivateKey||!credentials.embeddingApiKey||!profile.embedding||!profile.walrusAggregatorURL)throw new BoundaryError('credentials_required');
  if(!manual)manual=MemWalManual.create({key:new Uint8Array(key),serverUrl:profile.serverURL,namespace:profile.namespace,
    accountId:profile.accountID,packageId:profile.packageID,sealPolicyPackageId:profile.sealPolicyPackageID,registryId:profile.registryID,
    suiNetwork:profile.network,suiClient:await chainClient(),suiPrivateKey:credentials.suiPrivateKey,
    embeddingApiKey:credentials.embeddingApiKey,embeddingApiBase:profile.embedding.endpoint,embeddingModel:profile.embedding.model,
    walrusAggregatorUrl:profile.walrusAggregatorURL});
  return manual;
}
function object(value:unknown):ObjectValue{if(!value||typeof value!=='object'||Array.isArray(value))throw new BoundaryError('protocol_error');return value as ObjectValue;}
function scoped(value:ObjectValue):void{if(value.owner!==profile.expectedOwner||value.namespace!==profile.namespace)throw new BoundaryError('scope_mismatch');}
async function run(method:string,params:ObjectValue):Promise<ObjectValue>{
  if(method==='compatibility')return {metadata:await sdk.compatibility(),authenticated:false,network:profile.network};
  if(method==='deployment')return {configuration:await deployment(),authenticated:false};
  if(method==='restoreManifestPage'){
    if(!credentials)throw new BoundaryError('credentials_required');
    return restoreManifestPage(profile,credentials,params,await chainClient());
  }
  if(['ownerPrepare','ownerTransaction','ownerStatus'].includes(method)){
    enforceProfile=true;await verifyDeployment();
    const client=await chainClient();
    if(method==='ownerStatus')return transactionResult(await client.getTransactionBlock({digest:params.digest as string,options:{showEffects:true,showObjectChanges:true}}),params.digest as string);
    const input=params.input as OwnerActionInput;
    if(!input||!['createAccount','addDelegate','removeDelegate'].includes(input.operation))throw new BoundaryError('invalid_input');
    await verifyRegistry();if(input.operation!=='createAccount')await verifyOwner();
    if(method==='ownerPrepare')return {...await buildOwnerTransaction(profile,input,client)};
    const prepared=params as unknown as OwnerTransaction;
    let bytes:Uint8Array;try{bytes=await verifyOwnerSignature(profile,prepared,params.signature as string);}catch{throw new BoundaryError('invalid_owner_signature');}
    return transactionResult(await client.executeTransactionBlock({transactionBlock:bytes,signature:params.signature as string,options:{showEffects:true,showObjectChanges:true}}),prepared.digest);
  }
  if(!credentials)throw new BoundaryError('credentials_required');
  enforceProfile=true;await verifyDeployment();await verifyOwner();
  if(method==='connect'){
    await sdk.listNamespaces({limit:1});
    return {authenticated:true,owner:profile.expectedOwner,accountID:profile.accountID,namespace:profile.namespace,namespaceIsACL:false,ownerEvidence:'selected Sui fullnode object plus signed relayer metadata read'};
  }
  if(method==='namespaces')return {page:await sdk.listNamespaces(params as {cursor?:string;limit?:number}),owner:profile.expectedOwner,namespaceIsACL:false};
  if(['ownerMemories','ownerAgents','namespaceStats','rememberBulkStatus','rememberStatus','forgetNamespace'].includes(method)){
    await sdk.compatibility();
    if(method==='ownerMemories')return ownerMemories(profile,key,params as {cursor?:string;limit?:number});
    if(method==='ownerAgents')return ownerAgents(profile,key);
    if(method==='namespaceStats')return namespaceStats(profile,key);
    if(method==='rememberBulkStatus')return bulkStatus(profile,key,jobIDs(params.jobIDs));
    if(method==='forgetNamespace'){
      if(params.namespace!==profile.namespace||params.indexOnly!==true||params.blobsRetained!==true)throw new BoundaryError('review_mismatch');
      return forgetNamespace(profile,key);
    }
    const ids=jobIDs([params.jobID]);const result=await signedMetadata(profile,key,'GET','/api/remember/'+ids[0]);
    if(result.job_id!==ids[0]||!['pending','running','uploaded','done','failed'].includes(result.status as string))throw new BoundaryError('protocol_error');
    if(result.owner!==undefined&&result.owner!==profile.expectedOwner)throw new BoundaryError('scope_mismatch');
    if(result.status==='done'&&(typeof result.blob_id!=='string'||!result.blob_id||result.blob_id.length>300))throw new BoundaryError('protocol_error');
    return {jobID:result.job_id,status:result.status,scope:'owner',...(typeof result.namespace==='string'?{namespace:result.namespace}:{}),...(typeof result.blob_id==='string'?{blobID:result.blob_id}:{}),...(result.status==='failed'?{errorCode:'remote_job_failed'}:{})};
  }
  if(method==='rememberBulk'){
    if(profile.mode!=='relayerProcessing'||!Array.isArray(params.texts))throw new BoundaryError('invalid_input');
    const result=await sdk.rememberBulkAsync((params.texts as string[]).map(text=>({text,namespace:profile.namespace})));
    const ids=jobIDs(result.job_ids);if(ids.length!==params.texts.length||result.total!==ids.length)throw new BoundaryError('protocol_error');
    return {state:'accepted',owner:profile.expectedOwner,namespace:profile.namespace,jobIDs:ids,items:ids.map((jobID,index)=>({index,jobID,namespace:profile.namespace})),total:ids.length,durable:false,idempotencySupported:false};
  }
  if(method==='analyze'){
    if(profile.mode!=='relayerProcessing')throw new BoundaryError('relayer_plaintext_mode_required');
    const result=await sdk.analyze(params.text as string,{namespace:profile.namespace});
    if(result.owner!==profile.expectedOwner||!Array.isArray(result.job_ids)||!Array.isArray(result.facts)||result.facts.length>100||result.fact_count!==result.facts.length)throw new BoundaryError('protocol_error');
    return {state:'accepted',jobIDs:result.job_ids,facts:result.facts,factCount:result.fact_count,status:result.status,owner:result.owner,namespace:profile.namespace,mode:profile.mode,durable:false,idempotencySupported:false};
  }
  if(method==='remember'){
    if(profile.mode==='clientEncryption'){
      const result=object(await(await manualClient()).rememberManual(params.text as string,profile.namespace));scoped(result);
      if(typeof result.blob_id!=='string'||!result.blob_id)throw new BoundaryError('protocol_error');
      return {state:'stored',id:result.id,blobID:result.blob_id,owner:result.owner,namespace:result.namespace,mode:profile.mode,storageEpochs:null,monetaryQuote:null};
    }
    const result=await sdk.rememberAsync(params.text as string,profile.namespace,{idempotencyKey:params.operationID as string});
    return {state:'accepted',jobID:result.job_id,status:result.status,owner:profile.expectedOwner,namespace:profile.namespace,mode:profile.mode,storageEpochs:null,monetaryQuote:null};
  }
  if(method==='recall'){
    const before=suppressedDiagnostics;
    const result=profile.mode==='clientEncryption'?await(await manualClient()).recallManual(params.query as string,params.limit as number,profile.namespace):await sdk.recall({query:params.query as string,namespace:profile.namespace,limit:params.limit as number});
    return {memory:result,owner:profile.expectedOwner,namespace:profile.namespace,mode:profile.mode,namespaceIsACL:false,status:suppressedDiagnostics>before?'partial':'ok',suppressedDiagnosticCount:suppressedDiagnostics-before,completeness:'bounded SDK result; not full account inventory'};
  }
  if(method==='restoreIndexRelayer'){
    if(params.trustUpgrade!=='relayer-decryption-and-embedding')throw new BoundaryError('review_mismatch');
    // Deliberately use the relayer-mode public SDK: Manual.restore is not client-side restoration.
    const result=object(await sdk.restore(profile.namespace,params.limit as number));scoped(result);
    return {...result,complete:'unknown',mode:'relayerProcessing',requestedMode:profile.mode,trustUpgrade:true};
  }
  throw new BoundaryError('unsupported_operation');
}
parentPort!.on('message',async(raw:unknown)=>{
  let id:string|null=null;
  try{
    if(typeof raw!=='string'||Buffer.byteLength(raw)>FRAME_LIMIT)throw new BoundaryError('request_limit');
    const value=object(JSON.parse(raw));if(typeof value.id!=='string'||typeof value.method!=='string')throw new BoundaryError('protocol_error');id=value.id;
    const result=await run(value.method,object(value.parameters));
    const response=JSON.stringify({id,result});if(Buffer.byteLength(response)>FRAME_LIMIT)throw new BoundaryError('response_limit');
    parentPort!.postMessage(response);
  }catch(error){
    const value=error as {code?:unknown;name?:unknown;status?:unknown};
    const code=error instanceof BoundaryError||error instanceof WalrusError?error.code:value.name==='MemWalCompatibilityError'?'incompatible_relayer':typeof value.status==='number'?'http_error':'remote_error';
    // Never forward raw SDK error/cause bodies, stack, credential strings or console output.
    parentPort!.postMessage(JSON.stringify({id,error:{code,httpStatus:error instanceof WalrusError?error.httpStatus:typeof value.status==='number'?value.status:null}}));
  }finally{enforceProfile=false;}
});
