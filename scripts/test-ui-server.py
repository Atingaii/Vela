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
import re
import secrets
import signal
import stat
import subprocess
import threading
import time
from urllib.parse import urlsplit

from release_resources import DEVELOPMENT_UI_RESOURCES, UI_RESOURCES, validate_ui_resources

ROOT = Path(__file__).resolve().parents[1]
UI = ROOT / 'Sources/VelaApp/Resources/UI'
READ = set('dashboard.get projects.list agents.list sessions.refresh sessions.list sessions.get setup.list setup.scan setup.audit usage.get memory.list recall search guidelines.list library.list checkpoint.list checkpoint.export workflows.list workflows.health runs.list runs.get inbox.list improve.list improve.preview lab.list lab.compare regression.list evidence.get reuse.outcomes settings.get system.version'.split())
READ.update('memory.archive.export memory.archive.validate memory.semantic.status workflows.plan.get workflows.plan.list improve.model.describe improve.model.list improve.model.get daemon.status daemon.plan schedules.list usage.quota.status connectors.status connectors.action.list connectors.action.get outputs.list outputs.get outputs.inbox'.split())
READ.update('setup.catalog setup.get setup.history setup.diff setup.relations workflows.get workflows.validate loops.describe loops.get loops.list ask.describe ask.get ask.list ask.citations'.split())
READ.add('setup.edit.get')
READ.update('library.get library.history library.export library.index.status library.search watches.describe watches.get watches.preview'.split())
READ.update('history.describe history.sources history.get history.jobs history.page history.raw history.branch sessions.plan.describe sessions.plan.get sessions.plan.events sessions.relations.describe sessions.relations.get sessions.relations.children sessions.relations.events sessions.relations.resolve'.split())
READ.add('memory.capture.prepare')
READ.update('runs.feedback.prepare runs.feedback.get runs.feedback.list runs.feedback.history.list runs.feedback.history.get'.split())
READ.update('workflows.health.proposal.get workflows.health.proposal.list'.split())
WRITE = set('projects.add memory.save memory.transition guidelines.save library.add checkpoint.save workflows.build workflows.save workflows.run approvals.decide improve.analyze improve.apply improve.undo lab.run lab.promote reuse.preview settings.save'.split())
WRITE.update('memory.archive.import memory.semantic.index outputs.markRead'.split())
WRITE.update('workflows.clone workflows.setEnabled workflows.remove workflows.restore loops.plan loops.cancel ask.create ask.followup ask.cancel'.split())
WRITE.update('setup.edit.preview setup.edit.prepare setup.edit.undo'.split())
WRITE.update('library.update library.remove library.restore library.index'.split())
WRITE.update('history.discover history.start history.advance history.pause history.resume history.cancel'.split())
WRITE.add('memory.capture')
WRITE.add('runs.feedback.record')
WRITE.update('workflows.health.proposeTimeout workflows.health.proposal.decide'.split())
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


def fixture_paths(path, native_temporary_root=None):
    supplied = path.absolute()
    if supplied.is_symlink():
        raise ValueError('Fixture manifest must not be a symbolic link.')
    manifest = supplied.resolve(strict=True)
    base = manifest.parent
    if native_temporary_root is None:
        if not base.is_relative_to((ROOT / '.task-tmp').resolve()) or manifest.name != 'fixture.json':
            raise ValueError('Use a new create-ui-fixture.py fixture below repository .task-tmp.')
    else:
        supplied_root = Path(native_temporary_root).absolute()
        if supplied_root.is_symlink():
            raise ValueError('Native temporary root must not be a symbolic link.')
        native_root = supplied_root.resolve(strict=True)
        root_stat = native_root.stat()
        if (supplied_root.parent != Path('/private/tmp')
                or native_root != supplied_root
                or native_root.parent != Path('/private/tmp')
                or not re.fullmatch(r'vela-native-qa-[a-z0-9]{8,64}', native_root.name)
                or native_root.is_symlink()
                or not native_root.is_dir()
                or root_stat.st_uid != os.getuid()
                or stat.S_IMODE(root_stat.st_mode) != 0o700):
            raise ValueError('Native temporary root must be a current-user 0700 /private/tmp/vela-native-qa-<random> directory.')
        if supplied.parent != base or base.parent != native_root or base.is_symlink() or manifest.name != 'fixture.json':
            raise ValueError('Native QA fixture must be a direct ordinary child of its native temporary root.')
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
    marker_path = Path(data['home']) / '.vela-ui-fixture.json'
    if marker_path.is_symlink():
        raise ValueError('Fixture ownership marker must not be a symbolic link.')
    marker = json.loads(marker_path.read_text())
    if marker != {'format': 'vela-ui-fixture-v1', 'synthetic': True, 'manifest': str(manifest)}:
        raise ValueError('Missing fixture ownership marker.')
    return data, base


