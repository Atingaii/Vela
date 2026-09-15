import {createHash,randomUUID} from 'node:crypto';
import {Ed25519Keypair} from '@mysten/sui/keypairs/ed25519';
import {WalrusError,canonicalJSON,type ObjectValue,type RemoteProfile} from './index.js';

export type MetadataPageOptions={cursor?:string;limit?:number};
const object=(value:unknown):ObjectValue=>{if(!value||typeof value!=='object'||Array.isArray(value))throw new WalrusError('protocol_error');return value as ObjectValue;};
const text=(value:unknown,max=4096):string=>{if(typeof value!=='string'||!value||Buffer.byteLength(value)>max||value.includes('\0'))throw new WalrusError('protocol_error');return value;};
const count=(value:unknown):number=>{if(typeof value!=='number'||!Number.isSafeInteger(value)||value<0)throw new WalrusError('protocol_error');return value;};
const profileIdentity=(profile:RemoteProfile)=>createHash('sha256').update(canonicalJSON({serverURL:profile.serverURL,network:profile.network,packageID:profile.packageID,accountID:profile.accountID,owner:profile.expectedOwner})).digest('hex');
export function metadataCursor(profile:RemoteProfile,cursor:string|undefined):string|undefined{
 if(cursor===undefined)return;
 try{if(typeof cursor!=='string'||Buffer.byteLength(cursor)>8192||!/^[A-Za-z0-9_-]+$/.test(cursor))throw Error();const raw=JSON.parse(Buffer.from(cursor,'base64url').toString());
 if(Object.keys(raw).sort().join(',')!=='profile,remote,version'||raw.version!==1||raw.profile!==profileIdentity(profile))throw Error();return text(raw.remote,4096);
 }catch{throw new WalrusError('invalid_cursor');}
}
function cursor(profile:RemoteProfile,remote:unknown):string|null{
 if(remote===null)return null;text(remote,4096);return Buffer.from(canonicalJSON({version:1,profile:profileIdentity(profile),remote})).toString('base64url');
}
/** Published fixed REST protocol; no SDK private methods or decrypt credential. */
export async function signedMetadata(profile:RemoteProfile,key:Uint8Array,method:'GET'|'POST',path:string,body?:ObjectValue):Promise<ObjectValue>{
 const timestamp=String(Math.floor(Date.now()/1000)),nonce=randomUUID(),raw=method==='GET'?'':JSON.stringify(body??{}),bodyHash=createHash('sha256').update(raw).digest('hex');
 const signer=Ed25519Keypair.fromSecretKey(key),signature=await signer.sign(Buffer.from(`${timestamp}.${method}.${path}.${bodyHash}.${nonce}.${profile.accountID}`));
 const response=await fetch(profile.serverURL+path,{method,headers:{'content-type':'application/json','x-public-key':Buffer.from(signer.getPublicKey().toRawBytes()).toString('hex'),'x-signature':Buffer.from(signature).toString('hex'),'x-timestamp':timestamp,'x-nonce':nonce,'x-account-id':profile.accountID},...(method==='POST'?{body:raw}:{})});
 if(!response.ok)throw new WalrusError(response.status===404?'not_found':response.status===429?'rate_limited':'http_error',null,false,response.status);
 try{return object(await response.json());}catch(error){if(error instanceof WalrusError)throw error;throw new WalrusError('protocol_error');}
}
export async function ownerMemories(profile:RemoteProfile,key:Uint8Array,params:MetadataPageOptions):Promise<ObjectValue>{
 const query=new URLSearchParams({limit:String(params.limit??100)}),remote=metadataCursor(profile,params.cursor);if(remote)query.set('updated_after',remote);
 const value=await signedMetadata(profile,key,'GET',`/v1/owners/${profile.expectedOwner}/memories?${query}`);
 if(value.snapshot_version!==2||!Array.isArray(value.memories)||value.memories.length>500||!Array.isArray(value.deleted)||value.deleted.length>500||typeof value.has_more!=='boolean'||typeof value.must_resync!=='boolean')throw new WalrusError('unsupported_metadata_shape');
 const memories=value.memories.map(raw=>{const row=object(raw),result:ObjectValue={memory_id:text(row.memory_id,300),namespace_id:text(row.namespace_id,256),blob_id:text(row.blob_id,300),created_at:text(row.created_at,100),updated_at:text(row.updated_at,100),size:count(row.size)};
  for(const name of ['agent_id','package_id','status','end_epoch','expires_at','importance'])if(row[name]!==undefined){const field=row[name];if(field!==null&&typeof field!=='number'&&typeof field!=='string')throw new WalrusError('protocol_error');if(typeof field==='string')text(field,300);if(typeof field==='number'&&!Number.isFinite(field))throw new WalrusError('protocol_error');result[name]=field;}
  return result;
 });
 const deleted=value.deleted.map(raw=>{const row=object(raw);return {memory_id:text(row.memory_id,300),namespace_id:text(row.namespace_id,256),deleted_at:text(row.deleted_at,100)};});
 const next=cursor(profile,value.next_cursor);if(value.has_more&&next===null)throw new WalrusError('protocol_error');
 return {owner:profile.expectedOwner,scope:'owner',metadataOnly:true,memories,deleted,mustResync:value.must_resync,nextCursor:next,hasMore:value.has_more,snapshotVersion:2,complete:false,completionMeaning:'hasMore describes this traversal; mustResync invalidates incremental state'};
}
export async function ownerAgents(profile:RemoteProfile,key:Uint8Array):Promise<ObjectValue>{
 const value=await signedMetadata(profile,key,'GET',`/v1/owners/${profile.expectedOwner}/agents`);
 if(value.snapshot_version!==2||!Array.isArray(value.agents)||value.agents.length>500)throw new WalrusError('unsupported_metadata_shape');
 const agents=value.agents.map(raw=>{const row=object(raw);if(typeof row.label!=='string'||Buffer.byteLength(row.label)>256||row.label.includes('\0'))throw new WalrusError('protocol_error');return {label:row.label,sui_address:text(row.sui_address,100)};});
 return {owner:profile.expectedOwner,scope:'owner',agents,snapshotVersion:2,source:'relayer on-chain delegate projection; may be briefly cached',namespaceIsACL:false};
}
export async function namespaceStats(profile:RemoteProfile,key:Uint8Array):Promise<ObjectValue>{
 const value=await signedMetadata(profile,key,'POST','/api/stats',{namespace:profile.namespace});
 if(value.owner!==profile.expectedOwner||value.namespace!==profile.namespace)throw new WalrusError('scope_mismatch');
 return {owner:value.owner,namespace:value.namespace,memoryCount:count(value.memory_count),storageBytes:count(value.storage_bytes),metadataOnly:true};
}
export async function forgetNamespace(profile:RemoteProfile,key:Uint8Array):Promise<ObjectValue>{
 const value=await signedMetadata(profile,key,'POST','/api/forget',{namespace:profile.namespace});
 if(value.owner!==profile.expectedOwner||value.namespace!==profile.namespace)throw new WalrusError('scope_mismatch');
 return {owner:value.owner,namespace:value.namespace,deletedIndexRows:count(value.deleted),blobsRetained:true,permanentDeletion:false,restoreRequiresSeparateAction:true};
}
export function jobIDs(value:unknown,max=20):string[]{
 if(!Array.isArray(value)||value.length<1||value.length>max||value.some(id=>typeof id!=='string'||!/^[A-Za-z0-9_-]{1,200}$/.test(id))||new Set(value).size!==value.length)throw new WalrusError('invalid_input');return value as string[];
}
export async function bulkStatus(profile:RemoteProfile,key:Uint8Array,ids:string[]):Promise<ObjectValue>{
 jobIDs(ids);const value=await signedMetadata(profile,key,'POST','/api/remember/bulk/status',{job_ids:ids});
 if(!Array.isArray(value.results)||value.results.length!==ids.length)throw new WalrusError('protocol_error');
 const byID=new Map<string,ObjectValue>();
 for(const raw of value.results){const row=object(raw),id=text(row.job_id,200),status=text(row.status,20);
  if(!ids.includes(id)||byID.has(id)||!['pending','running','uploaded','done','failed','not_found'].includes(status))throw new WalrusError('protocol_error');
  byID.set(id,{jobID:id,status,...(status==='done'?{blobID:text(row.blob_id,300)}:{}),...(status==='failed'?{errorCode:'remote_job_failed'}:{})});
 }
 const results=ids.map(id=>byID.get(id)!);
 return {owner:profile.expectedOwner,scope:'owner',results,succeeded:results.filter(row=>row.status==='done').length,failed:results.filter(row=>row.status==='failed').length,missing:results.filter(row=>row.status==='not_found').length,pending:results.filter(row=>!['done','failed','not_found'].includes(row.status as string)).length,writesCancelled:false};
}
