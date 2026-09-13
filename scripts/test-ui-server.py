"""Test-only renderer -> real CLI bridge; never serve a normal Vela store.

Create a fresh scripts/create-ui-fixture.py fixture below .task-tmp first, then:
  python3 scripts/test-ui-server.py .task-tmp/ui-fixture/fixture.json
Native dialogs/notification delivery are not tested here. Only fixture-local
file.write and Git read workflows may run; arbitrary command tools are refused.
The URL is an ephemeral capability. RPC evidence stays beside the fixture.
"""
import argparse
import http.server
import json
import os
from pathlib import Path
import queue
import secrets
import signal
import subprocess
import threading
import time
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
UI = ROOT / 'Sources/VelaApp/Resources/UI'
READ = set('dashboard.get projects.list agents.list sessions.refresh sessions.list sessions.get setup.list setup.scan setup.audit usage.get memory.list recall search guidelines.list library.list checkpoint.list checkpoint.export workflows.list workflows.health runs.list runs.get inbox.list improve.list improve.preview lab.list lab.compare regression.list evidence.get reuse.outcomes settings.get system.version'.split())
READ.update('memory.archive.export memory.archive.validate memory.semantic.status workflows.plan.get workflows.plan.list improve.model.describe improve.model.list improve.model.get daemon.status daemon.plan schedules.list usage.quota.status connectors.status connectors.action.list connectors.action.get outputs.list outputs.get outputs.inbox'.split())
READ.update('setup.catalog setup.get setup.history setup.diff setup.relations workflows.get workflows.validate loops.describe loops.get loops.list ask.describe ask.get ask.list ask.citations'.split())
READ.update('library.get library.history library.export library.index.status library.search watches.describe watches.get watches.preview'.split())
READ.update('history.describe history.sources history.get history.jobs history.page history.raw history.branch sessions.plan.describe sessions.plan.get sessions.plan.events sessions.relations.describe sessions.relations.get sessions.relations.children sessions.relations.events sessions.relations.resolve'.split())
WRITE = set('projects.add memory.save memory.transition guidelines.save library.add checkpoint.save workflows.build workflows.save workflows.run approvals.decide improve.analyze improve.apply improve.undo lab.run lab.promote reuse.preview settings.save'.split())
WRITE.update('memory.archive.import memory.semantic.index outputs.markRead'.split())
WRITE.update('workflows.clone workflows.setEnabled workflows.remove workflows.restore loops.plan loops.cancel ask.create ask.followup ask.cancel'.split())
WRITE.update('library.update library.remove library.restore library.index'.split())
WRITE.update('history.discover history.start history.advance history.pause history.resume history.cancel'.split())
BRIDGE_JS = """
window.__velaUITest={refreshReceived:0,dashboardResolved:0,dashboardEvent:0,dashboardProject:null,nextRead:null,controlledReads:0};
window.addEventListener('vela:refresh',()=>window.__velaUITest.refreshReceived++);
window.vela={call:async(method,params={})=>{
  const test=window.__velaUITest,event=test.refreshReceived,candidate=test.nextRead;
  const control=candidate&&candidate.method===method&&['dashboard.get','usage.get','memory.archive.validate','memory.semantic.status','memory.semantic.index'].includes(method)&&
    (candidate.project===undefined||candidate.project===(params.project||''))?candidate:null;
  if(control)test.nextRead=null;
  const r=await fetch('__rpc',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({method,params})});
  const j=await r.json();if(j.error)throw Error(j.error);
  if(control){await new Promise(resolve=>setTimeout(resolve,Math.min(Math.max(control.delay||0,0),3000)));test.controlledReads++;
    if(control.fail)throw Error('Injected test-only read failure after real CLI response');}
  if(method==='dashboard.get'){test.dashboardResolved++;test.dashboardEvent=Math.max(event,test.dashboardEvent);test.dashboardProject=params.project||'';}
  return j.result;
}};
let revision=null;
setInterval(async()=>{try{const j=await(await fetch('__events')).json();if(revision!==null&&j.revision!==revision){window.dispatchEvent(new CustomEvent('vela:refresh',{detail:{source:'data.changed'}}));}revision=j.revision;}catch{}},500);
"""


