"""Fail closed if the distributable contains non-allowlisted files."""
import pathlib, sys, plistlib, subprocess
from release_resources import NOTIFICATION_SOUNDS, validate_notification_sound
root = pathlib.Path(sys.argv[1]).resolve()
allowed = {'Contents/Info.plist', 'Contents/MacOS/VelaDesktop', 'Contents/MacOS/vela', 'Contents/_CodeSignature/CodeResources'}
allowed.add('Contents/Resources/Vela.icns')
allowed.update('Contents/Resources/' + name for name in NOTIFICATION_SOUNDS)
ui_extensions = {'.html','.css','.js','.svg','.png','.ico','.woff2'}
errors = []
for p in root.rglob('*'):
    if p.is_symlink():
        errors.append(str(p.relative_to(root)))
    elif p.is_file():
        rel = p.relative_to(root).as_posix()
        if rel in allowed:
            continue
        if rel.startswith('Contents/Resources/UI/') and p.suffix in ui_extensions and not any(part.startswith('.') for part in p.relative_to(root).parts) and 'demo' not in p.stem.lower():
            continue
        errors.append(rel)
assert not errors, 'Unexpected release content: ' + ', '.join(errors)
assert (root/'Contents/Resources/UI/index.html').is_file(), 'Missing UI entrypoint'
for name in NOTIFICATION_SOUNDS:
    validate_notification_sound(root/'Contents/Resources'/name)
with (root/'Contents/Info.plist').open('rb') as stream:
    metadata = plistlib.load(stream)
assert metadata['CFBundleExecutable'] == 'VelaDesktop'
for name in ('VelaDesktop', 'vela'):
    executable = root/'Contents/MacOS'/name
    assert executable.is_file(), f'Missing executable: {name}'
    assert subprocess.check_output(['lipo','-archs',str(executable)],text=True).strip() == 'arm64', f'Wrong release architecture: {name}'
    payload = executable.read_bytes()
    checkout = pathlib.Path(__file__).resolve().parents[1]
    assert str(checkout).encode() not in payload, f'Build workstation path embedded in {name}'
    if name == 'VelaDesktop':
        for marker in (b'VELA_CAPTURE_DIRECTORY', b'captureTestScreenshot', b'.vela-ui-fixture.json'):
            assert marker not in payload, f'Development screenshot hook present in {name}'
print('Release allowlist passed')
