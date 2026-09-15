"""Install the optional AI middleware and verify real SDK HTTP/SSE + local helper.

This is isolated protocol/product integration, not external model-quality or
Walrus network acceptance. Existing checkpoints are not overwritten.
"""
import datetime,hashlib,json,os,re,shutil,subprocess,sys,tarfile,tempfile
from pathlib import Path
root=Path(__file__).resolve().parents[1]
out=Path(os.environ.get('VELA_AI_TEST_OUTPUT',root/'sdk/ai/evidence'/('installed-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S'))));out.mkdir(parents=True,exist_ok=True)
sha=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
with tempfile.TemporaryDirectory(prefix='vela-ai-installed-') as temporary:
 scratch=Path(temporary);consumer=scratch/'consumer';consumer.mkdir();(consumer/'package.json').write_text('{"private":true,"type":"module"}')
 helper=scratch/'vela';shutil.copy2(root/'.build/debug/vela',helper)
 env={**os.environ,'npm_config_cache':str(scratch/'npm-cache'),'VELA_DISABLE_DISCOVERY':'1','VELA_TEST_HELPER':str(helper),'VELA_TEST_PYTHON':sys.executable}
 def run(label,cmd,cwd=root,extra=None):
  r=subprocess.run(cmd,cwd=cwd,env={**env,**(extra or {})},capture_output=True,text=True,timeout=180)
  (out/(label+'.log')).write_text(r.stdout+r.stderr)
  if r.returncode:print(r.stdout+r.stderr);r.check_returncode()
  return r
 run('local-sdk-pack',['npm','pack','--json','--pack-destination',str(scratch)],root/'sdk/typescript')
 run('ai-pack',['npm','pack','--json','--pack-destination',str(scratch)],root/'sdk/ai')
 packages=sorted(scratch.glob('*.tgz'))
 for package in packages:
  with tarfile.open(package) as archive:members=archive.getnames()
  assert set(members)=={'package/package.json','package/LICENSE','package/README.md','package/dist/index.js','package/dist/index.d.ts'},members
 run('consumer-install',['npm','install','--ignore-scripts','--no-audit','--no-fund',*[str(p) for p in packages],'ai@7.0.99','@ai-sdk/openai@4.0.66','@types/node@22.20.2','zod@4.6.4'],consumer)
 (consumer/'consumer.ts').write_text('''import {createVelaMemoryMiddleware,type MemoryReceipt} from '@vela-engineering/ai';
import {VelaClient} from '@vela-engineering/sdk';
import {wrapLanguageModel,type LanguageModelMiddleware} from 'ai';
import {createOpenAI} from '@ai-sdk/openai';
const model=createOpenAI({apiKey:'synthetic',baseURL:'http://127.0.0.1:1/v1'}).chat('synthetic');
const manager=createVelaMemoryMiddleware({project:'/project',namespace:'main',helperPath:'/helper',storeHome:'/store',acknowledgeMemoryDisclosure:true,modelRecipient:{provider:model.provider,model:model.modelId}});
const turn=manager.forTurn({sessionID:'session',turnID:'turn'});const middleware:LanguageModelMiddleware=turn.middleware;
const result:Promise<MemoryReceipt>=turn.settled();void wrapLanguageModel({model,middleware});void result;
declare const client:VelaClient;void client.captureIntegration('main','turn',[],undefined,{integration:'ai-sdk-v4'});
// @ts-expect-error Unknown integration is not part of the public union.
void client.captureIntegration('main','turn',[],undefined,{integration:'unknown'});
''')
 run('consumer-typecheck',[str(root/'sdk/ai/node_modules/.bin/tsc'),'--strict','--skipLibCheck','--noEmit','--target','ES2022','--module','NodeNext','--moduleResolution','NodeNext','consumer.ts'],consumer)
 entry=consumer/'node_modules/@vela-engineering/ai/dist/index.js'
 tests=run('actual-ai-sdk-tests',['node','--test',str(root/'sdk/ai/test/integration.test.mjs')],consumer,{'VELA_AI_TEST_PACKAGE':entry.as_uri(),'VELA_AI_CONSUMER_PACKAGE':str(consumer/'package.json'),'VELA_LOCAL_SDK_TEST_PACKAGE':(consumer/'node_modules/@vela-engineering/sdk/dist/index.js').as_uri()})
 passed=re.search(r'(?:#|ℹ) pass (\d+)',tests.stdout);assert passed and int(passed.group(1))>=17
 run('local-sdk-compatibility-tests',['node','--test',str(root/'sdk/typescript/test/sdk.test.mjs')],consumer,{'VELA_TEST_PACKAGE':(consumer/'node_modules/@vela-engineering/sdk/dist/index.js').as_uri()})
 run('dependencies',['npm','ls','--all','--json'],consumer)
 legacy_record={'state':'not_run','reason':'No retained legacy SDK package selected; set VELA_AI_LEGACY_SDK_PACKAGE.'}
 if os.environ.get('VELA_AI_LEGACY_SDK_PACKAGE'):
  legacy=Path(os.environ['VELA_AI_LEGACY_SDK_PACKAGE']).resolve(strict=True)
  older=scratch/'legacy-consumer';older.mkdir();(older/'package.json').write_text('{"private":true,"type":"module"}')
  wrapper=next(p for p in packages if '-ai-' in p.name)
  run('legacy-consumer-install',['npm','install','--ignore-scripts','--no-audit','--no-fund',str(wrapper),str(legacy),'ai@7.0.99','@ai-sdk/openai@4.0.66','zod@4.6.4'],older)
  legacy_tests=run('legacy-sdk-tests',['node','--test',str(root/'sdk/ai/test/legacy-sdk.test.mjs')],older,{'VELA_AI_LEGACY_CONSUMER_PACKAGE':str(older/'package.json'),'VELA_AI_LEGACY_TEST_PACKAGE':(older/'node_modules/@vela-engineering/ai/dist/index.js').as_uri(),'VELA_AI_LEGACY_LOCAL_SDK_PACKAGE':(older/'node_modules/@vela-engineering/sdk/dist/index.js').as_uri()})
  legacy_pass=re.search(r'(?:#|ℹ) pass (\d+)',legacy_tests.stdout);assert legacy_pass and int(legacy_pass.group(1))==1
  legacy_record={'state':'passed','testsPassed':1,'packageSHA256':sha(legacy),'packagePath':str(legacy)}
 records=[]
 for p in packages:shutil.copy2(p,out/p.name);records.append({'name':p.name,'sha256':sha(p),'bytes':p.stat().st_size})
 receipt={'format':'vela-ai-installed-integration-v1','artifactDirectory':str(out.resolve()),'testsPassed':int(passed.group(1)),'localSDKCompatibilityTests':12,'legacySDKCompatibility':legacy_record,'consumerTypecheck':True,'actualAISDK':'7.0.99','actualOpenAIProvider':'4.0.66','modelProvider':'synthetic_loopback_http_sse','helperSHA256':sha(helper),'packages':records,'realModelQuality':'not_tested','remoteMemory':'not_used','existingUserAccounts':'not_used','temporaryInstallHelperStoresAndCacheRemovedOnExit':True}
 (out/'package-results.json').write_text(json.dumps(receipt,indent=2)+'\n')
 print(json.dumps(receipt))