def fixture_paths(path):
    manifest = path.resolve(strict=True)
    base = manifest.parent
    if not base.is_relative_to((ROOT / '.task-tmp').resolve()) or manifest.name != 'fixture.json':
        raise ValueError('Use a new create-ui-fixture.py fixture below repository .task-tmp.')
    data = json.loads(manifest.read_text())
    if data.get('format') != 'vela-ui-fixture-v1' or data.get('synthetic') is not True:
        raise ValueError('Not a synthetic Vela UI fixture.')
    for key, name in [('home', 'store'), ('project', 'Harbor'), ('sessionRoot', 'sources')]:
        value = Path(data[key])
        if value.is_symlink() or value.resolve(strict=True) != base / name:
            raise ValueError('Fixture paths must resolve to the expected isolated directories.')
    projects = data.get('projects', [data['project']])
    if projects not in ([str(base / 'Harbor')], [str(base / 'Harbor'), str(base / 'Beacon')]):
        raise ValueError('Only the generated Harbor/Beacon project allowlist is accepted.')
    if any(Path(p).is_symlink() or Path(p).resolve(strict=True) != Path(p) for p in projects):
        raise ValueError('Fixture project aliases are refused.')
    data['projects'] = projects
    marker = json.loads((Path(data['home']) / '.vela-ui-fixture.json').read_text())
    if marker != {'format': 'vela-ui-fixture-v1', 'synthetic': True, 'manifest': str(manifest)}:
        raise ValueError('Missing fixture ownership marker.')
    return data, base


