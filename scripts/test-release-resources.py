"""Verify exact packaged resources and sound bounds using disposable files."""
import os
import pathlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import wave

from release_resources import UI_RESOURCES, NOTIFICATION_SOUNDS, validate_notification_sound, validate_ui_resources


class ReleaseResourceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='vela-release-resource-tests-')
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.scripts = self.root / 'scripts'
        self.scripts.mkdir()
        repository = pathlib.Path(__file__).resolve().parents[1]
        for name in ('package-resources.py', 'release_resources.py', 'release-audit.py'):
            path = repository / 'scripts' / name
            if path.is_file():
                shutil.copy2(path, self.scripts / name)
        self.resources = self.root / 'Sources/VelaApp/Resources'
        self.ui = self.resources / 'UI'
        self.ui.mkdir(parents=True)
        for name in UI_RESOURCES:
            path = self.ui / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('synthetic release resource\n')
        (self.ui / 'demo.js').write_text('const SYNTHETIC_DEVELOPMENT_ONLY = true;\n')
        (self.resources / 'Vela.icns').write_bytes(b'synthetic icon')
        (self.resources / 'Sounds').mkdir()
        for name in NOTIFICATION_SOUNDS:
            with wave.open(str(self.resources / 'Sounds' / name), 'wb') as sound:
                sound.setparams((1, 2, 22050, 0, 'NONE', 'not compressed'))
                sound.writeframes(struct.pack('<h', 1000) * 2205)
        self.bundle = self.root / 'Vela.app'
        (self.bundle / 'Contents/MacOS').mkdir(parents=True)
        for name in ('vela', 'VelaDesktop'):
            (self.bundle / 'Contents/MacOS' / name).write_bytes(b'synthetic binary placeholder')
        self.environment = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')

    def package(self):
        return subprocess.run([sys.executable, str(self.scripts / 'package-resources.py'), str(self.bundle), 'dev'],
                              capture_output=True, text=True, env=self.environment, timeout=10)

    def audit(self):
        # Exercise the real packaged-file policy. The Mach-O architecture probe
        # alone is stubbed because these tests do not build/sign native binaries.
        script = '''import pathlib,runpy,subprocess,sys
sys.path.insert(0,str(pathlib.Path(sys.argv[1]).parent))
def architecture(command,**kwargs):
    if command[0]=='lipo':return 'arm64\\n'
    raise RuntimeError('Unexpected subprocess in resource audit')
subprocess.check_output=architecture
sys.argv=[sys.argv[1],sys.argv[2]]
runpy.run_path(sys.argv[0],run_name='__main__')
'''
        return subprocess.run([sys.executable, '-c', script, str(self.scripts / 'release-audit.py'), str(self.bundle)],
                              capture_output=True, text=True, env=self.environment, timeout=10)

    def test_exact_resources_are_packaged_and_development_demo_is_excluded(self):
        result = self.package()
        self.assertEqual(result.returncode, 0, result.stderr)
        target = self.bundle / 'Contents/Resources/UI'
        self.assertEqual({path.relative_to(target).as_posix() for path in target.rglob('*') if path.is_file()}, set(UI_RESOURCES))
        self.assertFalse((target / 'demo.js').exists())
        result = self.audit()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unlisted_source_fixture_is_rejected_before_existing_bundle_is_replaced(self):
        target = self.bundle / 'Contents/Resources/UI'
        target.mkdir(parents=True)
        marker = target / 'previous-release.txt'
        marker.write_text('preserve until all source resources validate')
        (self.ui / 'fixture-data.js').write_text('const SYNTHETIC_PRIVATE_FIXTURE_SENTINEL = true;\n')
        result = self.package()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Unexpected UI resource: fixture-data.js', result.stderr)
        self.assertTrue(marker.is_file())
        self.assertFalse((target / 'fixture-data.js').exists())

    def test_missing_and_linked_required_ui_resources_are_rejected(self):
        for name in UI_RESOURCES:
            with self.subTest(name=name):
                path = self.ui / name
                original = path.read_bytes()
                path.unlink()
                result = self.package()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(name, result.stderr)
                external = self.root / ('linked-' + name.replace('/', '-'))
                external.write_bytes(original)
                path.symlink_to(external)
                result = self.package()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Linked UI resource', result.stderr)
                path.unlink()
                path.write_bytes(original)

    def test_linked_ui_directory_and_required_icon_are_rejected(self):
        saved = self.resources / 'saved-ui'
        self.ui.rename(saved)
        self.ui.symlink_to(saved, target_is_directory=True)
        self.assertNotEqual(self.package().returncode, 0)
        self.ui.unlink()
        saved.rename(self.ui)
        icon = self.resources / 'Vela.icns'
        icon.unlink()
        self.assertNotEqual(self.package().returncode, 0)
        external = self.root / 'external.icns'
        external.write_bytes(b'synthetic icon')
        icon.symlink_to(external)
        self.assertNotEqual(self.package().returncode, 0)

    def test_audit_rejects_unlisted_bundle_js_and_missing_required_resources(self):
        self.assertEqual(self.package().returncode, 0)
        target = self.bundle / 'Contents/Resources/UI'
        for name in ('fixture-data.js', 'demo.js', 'private-material.png'):
            with self.subTest(extra=name):
                path = target / name
                path.write_text('synthetic unexpected bundled material')
                result = self.audit()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(name, result.stderr)
                path.unlink()
        for name in UI_RESOURCES:
            with self.subTest(missing=name):
                path = target / name
                value = path.read_bytes()
                path.unlink()
                result = self.audit()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(name, result.stderr)
                path.write_bytes(value)

    def test_audit_rejects_linked_required_resource_and_extra_directory(self):
        self.assertEqual(self.package().returncode, 0)
        target = self.bundle / 'Contents/Resources/UI'
        script = target / 'app.js'
        script.unlink()
        script.symlink_to(self.ui / 'app.js')
        self.assertNotEqual(self.audit().returncode, 0)
        script.unlink()
        shutil.copy2(self.ui / 'app.js', script)
        (target / 'test-fixtures').mkdir()
        with self.assertRaises(ValueError):
            validate_ui_resources(target)


class SoundResourceTests(unittest.TestCase):
    def test_valid_sound_and_invalid_payloads(self):
        with tempfile.TemporaryDirectory(prefix='vela-sound-test-') as temporary:
            root = pathlib.Path(temporary)

            def make(name, seconds=0.2, sample=1000, channels=1):
                path = root / name
                with wave.open(str(path), 'wb') as output:
                    output.setparams((channels, 2, 22050, 0, 'NONE', 'not compressed'))
                    output.writeframes(struct.pack('<h', sample) * int(22050 * seconds) * channels)
                return path

            valid = make('valid.wav')
            self.assertAlmostEqual(validate_notification_sound(valid), 0.2)
            for bad in [make('long.wav', seconds=2), make('silent.wav', sample=0),
                        make('clipped.wav', sample=32767), make('stereo.wav', channels=2)]:
                with self.assertRaises(AssertionError):
                    validate_notification_sound(bad)
            linked = root / 'linked.wav'
            linked.symlink_to(valid)
            with self.assertRaises(AssertionError):
                validate_notification_sound(linked)
            malformed = root / 'truncated.wav'
            malformed.write_bytes(valid.read_bytes()[:-20])
            with self.assertRaises(AssertionError):
                validate_notification_sound(malformed)


if __name__ == '__main__':
    unittest.main()
