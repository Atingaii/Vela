import {EncryptedObject,SealClient,SessionKey} from '@mysten/seal';
import {Ed25519Keypair} from '@mysten/sui/keypairs/ed25519';
import {decodeSuiPrivateKey} from '@mysten/sui/cryptography';
import {Transaction} from '@mysten/sui/transactions';
import {WalrusError,type ObjectValue,type RemoteProfile,type RemoteCredentials} from './index.js';
import {validateMemoryManifest,manifestMatchesProfile,manifestPage,validateSealIdentity,validateRecoveredPlaintext,type ManifestPageOptions} from './manifest.js';

/** Public SEAL APIs only. This module never accesses the relayer or an embedding service. */
export async function restoreManifestPage(profile:RemoteProfile,credentials:RemoteCredentials,parameters:ObjectValue,client:any):Promise<ObjectValue>{
  const manifest=validateMemoryManifest(parameters.manifest);manifestMatchesProfile(manifest,profile);
  const range=manifestPage(manifest,parameters.page as ManifestPageOptions);
  if(!credentials.suiPrivateKey||!profile.sealServerConfigs||!profile.walrusAggregatorURL)throw new WalrusError('restore_configuration_required');
  const decoded=decodeSuiPrivateKey(credentials.suiPrivateKey);if(decoded.scheme!=='ED25519')throw new WalrusError('unsupported_signer');
  const signer=Ed25519Keypair.fromSecretKey(decoded.secretKey);decoded.secretKey.fill(0);
  const account=await client.getObject({id:profile.accountID,options:{showContent:true}}),content=account?.data?.content,fields=content?.fields;
  if(content?.dataType!=='moveObject'||content.type!==`${profile.packageID}::account::MemWalAccount`||fields?.owner!==profile.expectedOwner)throw new WalrusError('owner_mismatch');
  if(fields.active!==true||fields.admin_quarantined===true)throw new WalrusError('account_inactive');
  if(signer.toSuiAddress()!==profile.expectedOwner&&(!Array.isArray(fields.delegate_keys)||!fields.delegate_keys.some((entry:any)=>entry?.fields?.sui_address===signer.toSuiAddress())))throw new WalrusError('signer_not_authorized');
  const registry=await client.getObject({id:profile.registryID,options:{showContent:true}});
  if(registry?.data?.content?.type!==`${profile.packageID}::account::AccountRegistry`)throw new WalrusError('registry_mismatch');
  const counter=fields.access_counter_version;if(typeof counter!=='string'||!/^\d+$/.test(counter))throw new WalrusError('access_counter_unavailable');
  const seal=new SealClient({suiClient:client,serverConfigs:profile.sealServerConfigs.map(config=>({objectId:config.objectID,weight:config.weight,...(config.aggregatorURL?{aggregatorUrl:config.aggregatorURL}:{})})),verifyKeyServers:true,timeout:15000});
  let session:SessionKey|undefined;const recovered:ObjectValue[]=[],failures:ObjectValue[]=[];let index=range.start,wireBytes=0;
  for(;index<range.end;index++){
    const entry=manifest.entries[index]!;
    try{
      const response=await fetch(profile.walrusAggregatorURL+'/v1/blobs/'+entry.blobID);
      if(!response.ok)throw new WalrusError(response.status===404?'blob_unavailable':'blob_download_failed',null,false,response.status);
      const cipher=new Uint8Array(await response.arrayBuffer());let envelope:ReturnType<typeof EncryptedObject.parse>;
      try{envelope=EncryptedObject.parse(cipher);}catch{throw new WalrusError('invalid_ciphertext');}
      if('0x'+envelope.packageId.replace(/^0x/,'')!==profile.packageID)throw new WalrusError('seal_package_mismatch');
      validateSealIdentity(envelope.id.replace(/^0x/,''),manifest,counter);
      if(!session)session=await SessionKey.create({address:signer.toSuiAddress(),packageId:profile.packageID,ttlMin:5,signer,suiClient:client});
      const transaction=new Transaction();transaction.moveCall({target:`${profile.sealPolicyPackageID}::account::seal_approve`,arguments:[transaction.pure('vector<u8>',Array.from(Buffer.from(envelope.id.replace(/^0x/,''),'hex'))),transaction.object(profile.registryID),transaction.object(profile.accountID)]});
      const txBytes=await transaction.build({client,onlyTransactionKind:true});
      const plaintext=await seal.decrypt({data:cipher,sessionKey:session,txBytes,checkShareConsistency:true});
      const checked=validateRecoveredPlaintext(entry,plaintext);plaintext.fill(0);
      const receipt={sealAuthenticated:true,expectedChecksumVerified:checked.expectedChecksumVerified,actualSHA256:checked.sha256,plaintextBytes:checked.bytes,manifestSHA256:manifest.sha256,manifestAuthenticated:false};
      const result={index,blobID:entry.blobID,encoding:entry.encoding,title:entry.title,...checked,receipt,source:manifest.source};
      const bytes=Buffer.byteLength(JSON.stringify(result));
      if(bytes>1500*1024)throw new WalrusError('plaintext_response_limit');
      if(wireBytes+bytes>1500*1024)break; // Retry this known index on the next explicit page.
      wireBytes+=bytes;recovered.push(result);
    }catch(error){const code=error instanceof WalrusError?error.code:'seal_decryption_failed';failures.push({index,blobID:entry.blobID,code,retryable:['blob_unavailable','blob_download_failed','seal_decryption_failed'].includes(code)});}
  }
  return {manifestSHA256:manifest.sha256,mode:'clientSideManifest',recovered,failures,nextCursor:index<manifest.entries.length?manifest.sha256+':'+index:null,manifestTraversalComplete:index===manifest.entries.length,pageAllRecovered:failures.length===0&&index===range.end,coverage:{start:range.start,end:index,total:manifest.entries.length,scope:'manifest-page',accountInventoryComplete:'unknown'},manifestAuthenticated:false,relayerUsed:false,embeddingUsed:false,namespaceIsACL:false};
}
