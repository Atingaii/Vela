"""Install optional LangChain wheels, then exercise real public host/HTTP/SSE/helper."""
import datetime,hashlib,json,os,re,shutil,subprocess,sys,tempfile,zipfile
from pathlib import Path
root=Path(__file__).resolve().parents[1]
out=Path(os.environ.get('VELA_LANGCHAIN_TEST_OUTPUT',root/'sdk/python-langchain/evidence'/('installed-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S'))));out.mkdir(parents=True,exist_ok=True)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
with tempfile.TemporaryDirectory(prefix='vela-langchain-installed-') as temporary:
 scratch=Path(temporary);venv=scratch/'venv';subprocess.run([sys.executable,'-m','venv',str(venv)],check=True);python=venv/'bin/python'
 selected=Path(os.environ.get('VELA_LANGCHAIN_HELPER',root/'.build/debug/vela')).resolve(strict=True);helper=scratch/'vela';shutil.copy2(selected,helper)
 env={**os.environ,'PIP_CACHE_DIR':str(scratch/'pip-cache'),'VELA_DISABLE_DISCOVERY':'1','VELA_TEST_HELPER':str(helper),'PYTHONNOUSERSITE':'1','PYTHONDONTWRITEBYTECODE':'1','LANGSMITH_TRACING':'false','LANGCHAIN_TRACING_V2':'false','LANGCHAIN_OPENAI_TCP_KEEPALIVE':'0'}
 def run(label,args,cwd=scratch):
  result=subprocess.run(args,cwd=cwd,env=env,text=True,capture_output=True,timeout=240);(out/(label+'.log')).write_text(result.stdout+result.stderr)
  if result.returncode:print(result.stdout+result.stderr);result.check_returncode()
  return result
 stages={};sources={};wheels=scratch/'wheels';wheels.mkdir()
 for package in ['python','python-langchain']:
  stage=scratch/package;stage.mkdir();stages[package]=stage
  for file in ['LICENSE','README.md','pyproject.toml']:
   source=root/'sdk'/package/file;shutil.copy2(source,stage/file);sources[str(source.relative_to(root))]=sha(stage/file)
  for directory in ['src','tests']:
   shutil.copytree(root/'sdk'/package/directory,stage/directory,ignore=shutil.ignore_patterns('__pycache__','*.pyc','*.egg-info'))
   for file in (stage/directory).rglob('*'):
    if file.is_file():sources[str(Path('sdk')/package/file.relative_to(stage))]=sha(file)
  run(package+'-wheel',[str(python),'-m','pip','wheel','--no-deps','--wheel-dir',str(wheels),str(stage)])
 assert all(sha(root/path)==digest for path,digest in sources.items()),'Source changed while staging; use a new evidence run.'
 packages=sorted(wheels.glob('*.whl'));wrapper=next(p for p in packages if 'engineering_langchain-' in p.name)
 for package in packages:
  with zipfile.ZipFile(package) as archive:members=archive.namelist()
  module='vela_langchain/' if package==wrapper else 'vela/'
  allowed={module+x for x in (['_common.py','_sync.py','_async.py','_snapshot.py','_runnable.py','__init__.py','py.typed'] if package==wrapper else ['__init__.py','py.typed'])}
  assert all(n in allowed or ('.dist-info/' in n and n.rsplit('/',1)[-1] in {'METADATA','WHEEL','top_level.txt','RECORD','LICENSE'}) for n in members),members
 run('core-only-consumer-install',[str(python),'-m','pip','install',*[str(p) for p in packages]])
 run('optional-provider-is-not-default',[str(python),'-c','import vela,vela_langchain,importlib.util; assert importlib.util.find_spec("openai") is None; assert importlib.util.find_spec("langchain_openai") is None; print("Base package imports without provider packages.")'])
 run('optional-provider-install',[str(python),'-m','pip','install',str(wrapper)+'[openai]'])
 test=run('actual-langchain-tests',[str(python),str(stages['python-langchain']/'tests/test_langchain.py')]);matched=re.search(r'Ran (\d+) tests',test.stdout+test.stderr);assert matched and int(matched.group(1))>=36
 base=run('base-sdk-tests',[str(python),'-m','unittest','discover','-s',str(stages['python']/'tests'),'-p','test_*.py','-v']);prior=re.search(r'Ran (\d+) tests',base.stdout+base.stderr);assert prior and int(prior.group(1))>=13
 run('consumer-imports',[str(python),'-c','import vela,vela_langchain,langchain_core,langchain_openai,openai; from importlib.metadata import version; assert version("langchain-core")=="1.6.3" and version("langchain-openai")=="1.6.2" and openai.__version__=="3.13.0"; print(vela.__file__); print(vela_langchain.__file__)'])
 run('dependencies',[str(python),'-m','pip','freeze','--all'])
 legacy_record={'state':'not_run','reason':'Set VELA_LANGCHAIN_LEGACY_SDK to a real pre-LangChain wheel.'}
 if os.environ.get('VELA_LANGCHAIN_LEGACY_SDK'):
  legacy=Path(os.environ['VELA_LANGCHAIN_LEGACY_SDK']).resolve(strict=True);oldvenv=scratch/'legacy-venv';run('legacy-venv',[sys.executable,'-m','venv',str(oldvenv)]);oldpython=oldvenv/'bin/python'
  run('legacy-install',[str(oldpython),'-m','pip','install',str(legacy),str(wrapper)+'[openai]'])
  result=run('legacy-tests',[str(oldpython),str(stages['python-langchain']/'tests/test_legacy_sdk.py')]);count=re.search(r'Ran (\d+) tests?',result.stdout+result.stderr);assert count and int(count.group(1))==1
  legacy_record={'state':'passed','testsPassed':1,'packagePath':str(legacy),'packageSHA256':sha(legacy)}
 entries=[]
 for package in packages:
  shutil.copy2(package,out/package.name);entries.append({'name':package.name,'sha256':sha(package),'bytes':package.stat().st_size})
 sources['scripts/test-langchain-integrations.py']=sha(Path(__file__))
 (out/'source-freeze.json').write_text(json.dumps({'sourceSHA256':sources},indent=2)+'\n')
 receipt={'format':'vela-langchain-installed-v1','artifactDirectory':str(out.resolve()),'testsPassed':int(matched.group(1)),'baseSDKTestsPassed':int(prior.group(1)),'legacySDKCompatibility':legacy_record,'coreOnlyImportWithoutOpenAI':True,'langchainCore':'1.6.3','langchainOpenAI':'1.6.2','openai':'3.13.0','pythonVersion':sys.version.split()[0],'provider':'synthetic_loopback_chat_completions_http_sse','helperSHA256':sha(helper),'selectedHelper':str(selected),'helperSourceManifestSHA256':sha(Path(os.environ['VELA_LANGCHAIN_SOURCE_MANIFEST'])) if os.environ.get('VELA_LANGCHAIN_SOURCE_MANIFEST') else None,'packages':entries,'realModelQuality':'not_tested','otherLangChainProviders':'not_tested','remoteMemory':'not_used','existingUserAccounts':'not_used','temporaryConsumerStoresAndDependenciesRemoved':True}
 (out/'package-results.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt))
