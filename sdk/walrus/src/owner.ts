import {createAccount,addDelegateKey,removeDelegateKey} from '@mysten-incubation/memwal/account';
import {Transaction} from '@mysten/sui/transactions';
import {verifyTransactionSignature} from '@mysten/sui/verify';
import type {RemoteProfile} from './index.js';
export type OwnerActionInput = {operation:'createAccount';maxGasBudgetMIST:string} | {operation:'addDelegate';publicKey:string;label:string;maxGasBudgetMIST:string} | {operation:'removeDelegate';publicKey:string;maxGasBudgetMIST:string};
export interface OwnerTransaction {
  operation:OwnerActionInput['operation']; input:OwnerActionInput; transactionBytes:string; digest:string;
  owner:string; network:string; maxGasBudgetMIST:string; expiresAfterEpoch:string;
}
class Capture extends Error { constructor(readonly transaction:Transaction){super('owner_transaction_captured');} }
/** Public SDK builders are intercepted at their documented wallet-signing callback, before submission. */
export async function captureOwnerTransaction(profile:RemoteProfile,input:OwnerActionInput,client:any):Promise<Transaction>{
  const walletSigner={address:profile.expectedOwner,
    signAndExecuteTransaction:async({transaction}:{transaction:any}):Promise<{digest:string}>=>{throw new Capture(Transaction.from(transaction));},
    signPersonalMessage:async():Promise<{signature:string}>=>{throw new Error('unexpected_personal_signing');}};
  const common={packageId:profile.sealPolicyPackageID,registryId:profile.registryID,suiClient:client,walletSigner};
  try{
    if(input.operation==='createAccount')await createAccount(common);
    else if(input.operation==='addDelegate')await addDelegateKey({...common,accountId:profile.accountID,publicKey:input.publicKey,label:input.label});
    else await removeDelegateKey({...common,accountId:profile.accountID,publicKey:input.publicKey});
  }catch(error){if(error instanceof Capture)return error.transaction;throw error;}
  throw new Error('owner_builder_did_not_capture');
}
export async function buildOwnerTransaction(profile:RemoteProfile,input:OwnerActionInput,client:any):Promise<OwnerTransaction>{
  const transaction=await captureOwnerTransaction(profile,input,client);
  const system=await client.getLatestSuiSystemState();
  if(typeof system.epoch!=='string'||!/^\d+$/.test(system.epoch))throw new Error('invalid_epoch');
  const expiry=(BigInt(system.epoch)+1n).toString();
  transaction.setSender(profile.expectedOwner);transaction.setGasBudget(input.maxGasBudgetMIST);transaction.setExpiration({Epoch:expiry});
  const bytes=await transaction.build({client});
  if(bytes.length>128*1024)throw new Error('transaction_limit');
  return {operation:input.operation,input,transactionBytes:Buffer.from(bytes).toString('base64'),digest:await Transaction.from(bytes).getDigest(),owner:profile.expectedOwner,network:profile.network,maxGasBudgetMIST:input.maxGasBudgetMIST,expiresAfterEpoch:expiry};
}
export async function verifyOwnerSignature(profile:RemoteProfile,prepared:OwnerTransaction,signature:string):Promise<Uint8Array>{
  const bytes=Buffer.from(prepared.transactionBytes,'base64');
  if(bytes.length===0||bytes.length>128*1024||bytes.toString('base64')!==prepared.transactionBytes)throw new Error('invalid_transaction');
  const transaction=Transaction.from(bytes),data=transaction.getData();
  if(prepared.owner!==profile.expectedOwner||prepared.network!==profile.network||data.sender!==profile.expectedOwner||data.gasData.budget!==prepared.maxGasBudgetMIST||await transaction.getDigest()!==prepared.digest)throw new Error('transaction_mismatch');
  await verifyTransactionSignature(bytes,signature,{address:profile.expectedOwner});return bytes;
}
