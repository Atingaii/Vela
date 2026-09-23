const {test} = require('node:test');
const assert = require('node:assert/strict');
const {mkdtemp, writeFile, rm, unlink, stat} = require('node:fs/promises');
const {spawnSync} = require('node:child_process');
const {tmpdir} = require('node:os');
const {join} = require('node:path');

const files = [
  'Velo-macos-arm64.app.tar.gz',
  'Velo-macos-x64.app.tar.gz',
];
const versions = {package:'0.1.1-preview.1', tauri:'0.1.1-preview.1', rust:'0.1.1-preview.1'};

test('preview feed publishes only two complete, signed macOS platforms', async t => {
  const {buildFeed, verifyRemoteRelease} = await import('./preview-update-feed.mjs');
  const directory = await mkdtemp(join(tmpdir(), 'velo-feed-test-'));
  t.after(() => rm(directory, {recursive:true, force:true}));
  for (const filename of files) {
    await writeFile(join(directory, filename), 'bundle-bytes');
    await writeFile(join(directory, `${filename}.sig`), `untrusted comment: test\nsignature-${filename}\n`);
  }
  await writeFile(join(directory, 'Velo-windows-x64-setup.exe'), 'unused-windows-bundle');
  await writeFile(join(directory, 'Velo-windows-x64-setup.exe.sig'), 'unused-windows-signature');
  const feed = await buildFeed(directory, 'v0.1.1-preview.1', versions, 'Atingaii/Velo',
    new Date('2026-09-23T00:00:00.000Z'));
  assert.deepEqual(Object.keys(feed.platforms), ['darwin-aarch64','darwin-x86_64']);
  assert.equal(feed.version, '0.1.1-preview.1');
  assert.equal(feed.platforms['darwin-x86_64'].url,
    'https://github.com/Atingaii/Velo/releases/download/v0.1.1-preview.1/Velo-macos-x64.app.tar.gz');
  assert.equal(feed.platforms['windows-x86_64'], undefined);
  assert.match(feed.platforms['darwin-aarch64'].signature, /signature-Velo-macos-arm64/);
  const release = {tag_name:'v0.1.1-preview.1', prerelease:true, draft:false,
    assets: files.flatMap(name => [{name,size:12},{name:`${name}.sig`,size:80}])};
  assert.doesNotThrow(() => verifyRemoteRelease(release, feed));
  for (const filename of files) {
    for (const name of [filename, `${filename}.sig`]) {
      assert.throws(() => verifyRemoteRelease({
        ...release, assets: release.assets.filter(asset => asset.name !== name),
      }, feed), /missing signed platform artifact/);
      await unlink(join(directory, name));
      await assert.rejects(buildFeed(directory, 'v0.1.1-preview.1', versions, 'Atingaii/Velo'),
        /ENOENT/);
      await writeFile(join(directory, name), name.endsWith('.sig') ? 'signature' : 'bundle-bytes');
    }
  }
});

test('feed version must match every package and never regress below an installed stable build', async () => {
  const {releaseVersion, comparePreviewVersions} = await import('./preview-update-feed.mjs');
  assert.equal(releaseVersion('v0.1.1-preview.1', versions), '0.1.1-preview.1');
  assert.throws(() => releaseVersion('v0.1.0-preview.5', versions), /does not match/);
  assert.throws(() => releaseVersion('v00.1.1-preview.1', versions), /Expected/);
  assert.equal(comparePreviewVersions('0.1.0-preview.5', '0.1.0'), -1);
  assert.equal(comparePreviewVersions('0.1.1-preview.1', '0.1.0'), 1);
  assert.equal(comparePreviewVersions('0.1.1-preview.2', '0.1.1-preview.1'), 1);
});

test('release preflight rejects wrong tags and missing signatures before writing a feed', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'velo-feed-preflight-test-'));
  t.after(() => rm(directory, {recursive:true, force:true}));
  const script = join(__dirname, 'preview-update-feed.mjs');
  const currentVersion = require('../package.json').version;
  const currentTag = `v${currentVersion}`;
  const wrongTag = currentVersion === '0.0.0-preview.0'
    ? 'v0.0.0-preview.1' : 'v0.0.0-preview.0';
  const preflight = tag => spawnSync(process.execPath, [script, directory, tag, '--check'], {
    encoding: 'utf8', timeout: 5_000,
    env: {...process.env, GITHUB_REPOSITORY: 'Atingaii/Velo'},
  });
  for (const filename of files) {
    await writeFile(join(directory, filename), 'bundle-bytes');
    await writeFile(join(directory, `${filename}.sig`), `signature-${filename}`);
  }
  assert.equal(preflight(currentTag).status, 0);
  await assert.rejects(stat(join(directory, 'latest.json')), {code: 'ENOENT'});
  assert.notEqual(preflight(wrongTag).status, 0);
  await unlink(join(directory, `${files[1]}.sig`));
  assert.notEqual(preflight(currentTag).status, 0);
  await assert.rejects(stat(join(directory, 'latest.json')), {code: 'ENOENT'});
});
