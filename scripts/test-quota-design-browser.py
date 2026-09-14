#!/usr/bin/env python3
"""Real-helper browser acceptance for the quota display, using only a synthetic
Codex ``app-server --stdio`` executable.  It never reads an account, token, or
user CODEX_HOME.  Every case creates a new direct child of .task-tmp through
create-ui-fixture.py, seeds its status via usage.quota.read, and serves that
persisted result through the normal read-only UI bridge.

Do not run until a frozen UI is supplied.  The test deliberately does not
pretend that a 300-second age-based ``status=stale`` is instant: the immediate
stale case is a real failed refresh retaining a real earlier snapshot.
"""
from __future__ import annotations
import argparse, hashlib, importlib.util, json, os, select, shutil, signal, subprocess, sys, time, traceback
from pathlib import Path
from release_resources import copy_ui_resources, validate_ui_resources

ROOT = Path(__file__).resolve().parents[1]
PLAYWRIGHT = ROOT / '.task-tmp/ui-browser-tools/node_modules/playwright/index.js'
CASES = ('neverread', 'fresh0', 'fresh100', 'null', 'reset-missing', 'expired', 'stale-error')

def sha(path: Path) -> str: return hashlib.sha256(path.read_bytes()).hexdigest()

def require_new_child(path: Path) -> Path:
    path = path.absolute(); tmp = (ROOT / '.task-tmp').resolve()
    if path.parent.resolve() != tmp or path.exists() or path.is_symlink():
        raise ValueError('each quota fixture must be a new direct non-symlink child of .task-tmp')
    return path

def provider(path: Path, response: dict) -> None:
    # The synthetic secret proves that raw provider output and process
    # environment do not leak into the saved status or receipt.
    code = '''#!/usr/bin/python3
import json, os, sys
assert sys.argv[1:] == ['app-server','--stdio']
assert 'SYNTHETIC_API_TOKEN' not in os.environ
first=json.loads(sys.stdin.readline()); assert first['method']=='initialize'
assert first['params']['clientInfo']['name']=='vela'
print(json.dumps({'id':1,'result':{}}),flush=True)
assert json.loads(sys.stdin.readline())=={'method':'initialized'}
assert json.loads(sys.stdin.readline())=={'id':2,'method':'account/rateLimits/read'}
print(RESPONSE,flush=True)
'''.replace('RESPONSE', repr(json.dumps(response, separators=(',', ':'))))
    path.write_text(code); path.chmod(0o700)

def good(used=None, duration=300, reset=2_000_000_000) -> dict:
    primary = None if used is None else {'usedPercent': used, 'windowDurationMins': duration, 'resetsAt': reset}
    return {'id': 2, 'result': {'rateLimitsByLimitId': {'synthetic': {'limitId': 'synthetic-window', 'limitName': 'Synthetic window', 'primary': primary, 'secondary': None}}, 'account': {'email':'SYNTHETIC_SECRET'}}}

def response_for(case: str) -> tuple[dict | None, dict | None]:
    if case == 'neverread': return None, None
    if case == 'fresh0': return good(0), None
    if case == 'fresh100': return good(100), None
    if case == 'null': return good(None), None
    if case == 'reset-missing': return good(50, duration=300, reset=None), None
    if case == 'expired': return good(25, duration=300, reset=1), None
    if case == 'stale-error':
        return good(30), {'id':2, 'error': {'code':-32000, 'message':'Not logged in SYNTHETIC_SECRET'}}
    raise ValueError(case)

