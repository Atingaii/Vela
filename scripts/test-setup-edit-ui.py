"""Run the real Setup edit renderer journey against frozen UI and helper inputs.

The browser consumer is intentionally separate. This wrapper owns only its new
fixture and output/playwright evidence directory, freezes allowed UI resources
and the helper into that fixture, launches the strict fixture-only bridge, and
retains every subprocess receipt. It never opens a normal Vela store.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys
import traceback

from release_resources import DEVELOPMENT_UI_RESOURCES, UI_RESOURCES, copy_ui_resources

ROOT = Path(__file__).resolve().parents[1]
UI_FILES = UI_RESOURCES + DEVELOPMENT_UI_RESOURCES
HARNESS_FILES = (
    'test-setup-edit-ui.py',
    'test-setup-edit-browser.mjs',
    'test-ui-server.py',
    'create-ui-fixture.py',
    'test-ui-browser.py',
)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def checked_new_fixture(path: Path) -> Path:
    value = path.absolute()
    parent = (ROOT / '.task-tmp').resolve()
    if value.exists() or value.is_symlink() or value.parent.resolve() != parent:
        raise ValueError('fixture must be a new, non-symlink immediate child of repository .task-tmp')
    return value


def checked_new_output(path: Path) -> Path:
    value = path.absolute()
    parent = (ROOT / 'output' / 'playwright').resolve()
    if value.exists() or value.is_symlink() or value.parent.resolve() != parent:
        raise ValueError('output must be a new, non-symlink immediate child of output/playwright')
    return value


def terminate_owned_group(label: str, process: subprocess.Popen | None, evidence: dict, timeout: float = 8) -> bool:
    """Stop one process group this wrapper created without losing its receipt."""
    status = evidence.setdefault('processGroupCleanup', {}).setdefault(label, {
        'started': process is not None,
        'stopped': False,
    })
    if process is None:
        return False
    try:
        if process.poll() is not None:
            status['alreadyExited'] = True
            status['stopped'] = True
            return True
        os.killpg(process.pid, signal.SIGTERM)
        status['terminationSignal'] = 'SIGTERM'
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            status['terminationSignal'] = 'SIGKILL'
            process.wait(timeout=timeout)
        status['stopped'] = process.poll() is not None
        if not status['stopped']:
            raise RuntimeError('owned process group remained alive after termination')
        return True
    except ProcessLookupError:
        # A child may exit between poll and signal. That is a confirmed stop,
        # not a reason to discard the otherwise useful failure receipt.
        status['alreadyExited'] = process.poll() is not None
        status['stopped'] = status['alreadyExited']
        if status['stopped']:
            return True
        status['error'] = 'owned process group disappeared but process is still live'
        evidence.setdefault('cleanupErrors', {})[label] = status['error']
        return False
    except Exception as error:
        status['error'] = str(error)
        evidence.setdefault('cleanupErrors', {})[label] = str(error)
        return False


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ui-directory', type=Path, required=True, help='Frozen UI directory.')
    parser.add_argument('--binary', type=Path, required=True, help='Frozen real helper binary.')
    parser.add_argument('--fixture', type=Path, required=True, help='New immediate .task-tmp child; removed after the run.')
    parser.add_argument('--output', type=Path, required=True, help='New output/playwright child retained as evidence.')
    parser.add_argument('--browser-executable', type=Path, required=True, help='Explicit browser executable.')
    parser.add_argument('--timeout-seconds', type=int, default=300, help='Bound for the one browser consumer (60..900).')
    args = parser.parse_args()
    if not 60 <= args.timeout_seconds <= 900:
        parser.error('--timeout-seconds must be between 60 and 900')
    try:
        fixture = checked_new_fixture(args.fixture)
        output = checked_new_output(args.output)
        ui_source = args.ui_directory.resolve(strict=True)
        helper_source = args.binary.resolve(strict=True)
    except (ValueError, FileNotFoundError) as error:
        parser.error(str(error))
    if not helper_source.is_file() or helper_source.is_symlink():
        parser.error('binary must be a regular frozen helper file')
    if not args.browser_executable.is_file() or args.browser_executable.is_symlink():
        parser.error('browser executable must be a regular file')
    if not shutil.which('node'):
        parser.error('Node.js is required for the renderer consumer')
    for name in UI_FILES:
        candidate = ui_source / name
        if not candidate.is_file() or candidate.is_symlink():
            parser.error('UI allowlist file missing or linked: ' + name)
    for name in HARNESS_FILES:
        candidate = ROOT / 'scripts' / name
        if not candidate.is_file() or candidate.is_symlink():
            parser.error('harness source missing or linked: ' + name)

    output.mkdir(parents=True)
    # The Node consumer deliberately creates its output directory with
    # `recursive:false`; keep its browser artifacts in a new child while this
    # wrapper owns the parent lifecycle receipt and server logs.
    browser_output = output / 'browser'
    evidence = {
        'format': 'vela-setup-edit-renderer-wrapper-v1',
        'synthetic': True,
        'nativeClaimed': False,
        'realProviderExecuted': False,
        'userWorkflowExecuted': False,
        'projectScriptsExecuted': False,
        'setupFileWritesExpected': True,
        'completeSuite': False,
        'fixtureDirectory': str(fixture),
        'outputDirectory': str(output),
        'browserOutputDirectory': str(browser_output),
        'browserExecutable': str(args.browser_executable.resolve()),
        'timeoutSeconds': args.timeout_seconds,
        'sourceHashes': {name: digest(ROOT / 'scripts' / name) for name in HARNESS_FILES},
        'uiSourceBefore': {name: digest(ui_source / name) for name in UI_FILES},
        'helperSourceSHA256': digest(helper_source),
        'fixtureRemoved': False,
        'cleanupErrors': {},
        'passed': False,
    }
    (output / 'wrapper-source.py').write_bytes(Path(__file__).read_bytes())
    (output / 'consumer-test-source.mjs').write_bytes((ROOT / 'scripts' / 'test-setup-edit-browser.mjs').read_bytes())
    server = consumer = None
    fixture_created = False
    failure = None

    def write_log(name: str, text: str) -> None:
        (output / name).write_text(text, encoding='utf-8')

    def save() -> None:
        (output / 'results.json').write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')

    try:
        made = subprocess.run(
            [sys.executable, str(ROOT / 'scripts' / 'create-ui-fixture.py'), str(fixture), '--binary', str(helper_source)],
            capture_output=True, text=True, timeout=120, cwd=ROOT,
        )
        write_log('fixture-creation.log', made.stdout + made.stderr)
        fixture_created = (fixture / 'store' / '.vela-ui-fixture.json').is_file()
        made.check_returncode()
        manifest = fixture / 'fixture.json'
        fixture_data = json.loads(manifest.read_text(encoding='utf-8'))
        if fixture_data.get('format') != 'vela-ui-fixture-v1' or fixture_data.get('synthetic') is not True:
            raise AssertionError('fixture creator did not produce the synthetic UI fixture contract')
        if Path(fixture_data.get('project', '')).resolve(strict=True).parent != fixture.resolve(strict=True):
            raise AssertionError('fixture project escaped the owned fixture root')

        snapshot = fixture / 'ui-snapshot'
        copy_ui_resources(ui_source, snapshot, allow_development=True)
        helper = fixture / 'vela-frozen'
        shutil.copy2(helper_source, helper)
        if helper.is_symlink():
            raise AssertionError('frozen helper became a symlink')
        evidence['uiFixtureSHA256'] = {name: digest(snapshot / name) for name in UI_FILES}
        evidence['helperFixtureSHA256'] = digest(helper)
        if evidence['uiSourceBefore'] != evidence['uiFixtureSHA256']:
            raise AssertionError('frozen UI does not exactly match the supplied UI input')
        if evidence['helperSourceSHA256'] != evidence['helperFixtureSHA256']:
            raise AssertionError('frozen helper does not exactly match the supplied helper input')

        server = subprocess.Popen(
            [sys.executable, str(ROOT / 'scripts' / 'test-ui-server.py'), str(manifest), '--binary', str(helper), '--ui-directory', str(snapshot)],
            cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
        )
        if not select.select([server.stdout], [], [], 20)[0]:
            raise AssertionError('strict fixture server did not start within 20 seconds')
        first_line = server.stdout.readline()
        startup = json.loads(first_line)
        url = startup.get('url')
        if not isinstance(url, str) or not url.startswith('http://127.0.0.1:'):
            raise AssertionError('fixture server returned an unsafe or invalid URL')
        evidence['serverURL'] = url

        output_argument = str(browser_output.relative_to(ROOT))
        fixture_argument = str(manifest.relative_to(ROOT))
        snapshot_argument = str(snapshot.relative_to(ROOT))
        child_env = dict(os.environ, VELA_BROWSER_EXECUTABLE=str(args.browser_executable.resolve()))
        consumer = subprocess.Popen(
            ['node', str(ROOT / 'scripts' / 'test-setup-edit-browser.mjs'), url, output_argument, fixture_argument, snapshot_argument],
            cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True, env=child_env,
        )
        try:
            consumer_stdout, consumer_stderr = consumer.communicate(timeout=args.timeout_seconds)
        except subprocess.TimeoutExpired:
            terminate_owned_group('consumer', consumer, evidence)
            consumer_stdout, consumer_stderr = consumer.communicate()
            write_log('consumer.stdout.log', consumer_stdout)
            write_log('consumer.stderr.log', consumer_stderr)
            evidence['consumerExitCode'] = consumer.returncode
            raise AssertionError(f'Setup edit browser consumer exceeded {args.timeout_seconds} seconds')
        write_log('consumer.stdout.log', consumer_stdout)
        write_log('consumer.stderr.log', consumer_stderr)
        evidence['consumerExitCode'] = consumer.returncode
        browser_result = browser_output / 'results.json'
        if browser_result.is_file() and not browser_result.is_symlink():
            shutil.copy2(browser_result, output / 'browser-results.json')
            browser_data = json.loads((output / 'browser-results.json').read_text(encoding='utf-8'))
            evidence['browserResultSHA256'] = digest(output / 'browser-results.json')
            evidence['browserPassed'] = browser_data.get('passed') is True
            evidence['browserCheckCount'] = len(browser_data.get('checks', []))
            evidence['browserErrors'] = browser_data.get('errors', [])
        else:
            evidence['browserPassed'] = False
            evidence['browserErrors'] = ['consumer did not retain results.json']
        if consumer.returncode != 0:
            raise AssertionError('Setup edit browser consumer failed; inspect consumer logs and browser-results.json')
        if evidence.get('browserPassed') is not True:
            raise AssertionError('Setup edit browser consumer did not report a complete passing result')
        evidence['uiSourceAfter'] = {name: digest(ui_source / name) for name in UI_FILES}
        evidence['helperSourceAfterSHA256'] = digest(helper_source)
        evidence['harnessSourceAfter'] = {name: digest(ROOT / 'scripts' / name) for name in HARNESS_FILES}
        evidence['sourceUnchanged'] = (
            evidence['uiSourceBefore'] == evidence['uiSourceAfter'] == evidence['uiFixtureSHA256']
            and evidence['helperSourceSHA256'] == evidence['helperSourceAfterSHA256'] == evidence['helperFixtureSHA256']
            and evidence['sourceHashes'] == evidence['harnessSourceAfter']
        )
        if not evidence['sourceUnchanged']:
            raise AssertionError('UI, helper, or browser harness changed during the run')
        evidence['completeSuite'] = True
    except Exception as error:
        failure = error
        evidence['error'] = str(error)
        evidence['traceback'] = traceback.format_exc(limit=8)
    finally:
        terminate_owned_group('consumer', consumer, evidence)
        if consumer is not None:
            try:
                stdout, stderr = consumer.communicate(timeout=1)
                if stdout and not (output / 'consumer.stdout.log').exists():
                    write_log('consumer.stdout.log', stdout)
                if stderr and not (output / 'consumer.stderr.log').exists():
                    write_log('consumer.stderr.log', stderr)
            except Exception as error:
                evidence['cleanupErrors']['consumerLogs'] = str(error)
        terminate_owned_group('server', server, evidence)
        if server is not None:
            try:
                stdout, stderr = server.communicate(timeout=1)
                write_log('server.stdout.log', (first_line if 'first_line' in locals() else '') + stdout)
                write_log('server.stderr.log', stderr)
            except Exception as error:
                evidence['cleanupErrors']['serverLogs'] = str(error)
        for name in ('fixture.json', 'harness-rpc.jsonl'):
            source = fixture / name
            if source.is_file() and not source.is_symlink():
                shutil.copy2(source, output / name)
                evidence.setdefault('retainedEvidenceSHA256', {})[name] = digest(output / name)
        marker = fixture / 'store' / '.vela-ui-fixture.json'
        if fixture_created and marker.is_file() and not marker.is_symlink():
            expected_marker = {'format': 'vela-ui-fixture-v1', 'synthetic': True, 'manifest': str(fixture / 'fixture.json')}
            try:
                if json.loads(marker.read_text(encoding='utf-8')) == expected_marker:
                    shutil.rmtree(fixture)
                    evidence['fixtureRemoved'] = True
                else:
                    evidence['fixtureCleanupRefused'] = 'ownership marker differed'
            except Exception as error:
                evidence['cleanupErrors']['fixtureRoot'] = str(error)
        evidence['fixtureRootCleanup'] = {
            'ownedMarkerVerified': fixture_created,
            'removed': evidence['fixtureRemoved'],
        }
        evidence['cleanupConfirmed'] = (
            all(evidence.get('processGroupCleanup', {}).get(name, {}).get('started') and
                evidence['processGroupCleanup'][name].get('stopped')
                for name in ('consumer', 'server'))
            and evidence['fixtureRootCleanup']['removed'] is True
        )
        evidence['cleanupNoErrors'] = not evidence['cleanupErrors']
        evidence['passed'] = (
            failure is None and evidence.get('completeSuite') is True
            and evidence['cleanupConfirmed'] and evidence['cleanupNoErrors']
        )
        save()
    if failure is not None or not evidence['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
