"""Pack/install Vela's optional plugin; verify a pinned real OpenClaw host and helper.

Set VELA_TEST_OPENCLAW_ROOT to an isolated installation of openclaw@2026.9.4.
Never reads normal OpenClaw config or auth. No model, faucet or remote write occurs.
"""
import hashlib,json,os,re,shutil,subprocess,tarfile,tempfile,threading
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
from pathlib import Path

root=Path(__file__).resolve().parents[1]
out=Path(os.environ.get('VELA_OPENCLAW_TEST_OUTPUT',root/'output/parity/openclaw'));out.mkdir(parents=True,exist_ok=True)
host=Path(os.environ.get('VELA_TEST_OPENCLAW_ROOT',root/'.task-tmp/openclaw-host-20260913/node_modules/openclaw')).resolve()
assert json.loads((host/'package.json').read_text())['version']=='2026.9.4'
sha=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
with tempfile.TemporaryDirectory(prefix='vela-openclaw-installed-') as temporary:
    scratch=Path(temporary);consumer=scratch/'consumer';consumer.mkdir()
    helper=scratch/'vela';shutil.copy2(root/'.build/debug/vela',helper)
    project=scratch/'project';project.mkdir()
    state=scratch/'host-state';state.mkdir()
    configpath=state/'openclaw.json'
    env={**os.environ,'npm_config_cache':str(scratch/'npm-cache'),'OPENCLAW_HOME':str(scratch/'host-home'),'OPENCLAW_STATE_DIR':str(state),'OPENCLAW_CONFIG_PATH':str(configpath),'VELA_DISABLE_DISCOVERY':'1'}
    def run(name,cmd,cwd=root,extra=None):
        result=subprocess.run(cmd,cwd=cwd,env={**env,**(extra or {})},capture_output=True,text=True,timeout=180)
        (out/(name+'.log')).write_text(result.stdout+result.stderr)
        if result.returncode:print(result.stdout+result.stderr);result.check_returncode()
        return result
    packages=[]
    for name in ['typescript','walrus','openclaw']:
        run(name+'-pack',['npm','pack','--json','--pack-destination',str(scratch)],root/'sdk'/name)
    packages=sorted(scratch.glob('*.tgz'))
    (consumer/'package.json').write_text('{"private":true,"type":"module"}')
    run('plugin-install',['npm','install','--ignore-scripts','--no-audit','--no-fund','--legacy-peer-deps',*[str(p) for p in packages]],consumer)
    # Link only the already isolated, pinned host; do not modify its dependencies.
    (consumer/'node_modules/openclaw').symlink_to(host,target_is_directory=True)
    installed=consumer/'node_modules/@vela-engineering/openclaw'
    (consumer/'consumer.ts').write_text("import plugin, {type VelaOpenClawConfig} from '@vela-engineering/openclaw';\nimport type {OpenClawPluginDefinition} from 'openclaw/plugin-sdk/plugin-entry';\nconst definition: OpenClawPluginDefinition=plugin; void definition;\n")
    run('consumer-typecheck',[str(root/'sdk/typescript/node_modules/.bin/tsc'),'--strict','--skipLibCheck','--noEmit','--target','ES2022','--module','NodeNext','--moduleResolution','NodeNext','consumer.ts'],consumer)
    config={'version':1,'backend':'local','helper':str(helper),'home':str(scratch/'vela-store'),'stateDirectory':str(scratch/'capture-journal'),'agents':{'main':{'project':str(project),'namespace':'main'}},'maxCaptureOperations':5,'maxCaptureBytes':10000}
    # Set the whole host config explicitly, including plugin hook and memory-slot permissions.
    configpath.write_text(json.dumps({'plugins':{'allow':['vela-memory'],'load':{'paths':[str(installed)]},'slots':{'memory':'vela-memory'},'entries':{'vela-memory':{'enabled':True,'hooks':{'allowConversationAccess':True,'allowPromptInjection':True},'config':config}}}}))
    request={'id':1,'method':'projects.add','params':{'path':str(project)}}
    added=subprocess.run([str(helper),'rpc','--no-watch','--no-schedule','--home',config['home']],input=json.dumps(request)+'\n',env=env,capture_output=True,text=True,timeout=30);assert added.returncode==0 and '"error"' not in added.stdout
    cli=['node',str(host/'openclaw.mjs')]
    listing=run('host-plugin-list',cli+['plugins','list','--json'],consumer)
    assert 'vela-memory' in listing.stdout
    stats=run('host-cli-stats',cli+['vela-memory','stats','--agent','main'],consumer)
    assert '"namespace":"main"' in stats.stdout and '"observedRecords":0' in stats.stdout
    search=run('host-cli-search',cli+['vela-memory','search','synthetic','--agent','main'],consumer)
    assert '"items":[]' in search.stdout
    tests=run('host-hook-tests',['node','--test',str(root/'sdk/openclaw/test/plugin.test.mjs')],consumer,{'VELA_TEST_PLUGIN':(installed/'dist/index.js').as_uri(),'VELA_TEST_HELPER':str(helper),'VELA_TEST_OPENCLAW_ROOT':str(host)})
    passed=re.search(r'(?:#|ℹ) pass (\d+)',tests.stdout);assert passed and int(passed.group(1))>=7
    # Actual host agent turn with a synthetic loopback model transport. This
    # verifies the emitted provider payload; it is not a model quality test.
    received=[]
    class FixtureModel(BaseHTTPRequestHandler):
        def log_message(self,*args):pass
        def do_POST(self):
            size=int(self.headers.get('content-length','0'))
            if size<1 or size>2097152:self.send_error(413);return
            body=json.loads(self.rfile.read(size));received.append(body)
            value={'id':'synthetic-response','object':'chat.completion.chunk','created':1,'model':'synthetic','choices':[{'index':0,'delta':{'role':'assistant','content':'Synthetic fixture confirms the provider transport completed.'},'finish_reason':None}]}
            end={'id':'synthetic-response','object':'chat.completion.chunk','created':1,'model':'synthetic','choices':[{'index':0,'delta':{},'finish_reason':'stop'}]}
            if len(received)==1:
                value['choices'][0]['delta']={'role':'assistant','tool_calls':[{'index':0,'id':'synthetic-memory-call','type':'function','function':{'name':'memory_store','arguments':json.dumps({'text':'Synthetic tool-selected observation belongs to the main namespace candidate queue.'})}}]}
                end['choices'][0]['finish_reason']='tool_calls'
            data=('data: '+json.dumps(value)+'\n\ndata: '+json.dumps(end)+'\n\ndata: [DONE]\n\n').encode()
            self.send_response(200);self.send_header('Content-Type','text/event-stream');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
    server=ThreadingHTTPServer(('127.0.0.1',0),FixtureModel);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        def rpc(method,params):
            call=subprocess.run([str(helper),'rpc','--no-watch','--no-schedule','--home',config['home']],input=json.dumps({'id':1,'method':method,'params':params})+'\n',env=env,capture_output=True,text=True,timeout=30)
            assert call.returncode==0
            response=next(json.loads(line) for line in call.stdout.splitlines() if json.loads(line).get('id')==1)
            assert 'error' not in response,response
            return response['result']
        evidence='SQLite CedarNamespaceBoundary uses WAL for local durability.'
        rpc('memory.save',{'id':'host-turn-evidence','project':str(project),'scope':'namespace','namespace':'main','private':False,'state':'active','title':'SQLite policy','content':evidence})
        rpc('memory.save',{'id':'host-turn-foreign','project':str(project),'scope':'namespace','namespace':'other','private':False,'state':'active','title':'SQLite foreign','content':'SQLite ForbiddenForeignNamespace must not enter the main prompt.'})
        hostconfig=json.loads(configpath.read_text());hostconfig['plugins']['entries']['vela-memory']['config']['autoCapture']=True
        hostconfig['agents']={'defaults':{'workspace':str(project),'skipBootstrap':True,'model':{'primary':'fixture/synthetic'},'timeoutSeconds':30},'entries':{'main':{'workspace':str(project)}}}
        hostconfig['models']={'mode':'replace','providers':{'fixture':{'baseUrl':f'http://127.0.0.1:{server.server_port}/v1','apiKey':'synthetic-local-only','api':'openai-completions','models':[{'id':'synthetic','name':'Synthetic local fixture','input':['text'],'contextWindow':32768,'maxTokens':1024}]}}}
        hostconfig['tools']={'allow':['memory_search','memory_store']}
        hostconfig['skills']={'allowBundled':[],'load':{'extraDirs':[],'watch':False}}
        configpath.write_text(json.dumps(hostconfig))
        question='Please retrieve the SQLite policy for this isolated project workspace.'
        turn=run('host-agent-turn',cli+['agent','--local','--agent','main','--session-id','vela-synthetic-acceptance','--message',question,'--json','--timeout','30'],consumer)
        assert len(received)==2,f'Unexpected model calls: {len(received)}'
        wire=json.dumps(received[0],ensure_ascii=False)
        assert evidence in wire and '<vela-memories' in wire and 'ForbiddenForeignNamespace' not in wire
        toolnames={tool.get('function',{}).get('name') for tool in received[0].get('tools',[])}
        assert toolnames=={'memory_search','memory_store'},toolnames
        assert any(message.get('role')=='tool' and 'candidate' in json.dumps(message) for message in received[1]['messages'])
        captures=[item for item in rpc('memory.list',{'project':str(project)}) if item.get('provenance',{}).get('origin')=='integration-capture']
        assert len(captures)==2 and all(item['state']=='candidate' and item['namespace']=='main' for item in captures),captures
        assert any(question in item['content'] for item in captures)
        toolnote=next(item for item in captures if 'Synthetic tool-selected' in item['content'])
        assert toolnote['provenance']['integrationIdentity']['role']=='assistant'
        (out/'host-turn-result.json').write_text(json.dumps({'hostAgentTurn':True,'provider':'synthetic_loopback_fixture','providerCalls':len(received),'actualPromptContainsSelectedNamespaceEvidence':True,'actualPromptExcludesForeignNamespace':True,'actualToolExecution':'memory_store','actualAgentEndCapturedCandidates':1,'actualToolCapturedCandidates':1,'realModelQuality':'not_tested','existingUserAccounts':'not_used','providerRequestSHA256':hashlib.sha256(wire.encode()).hexdigest()},indent=2))
    finally:server.shutdown();server.server_close();thread.join(timeout=2)
    package=next(path for path in packages if 'openclaw' in path.name)
    with tarfile.open(package) as archive:members=archive.getnames()
    assert set(members)=={'package/package.json','package/LICENSE','package/README.md','package/openclaw.plugin.json','package/dist/index.js','package/dist/index.d.ts','package/dist/journal.js','package/dist/safety.js'}
    shutil.copy2(package,out/package.name)
    (out/'package-results.json').write_text(json.dumps({'testsPassed':int(passed.group(1)),'hostVersion':'2026.9.4','hostPackageSHA256':sha(host/'package.json'),'hostHookRunnerSHA256':sha(host/'dist/hook-runner-global-BhDCl4qm.mjs'),'hostPluginLoader':True,'hostCLI':True,'hostHookRunner':True,'installedConsumerTypecheck':True,'helperSHA256':sha(helper),'packageSHA256':sha(package),'members':members,'modelTurn':'actual_host_with_synthetic_loopback_provider','realModelQuality':'not_tested','remoteEncryptedRoundtrip':'not_run','temporaryInstallStoresAndCacheRemovedOnExit':True},indent=2))
    print(f'Installed OpenClaw plugin: {passed.group(1)} tests; real host loader/CLI/hook runner; isolated helper.')
