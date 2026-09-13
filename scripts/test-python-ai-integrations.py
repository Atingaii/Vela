"""Verify installed Python Responses wrappers with real SDK HTTP/SSE and helper."""
import datetime,hashlib,json,os,re,shutil,subprocess,sys,tempfile,zipfile
from pathlib import Path
root=Path(__file__).resolve().parents[1]
base_sdk=Path(os.environ.get('VELA_PYTHON_AI_BASE_SDK',root/'sdk/python')).resolve(strict=True)
out=Path(os.environ.get('VELA_PYTHON_AI_TEST_OUTPUT',root/'sdk/python-ai/evidence'/('installed-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S'))));out.mkdir(parents=True,exist_ok=True)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
with tempfile.TemporaryDirectory(prefix='vela-python-ai-installed-') as temporary:
 scratch=Path(temporary);venv=scratch/'venv';subprocess.run([sys.executable,'-m','venv',str(venv)],check=True);python=venv/'bin/python'
 selected_helper=Path(os.environ.get('VELA_PYTHON_AI_HELPER',root/'.build/debug/vela')).resolve(strict=True)
 helper=scratch/'vela';shutil.copy2(selected_helper,helper)
 env={**os.environ,'PIP_CACHE_DIR':str(scratch/'pip-cache'),'VELA_DISABLE_DISCOVERY':'1','VELA_TEST_HELPER':str(helper),'PYTHONNOUSERSITE':'1'}
 def run(label,args,cwd=scratch):
  result=subprocess.run(args,cwd=cwd,env=env,text=True,capture_output=True,timeout=180)
  (out/(label+'.log')).write_text(result.stdout+result.stderr)
  if result.returncode:print(result.stdout+result.stderr);result.check_returncode()
  return result
 wheels=scratch/'wheels';wheels.mkdir()
 for package in ['python','python-ai']:
  stage=scratch/package;stage.mkdir()
  source=base_sdk if package=='python' else root/'sdk'/package
  for file in ['LICENSE','README.md','pyproject.toml']:shutil.copy2(source/file,stage/file)
  shutil.copytree(source/'src',stage/'src',ignore=shutil.ignore_patterns('__pycache__','*.pyc','*.egg-info'))
  run(package+'-wheel',[str(python),'-m','pip','wheel','--no-deps','--wheel-dir',str(wheels),str(stage)])
 packages=sorted(wheels.glob('*.whl'))
 for package in packages:
  with zipfile.ZipFile(package) as archive:
   members=archive.namelist()
  module='vela_ai/' if 'engineering_ai-' in package.name else 'vela/'
  allowed={module+x for x in (['_common.py','_sync.py','_async.py','__init__.py','py.typed'] if module=='vela_ai/' else ['__init__.py','py.typed'])}
  assert all(n in allowed or ('.dist-info/' in n and n.rsplit('/',1)[-1] in {'METADATA','WHEEL','top_level.txt','RECORD','LICENSE'}) for n in members),members
 run('consumer-install',[str(python),'-m','pip','install',*[str(p) for p in packages]])
 tests=run('actual-responses-tests',[str(python),str(root/'sdk/python-ai/tests/test_responses.py')])
 output=tests.stdout+tests.stderr;matched=re.search(r'Ran (\d+) tests',output);assert matched and int(matched.group(1))>=30
 compatibility=run('local-python-sdk-tests',[str(python),'-m','unittest','discover','-s',str(base_sdk/'tests'),'-p','test_*.py','-v'])
 prior=re.search(r'Ran (\d+) tests',compatibility.stdout+compatibility.stderr);assert prior and int(prior.group(1))>=11
 run('consumer-imports',[str(python),'-c','import openai,vela,vela_ai; print(openai.__version__); print(vela.__file__); print(vela_ai.__file__); assert openai.__version__ == "3.13.0"'])
 run('dependencies',[str(python),'-m','pip','freeze','--all'])
 legacy_record={'state':'not_run','reason':'Select an actual retained wheel with VELA_PYTHON_AI_LEGACY_SDK.'}
 if os.environ.get('VELA_PYTHON_AI_LEGACY_SDK'):
  legacy=Path(os.environ['VELA_PYTHON_AI_LEGACY_SDK']).resolve(strict=True);legacy_venv=scratch/'legacy-venv'
  run('legacy-venv',[sys.executable,'-m','venv',str(legacy_venv)])
  older=legacy_venv/'bin/python';wrapper=next(p for p in packages if 'engineering_ai-' in p.name)
  run('legacy-install',[str(older),'-m','pip','install',str(legacy),str(wrapper)])
  legacy_tests=run('legacy-tests',[str(older),str(root/'sdk/python-ai/tests/test_legacy_sdk.py')])
  matched_legacy=re.search(r'Ran (\d+) tests?',legacy_tests.stdout+legacy_tests.stderr);assert matched_legacy and int(matched_legacy.group(1))==1
  legacy_record={'state':'passed','testsPassed':1,'packageSHA256':sha(legacy),'packagePath':str(legacy)}
 entries=[]
 for package in packages:shutil.copy2(package,out/package.name);entries.append({'name':package.name,'sha256':sha(package),'bytes':package.stat().st_size})
 receipt={'format':'vela-python-responses-installed-v1','artifactDirectory':str(out.resolve()),'testsPassed':int(matched.group(1)),'baseSDKCompatibilityTests':int(prior.group(1)),'baseSDKSourceDirectory':str(base_sdk),'legacySDKCompatibility':legacy_record,'actualOpenAIPython':'3.13.0','pythonVersion':sys.version.split()[0],'provider':'synthetic_loopback_http_sse','helperSHA256':sha(helper),'selectedHelper':str(selected_helper),'helperSourceManifestSHA256':sha(Path(os.environ['VELA_PYTHON_AI_SOURCE_MANIFEST'])) if os.environ.get('VELA_PYTHON_AI_SOURCE_MANIFEST') else None,'packages':entries,'realModelQuality':'not_tested','remoteMemory':'not_used','existingUserAccounts':'not_used','temporaryConsumerHelperStoresAndCacheRemovedOnExit':True}
 (out/'package-results.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt))
