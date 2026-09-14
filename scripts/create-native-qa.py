"""Build an isolated native QA wrapper, never a distributable application.

Every LaunchServices or direct restart executes the same compiled launcher. Its
store and synthetic source paths are fixed at creation, independent of inherited
environment. A missing/modified fixture marker fails closed before the real host.
The caller owns fixture creation/cleanup. This script does not launch the UI.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

from release_resources import UI_RESOURCES, copy_ui_resources, validate_ui_resources

ROOT = Path(__file__).resolve().parents[1]
UI_FILES = UI_RESOURCES


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--host', type=Path, required=True)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--ui-directory', type=Path, required=True)
    parser.add_argument('--capture-directory', type=Path, required=True)
    parser.add_argument('--name', required=True, help='Unique short lowercase identifier, such as history-r11.')
    args = parser.parse_args()
    if not re.fullmatch('[a-z][a-z0-9-]{0,40}', args.name):
        parser.error('Use a short lowercase QA identifier.')
    spec = importlib.util.spec_from_file_location('vela_fixture_bridge', ROOT / 'scripts/test-ui-server.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    fixture, base = module.fixture_paths(args.fixture)
    capture = args.capture_directory.absolute()
    if capture.is_symlink() or not capture.resolve().is_relative_to((ROOT / 'output/playwright').resolve()):
        parser.error('Capture evidence must be under output/playwright.')
    capture.mkdir(parents=True, exist_ok=True)
    bundle = base / ('Vela QA ' + args.name + '.app')
    if bundle.exists() or bundle.is_symlink():
        parser.error('The named QA bundle already exists.')
    ui = args.ui_directory.resolve(strict=True)
    try:
        validate_ui_resources(ui, allow_development=True)
    except ValueError as error:
        parser.error('Invalid frozen UI resources: ' + str(error))
    marker = Path(fixture['home']) / '.vela-ui-fixture.json'
    marker_bytes = marker.read_bytes()
    assert len(marker_bytes) < 4096 and not marker.is_symlink()
    macos, resources = bundle / 'Contents/MacOS', bundle / 'Contents/Resources'
    macos.mkdir(parents=True)
    copy_ui_resources(ui, resources / 'UI', source_allow_development=True)
    assets = ROOT / 'Sources/VelaApp/Resources'
    shutil.copyfile(assets / 'Vela.icns', resources / 'Vela.icns')
    for name in ('vela-approval.wav', 'vela-completed.wav', 'vela-error.wav'):
        shutil.copyfile(assets / 'Sounds' / name, resources / name)
    for source, dest in ((args.host, macos / 'VelaHost'), (args.binary, macos / 'vela')):
        source = source.resolve(strict=True)
        assert source.is_file()
        shutil.copy2(source, dest)
    env = dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin', LANG='en_US.UTF-8',
               VELA_HOME=fixture['home'], VELA_SESSION_ROOT=fixture['sessionRoot'], VELA_DISABLE_DISCOVERY='1',
               VELA_NATIVE_QA='1', VELA_CAPTURE_DIRECTORY=str(capture), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
    # JSON string escapes are valid C literals here: generated controlled ASCII paths only.
    assert all(value.isascii() for value in [str(marker), str(macos / 'VelaHost'), str(base), *env.values()])
    cstr = json.dumps
    c = '''#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
  const unsigned char expected[] = {MARKER_BYTES};
  unsigned char actual[4097]; struct stat info;
  int fd = open(MARKER_PATH, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0 || fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_uid != getuid()) return 78;
  ssize_t count = read(fd, actual, sizeof(actual)); close(fd);
  if (count != sizeof(expected) || memcmp(actual, expected, sizeof(expected))) return 78;
  if (chdir(BASE_PATH)) return 78;
  if (argc == 2 && strcmp(argv[1], "--verify-isolation") == 0) { puts("synthetic fixture binding verified"); return 0; }
  char *env[] = {ENV_VALUES, NULL};
  char *args[] = {HOST_PATH, NULL};
  execve(HOST_PATH, args, env);
  perror("QA host exec"); return 78;
}
'''
    c = c.replace('MARKER_BYTES', ','.join(map(str, marker_bytes))).replace('MARKER_PATH', cstr(str(marker)))
    c = c.replace('BASE_PATH', cstr(str(base))).replace('HOST_PATH', cstr(str(macos / 'VelaHost')))
    c = c.replace('ENV_VALUES', ','.join(cstr(k + '=' + v) for k, v in env.items()))
    source = base / ('qa-launcher-' + args.name + '.c'); source.write_text(c)
    launcher = macos / 'VelaQA'
    subprocess.run(['xcrun', 'clang', '-O2', str(source), '-o', str(launcher)], check=True)
    info = dict(CFBundleName='Vela QA ' + args.name, CFBundleDisplayName='Vela QA ' + args.name,
                CFBundleIdentifier='ai.vela.qa.' + args.name, CFBundleExecutable='VelaQA',
                CFBundlePackageType='APPL', CFBundleIconFile='Vela', CFBundleVersion='1',
                CFBundleShortVersionString='0.1.0', LSMinimumSystemVersion='13.0', NSHighResolutionCapable=True,
                VelaChannel='dev', CFBundleURLTypes=[dict(CFBundleURLName='Vela QA', CFBundleURLSchemes=['vela-qa-' + args.name])])
    (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    for path in (macos / 'vela', macos / 'VelaHost', bundle):
        subprocess.run(['codesign', '--force', '--sign', '-', str(path)], check=True, capture_output=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle)], check=True)
    verified = subprocess.run([str(launcher), '--verify-isolation'], env={}, capture_output=True, text=True, check=True)
    # Exact owned marker test; always restore before returning, never touch user data.
    saved = marker.with_name('.vela-ui-fixture.qa-held')
    assert not saved.exists()
    marker.rename(saved)
    try:
        rejected = subprocess.run([str(launcher), '--verify-isolation'], env={}, capture_output=True)
        assert rejected.returncode == 78, 'Missing marker did not fail closed'
    finally:
        saved.rename(marker)
    paths = [*macos.iterdir(), *resources.rglob('*')]
    receipt = dict(format='vela-native-qa-launcher-v1', synthetic=True, bundle=str(bundle),
                   fixture=str(args.fixture.resolve()), sourceSHA256=hashlib.sha256(source.read_bytes()).hexdigest(),
                   files={str(p.relative_to(bundle)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths if p.is_file()},
                   inheritedEnvironmentRequired=False, homeOverride=False,
                   fixtureHome=fixture['home'], fixtureSessionRoot=fixture['sessionRoot'],
                   fixtureCaptureDirectory=str(capture), discoveryDisabled=True,
                   requestedWebsiteDataStore='nonPersistent',
                   missingMarkerRejected=True, verification=verified.stdout.strip(),
                   uiLaunched=False, actualLaunchServicesRestartVerified=False)
    (capture / ('launcher-' + args.name + '.json')).write_text(json.dumps(receipt, indent=2) + '\n')
    source.unlink()
    print(json.dumps(dict(bundle=str(bundle), launcher=str(launcher), synthetic=True, uiLaunched=False)))


if __name__ == '__main__':
    main()
