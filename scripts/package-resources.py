"""Package only explicitly allowed UI resources and release metadata."""
import pathlib, plistlib, shutil, sys
from release_resources import (NOTIFICATION_SOUNDS, UI_RESOURCES,
                               validate_notification_sound, validate_regular_resource,
                               validate_ui_resources)

bundle = pathlib.Path(sys.argv[1]).resolve()
channel = sys.argv[2]
source = pathlib.Path(__file__).resolve().parents[1] / 'Sources/VelaApp/Resources/UI'
target = bundle / 'Contents/Resources/UI'
# Validate before replacing an existing resource directory. Only the named
# development demo may coexist with the required release UI sources.
validate_ui_resources(source, allow_development=True)
validate_regular_resource(source.parent / 'Vela.icns')
sounds = source.parent / 'Sounds'
if sounds.is_symlink() or not sounds.is_dir():
    raise ValueError('Notification sounds must be an ordinary source directory.')
for name in NOTIFICATION_SOUNDS:
    validate_notification_sound(sounds / name)
if target.exists():
    shutil.rmtree(target)
target.mkdir(parents=True)
for name in UI_RESOURCES:
    path = source / name
    dest = target / name
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, dest, follow_symlinks=False)
validate_ui_resources(target)
shutil.copy2(source.parent / 'Vela.icns', bundle / 'Contents/Resources/Vela.icns', follow_symlinks=False)
validate_regular_resource(bundle / 'Contents/Resources/Vela.icns')
for name in NOTIFICATION_SOUNDS:
    sound = sounds / name
    # UNNotificationSound(named:) resolves named files in the main app bundle.
    shutil.copy2(sound, bundle / 'Contents/Resources' / name, follow_symlinks=False)
    validate_notification_sound(bundle / 'Contents/Resources' / name)
info = {
    'CFBundleName': 'Vela', 'CFBundleDisplayName': 'Vela',
    'CFBundleIdentifier': 'ai.vela.desktop' + ('' if channel == 'stable' else '.' + channel),
    'CFBundleExecutable': 'VelaDesktop', 'CFBundlePackageType': 'APPL',
    'CFBundleIconFile': 'Vela',
    'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '2',
    'LSMinimumSystemVersion': '13.0', 'NSHighResolutionCapable': True,
    'LSApplicationCategoryType': 'public.app-category.developer-tools',
    'VelaChannel': channel,
    'NSHumanReadableCopyright': 'Copyright © 2026 Vela contributors',
    'CFBundleURLTypes': [{'CFBundleURLName': 'Vela', 'CFBundleURLSchemes': ['vela' if channel == 'stable' else 'vela-' + channel]}],
}
with (bundle / 'Contents/Info.plist').open('wb') as f:
    plistlib.dump(info, f)
