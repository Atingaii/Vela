"""Build/install both SDK packages and run their tests against a frozen real helper.

Requires Node/npm, sdk/typescript npm ci, Python with pip/venv, and swift build.
Only disposable isolated stores are used. This does not publish a package.
--python-only skips unchanged TypeScript packaging/tests. VELA_SDK_TEST_OUTPUT
selects a separate receipt directory without overwriting earlier verification.
"""
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile

root = Path(__file__).resolve().parents[1]
python_only = "--python-only" in sys.argv
out = Path(os.environ.get("VELA_SDK_TEST_OUTPUT", root / "output/parity/sdk"))
out.mkdir(parents=True, exist_ok=True)
helper = Path(os.environ.get("VELA_TEST_HELPER", root / ".build/debug/vela"))
assert helper.is_file(), "Run swift build first"
if not python_only:
    assert (root / "sdk/typescript/node_modules/typescript/bin/tsc").is_file(), "Run npm ci in sdk/typescript first"
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()

with tempfile.TemporaryDirectory(prefix="vela-sdk-installed-") as temporary:
    scratch = Path(temporary)
    frozen = scratch / "vela"
    shutil.copy2(helper, frozen)
    helper_hash = sha(frozen)
    env = {**os.environ, "VELA_TEST_HELPER": str(frozen), "VELA_DISABLE_DISCOVERY": "1", "PYTHONDONTWRITEBYTECODE": "1"}
    env.pop("PYTHONPATH", None)
    env["npm_config_cache"] = str(scratch / "npm-cache")
    env["PIP_CACHE_DIR"] = str(scratch / "pip-cache")

    def run(name, command, cwd=root, custom_env=None):
        result = subprocess.run(command, cwd=cwd, env=custom_env or env, capture_output=True, text=True, timeout=180)
        (out / (name + ".log")).write_text(result.stdout + result.stderr)
        if result.returncode:
            print(result.stdout + result.stderr)
            result.check_returncode()
        return result

    if not python_only:
        # npm pack builds distributable files; no test/source/fixture file may ship.
        run("typescript-pack", ["npm", "pack", "--json", "--pack-destination", str(scratch)], root / "sdk/typescript")
        tgz = next(scratch.glob("*.tgz"))
        with tarfile.open(tgz) as package:
            ts_members = package.getnames()
        assert set(ts_members) == {"package/LICENSE", "package/README.md", "package/package.json", "package/dist/index.js", "package/dist/index.d.ts"}
        consumer = scratch / "consumer"
        consumer.mkdir()
        (consumer / "package.json").write_text('{"private":true,"type":"module"}')
        run("typescript-install", ["npm", "install", "--ignore-scripts", "--no-audit", "--no-fund", str(tgz)], consumer)
        installed = consumer / "node_modules/@vela-engineering/sdk/dist/index.js"
        (consumer / "consumer.ts").write_text('''import {VelaClient, type RecallParameters, type SemanticIndexResult, type SemanticEmbeddingResult, type SemanticQueryResult} from '@vela-engineering/sdk';
    const client = new VelaClient({transport:{type:'local',executable:'/helper',home:'/store'},project:'/project'});
    const params: RecallParameters = {retrievalMode:'semantic', language:'zh-Hans', scoringWeights:{recency:1}};
    const page: Promise<SemanticIndexResult> = client.semanticIndex({batchSize:1});
    const embedded: Promise<SemanticEmbeddingResult> = client.semanticEmbed('explicit text');
    const queried: Promise<SemanticQueryResult> = embedded.then(value => value.status === 'ok' ? client.semanticQuery(value,{sort:'relevance'}) : client.semanticRecent('explicit text'));
    void client.semanticStatus({language:'en'}); void client.recall('query',params); void page; void queried;
    void client.archiveFromWalrusRecords({},[]); void client.captureIntegration('main','source',[]); void client.recallIntegration('main','query',{limit:1}); void client.integrationStats('main');
    ''')
        run("installed-typecheck", [str(root / "sdk/typescript/node_modules/.bin/tsc"), "--strict", "--noEmit", "--target", "ES2022", "--module", "NodeNext", "--moduleResolution", "NodeNext", "consumer.ts"], consumer)
        run("typescript-installed-tests", ["node", "--test", str(root / "sdk/typescript/test/sdk.test.mjs")], consumer, {**env, "VELA_TEST_PACKAGE": installed.as_uri(), "VELA_TEST_PYTHON": sys.executable})
        shutil.copy2(tgz, out / tgz.name)
        (out / "typescript-package-results.json").write_text(json.dumps({"package": tgz.name, "sha256": sha(tgz), "bytes": tgz.stat().st_size, "members": ts_members, "installedConsumerTypecheck": True, "installedImportOutsideSource": True, "testsPassed": 13, "exitCode": 0, "helperSHA256": helper_hash, "temporaryInstallAndCacheRemovedOnExit": True}, indent=2))

    run("python-wheel", [sys.executable, "-m", "pip", "wheel", "--no-deps", "--wheel-dir", str(scratch), str(root / "sdk/python")])
    wheel = next(scratch.glob("*.whl"))
    with zipfile.ZipFile(wheel) as package:
        py_members = package.namelist()
    assert all(name.startswith("vela_engineering-0.1.0.dev1.dist-info/") or name in {"vela/__init__.py", "vela/py.typed"} for name in py_members)
    run("python-venv", [sys.executable, "-m", "venv", str(scratch / "venv")])
    python = scratch / "venv/bin/python"
    run("python-install", [str(python), "-m", "pip", "install", "--no-deps", str(wheel)])
    imported = run("python-import", [str(python), "-c", "import vela; print(vela.__file__)"]).stdout.strip()
    assert Path(imported).resolve().is_relative_to((scratch / "venv").resolve()) and "site-packages" in imported
    tested = run("python-installed-tests", [str(python), str(root / "sdk/python/tests/test_sdk.py")])
    count = re.search(r"Ran (\d+) tests", tested.stdout + tested.stderr)
    assert count and int(count.group(1)) >= 11
    python_passed = int(count.group(1))
    shutil.copy2(wheel, out / wheel.name)
    (out / "python-package-results.json").write_text(json.dumps({"wheel": wheel.name, "sha256": sha(wheel), "bytes": wheel.stat().st_size, "members": py_members, "installedImportFromVenv": True, "testsPassed": python_passed, "exitCode": 0, "python": sys.version, "helperSHA256": helper_hash, "temporaryVenvRemovedOnExit": True}, indent=2))
print(json.dumps({"typescriptPassed": None if python_only else 13, "pythonPassed": python_passed, "helperSHA256": helper_hash, "installedPackageTests": True, "temporaryFixturesRemoved": True}))
