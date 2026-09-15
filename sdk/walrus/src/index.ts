import { Worker } from 'node:worker_threads';
import { createHash, randomUUID } from 'node:crypto';
import type {OwnerActionInput} from './owner.js';
import {validateMemoryManifest,manifestMatchesProfile,manifestPage,type MemoryManifest,type ManifestPageOptions} from './manifest.js';
import {metadataCursor,jobIDs,type MetadataPageOptions} from './metadata.js';
export type {MetadataPageOptions} from './metadata.js';
export type {OwnerActionInput, OwnerTransaction} from './owner.js';
export {createMemoryManifest,validateMemoryManifest} from './manifest.js';
export type {MemoryManifest,ManifestEntry,ManifestPageOptions} from './manifest.js';
export type ObjectValue = {[key:string]:unknown};
export interface RemoteProfile {
  version:1; id:string; mode:'clientEncryption' | 'relayerProcessing';
  serverURL:string; network:'testnet'|'mainnet'; fullnodeURL:string;
  packageID:string; sealPolicyPackageID:string; registryID:string; accountID:string; expectedOwner:string; namespace:string;
  allowedOrigins:string[];
  embedding?:{endpoint:string;model:string;plaintextRecipientAcknowledged:true};
  walrusAggregatorURL?:string;
  sealServerConfigs?:{objectID:string;weight:number;aggregatorURL?:string}[];
  writeLimits:{maxOperations:number;maxPlaintextBytes:number};
  /** Test fixtures only: exact loopback HTTP origins; never permits remote HTTP. */
  allowLoopbackHTTP?:boolean;
}
export interface RemoteCredentials { delegateKey:Uint8Array; suiPrivateKey?:string; embeddingApiKey?:string }
export interface RemoteOptions { timeoutMs?:number; signal?:AbortSignal }
export interface PreparedRemoteAction {
  id:string; hash:string; operation:'remember'|'rememberBulk'|'analyze'|'forgetNamespace'|'restoreIndexRelayer'|'ownerTransaction'; profile:RemoteProfile;
  arguments:ObjectValue; plaintextRecipients:string[]; storageEpochs:null; monetaryQuote:null;
  notice:string; expiresAt:string;
}
export class WalrusError extends Error {
  constructor(public readonly code:string, public readonly requestID:string|null=null, public readonly effectsUnknown=false, public readonly httpStatus:number|null=null) {
    super(`Vela Walrus operation failed: ${code}.`);this.name='WalrusError';
  }
}
export function canonicalJSON(value:unknown):string {
  if (Array.isArray(value)) return '['+value.map(canonicalJSON).join(',')+']';
  if (value && typeof value==='object') return '{'+Object.entries(value).sort(([a],[b])=>a<b?-1:a>b?1:0).map(([k,v])=>JSON.stringify(k)+':'+canonicalJSON(v)).join(',')+'}';
  const result=JSON.stringify(value); if (result===undefined) throw new WalrusError('invalid_input');return result;
}
function exact(value:unknown,keys:string[]):void {
  if (!value || typeof value!=='object' || Array.isArray(value) || Object.keys(value).some(k=>!keys.includes(k))) throw new WalrusError('invalid_input');
}
function text(value:unknown,max=4096):asserts value is string {
  if(typeof value!=='string'||!value.trim()||Buffer.byteLength(value)>max||value.includes('\0'))throw new WalrusError('invalid_input');
}
function integer(value:unknown,min:number,max:number):asserts value is number {
  if(typeof value!=='number'||!Number.isInteger(value)||value<min||value>max)throw new WalrusError('invalid_input');
}
function endpoint(value:unknown,loopback:boolean):string {
  text(value);let url:URL;try{url=new URL(value);}catch{throw new WalrusError('invalid_input');}
  if(url.username||url.password||url.hash||url.search||!(url.protocol==='https:'||(loopback&&url.protocol==='http:'&&['localhost','127.0.0.1','[::1]'].includes(url.hostname))))throw new WalrusError('invalid_input');
  return url.toString().replace(/\/$/,'');
}
export function validateProfile(value:RemoteProfile):RemoteProfile {
  exact(value,['version','id','mode','serverURL','network','fullnodeURL','packageID','sealPolicyPackageID','registryID','accountID','expectedOwner','namespace','allowedOrigins','embedding','walrusAggregatorURL','sealServerConfigs','writeLimits','allowLoopbackHTTP']);
  if(value.version!==1||!['clientEncryption','relayerProcessing'].includes(value.mode)||!['testnet','mainnet'].includes(value.network))throw new WalrusError('invalid_input');
  if(value.allowLoopbackHTTP!==undefined&&typeof value.allowLoopbackHTTP!=='boolean')throw new WalrusError('invalid_input');
  text(value.id,100);text(value.namespace,255);
  for(const key of ['packageID','sealPolicyPackageID','registryID','accountID','expectedOwner'] as const)if(!/^0x[0-9a-f]{64}$/.test(value[key]))throw new WalrusError('invalid_input');
  exact(value.writeLimits,['maxOperations','maxPlaintextBytes']);integer(value.writeLimits.maxOperations,0,100);integer(value.writeLimits.maxPlaintextBytes,0,1024*1024);
  const profile=JSON.parse(canonicalJSON(value)) as RemoteProfile;
  profile.serverURL=endpoint(profile.serverURL,profile.allowLoopbackHTTP===true);profile.fullnodeURL=endpoint(profile.fullnodeURL,profile.allowLoopbackHTTP===true);
  if(!Array.isArray(profile.allowedOrigins)||profile.allowedOrigins.length<1||profile.allowedOrigins.length>16)throw new WalrusError('invalid_input');
  profile.allowedOrigins=profile.allowedOrigins.map(value=>{const normalized=endpoint(value,profile.allowLoopbackHTTP===true);if(new URL(normalized).origin!==normalized)throw new WalrusError('invalid_input');return normalized;});
  if(profile.embedding){exact(profile.embedding,['endpoint','model','plaintextRecipientAcknowledged']);if(profile.embedding.plaintextRecipientAcknowledged!==true)throw new WalrusError('invalid_input');text(profile.embedding.model,200);profile.embedding.endpoint=endpoint(profile.embedding.endpoint,profile.allowLoopbackHTTP===true);}
  if(profile.mode==='clientEncryption'&&!profile.embedding)throw new WalrusError('invalid_input');
  if(profile.walrusAggregatorURL)profile.walrusAggregatorURL=endpoint(profile.walrusAggregatorURL,profile.allowLoopbackHTTP===true);
  if(profile.sealServerConfigs){
    if(!Array.isArray(profile.sealServerConfigs)||profile.sealServerConfigs.length<1||profile.sealServerConfigs.length>10)throw new WalrusError('invalid_input');
    const ids=new Set<string>();for(const config of profile.sealServerConfigs){exact(config,['objectID','weight','aggregatorURL']);if(!/^0x[0-9a-f]{64}$/.test(config.objectID)||ids.has(config.objectID))throw new WalrusError('invalid_input');ids.add(config.objectID);integer(config.weight,1,100);
      if(config.aggregatorURL){config.aggregatorURL=endpoint(config.aggregatorURL,profile.allowLoopbackHTTP===true);if(!profile.allowedOrigins.includes(new URL(config.aggregatorURL).origin))throw new WalrusError('egress_not_allowed');}}
  }
  for(const url of [profile.serverURL,profile.fullnodeURL,profile.embedding?.endpoint,profile.walrusAggregatorURL])if(url&&!profile.allowedOrigins.includes(new URL(url).origin))throw new WalrusError('egress_not_allowed');
  return profile;
}
/** No network is started by construction or preparation. Each remote call is explicit. */
export class WalrusClient {
  private readonly profile:RemoteProfile;
  private credentials?:RemoteCredentials;
  private worker?:Worker;
  private termination?:Promise<number>;
  private pending?:{id:string;mutating:boolean;resolve:(value:ObjectValue)=>void;reject:(error:WalrusError)=>void;timer:ReturnType<typeof setTimeout>;cleanup:()=>void};
  private closed=false;
  private readonly actions=new Map<string,{canonical:string;preview:PreparedRemoteAction}>();
  private consumedOperations=0;
  private consumedBytes=0;
  constructor(profile:RemoteProfile,credentials?:RemoteCredentials){
    this.profile=validateProfile(profile);
    if(credentials){exact(credentials,['delegateKey','suiPrivateKey','embeddingApiKey']);if(!(credentials.delegateKey instanceof Uint8Array)||credentials.delegateKey.length!==32)throw new WalrusError('invalid_input');
      if(credentials.suiPrivateKey!==undefined)text(credentials.suiPrivateKey,200);if(credentials.embeddingApiKey!==undefined)text(credentials.embeddingApiKey,4096);
      this.credentials={...credentials,delegateKey:new Uint8Array(credentials.delegateKey)};}
  }
  private start():Worker {
    if(this.worker)return this.worker;
    const worker=new Worker(new URL('./worker.js',import.meta.url),{workerData:{profile:this.profile,credentials:this.credentials},stdout:true,stderr:true});this.worker=worker;
    let output=0;
    for(const stream of [worker.stdout,worker.stderr])stream.on('data',(chunk:Buffer)=>{output+=chunk.length;if(output>65536)void this.fail('output_limit');});
    worker.on('message',(raw:unknown)=>{
      const pending=this.pending;if(!pending){void this.fail('protocol_error');return;}
      if(typeof raw!=='string'||Buffer.byteLength(raw)>2*1024*1024){void this.fail('output_limit');return;}
      let value:ObjectValue;try{value=JSON.parse(raw);}catch{void this.fail('protocol_error');return;}
      if(!value||value.id!==pending.id||(('result'in value)===('error'in value))){void this.fail('protocol_error');return;}
      this.pending=undefined;clearTimeout(pending.timer);pending.cleanup();
      if('error'in value){const error=value.error as ObjectValue;pending.reject(new WalrusError(typeof error.code==='string'?error.code:'remote_error',pending.id,pending.mutating,typeof error.httpStatus==='number'?error.httpStatus:null));}
      else pending.resolve(value.result as ObjectValue);
    });
    worker.on('error',()=>void this.fail('worker_failed'));worker.on('exit',()=>{if(!this.closed)void this.fail('worker_closed');});return worker;
  }
  private async fail(code:string):Promise<void>{
    if(this.closed){await this.termination;return;}this.closed=true;
    const pending=this.pending;this.pending=undefined;if(pending){clearTimeout(pending.timer);pending.cleanup();pending.reject(new WalrusError(code,pending.id,pending.mutating));}
    this.credentials?.delegateKey.fill(0);this.credentials=undefined;this.actions.clear();this.termination=this.worker?.terminate();await this.termination;
  }
  private request(method:string,parameters:ObjectValue,mutating=false,options:RemoteOptions={}):Promise<ObjectValue>{
    if(this.closed)return Promise.reject(new WalrusError('closed'));if(this.pending)return Promise.reject(new WalrusError('busy'));
    exact(options,['timeoutMs','signal']);if(options.signal!==undefined&&!(options.signal instanceof AbortSignal))throw new WalrusError('invalid_input');const timeoutMs=options.timeoutMs??15000;integer(timeoutMs,1,120000);
    if(options.signal?.aborted)return Promise.reject(new WalrusError('cancelled'));
    const id=randomUUID(),wire=JSON.stringify({id,method,parameters});if(Buffer.byteLength(wire)>2*1024*1024)throw new WalrusError('invalid_input');
    return new Promise((resolve,reject)=>{const aborted=()=>void this.fail('cancelled');const timer=setTimeout(()=>void this.fail('timeout'),timeoutMs);
      this.pending={id,resolve,reject,mutating,timer,cleanup:()=>options.signal?.removeEventListener('abort',aborted)};options.signal?.addEventListener('abort',aborted,{once:true});
      try{this.start().postMessage(wire);}catch{void this.fail('worker_failed');}
    });
  }
  compatibility(options?:RemoteOptions):Promise<ObjectValue>{return this.request('compatibility',{},false,options);}
  deployment(options?:RemoteOptions):Promise<ObjectValue>{return this.request('deployment',{},false,options);}
  connect(options?:RemoteOptions):Promise<ObjectValue>{if(!this.credentials)throw new WalrusError('credentials_required');return this.request('connect',{},false,options);}
  namespaces(parameters:{cursor?:string;limit?:number}={},options?:RemoteOptions):Promise<ObjectValue>{
    exact(parameters,['cursor','limit']);if(parameters.cursor!==undefined)text(parameters.cursor);if(parameters.limit!==undefined)integer(parameters.limit,1,500);
    if(!this.credentials)throw new WalrusError('credentials_required');return this.request('namespaces',parameters,false,options);
  }
  recall(query:string,limit=10,options?:RemoteOptions):Promise<ObjectValue>{text(query,16384);integer(limit,1,50);if(!this.credentials)throw new WalrusError('credentials_required');return this.request('recall',{query,limit},false,options);}
  rememberStatus(jobID:string,options?:RemoteOptions):Promise<ObjectValue>{text(jobID,200);if(!/^[A-Za-z0-9_-]+$/.test(jobID))throw new WalrusError('invalid_input');if(!this.credentials)throw new WalrusError('credentials_required');return this.request('rememberStatus',{jobID},false,options);}
  rememberBulkStatus(ids:string[],options?:RemoteOptions):Promise<ObjectValue>{jobIDs(ids);if(!this.credentials)throw new WalrusError('credentials_required');return this.request('rememberBulkStatus',{jobIDs:ids},false,options);}
  ownerMemories(parameters:MetadataPageOptions={},options?:RemoteOptions):Promise<ObjectValue>{
    exact(parameters,['cursor','limit']);if(parameters.limit!==undefined)integer(parameters.limit,1,500);metadataCursor(this.profile,parameters.cursor);
    if(!this.credentials)throw new WalrusError('credentials_required');return this.request('ownerMemories',parameters,false,options);
  }
  ownerAgents(options?:RemoteOptions):Promise<ObjectValue>{if(!this.credentials)throw new WalrusError('credentials_required');return this.request('ownerAgents',{},false,options);}
  namespaceStats(options?:RemoteOptions):Promise<ObjectValue>{if(!this.credentials)throw new WalrusError('credentials_required');return this.request('namespaceStats',{},false,options);}
  async waitForRememberJobs(ids:string[],parameters:{maxWaitMs?:number;pollIntervalMs?:number}={},options:RemoteOptions={}):Promise<ObjectValue>{
    jobIDs(ids);exact(parameters,['maxWaitMs','pollIntervalMs']);exact(options,['timeoutMs','signal']);
    const maximum=parameters.maxWaitMs??60000,interval=parameters.pollIntervalMs??1500;integer(maximum,1,120000);integer(interval,250,10000);
    if(options.signal!==undefined&&!(options.signal instanceof AbortSignal))throw new WalrusError('invalid_input');
    const deadline=Date.now()+maximum;let status:ObjectValue={};
    while(true){
      if(options.signal?.aborted){await this.close();throw new WalrusError('cancelled');}
      if(Date.now()>=deadline&&Object.keys(status).length)return {...status,waitState:'timeout',writesCancelled:false};
      status=await this.rememberBulkStatus(ids,{...options,timeoutMs:Math.min(options.timeoutMs??15000,Math.max(1,deadline-Date.now()))});
      if(Number(status.succeeded)+Number(status.failed)===ids.length)return {...status,waitState:'terminal',writesCancelled:false};
      if(Date.now()>=deadline)return {...status,waitState:'timeout',writesCancelled:false};
      await new Promise<void>((resolve,reject)=>{
        const abort=()=>{clearTimeout(timer);void this.close();reject(new WalrusError('cancelled'));};
        const timer=setTimeout(()=>{options.signal?.removeEventListener('abort',abort);resolve();},Math.min(interval,deadline-Date.now()));
        options.signal?.addEventListener('abort',abort,{once:true});if(options.signal?.aborted)abort();
      });
    }
  }
  /** Explicit client-side download/decrypt. Never invokes relayer index restore or embedding. */
  restoreManifestPage(value:MemoryManifest,page:ManifestPageOptions={},options?:RemoteOptions):Promise<ObjectValue>{
    const manifest=validateMemoryManifest(value);manifestMatchesProfile(manifest,this.profile);manifestPage(manifest,page);
    if(!this.credentials?.suiPrivateKey)throw new WalrusError('credentials_required');
    if(!this.profile.walrusAggregatorURL||!this.profile.sealServerConfigs)throw new WalrusError('restore_configuration_required');
    return this.request('restoreManifestPage',{manifest,page},false,options);
  }
  async prepareOwnerAction(input:OwnerActionInput,options?:RemoteOptions):Promise<PreparedRemoteAction>{
    exact(input,['operation','maxGasBudgetMIST','publicKey','label']);
    exact(input,input.operation==='createAccount'?['operation','maxGasBudgetMIST']:input.operation==='addDelegate'?['operation','publicKey','label','maxGasBudgetMIST']:['operation','publicKey','maxGasBudgetMIST']);
    if(!['createAccount','addDelegate','removeDelegate'].includes(input.operation)||typeof input.maxGasBudgetMIST!=='string'||!/^[1-9]\d{0,19}$/.test(input.maxGasBudgetMIST)||BigInt(input.maxGasBudgetMIST)<1n||BigInt(input.maxGasBudgetMIST)>18446744073709551615n)throw new WalrusError('invalid_input');
    if(input.operation!=='createAccount'&&!/^[0-9a-f]{64}$/.test(input.publicKey))throw new WalrusError('invalid_input');
    if(input.operation==='addDelegate')text(input.label,64);
    const prepared=await this.request('ownerPrepare',{input},false,options);
    return this.prepare('ownerTransaction',prepared);
  }
  ownerTransactionStatus(digest:string,options?:RemoteOptions):Promise<ObjectValue>{text(digest,100);if(!/^[1-9A-HJ-NP-Za-km-z]{32,64}$/.test(digest))throw new WalrusError('invalid_input');return this.request('ownerStatus',{digest},false,options);}
  executeOwnerAction(preview:PreparedRemoteAction,signature:string,options:RemoteOptions={}):Promise<ObjectValue>{
    if(preview.operation!=='ownerTransaction')throw new WalrusError('review_mismatch');text(signature,16384);
    if(!/^[A-Za-z0-9+/]+={0,2}$/.test(signature))throw new WalrusError('invalid_input');
    return this.dispatchReviewed(preview,{signature},options);
  }
  prepareRemember(textValue:string):PreparedRemoteAction{text(textValue,65536);return this.prepare('remember',{text:textValue});}
  prepareRememberBulk(texts:string[]):PreparedRemoteAction{
    if(this.profile.mode!=='relayerProcessing')throw new WalrusError('relayer_plaintext_mode_required');
    if(!Array.isArray(texts)||texts.length<1||texts.length>20)throw new WalrusError('invalid_input');for(const value of texts)text(value,65536);
    if(texts.reduce((sum,value)=>sum+Buffer.byteLength(value),0)>1024*1024)throw new WalrusError('invalid_input');
    return this.prepare('rememberBulk',{texts});
  }
  prepareForgetNamespace():PreparedRemoteAction{return this.prepare('forgetNamespace',{namespace:this.profile.namespace,indexOnly:true,blobsRetained:true});}
  prepareAnalyze(textValue:string):PreparedRemoteAction{
    text(textValue,65536);if(this.profile.mode!=='relayerProcessing')throw new WalrusError('relayer_plaintext_mode_required');
    return this.prepare('analyze',{text:textValue});
  }
  prepareRestoreIndexRelayer(limit=10):PreparedRemoteAction{integer(limit,1,100);return this.prepare('restoreIndexRelayer',{limit,trustUpgrade:'relayer-decryption-and-embedding'});}
  private prepare(operation:PreparedRemoteAction['operation'],args:ObjectValue):PreparedRemoteAction{
    if(this.closed)throw new WalrusError('closed');if(this.actions.size>=20)throw new WalrusError('busy');
    // Own every nested argument before hashing; caller arrays must not alter dispatch after review.
    const frozenArguments=JSON.parse(canonicalJSON(args)) as ObjectValue;
    const plaintextRecipients=['ownerTransaction','forgetNamespace'].includes(operation)?[]:operation==='restoreIndexRelayer'||this.profile.mode==='relayerProcessing'?[this.profile.serverURL]:[this.profile.embedding!.endpoint];
    const unsigned={id:randomUUID(),operation,profile:this.profile,arguments:frozenArguments,plaintextRecipients,storageEpochs:null,monetaryQuote:null,
      notice:operation==='forgetNamespace'?'Deletes every selected owner/namespace index row. Walrus blobs remain. Re-indexing requires a separate restore action and its explicit trust decision.':operation==='ownerTransaction'?'Exact unsigned transaction bytes are frozen. Sign those bytes with the owner wallet; the declared gas budget is a maximum, not an actual fee quote.':operation==='restoreIndexRelayer'?'Trust upgrade: relayer decrypts and re-embeds. A bounded restore does not establish complete recovery.':'Storage duration and fees are controlled by the relayer; no quote or duration guarantee is available from this SDK method.',expiresAt:new Date(Date.now()+10*60*1000).toISOString()};
    const hash=createHash('sha256').update(canonicalJSON(unsigned)).digest('hex');const preview={...unsigned,hash};
    this.actions.set(hash,{canonical:canonicalJSON(preview),preview});return JSON.parse(canonicalJSON(preview));
  }
  /** The caller reviews the exact returned preview before explicitly executing it once. */
  execute(preview:PreparedRemoteAction,options:RemoteOptions={}):Promise<ObjectValue>{
    if(preview.operation==='ownerTransaction')throw new WalrusError('owner_signature_required');return this.dispatchReviewed(preview,{},options);
  }
  private dispatchReviewed(preview:PreparedRemoteAction,additional:ObjectValue,options:RemoteOptions):Promise<ObjectValue>{
    const action=this.actions.get(preview.hash);if(!action||canonicalJSON(preview)!==action.canonical)throw new WalrusError('review_mismatch');
    if(Date.parse(action.preview.expiresAt)<Date.now())throw new WalrusError('review_expired');
    if(preview.operation!=='ownerTransaction'&&!this.credentials)throw new WalrusError('credentials_required');
    if(this.closed)throw new WalrusError('closed');if(this.pending)throw new WalrusError('busy');
    exact(options,['timeoutMs','signal']);if(options.signal!==undefined&&!(options.signal instanceof AbortSignal))throw new WalrusError('invalid_input');integer(options.timeoutMs??15000,1,120000);if(options.signal?.aborted)throw new WalrusError('cancelled');
    const texts=action.preview.operation==='rememberBulk'?action.preview.arguments.texts as string[]:[];
    const bytes=['remember','analyze'].includes(action.preview.operation)?Buffer.byteLength(action.preview.arguments.text as string):texts.reduce((sum,value)=>sum+Buffer.byteLength(value),0);
    const operations=action.preview.operation==='rememberBulk'?texts.length:1;
    if(this.consumedOperations+operations>this.profile.writeLimits.maxOperations||this.consumedBytes+bytes>this.profile.writeLimits.maxPlaintextBytes)throw new WalrusError('write_limit');
    // Consume before dispatch: uncertain effects never make this approval reusable.
    this.actions.delete(preview.hash);this.consumedOperations+=operations;this.consumedBytes+=bytes;
    return this.request(action.preview.operation,{...action.preview.arguments,...additional,operationID:preview.id},true,options);
  }
  async close():Promise<void>{await this.fail('closed');}
}
