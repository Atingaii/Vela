const {test}=require('node:test');
const assert=require('node:assert/strict');
const valid=()=>({signature:{status:0,output:''},identity:{status:0,output:'Authority=Developer ID Application: Example (TEAM)'},gatekeeper:{status:0,output:'accepted'},ticket:{status:0,output:'validated'}});
test('ad-hoc integrity never implies ordinary installation works',async()=>{
 const {verdict,exitCode}=await import('./assess-macos.mjs');const checks=valid();
 checks.identity.output='Signature=adhoc';checks.gatekeeper.status=3;checks.ticket.status=65;
 const result=verdict(checks);assert.equal(result.integrity,true);assert.equal(result.ready_for_default_open,false);
 assert.equal(exitCode(result,false),1);assert.equal(exitCode(result,true),0);
});
test('preview exception never admits a broken signature',async()=>{
 const {verdict,exitCode}=await import('./assess-macos.mjs');const checks=valid();checks.signature.status=1;
 assert.equal(exitCode(verdict(checks),true),1);
});
test('default-open requires every distribution check',async()=>{
 const {verdict}=await import('./assess-macos.mjs');assert.equal(verdict(valid()).ready_for_default_open,true);
 for(const key of ['signature','identity','gatekeeper','ticket']){const checks=valid();checks[key].status=null;assert.equal(verdict(checks).ready_for_default_open,false,key);}
});