def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--ui-directory', type=Path, required=True, help='Frozen UI directory')
    p.add_argument('--binary', type=Path, required=True, help='Frozen real Vela helper')
    p.add_argument('--fixture-prefix', type=Path, required=True, help='New .task-tmp direct-child prefix; case suffixes are added')
    p.add_argument('--output', type=Path, required=True, help='New output directory')
    p.add_argument('--browser-executable', type=Path, required=True)
    p.add_argument('--checks', help='Optional comma-separated subset of: ' + ','.join(CASES))
    p.add_argument('--keep-fixtures', action='store_true')
    a = p.parse_args(); ui=a.ui_directory.resolve(strict=True); binary=a.binary.resolve(strict=True); out=a.output.absolute()
    if ui.is_symlink() or binary.is_symlink() or not binary.is_file() or not a.browser_executable.is_file(): p.error('inputs must be ordinary frozen paths')
    validate_ui_resources(ui, allow_development=True)
    chosen=tuple(a.checks.split(',')) if a.checks else CASES
    if not chosen or any(item not in CASES for item in chosen): p.error('unknown --checks case')
    if out.exists() or out.is_symlink(): p.error('--output must be new')
    prefix=a.fixture_prefix.absolute(); require_new_child(prefix.with_name(prefix.name + '-' + chosen[0]))
    if not PLAYWRIGHT.is_file(): p.error('pinned Playwright is unavailable; this test will not install it')
    spec=importlib.util.spec_from_file_location('ui_driver', ROOT/'scripts/test-ui-browser.py'); module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    out.mkdir(parents=True); evidence={'format':'vela-quota-design-browser-v1','synthetic':True,'providerRuns':0,'userCredentialsAccessed':False,'modelCalls':0,'uiSHA256':{x.name:sha(x) for x in ui.iterdir() if x.is_file()},'helperSHA256':sha(binary),'cases':[],'limitations':['Pure stale requires actual snapshot age above 300 seconds; stale-error below is an immediate real failed read retaining the prior snapshot.'],'completeSuite':set(chosen)==set(CASES)}
    driver=None; failure=None
    def save(): (out/'results.json').write_text(json.dumps(evidence,ensure_ascii=False,indent=2)+'\n')
    def close(proc):
        if not proc: return True
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGTERM)
            try: proc.wait(timeout=5)
            except subprocess.TimeoutExpired: os.killpg(proc.pid,signal.SIGKILL); proc.wait(timeout=5)
        return proc.returncode is not None
    try:
      # One browser process, one page at a time; server/fixture lifecycle stays case-local.
      driver=subprocess.Popen(['node','-e',module.PLAYWRIGHT_DRIVER,str(PLAYWRIGHT),str(a.browser_executable)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,start_new_session=True)
      def browser(*args):
        driver.stdin.write(json.dumps(args)+'\n'); driver.stdin.flush()
        if not select.select([driver.stdout],[],[],15)[0]: raise TimeoutError('browser driver timeout')
        result=json.loads(driver.stdout.readline())
        if 'error' in result: raise AssertionError(result['error'])
        return result['output']
      def value(expr): return json.loads(json.loads(browser('eval','JSON.stringify('+expr+')')))
      for case in chosen:
        base=prefix.with_name(prefix.name+'-'+case); require_new_child(base); row={'case':case,'fixture':str(base),'passed':False}; server=None
        try:
          made=subprocess.run(['python3',str(ROOT/'scripts/create-ui-fixture.py'),str(base),'--binary',str(binary),'--with-routing-project'],cwd=ROOT,text=True,capture_output=True,timeout=120)
          (out/(case+'-fixture.log')).write_text(made.stdout+made.stderr); made.check_returncode()
          fx=json.loads((base/'fixture.json').read_text()); copy_ui_resources(ui, base/'ui-snapshot', allow_development=True)
          helper=base/'synthetic-codex'; first,second=response_for(case)
          env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','VELA_HOME':fx['home'],'VELA_SESSION_ROOT':fx['sessionRoot'],'VELA_DISABLE_DISCOVERY':'1','CODEX_HOME':str(base/'empty-codex-home'),'SYNTHETIC_API_TOKEN':'must-not-forward'}
          def direct(method, params):
            done=subprocess.run([str(binary),'call',method,json.dumps(params),'--home',fx['home']],cwd=base,env=env,text=True,capture_output=True,timeout=30)
            if done.returncode: raise RuntimeError(method+': '+(done.stderr or done.stdout))
            return json.loads(done.stdout)
          if first:
            provider(helper,first); status=direct('usage.quota.read',{'provider':'codex','executable':str(helper)}); evidence['providerRuns']+=1
            if second:
              provider(helper,second); status=direct('usage.quota.read',{'provider':'codex','executable':str(helper)}); evidence['providerRuns']+=1
          else: status=direct('usage.quota.status',{'provider':'codex'})
          if (base/'empty-codex-home').exists() or 'SYNTHETIC_SECRET' in json.dumps(status): raise AssertionError('synthetic credential boundary was breached')
          row['status']=status; row['statusSHA256']=hashlib.sha256(json.dumps(status,sort_keys=True).encode()).hexdigest()
          server=subprocess.Popen(['python3',str(ROOT/'scripts/test-ui-server.py'),str(base/'fixture.json'),'--binary',str(binary),'--ui-directory',str(base/'ui-snapshot')],cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
          ready, _, _ = select.select([server.stdout, server.stderr], [], [], 15)
          if server.stderr in ready:
            line = server.stderr.readline().strip()
            if line:
              (out / (case + '-bridge.stderr')).write_text(line + '\n')
              raise RuntimeError('test bridge failed before ready: ' + line)
          if server.stdout not in ready:
            raise RuntimeError('test bridge did not start within 15 seconds')
          ready_line = server.stdout.readline().strip()
          if not ready_line:
            stderr = server.stderr.read().strip()
            (out / (case + '-bridge.stderr')).write_text(stderr + '\n')
            raise RuntimeError('test bridge exited before ready: ' + stderr)
          address=json.loads(ready_line)['url']; browser('open',address); browser('click','.nav-link[data-page="usage"]'); browser('click','[data-usagetab="quota"]'); browser('wait','#btn-refresh-codex-quota')
          observed=value("(()=>{const rows=[...document.querySelectorAll('.quota-window-row')],meters=[...document.querySelectorAll('.quota-bar-track[role=\"meter\"]')];return {rows:rows.length,meters:meters.map(x=>x.getAttribute('aria-valuenow')),remaining:rows.map(x=>x.querySelector('.quota-remaining strong')?.textContent?.trim()||''),empty:!!document.querySelector('.quota-empty'),history:!!document.querySelector('.quota-history-note'),resetPassed:!!document.querySelector('.quota-reset-note'),error:!!document.querySelector('.quota-error'),connectionOpen:document.querySelector('.quota-connection')?.open===true,refresh:!!document.querySelector('#btn-refresh-codex-quota'),input:!!document.querySelector('#codex-cli-path-input')};})()")
          if not observed['refresh'] or not observed['input']: raise AssertionError('quota refresh controls missing')
          if case=='neverread' and not(observed['empty'] and observed['connectionOpen'] and not observed['meters']): raise AssertionError('never-read must be unavailable and connection-expanded, never a zero meter')
          if case=='fresh0' and observed['meters']!=['100']: raise AssertionError('0 used must render actual 100 remaining meter')
          if case=='fresh100' and observed['meters']!=['0']: raise AssertionError('100 used must render actual 0 remaining meter')
          if case=='null' and (observed['meters'] or observed['rows']): raise AssertionError('null primary window must remain unavailable; it must not fabricate a 0/100 meter')
          if case=='reset-missing' and observed['meters']!=['50']: raise AssertionError('missing reset must preserve observed 50 remaining rather than erase it')
          if case=='expired' and (observed['meters']!=['75'] or not observed['resetPassed']): raise AssertionError('expired window must show its reset-passed evidence, not be presented as current quota')
          if case=='stale-error' and not(observed['meters']==['70'] and observed['history'] and observed['error']): raise AssertionError('failed refresh must retain prior real snapshot and label it historical/error')
          row['observed']=observed; browser('screenshot',str(out/(case+'.png'))); row['passed']=True
        except Exception as err:
          row['error']=traceback.format_exc(); failure=err
        finally:
          row['serverStopped']=close(server); row['fixtureRemoved']=False
          if base.exists() and not a.keep_fixtures:
            shutil.rmtree(base); row['fixtureRemoved']=not base.exists()
          evidence['cases'].append(row); save()
          if failure: raise failure
      browser('close'); driver=None
    except Exception:
      evidence['error']=traceback.format_exc(); failure=True
    finally:
      if driver: close(driver)
      evidence['passed']=not failure and all(row.get('passed') and row.get('serverStopped') and (row.get('fixtureRemoved') or a.keep_fixtures) for row in evidence['cases'])
      save()
    return 0 if evidence['passed'] else 1
if __name__=='__main__': raise SystemExit(main())
