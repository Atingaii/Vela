#!/usr/bin/env python3
"""Create a new, synthetic fixture for ``test-desktop-design-browser.mjs``.

The fixture contains no user data and must be a new direct child of ``.task-tmp``.
It delegates baseline creation to ``create-ui-fixture.py``, then creates the
long-title workflows and full frozen approval through the actual Vela CLI. It
also copies declared renderer resources to the fixture-owned ``ui-snapshot``.

Example:
  python3 scripts/create-desktop-design-fixture.py .task-tmp/desktop-design-r3 \
    --binary .build/debug/vela --ui-directory .task-tmp/frozen-ui/UI
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

from release_resources import copy_ui_resources, validate_ui_resources

ROOT = Path(__file__).resolve().parents[1]


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('fixture', type=Path, help='New immediate .task-tmp child')
    parser.add_argument('--binary', type=Path, required=True, help='Frozen real Vela helper')
    parser.add_argument('--ui-directory', type=Path, required=True, help='Frozen declared UI source directory')
    args = parser.parse_args()

    fixture = args.fixture.absolute()
    tmp = (ROOT / '.task-tmp').resolve()
    if fixture.parent.resolve() != tmp or fixture.exists() or fixture.is_symlink():
        parser.error('fixture must be a new, non-symlink direct child of repository .task-tmp.')
    binary = args.binary.resolve(strict=True)
    ui = args.ui_directory.resolve(strict=True)
    if binary.is_symlink() or not binary.is_file():
        parser.error('--binary must be an ordinary frozen executable.')
    if ui.is_symlink() or not ui.is_dir():
        parser.error('--ui-directory must be an ordinary frozen directory.')
    validate_ui_resources(ui, allow_development=True)

    # This script owns the new fixture directory only; the baseline creator is
    # deliberately the existing real-CLI fixture path.
    subprocess.run([sys.executable, str(ROOT / 'scripts/create-ui-fixture.py'), str(fixture),
                    '--binary', str(binary), '--with-routing-project'], check=True, timeout=90)
    fixture = fixture.resolve(strict=True)
    manifest = json.loads((fixture / 'fixture.json').read_text())
    project = Path(manifest['project']).resolve(strict=True)
    beacon = Path(manifest['routingProject']).resolve(strict=True)
    store = Path(manifest['store']).resolve(strict=True)
    sources = Path(manifest['sessionRoot']).resolve(strict=True)
    copy_ui_resources(ui, fixture / 'ui-snapshot', allow_development=True)

    environment = {
        'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
        'VELA_HOME': str(store),
        'VELA_SESSION_ROOT': str(sources),
        'VELA_DISABLE_DISCOVERY': '1',
        'GIT_CONFIG_NOSYSTEM': '1',
        'GIT_CONFIG_GLOBAL': os.devnull,
    }

    def call(method: str, params: dict) -> dict | list:
        completed = subprocess.run([str(binary), 'call', method, json.dumps(params, ensure_ascii=False),
                                    '--home', str(store)], cwd=project, env=environment,
                                   text=True, capture_output=True, timeout=30)
        if completed.returncode:
            raise RuntimeError(f'{method} failed: {completed.stderr or completed.stdout}')
        return json.loads(completed.stdout)

    # Both titles remain below the real 240-byte title boundary but force the
    # renderer's CJK/no-space overflow paths. Their source is persisted through
    # workflows.save; no renderer state or DOM is changed here.
    chinese_title = '工作流标题' + '甲乙丙丁戊己庚辛壬癸' * 7
    english_title = 'WorkflowTitleWithoutAnySpaces' + 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789' * 5
    description = ('This exact fixture description is deliberately long enough to wrap through more than two '
                   'visual lines in the normal workflow list, while remaining ordinary persisted workflow metadata. ') * 3
    if len(chinese_title.encode()) > 240 or len(english_title.encode()) > 240:
        raise RuntimeError('fixture title exceeds the product title byte limit.')
    steps = [{'title': 'Inspect status', 'tool': 'git.status', 'arguments': {}}]
    zh = call('workflows.save', {'project': str(project), 'title': chinese_title, 'description': description,
                                 'trigger': 'manual', 'steps': steps})
    en = call('workflows.save', {'project': str(project), 'title': english_title, 'description': description,
                                 'trigger': 'manual', 'steps': steps})
    all_projects = call('workflows.save', {
        'project': str(beacon), 'title': 'All projects definition scope check',
        'description': 'Persisted Beacon definition used only to verify all-projects scope identity.',
        'trigger': 'manual', 'steps': steps,
    })
    # Provider-shaped source that the real helper ingests. The literal tag is
    # fixture input only; browser checks must prove it remains inert text.
    tool_title = 'Synthetic command rendering safety check'
    tool_command = "printf '<img src=x onerror=window.__vela_design_tool_xss=1>'"
    tool_arguments = json.dumps({'cmd': tool_command}, separators=(',', ':'))
    tool_log = sources / 'codex' / 'design-tool-command.jsonl'
    tool_rows = [
        {'type': 'session_meta', 'timestamp': '2026-09-14T06:00:00Z',
         'payload': {'id': 'design-tool-command-session', 'cwd': str(project), 'git': {'branch': 'main'}}},
        {'type': 'response_item', 'timestamp': '2026-09-14T06:00:01Z',
         'payload': {'id': 'design-tool-user', 'type': 'message', 'role': 'user',
                     'content': [{'type': 'input_text', 'text': tool_title}]}},
        {'type': 'response_item', 'timestamp': '2026-09-14T06:00:02Z',
         'payload': {'id': 'design-tool-call', 'type': 'function_call', 'name': 'exec_command',
                     'arguments': tool_arguments}},
    ]
    tool_log.write_text(''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in tool_rows))
    call('sessions.refresh', {})
    tool_session = next((row for row in call('sessions.list', {'project': str(project)})
                         if row.get('sourceSessionId') == 'design-tool-command-session'), None)
    if not tool_session:
        raise RuntimeError('real helper did not ingest synthetic command source session.')
    source = ('DESIGN_APPROVAL_SOURCE_BEGIN\n' +
              ('exact synthetic approval source line: preserve all frozen bytes for reviewer visibility.\n' * 60) +
              'DESIGN_APPROVAL_SOURCE_END\n')
    approval_workflow = call('workflows.save', {
        'project': str(project), 'title': 'Full approval source design check',
        'description': 'Synthetic pending approval with complete source disclosure.', 'trigger': 'manual',
        'steps': [{'title': 'Write full synthetic source', 'tool': 'file.write',
                   'arguments': {'path': 'docs/design-full-source.md', 'content': source}}],
    })
    run = call('workflows.run', {'id': approval_workflow['id'], 'dryRun': False})
    if run.get('state') != 'pending_approval':
        raise RuntimeError(f'expected pending_approval, received {run.get("state")!r}.')
    approvals = call('inbox.list', {})
    approval = next((row for row in approvals if row.get('runId') == run['id']), None)
    if not approval:
        raise RuntimeError('pending full-source approval was not returned by the real helper.')

    contract = {
        'format': 'vela-desktop-design-fixture-contract-v2', 'synthetic': True,
        'workflowLongChinese': {'id': zh['id'], 'project': str(project), 'title': chinese_title, 'description': description},
        'workflowLongEnglish': {'id': en['id'], 'project': str(project), 'title': english_title, 'description': description},
        'allProjectsWorkflow': {'id': all_projects['id'], 'project': str(beacon), 'title': all_projects['title']},
        'approval': {'id': approval['id'], 'sourceText': source},
        'toolCommand': {'sessionId': tool_session['id'], 'title': tool_title, 'name': 'exec_command',
                        'command': tool_command, 'input': tool_arguments,
                        'rawRecord': '[Tool: exec_command]\n' + tool_arguments,
                        'sourceSHA256': sha(tool_log)},
        'workflowIcons': {'gitIDs': [zh['id'], en['id']], 'writeID': approval_workflow['id']},
        'harnessTranscript': str(fixture / 'harness-rpc.jsonl'),
    }
    contract_path = fixture / 'design-fixture-contract.json'
    contract_path.write_text(json.dumps(contract, ensure_ascii=False, indent=2) + '\n')
    receipt = {
        'format': 'vela-desktop-design-fixture-setup-v1', 'synthetic': True,
        'createdThrough': ['scripts/create-ui-fixture.py', 'vela call workflows.save', 'vela call workflows.run', 'vela call sessions.refresh'],
        'helperPath': str(binary), 'helperSHA256': sha(binary),
        'uiSourceSHA256': {entry.name: sha(entry) for entry in sorted((fixture / 'ui-snapshot').iterdir()) if entry.is_file()},
        'workflowIDs': [zh['id'], en['id'], all_projects['id'], approval_workflow['id']],
        'pendingRunID': run['id'], 'approvalID': approval['id'], 'sourceBytes': len(source.encode()),
        'toolSource': {'sessionID': tool_session['id'], 'path': str(tool_log), 'sha256': sha(tool_log),
                       'commandBytes': len(tool_command.encode())},
        'contractSHA256': sha(contract_path),
    }
    (fixture / 'design-fixture-setup.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'fixture': str(fixture), 'manifest': str(fixture / 'fixture.json'),
                      'contract': str(contract_path), 'receipt': str(fixture / 'design-fixture-setup.json')}, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
