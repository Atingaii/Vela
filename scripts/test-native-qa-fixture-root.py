"""Negative-only checks for native QA fixture-root admission; no helper or UI starts."""
import importlib.util
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('vela_test_ui_server', ROOT / 'scripts/test-ui-server.py')
SERVER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SERVER)


class NativeQAFixtureRootTests(unittest.TestCase):
    def manifest(self, directory):
        path = directory / 'fixture.json'
        path.write_text('{}')
        return path

    def test_default_http_fixture_admission_rejects_external_root(self):
        with tempfile.TemporaryDirectory() as raw:
            with self.assertRaises(ValueError):
                SERVER.fixture_paths(self.manifest(Path(raw)))

    def test_native_root_rejects_any_home_directory(self):
        with tempfile.TemporaryDirectory() as raw:
            home = Path(raw)
            with self.assertRaises(ValueError):
                SERVER.fixture_paths(self.manifest(home), native_temporary_root=home)

    def test_manifest_symlink_is_rejected_before_resolution(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            manifest = self.manifest(directory)
            linked = directory / 'linked-fixture.json'
            linked.symlink_to(manifest)
            with self.assertRaises(ValueError):
                SERVER.fixture_paths(linked)


if __name__ == '__main__':
    unittest.main()
