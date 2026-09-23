import {test} from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {readFile, realpath, rm, stat} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {basename, join, sep} from 'node:path';

test('old verification source keeps the same signed feed and changes all package versions', async () => {
  const output = spawnSync(process.execPath, ['scripts/prepare-old-update-verification.mjs'], {
    encoding: 'utf8', timeout: 15_000,
  });
  assert.equal(output.status, 0, output.stderr);
  const prepared = JSON.parse(output.stdout);
  const root = await realpath(prepared.prepared_root);
  const temporary = await realpath(tmpdir());
  assert.ok(root.startsWith(`${temporary}${sep}`));
  assert.ok(basename(root).startsWith('velo-old-update-source-'));
  try {
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
    assert.match(await readFile(join(root, 'Cargo.lock'), 'utf8'), /name = "vela"\nversion = "0\.1\.1-preview\.0"/);
    assert.equal(tauri.plugins.updater.pubkey, original.plugins.updater.pubkey);
    assert.deepEqual(tauri.plugins.updater.endpoints, original.plugins.updater.endpoints);
    assert.equal(tauri.plugins.updater.requireSignedVersion, true);
    assert.equal(tauri.bundle.createUpdaterArtifacts, true);
    assert.ok((await stat(join(root, 'node_modules'))).isDirectory());
  } finally {
    await rm(root, {recursive: true, force: true});
  }
});
