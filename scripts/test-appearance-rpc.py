"""Appearance preference contract against the real helper and disposable stores."""
import argparse, hashlib, json, os, subprocess, tempfile
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binary', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
binary = args.binary.resolve(strict=True)
receipt = {'synthetic': True, 'helperSHA256': hashlib.sha256(binary.read_bytes()).hexdigest(), 'checks': []}
env = dict(os.environ, VELA_DISABLE_DISCOVERY='1')
with tempfile.TemporaryDirectory(prefix='vela-appearance-') as directory:
    home = Path(directory) / 'store'
    def invoke(method, params=None, ok=True):
        proc = subprocess.run([str(binary), 'call', method, '--params-stdin', '--home', str(home)],
            input=json.dumps(params or {}), text=True, capture_output=True, env=env, timeout=15)
        assert (proc.returncode == 0) == ok, (method, proc.stderr)
        return json.loads(proc.stdout) if ok else None
    initial = invoke('settings.get')
    assert (initial['theme'], initial['density'], initial['zoomPercent']) == ('system', 'standard', 100)
    invoke('settings.save', {'notificationSound': False, 'locale': 'en'})
    for theme in ['system', 'light', 'dark']:
        for density in ['standard', 'compact']:
            for zoom in [90, 100, 110, 125, 150]:
                saved = invoke('settings.save', {'theme': theme, 'density': density, 'zoomPercent': zoom})
                reopened = invoke('settings.get')
                assert (saved['theme'], saved['density'], saved['zoomPercent']) == (theme, density, zoom)
                assert reopened == saved
                assert reopened['notificationSound'] is False and reopened['locale'] == 'en'
    receipt['checks'].append({'name': '30-valid-combinations-persist-across-helper-restarts-with-unrelated-preferences', 'passed': True})
    before = invoke('settings.get')
    invalid = [{'theme': v} for v in ['auto', '', None, True, 42, {}, ['dark']]] + [{'density': v} for v in ['dense', '', None, False, 1, {}]] + [{'zoomPercent': v} for v in [True, False, '125', None, {}, 89, 151, 100.5, 1e30]]
    invalid += [{'theme': 'light', 'zoomPercent': 151}, {'theme': 'light', 'unknownAppearance': True}]
    for change in invalid:
        invoke('settings.save', change, ok=False)
        assert invoke('settings.get') == before, change
    receipt['checks'].append({'name': 'invalid-or-mixed-patches-fail-atomically', 'passed': True, 'cases': len(invalid)})
    invoke('settings.save', {'theme': 'light'})
    after = invoke('dashboard.get')['settings']
    assert after['theme'] == 'light' and after['density'] == before['density'] and after['zoomPercent'] == before['zoomPercent']
    assert after['telemetry'] is False
    receipt['checks'].append({'name': 'partial-save-dashboard-agreement-and-telemetry-unchanged', 'passed': True})
receipt.update(passed=True, temporaryStoreRemoved=True)
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({'passed': True, 'groups': len(receipt['checks'])}))
