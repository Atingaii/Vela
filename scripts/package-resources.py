"""Package only explicitly allowed UI resources and release metadata."""
import pathlib, plistlib, shutil, sys

bundle = pathlib.Path(sys.argv[1]).resolve()
channel = sys.argv[2]
source = pathlib.Path(__file__).resolve().parents[1] / 'Sources/VelaApp/Resources/UI'
target = bundle / 'Contents/Resources/UI'
if target.exists():
    shutil.rmtree(target)
target.mkdir(parents=True)
allowed = {'.html', '.css', '.js', '.svg', '.png', '.ico', '.woff2'}
for path in source.rglob('*'):
    if not path.is_file():
        continue
    if path.is_symlink() or path.suffix not in allowed or 'demo' in path.stem.lower():
        continue
    dest = target / path.relative_to(source)
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, dest)
shutil.copy2(source.parent / 'Vela.icns', bundle / 'Contents/Resources/Vela.icns')
info = {
    'CFBundleName': 'Vela', 'CFBundleDisplayName': 'Vela',
    'CFBundleIdentifier': 'ai.vela.desktop' + ('' if channel == 'stable' else '.' + channel),
    'CFBundleExecutable': 'VelaDesktop', 'CFBundlePackageType': 'APPL',
    'CFBundleIconFile': 'Vela',
    'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '1',
    'LSMinimumSystemVersion': '13.0', 'NSHighResolutionCapable': True,
    'LSApplicationCategoryType': 'public.app-category.developer-tools',
    'VelaChannel': channel,
    'NSHumanReadableCopyright': 'Copyright © 2026 Vela contributors',
    'CFBundleURLTypes': [{'CFBundleURLName': 'Vela', 'CFBundleURLSchemes': ['vela' if channel == 'stable' else 'vela-' + channel]}],
}
with (bundle / 'Contents/Info.plist').open('wb') as f:
    plistlib.dump(info, f)
