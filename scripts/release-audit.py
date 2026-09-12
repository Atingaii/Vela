"""Fail closed if the distributable contains non-allowlisted files."""
import pathlib, sys, plistlib, subprocess
root = pathlib.Path(sys.argv[1]).resolve()
allowed = {'Contents/Info.plist', 'Contents/MacOS/VelaDesktop', 'Contents/MacOS/vela', 'Contents/_CodeSignature/CodeResources'}
allowed.add('Contents/Resources/Vela.icns')
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
with (root/'Contents/Info.plist').open('rb') as stream:
    metadata = plistlib.load(stream)
assert metadata['CFBundleExecutable'] == 'VelaDesktop'
for name in ('VelaDesktop', 'vela'):
    executable = root/'Contents/MacOS'/name
    assert executable.is_file(), f'Missing executable: {name}'
    assert subprocess.check_output(['lipo','-archs',str(executable)],text=True).strip() == 'arm64', f'Wrong release architecture: {name}'
print('Release allowlist passed')
