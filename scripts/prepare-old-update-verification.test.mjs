import {test} from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {cp, mkdir, mkdtemp, readFile, realpath, rm, stat, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {basename, dirname, join, sep} from 'node:path';
import {rewriteCargoLockVersion} from './prepare-old-update-verification.mjs';

test('old verification source keeps the same signed feed and changes all package versions', async () => {
  const output = spawnSync(process.execPath, ['scripts/prepare-old-update-verification.mjs'], {
    encoding: 'utf8', timeout: 15_000,
  });
  const prepared = JSON.parse(output.stdout);
  const root = await realpath(prepared.prepared_root);
  const temporary = await realpath(tmpdir());
  assert.ok(root.startsWith(`${temporary}${sep}`));
  assert.ok(basename(root).startsWith('velo-old-update-source-'));
  try {
    assert.equal(output.status, 0, output.stderr);
    const readJson = async (file) => JSON.parse(await readFile(join(root, file), 'utf8'));
    const [tauri, packageJson, lock, original] = await Promise.all([
      readJson('src-tauri/tauri.conf.json'), readJson('package.json'),
      readJson('package-lock.json'),
      readFile('src-tauri/tauri.conf.json', 'utf8').then(JSON.parse),
    ]);
    assert.equal(tauri.version, '0.1.1-preview.0');
    assert.equal(packageJson.version, tauri.version);
    assert.equal(lock.version, tauri.version);
    assert.equal(lock.packages[''].version, tauri.version);
    assert.match(await readFile(join(root, 'src-tauri/Cargo.toml'), 'utf8'), /^version = "0\.1\.1-preview\.0"$/m);
    assert.match(await readFile(join(root, 'Cargo.lock'), 'utf8'), /name = "vela"\r?\nversion = "0\.1\.1-preview\.0"/);
    assert.equal(tauri.plugins.updater.pubkey, original.plugins.updater.pubkey);
    assert.deepEqual(tauri.plugins.updater.endpoints, original.plugins.updater.endpoints);
    assert.equal(tauri.plugins.updater.requireSignedVersion, true);
    assert.equal(tauri.bundle.createUpdaterArtifacts, true);
    assert.ok((await stat(join(root, 'node_modules'))).isDirectory());
  } finally {
    await rm(root, {recursive: true, force: true});
  }
});

test('Cargo.lock version replacement accepts LF and CRLF without changing either style', () => {
  for (const newline of ['\n', '\r\n']) {
    const original = ['version = 4', '', '[[package]]', 'name = "vela"',
      'version = "0.1.1-preview.1"', '', '[[package]]', 'name = "other"',
      'version = "0.1.1-preview.1"', ''].join(newline);
    const rewritten = rewriteCargoLockVersion(original);
    assert.equal(rewritten, original.replace('name = "vela"' + newline
      + 'version = "0.1.1-preview.1"', 'name = "vela"' + newline
      + 'version = "0.1.1-preview.0"'));
  }
});

test('failed preparation reports and removes its own temporary output', async () => {
  const fixture = await mkdtemp(join(tmpdir(), 'velo-preparer-failure-fixture-'));
  try {
    await mkdir(join(fixture, 'scripts'));
    await cp('scripts/prepare-old-update-verification.mjs',
      join(fixture, 'scripts', 'prepare-old-update-verification.mjs'));
    await writeFile(join(fixture, 'Cargo.toml'), '[package]\nname = "vela"\n');
    const output = spawnSync(process.execPath,
      [join(fixture, 'scripts', 'prepare-old-update-verification.mjs')],
      {encoding: 'utf8', timeout: 15_000});
    const result = JSON.parse(output.stdout);
    const temporary = await realpath(tmpdir());
    const parent = await realpath(dirname(result.prepared_root));
    assert.equal(parent, temporary);
    assert.ok(basename(result.prepared_root).startsWith('velo-old-update-source-'));
    try {
      assert.equal(output.status, 1, `stdout=${output.stdout}; stderr=${output.stderr}`);
      assert.equal(result.success, false);
      assert.equal(result.cleaned, true);
      assert.equal(await stat(result.prepared_root).catch(() => null), null);
    } finally {
      await rm(result.prepared_root, {recursive: true, force: true});
    }
  } finally {
    await rm(fixture, {recursive: true, force: true});
  }
});
