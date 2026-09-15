import {createHash} from 'node:crypto';
import {canonicalJSON,WalrusError,type RemoteProfile} from './index.js';

export interface ManifestEntry {
  blobID:string; encoding:'utf8-memory-v1'|'vela-memory-archive-v1'; title:string;
  /** Null means no independently known plaintext checksum; SEAL authentication is still checked. */
  plaintextSHA256:string|null; plaintextBytes:number|null;
}
export interface MemoryManifest {
  format:'vela.walrus-manifest';version:1;
  source:{network:'testnet'|'mainnet';packageID:string;accountID:string;owner:string;namespace:string};
  entries:ManifestEntry[];sha256:string;
}
export interface ManifestPageOptions {cursor?:string;limit?:number}
const hash=(value:unknown)=>createHash('sha256').update(canonicalJSON(value)).digest('hex');
function exact(value:unknown,keys:string[]):asserts value is Record<string,unknown>{
  if(!value||typeof value!=='object'||Array.isArray(value)||Object.keys(value).length!==keys.length||Object.keys(value).some(key=>!keys.includes(key)))throw new WalrusError('invalid_manifest');
}
export function createMemoryManifest(source:MemoryManifest['source'],entries:ManifestEntry[]):MemoryManifest{
  const unsigned={format:'vela.walrus-manifest' as const,version:1 as const,source,entries};
  return validateMemoryManifest({...unsigned,sha256:hash(unsigned)});
}
export function validateMemoryManifest(value:unknown):MemoryManifest{
  exact(value,['format','version','source','entries','sha256']);
  if(value.format!=='vela.walrus-manifest'||value.version!==1||Buffer.byteLength(canonicalJSON(value))>512*1024)throw new WalrusError('invalid_manifest');
  exact(value.source,['network','packageID','accountID','owner','namespace']);
  const source=value.source;
  if(!['mainnet','testnet'].includes(source.network as string)||['packageID','accountID','owner'].some(key=>typeof source[key]!=='string'||!/^0x[0-9a-f]{64}$/.test(source[key] as string))||typeof source.namespace!=='string'||!source.namespace.trim()||source.namespace.includes('\0')||Buffer.byteLength(source.namespace)>256)throw new WalrusError('invalid_manifest');
  if(!Array.isArray(value.entries)||value.entries.length>1000)throw new WalrusError('invalid_manifest');
  const ids=new Set<string>();
  for(const entry of value.entries){
    exact(entry,['blobID','encoding','title','plaintextSHA256','plaintextBytes']);
    if(typeof entry.blobID!=='string'||!/^[A-Za-z0-9_-]{43}$/.test(entry.blobID)||Buffer.from(entry.blobID,'base64url').toString('base64url')!==entry.blobID||ids.has(entry.blobID)||!['utf8-memory-v1','vela-memory-archive-v1'].includes(entry.encoding as string)||typeof entry.title!=='string'||!entry.title.trim()||entry.title.includes('\0')||[...entry.title].length>300)throw new WalrusError('invalid_manifest');
    ids.add(entry.blobID);
    if(entry.plaintextSHA256===null&&entry.plaintextBytes===null)continue;
    if(typeof entry.plaintextSHA256!=='string'||!/^[0-9a-f]{64}$/.test(entry.plaintextSHA256)||typeof entry.plaintextBytes!=='number'||!Number.isInteger(entry.plaintextBytes)||entry.plaintextBytes<1||entry.plaintextBytes>1024*1024)throw new WalrusError('invalid_manifest');
  }
  const {sha256,...unsigned}=value;
  if(typeof sha256!=='string'||sha256!==hash(unsigned))throw new WalrusError('manifest_checksum_mismatch');
  return JSON.parse(canonicalJSON(value)) as MemoryManifest;
}
export function manifestPage(manifest:MemoryManifest,options:ManifestPageOptions={}):{start:number;end:number}{
  if(!options||typeof options!=='object'||Object.keys(options).some(key=>!['cursor','limit'].includes(key)))throw new WalrusError('invalid_input');
  const limit=options.limit??10;if(!Number.isInteger(limit)||limit<1||limit>20)throw new WalrusError('invalid_input');
  let start=0;
  if(options.cursor!==undefined){
    if(typeof options.cursor!=='string'||options.cursor.length>150)throw new WalrusError('invalid_cursor');
    const parts=options.cursor.split(':');if(parts.length!==2||parts[0]!==manifest.sha256||!/^(0|[1-9]\d*)$/.test(parts[1]!))throw new WalrusError('invalid_cursor');
    start=Number(parts[1]);if(!Number.isSafeInteger(start)||start>manifest.entries.length)throw new WalrusError('invalid_cursor');
  }
  return {start,end:Math.min(manifest.entries.length,start+limit)};
}
export function manifestMatchesProfile(manifest:MemoryManifest,profile:RemoteProfile):void{
  const source=manifest.source;
  if(source.packageID!==profile.packageID||source.network!==profile.network||source.accountID!==profile.accountID||source.owner!==profile.expectedOwner||source.namespace!==profile.namespace)throw new WalrusError('manifest_scope_mismatch');
}
/** Encrypted identities are namespace bytes followed by owner bytes and the little-endian access counter. */
export function validateSealIdentity(id:string,manifest:MemoryManifest,currentCounter:string):void{
  if(typeof id!=='string'||!/^([0-9a-f]{2})+$/.test(id)||!/^\d+$/.test(currentCounter))throw new WalrusError('seal_identity_mismatch');
  const bytes=Buffer.from(id,'hex'),prefix=Buffer.concat([Buffer.from(manifest.source.namespace),Buffer.from(manifest.source.owner.slice(2),'hex')]);
  if(bytes.length!==prefix.length+8||!bytes.subarray(0,prefix.length).equals(prefix)||bytes.readBigUInt64LE(prefix.length)>BigInt(currentCounter))throw new WalrusError('seal_identity_mismatch');
}
export function validateRecoveredPlaintext(entry:ManifestEntry,data:Uint8Array):{text:string;sha256:string;bytes:number;expectedChecksumVerified:boolean}{
  if(data.byteLength<1||data.byteLength>1024*1024)throw new WalrusError('plaintext_limit');
  const sha256=createHash('sha256').update(data).digest('hex');
  if(entry.plaintextSHA256!==null&&(sha256!==entry.plaintextSHA256||data.byteLength!==entry.plaintextBytes))throw new WalrusError('plaintext_checksum_mismatch');
  let text:string;try{text=new TextDecoder('utf-8',{fatal:true}).decode(data);}catch{throw new WalrusError('invalid_utf8');}
  if(!text.trim()||text.includes('\0'))throw new WalrusError('invalid_plaintext');
  if(entry.encoding==='vela-memory-archive-v1'){
    let archive:unknown;try{archive=JSON.parse(text);}catch{throw new WalrusError('invalid_archive');}
    if(!archive||typeof archive!=='object'||Array.isArray(archive)||(archive as any).format!=='vela.memory-archive'||(archive as any).version!==1)throw new WalrusError('invalid_archive');
    // Core performs the complete schema and canonical Foundation checksum validation before import.
  }
  return {text,sha256,bytes:data.byteLength,expectedChecksumVerified:entry.plaintextSHA256!==null};
}