class Bridge:
    def __init__(self, binary, fixture, base):
        self.fixture, self.base = fixture, base
        self.events, self.next_id, self.failed = 0, 0, False
        self.lock, self.responses = threading.Lock(), queue.Queue(maxsize=64)
        self.transcript = base / 'harness-rpc.jsonl'
        env = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(base), 'LANG': 'en_US.UTF-8',
               'VELA_HOME': fixture['home'], 'VELA_SESSION_ROOT': fixture['sessionRoot'],
               'VELA_DISABLE_DISCOVERY': '1', 'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': os.devnull}
        self.process = subprocess.Popen([str(binary), 'rpc', '--no-schedule', '--home', fixture['home']],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, text=True, env=env, cwd=base)
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        for line in iter(lambda: self.process.stdout.readline(32 * 1024 * 1024), ''):
            try:
                response = json.loads(line)
                if response.get('event') == 'data.changed':
                    self.events += 1
                else:
                    self.responses.put_nowait(response)
            except (ValueError, queue.Full):
                self.failed = True
                return
        self.failed = True

    def rpc(self, method, params):
        with self.lock:
            if self.failed or self.process.poll() is not None:
                raise ValueError('Fixture helper stopped; no automatic action retry.')
            self.next_id += 1
            request = {'id': str(self.next_id), 'method': method, 'params': params}
            self.process.stdin.write(json.dumps(request) + '\n')
            self.process.stdin.flush()
            try:
                response = self.responses.get(timeout=30)
            except queue.Empty:
                self.failed = True
                raise ValueError('Helper timeout; inspect persisted state before restarting.')
            with self.transcript.open('a') as log:
                log.write(json.dumps(dict(request, at=time.time(), ok='error' not in response)) + '\n')
            if response.get('id') != request['id']:
                self.failed = True
                raise ValueError('Unexpected helper response.')
            if 'error' in response:
                raise ValueError(response['error'].get('message', 'CLI error'))
            return response.get('result')

    def local_path(self, value, project=None):
        root = Path(project or self.fixture['project'])
        if str(root) not in self.fixture['projects']:
            raise ValueError('Unknown fixture project.')
        path = Path(value)
        resolved = (path if path.is_absolute() else root / path).resolve()
        if not resolved.is_relative_to(root) or '.git' in resolved.relative_to(root).parts:
            raise ValueError('Only fixture project paths are permitted.')

    def tool(self, tool, arguments, project):
        if not isinstance(arguments, dict):
            raise ValueError('Tool arguments must be an object.')
        if tool in ('git.status', 'git.diff', 'git.log'):
            return
        if tool != 'file.write':
            raise ValueError('Harness only executes Git reads and fixture file.write, never shell/agent tools.')
        self.local_path(arguments.get('path', ''), project)

    def synthetic_provider(self, agent):
        path = self.base / 'synthetic-codex'
        if (not isinstance(agent, dict) or agent.get('executable') != str(path)
                or agent.get('model') != 'synthetic-ui' or path.is_symlink()
                or not path.is_file() or path.read_bytes() != (ROOT / 'scripts/ui-fixture-provider.py').read_bytes()):
            raise ValueError('UI model checks only permit the exact network-free fixture provider.')

    def watch(self, workflow):
        """Permit only fixture-local passive snapshots, with no scheduler."""
        if not workflow or workflow.get('project') not in self.fixture['projects'] or workflow.get('trigger') != 'watch':
            raise ValueError('Watch must belong to the isolated fixture project.')
        policy = workflow.get('watch')
        if not isinstance(policy, dict):
            raise ValueError('Watch policy must be an object.')
        source = policy.get('source', 'tool')
        if source == 'files':
            paths = policy.get('paths')
            if not isinstance(paths, list) or not 1 <= len(paths) <= 16:
                raise ValueError('File watch requires bounded fixture-local paths.')
            for path in paths:
                if not isinstance(path, str) or Path(path).is_absolute():
                    raise ValueError('File watch paths must be relative to the fixture project.')
                self.local_path(path, workflow['project'])
        elif source == 'tool':
            if policy.get('tool') not in ('git.status', 'git.diff', 'git.log', 'memory.recall', 'library.retrieve'):
                raise ValueError('Watch only permits the built-in local read catalog.')
        else:
            raise ValueError('Unknown fixture watch source.')
        # Keep graph/provider/connector execution outside this test surface.
        if workflow.get('pipeline') or workflow.get('context') or not workflow.get('steps'):
            raise ValueError('Fixture watches use explicit Git-read steps only.')
        for step in workflow['steps']:
            if not isinstance(step, dict) or step.get('tool') not in ('git.status', 'git.diff', 'git.log'):
                raise ValueError('Fixture watch steps must be Git reads.')
            self.tool(step['tool'], step.get('arguments', {}), workflow['project'])

    def call(self, method, params):
        if method in ('system.ready', 'system.updateStatus'):
            return True  # Explicit native UI stubs, not claimed as native integration tests.
        if method == 'system.chooseProject':
            return self.fixture['project']
        if method == 'system.info':
            return dict(channel='test', home=self.fixture['home'], version='test-harness', helperRunning=True,
                        testHarness=True, notificationsSupported=False, notificationsStatus='test_stub',
                        launchAtLoginSupported=False, launchAtLoginStatus='test_stub')
        if method not in READ | WRITE:
            raise ValueError('Method not available through the test harness: ' + method)
        if params.get('project') not in [None, '', *self.fixture['projects']]:
            raise ValueError('Project must be the isolated fixture project.')
        if (method.startswith('history.') or method.startswith('sessions.plan.') or method.startswith('sessions.relations.')) and not method.endswith('.describe'):
            if params.get('project') not in self.fixture['projects']:
                raise ValueError('History, plan, and relation operations require an explicit isolated project.')
        if method == 'projects.add' and params.get('path') not in self.fixture['projects']:
            raise ValueError('Only the fixture project may be registered.')
        if method == 'library.add':
            if params.get('url'):
                raise ValueError('Network imports are disabled in UI tests.')
            if params.get('path'):
                self.local_path(params['path'], params.get('project'))
        if method in ('ask.create', 'ask.followup'):
            self.synthetic_provider(params)
        if method == 'loops.plan':
            self.synthetic_provider(params.get('agent'))
            if params.get('tools') != ['git.status']:
                raise ValueError('Synthetic loop checks only permit the actual Git status read.')
        if method in ('workflows.save', 'workflows.run'):
            workflow = params if method.endswith('save') else next(
                (w for w in self.rpc('workflows.list', {}) if w['id'] == params.get('id')), None)
            if method == 'workflows.save' and workflow and workflow.get('trigger') == 'watch':
                self.watch(workflow)
            elif not workflow or workflow.get('project') not in self.fixture['projects'] or workflow.get('trigger', 'manual') != 'manual':
                raise ValueError('Only manual execution or passive watch definitions are permitted; the helper disables scheduling.')
            for step in workflow.get('steps', []):
                if not isinstance(step, dict):
                    raise ValueError('Workflow steps must be objects.')
                self.tool(step.get('tool'), step.get('arguments', {}), workflow['project'])
        if method in ('watches.get', 'watches.preview'):
            workflow = self.rpc('workflows.get', {'id': params.get('id'), 'project': params.get('project')})
            self.watch(workflow.get('definition'))
        if method in ('improve.preview', 'improve.apply', 'improve.undo'):
            suggestion = next((s for s in self.rpc('improve.list', {}) if s['id'] == params.get('id')), None)
            if not suggestion or suggestion.get('project') not in self.fixture['projects']:
                raise ValueError('Only a generated fixture suggestion can be reviewed or applied.')
            for operation in suggestion.get('operations', []):
                self.local_path(operation.get('path', ''), suggestion['project'])
        if method in ('lab.run', 'reuse.preview', 'improve.analyze') and params.get('project') not in self.fixture['projects']:
            raise ValueError('Select an isolated fixture project explicitly.')
        if method == 'lab.promote':
            evaluation = self.rpc('lab.compare', {'id': params.get('id')})
            if evaluation.get('project') not in self.fixture['projects']:
                raise ValueError('Only a fixture evaluation may be reviewed.')
        if method == 'approvals.decide':
            approval = next((a for a in self.rpc('inbox.list', {}) if a['id'] == params.get('id')), None)
            if not approval or approval.get('project') not in self.fixture['projects']:
                raise ValueError('Unknown fixture approval.')
            if params.get('decision') == 'reject':
                # Explicit rejection cannot invoke the reviewed tool. Keep the
                # fixture-project identity gate, including for seeded commands.
                return self.rpc(method, params)
            tool, arguments = approval.get('tool'), approval.get('arguments', {})
            if tool == 'knowledge.answer':
                query = self.rpc('ask.get', {'id': arguments.get('askId'), 'project': approval['project']})
                self.synthetic_provider(query.get('request', {}).get('agent'))
            elif tool == 'agent.loop':
                request = arguments.get('request', {})
                self.synthetic_provider(request.get('agent'))
                if [entry.get('id') for entry in request.get('catalog', [])] != ['git.status']:
                    raise ValueError('Fixture loop catalog changed.')
            else:
                self.tool(tool, arguments, approval['project'])
        return self.rpc(method, params)

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path)
    parser.add_argument('--binary', type=Path, default=ROOT / '.build/debug/vela')
    parser.add_argument('--ui-directory', type=Path, help='Optional frozen UI copy at <fixture>/ui-snapshot; never arbitrary files.')
    args = parser.parse_args()
    fixture, base = fixture_paths(args.manifest)
    ui_directory = UI
    if args.ui_directory:
        candidate = args.ui_directory.absolute()
        if candidate.is_symlink() or candidate.resolve(strict=True) != base / 'ui-snapshot':
            raise ValueError('A frozen UI must be the owned fixture ui-snapshot directory.')
        for name in ('index.html', 'app.js', 'i18n.js', 'app.css', 'app-icon.svg'):
            if (candidate / name).is_symlink() or not (candidate / name).is_file():
                raise ValueError('Frozen UI resources must be ordinary files.')
        ui_directory = candidate
    bridge = Bridge(args.binary.resolve(strict=True), fixture, base)
    prefix = '/' + secrets.token_urlsafe(32) + '/'

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass  # Do not log capability URLs.

        def checked_path(self, post=False):
            origin = 'http://127.0.0.1:' + str(self.server.server_port)
            if self.headers.get('Host') != origin.removeprefix('http://'):
                raise ValueError('Invalid Host.')
            if self.headers.get('Origin') not in ((origin,) if post else (None, origin)):
                raise ValueError('Invalid Origin.')
            if self.headers.get('Sec-Fetch-Site') in ('cross-site', 'same-site'):
                raise ValueError('Cross-site requests refused.')
            path = urlsplit(self.path).path
            if not path.startswith(prefix):
                raise ValueError('Invalid test capability.')
            return path[len(prefix):]

        def respond(self, body, mime='application/json', status=200):
            payload = body if isinstance(body, bytes) else body.encode()
            self.send_response(status)
            self.send_header('Content-Type', mime)
            self.send_header('Content-Length', str(len(payload)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Referrer-Policy', 'no-referrer')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self):
            try:
                path = self.checked_path()
                if path == '__events':
                    return self.respond(json.dumps({'revision': bridge.events}))
                if path == '__bridge.js':
                    return self.respond(BRIDGE_JS, 'text/javascript')
                types = {'index.html': 'text/html; charset=utf-8', 'app.js': 'text/javascript', 'i18n.js': 'text/javascript',
                         'app.css': 'text/css', 'app-icon.svg': 'image/svg+xml'}
                path = path or 'index.html'
                if path not in types:
                    raise ValueError('Not a test UI resource.')
                body = (ui_directory / path).read_bytes()
                if path == 'index.html':
                    body = body.replace(b"connect-src 'none'", b"connect-src 'self'").replace(
                        b'</head>', b'<script src="__bridge.js"></script></head>', 1)
                self.respond(body, types[path])
            except (ValueError, OSError) as error:
                self.respond(json.dumps({'error': str(error)}), status=403)

        def do_POST(self):
            try:
                if self.checked_path(post=True) != '__rpc' or self.headers.get('Content-Type') != 'application/json':
                    raise ValueError('Use the typed test RPC endpoint.')
                size = int(self.headers.get('Content-Length', '0'))
                if not 0 < size <= 2_000_000:
                    raise ValueError('Invalid request size.')
                request = json.loads(self.rfile.read(size))
                if not isinstance(request, dict) or not isinstance(request.get('method'), str) or not isinstance(request.get('params', {}), dict):
                    raise ValueError('Invalid RPC shape.')
                result = bridge.call(request['method'], request.get('params', {}))
                self.respond(json.dumps({'result': result}))
            except (ValueError, TypeError, KeyError, OSError) as error:
                self.respond(json.dumps({'error': str(error)}), status=400)

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    def stop(*_):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, stop)
    print(json.dumps({'url': f'http://127.0.0.1:{server.server_port}{prefix}',
                      'fixture': str(base), 'transcript': str(bridge.transcript), 'nativeStubs': True}), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        bridge.close()

if __name__ == '__main__':
    main()