class Bridge:
    def __init__(self, binary, fixture, base):
        self.fixture, self.base = fixture, base
        self.events, self.next_id, self.failed = 0, 0, False
        self.lock, self.responses = threading.Lock(), queue.Queue(maxsize=64)
        # Renderer-visible approvals are cached only as the frozen identity shown
        # by a real helper response.  A decision must not call inbox.list first:
        # that read may itself expire an otherwise displayed approval.
        self.displayed_approvals = {}
        # Edit preview/prepare calls are admitted only after a real, fixture
        # scoped setup.edit.get response.  This is deliberately separate from
        # generic approval caching: setup.file.edit is never a generic tool.
        self.setup_edits = {}
        self.transcript = base / 'harness-rpc.jsonl'
        env = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LANG': 'en_US.UTF-8',
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
            result = response.get('result')
            # Cache only the exact frozen approval identity that was already
            # rendered by a real helper response. Ask detail deliberately reads
            # its pending approval through ask.get rather than pre-reading
            # inbox.list (which could advance expiry projection).
            rows = result if method == 'inbox.list' and isinstance(result, list) else result.get('approvals', []) if method == 'dashboard.get' and isinstance(result, dict) else []
            if method == 'ask.get' and isinstance(result, dict) and isinstance(result.get('approval'), dict):
                rows = [*rows, result['approval']]
            for row in rows:
                if not isinstance(row, dict) or row.get('project') not in self.fixture['projects']:
                    continue
                if not all(isinstance(row.get(key), str) and row.get(key) for key in ('id', 'project', 'snapshotHash', 'tool')) or not isinstance(row.get('arguments'), dict):
                    continue
                self.displayed_approvals[row['id']] = json.loads(json.dumps({key: row[key] for key in ('id', 'project', 'snapshotHash', 'tool', 'arguments')}))
            return result

    def displayed_approval_for_decision(self, params):
        if set(params) != {'id', 'decision', 'snapshotHash'} or params.get('decision') not in ('approve', 'reject'):
            raise ValueError('Approval decision has an unsupported shape.')
        approval = self.displayed_approvals.get(params.get('id'))
        if not approval or approval.get('project') not in self.fixture['projects']:
            raise ValueError('Unknown fixture approval.')
        if params.get('snapshotHash') != approval.get('snapshotHash'):
            raise ValueError('Approval snapshot does not match the renderer-visible fixture approval.')
        return approval

    def cache_displayed_approval(self, row):
        if (not isinstance(row, dict) or row.get('project') not in self.fixture['projects']
                or not all(isinstance(row.get(key), str) and row.get(key)
                           for key in ('id', 'project', 'snapshotHash', 'tool'))
                or not isinstance(row.get('arguments'), dict)):
            raise ValueError('Setup edit did not return a usable fixture approval.')
        self.displayed_approvals[row['id']] = json.loads(json.dumps(
            {key: row[key] for key in ('id', 'project', 'snapshotHash', 'tool', 'arguments')}))

    def setup_edit_get(self, params):
        if set(params) != {'project', 'artifactId'} or params.get('project') not in self.fixture['projects']:
            raise ValueError('Setup edit lookup requires an explicit fixture project and artifact id.')
        if not isinstance(params.get('artifactId'), str) or not params['artifactId']:
            raise ValueError('Setup edit artifact id is invalid.')
        result = self.rpc('setup.edit.get', params)
        if not isinstance(result, dict) or result.get('project') != params['project'] or result.get('artifactId') != params['artifactId']:
            raise ValueError('Setup edit lookup returned a different fixture artifact.')
        relative = result.get('relativePath')
        if not isinstance(relative, str) or not relative or Path(relative).is_absolute():
            raise ValueError('Setup edit lookup returned an unsafe relative path.')
        self.local_path(relative, params['project'])
        return result

    def setup_edit_request(self, method, params):
        required = {'project', 'artifactId', 'baseHash', 'sourceIdentity', 'content'}
        if set(params) != required or params.get('project') not in self.fixture['projects']:
            raise ValueError('Setup edit preview and prepare require their exact frozen request shape.')
        if (not isinstance(params.get('artifactId'), str) or not params['artifactId']
                or not isinstance(params.get('baseHash'), str) or not params['baseHash']
                or not isinstance(params.get('sourceIdentity'), dict)
                or not isinstance(params.get('content'), str)
                or len(params['content'].encode()) > 65536):
            raise ValueError('Setup edit request has invalid fixture fields.')
        current = self.setup_edit_get({'project': params['project'], 'artifactId': params['artifactId']})
        if current.get('editable') is not True:
            raise ValueError('This fixture setup artifact is not editable.')
        if (params['baseHash'] != current.get('baseHash')
                or params['sourceIdentity'] != current.get('sourceIdentity')):
            raise ValueError('Setup edit request no longer matches the real fixture source.')
        self.setup_edits[(params['project'], params['artifactId'])] = json.loads(json.dumps({
            'relativePath': current['relativePath'], 'baseHash': params['baseHash'],
            'sourceIdentity': params['sourceIdentity'], 'content': params['content'],
        }))
        result = self.rpc(method, params)
        if not isinstance(result, dict) or result.get('project') != params['project'] or result.get('artifactId') != params['artifactId']:
            raise ValueError('Setup edit response does not belong to the requested fixture artifact.')
        if method == 'setup.edit.prepare':
            approval = result.get('approval')
            expected = {'editId', 'artifactId', 'relativePath', 'baseHash', 'sourceIdentity',
                        'before', 'content', 'afterHash'}
            if (not isinstance(approval, dict) or approval.get('tool') != 'setup.file.edit'
                    or set(approval.get('arguments', {})) != expected
                    or approval['arguments'].get('artifactId') != params['artifactId']
                    or approval['arguments'].get('relativePath') != current['relativePath']
                    or approval['arguments'].get('baseHash') != params['baseHash']
                    or approval['arguments'].get('sourceIdentity') != params['sourceIdentity']
                    or approval['arguments'].get('content') != params['content']):
                raise ValueError('Setup edit approval does not freeze the reviewed fixture request.')
            self.cache_displayed_approval(approval)
            self.setup_edits[(params['project'], params['artifactId'])]['approvalId'] = approval['id']
            self.setup_edits[(params['project'], params['artifactId'])]['arguments'] = json.loads(json.dumps(approval['arguments']))
        return result

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

    def lab_recall_request(self, params):
        if not isinstance(params,dict) or params.get('project') != self.fixture['project'] or params.get('kind') != 'memory': raise ValueError('Lab Recall must use the Harbor fixture.')
        allowed={'title','project','kind','agent','task','verificationCommand','verificationFiles','outputFiles','timeoutSeconds','repetitions','baseline','candidate','sourceSuggestionId'}
        if not set(params).issubset(allowed): raise ValueError('Lab Recall request has unsupported fields.')
        if 'sourceSuggestionId' in params:
            source = params.get('sourceSuggestionId')
            suggestions = self.rpc('improve.list', {})
            if not isinstance(source, str) or not any(row.get('id') == source and row.get('project') == self.fixture['project'] for row in suggestions):
                raise ValueError('Lab Recall source suggestion must belong to the Harbor fixture.')
        agent=params.get('agent'); path=self.base/'synthetic-lab-recall-agent.py'
        recall_agent = {'provider':'codex','executable':str(path),'model':'fixed-local-jsonl','reasoningEffort':'high'}
        if agent != recall_agent:
            # The legacy acceptance case creates only a pending approval. Its
            # approval gate below still rejects every Agent execution.
            legacy_agent = {'provider':'codex','executable':'/usr/bin/true','model':'fixture-no-provider-execution','reasoningEffort':'high'}
            if agent != legacy_agent: raise ValueError('Lab fixture only permits its fixed synthetic or pending-only Agent.')
            if params.get('verificationCommand') != ['/usr/bin/printf', '', 'argument with spaces', 'quote"argument'] or params.get('verificationFiles') != ['tests/parser.test.mjs'] or params.get('outputFiles') != ['src/parser.mjs'] or params.get('timeoutSeconds') != 10 or params.get('repetitions') != 3: raise ValueError('Pending-only Lab fixture command differs.')
            for side in ('baseline','candidate'):
                value = params.get(side)
                if not isinstance(value,dict) or not set(value).issubset({'files','label','context','memoryIds'}): raise ValueError('Pending-only Lab variant is invalid.')
            return
        if path.is_symlink() or not path.is_file(): raise ValueError('Lab Recall only permits its owned synthetic agent.')
        if params.get('verificationCommand') != ['/usr/bin/python3','verify.py'] or params.get('verificationFiles') != ['verify.py'] or params.get('outputFiles') != ['observed-context.txt'] or params.get('timeoutSeconds') != 20 or params.get('repetitions') != 1: raise ValueError('Lab Recall fixture command differs.')
        for side in ('baseline','candidate'):
            v=params.get(side); recall=v.get('recall') if isinstance(v,dict) else None
            if not isinstance(v,dict) or not set(v).issubset({'files','label','context','memoryIds','recall'}) or v.get('files') != [] or ('memoryIds'in v and not isinstance(v['memoryIds'],list)) or (recall is not None and(not isinstance(recall,dict) or not set(recall).issubset({'enabled','strictOff','query','mode','scope','budget'}))): raise ValueError('Lab Recall variant is invalid.')

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
        if method == 'setup.edit.get':
            return self.setup_edit_get(params)
        if method in ('setup.edit.preview', 'setup.edit.prepare'):
            return self.setup_edit_request(method, params)
        if method == 'setup.edit.undo':
            if (set(params) != {'project', 'artifactId', 'journalId'}
                    or params.get('project') not in self.fixture['projects']
                    or not isinstance(params.get('artifactId'), str) or not params['artifactId']
                    or not isinstance(params.get('journalId'), str) or not params['journalId']):
                raise ValueError('Setup edit undo requires exact fixture project, artifact, and journal identities.')
            current = self.setup_edit_get({'project': params['project'], 'artifactId': params['artifactId']})
            if current.get('editable') is not True:
                raise ValueError('This fixture setup artifact is not editable.')
            return self.rpc(method, params)
        if method.startswith('runs.feedback.'):
            project = params.get('project')
            if project not in self.fixture['projects']:
                raise ValueError('Run feedback requires the actual isolated project.')
            exact = {'runs.feedback.prepare': {'project','runId'}, 'runs.feedback.record': {'project','runId','runHash','previousFeedbackHash','outcome','reason'}, 'runs.feedback.get': {'project','id'}, 'runs.feedback.history.get': {'project','id'}}
            if method in exact and set(params) != exact[method]: raise ValueError('Run feedback request does not match its frozen shape.')
            if method in ('runs.feedback.list','runs.feedback.history.list'):
                allowed={'project','runId','limit','cursor'}
                if not {'project'} <= set(params) <= allowed: raise ValueError('Run feedback list has unsupported fields.')
                if 'limit' in params and (type(params['limit']) is not int or not 1 <= params['limit'] <= 100): raise ValueError('Run feedback list limit must be an integer from 1 to 100.')
                if 'cursor' in params and (type(params['cursor']) is not str or not params['cursor'] or len(params['cursor'].encode()) > 2048): raise ValueError('Run feedback cursor is invalid.')
            if method == 'runs.feedback.record':
                if params['outcome'] not in ('good','bad','clear') or type(params['reason']) is not str or not params['reason'].strip() or len(params['reason'].encode()) > 1000 or any(ord(x)<32 or ord(x)==127 for x in params['reason']): raise ValueError('Run feedback outcome or reason is invalid.')
                import re
                if not isinstance(params['runHash'],str) or not re.fullmatch(r'[a-f0-9]{64}',params['runHash']): raise ValueError('Run feedback hash is invalid.')
                prior=params['previousFeedbackHash']
                if prior is not None and (not isinstance(prior,str) or not re.fullmatch(r'[a-f0-9]{64}',prior)): raise ValueError('Run feedback previous hash is invalid.')
            record = None
            if method in ('runs.feedback.get','runs.feedback.history.get'):
                record = self.rpc(method,params)
                run_id = record.get('runId')
            else: run_id = params.get('runId')
            if run_id:
                run = self.rpc('runs.get', {'id':run_id})
                if run.get('project') != project or (record and record.get('project') != project): raise ValueError('Run feedback must use run.actualproject.')
        if method in ('memory.capture.prepare', 'memory.capture'):
            fields = {'project', 'sessionId', 'messageId'}
            if method == 'memory.capture':
                fields |= {'sourceIdentity', 'expectedSourceHash'}
            if set(params) != fields or params.get('project') not in self.fixture['projects']:
                raise ValueError('Session capture requires an exact request in an explicit isolated project.')
        if method.startswith('workflows.health.'):
            if params.get('project') not in self.fixture['projects']:
                raise ValueError('Health proposals require an explicit isolated project.')
            if method == 'workflows.health.proposal.get':
                if set(params) != {'project', 'id'}:
                    raise ValueError('Health proposal lookup requires project and id only.')
            elif method == 'workflows.health.proposal.list':
                if (not {'project'} <= set(params) <= {'project', 'limit'}
                        or type(params.get('limit', 50)) is not int
                        or not 1 <= params.get('limit', 50) <= 100):
                    raise ValueError('Health proposal list requires a bounded fixture request.')
            elif method == 'workflows.health.proposeTimeout':
                fields = {'project', 'workflowId', 'workflowVersion', 'snapshotHash',
                          'runId', 'stepId', 'findingId', 'newTimeoutSeconds'}
                if (set(params) != fields or type(params.get('newTimeoutSeconds')) is not int
                        or not 1 <= params['newTimeoutSeconds'] <= 300):
                    raise ValueError('Health timeout proposals require exact frozen evidence.')
                inspected = self.rpc('workflows.get', {'project': params['project'], 'id': params['workflowId']})
                definition = inspected.get('definition', {})
                if (definition.get('project') != params['project']
                        or definition.get('version') != params['workflowVersion']
                        or inspected.get('snapshotHash') != params['snapshotHash']):
                    raise ValueError('Health proposal must match the current fixture workflow.')
                health = self.rpc('workflows.health', {'project': params['project'], 'id': params['workflowId']})
                if not any(f.get('code') == 'timeout_observed' and f.get('id') == params['findingId']
                           and f.get('runId') == params['runId'] and f.get('stepId') == params['stepId']
                           for f in health.get('findings', [])):
                    raise ValueError('Health proposal must match an actual fixture timeout finding.')
            elif method == 'workflows.health.proposal.decide':
                required = {'project', 'id', 'proposalHash', 'decision'}
                allowed = required | {'acknowledgeUncertainSource'}
                decision = params.get('decision')
                if (not required <= set(params) <= allowed or decision not in ('accept', 'reject', 'recover')
                        or ('acknowledgeUncertainSource' in params
                            and (decision != 'accept' or type(params['acknowledgeUncertainSource']) is not bool))):
                    raise ValueError('Health proposal decision has unsupported fields or acknowledgement.')
                proposal = self.rpc('workflows.health.proposal.get', {'project': params['project'], 'id': params['id']})
                if proposal.get('proposalHash') != params['proposalHash']:
                    raise ValueError('Health proposal does not match the reviewed fixture evidence.')
                if decision == 'recover' and proposal.get('state') != 'accepting':
                    raise ValueError('Only an interrupted fixture proposal may be recovered.')
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
        if method == 'lab.run': self.lab_recall_request(params)
        if method == 'lab.promote':
            evaluation = self.rpc('lab.compare', {'id': params.get('id')})
            if evaluation.get('project') not in self.fixture['projects']:
                raise ValueError('Only a fixture evaluation may be reviewed.')
        if method == 'approvals.decide':
            approval = self.displayed_approval_for_decision(params)
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
            elif tool == 'setup.file.edit':
                expected = {'editId', 'artifactId', 'relativePath', 'baseHash', 'sourceIdentity',
                            'before', 'content', 'afterHash'}
                arguments = approval['arguments']
                matching = next((value for value in self.setup_edits.values()
                                 if value.get('approvalId') == approval['id']), None)
                if (not matching or set(arguments) != expected
                        or arguments != matching.get('arguments')
                        or not isinstance(arguments.get('relativePath'), str)
                        or Path(arguments['relativePath']).is_absolute()):
                    raise ValueError('Setup edit approval is not the exact cached fixture request.')
                self.local_path(arguments['relativePath'], approval['project'])
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
        try:
            validate_ui_resources(candidate, allow_development=True)
        except ValueError as error:
            raise ValueError('Frozen UI resources must be declared ordinary files: ' + str(error)) from error
        ui_directory = candidate
    else:
        validate_ui_resources(ui_directory, allow_development=True)
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
                path = path or 'index.html'
                allowed = set(UI_RESOURCES) | set(DEVELOPMENT_UI_RESOURCES)
                if path not in allowed:
                    raise ValueError('Not a declared test UI resource.')
                types = {
                    '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
                    '.mjs': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
                    '.svg': 'image/svg+xml', '.json': 'application/json', '.license': 'text/plain; charset=utf-8', '.woff2': 'font/woff2',
                    '.woff': 'font/woff', '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
                    '.gif': 'image/gif', '.webp': 'image/webp',
                }
                mime = types.get(Path(path).suffix.lower())
                if not mime:
                    raise ValueError('Unsupported declared UI resource type.')
                body = (ui_directory / path).read_bytes()
                if path == 'index.html':
                    body = body.replace(b"connect-src 'none'", b"connect-src 'self'").replace(
                        b'</head>', b'<script src="__bridge.js"></script></head>', 1)
                self.respond(body, mime)
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
