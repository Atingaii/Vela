const {test} = require('node:test');
const assert = require('node:assert/strict');
const {mkdtemp, writeFile, rm, unlink} = require('node:fs/promises');
const {tmpdir} = require('node:os');
const {join} = require('node:path');

const files = [
  'Velo-macos-arm64.app.tar.gz',
  'Velo-macos-x64.app.tar.gz',
  'Velo-windows-x64-setup.exe',
];
const versions = {package:'0.1.1-preview.1', tauri:'0.1.1-preview.1', rust:'0.1.1-preview.1'};

test('preview feed publishes only a complete, signed three-platform release', async t => {
  const {buildFeed, verifyRemoteRelease} = await import('./preview-update-feed.mjs');
  const directory = await mkdtemp(join(tmpdir(), 'velo-feed-test-'));
  t.after(() => rm(directory, {recursive:true, force:true}));
  for (const filename of files) {
    await writeFile(join(directory, filename), 'bundle-bytes');
    await writeFile(join(directory, `${filename}.sig`), `untrusted comment: test\nsignature-${filename}\n`);
  }
  const feed = await buildFeed(directory, 'v0.1.1-preview.1', versions, 'Atingaii/Velo',
    new Date('2026-09-23T00:00:00.000Z'));
  assert.deepEqual(Object.keys(feed.platforms), ['darwin-aarch64','darwin-x86_64','windows-x86_64']);
  assert.equal(feed.version, '0.1.1-preview.1');
  assert.equal(feed.platforms['windows-x86_64'].url,
    'https://github.com/Atingaii/Velo/releases/download/v0.1.1-preview.1/Velo-windows-x64-setup.exe');
  assert.match(feed.platforms['darwin-aarch64'].signature, /signature-Velo-macos-arm64/);
  const release = {tag_name:'v0.1.1-preview.1', prerelease:true, draft:false,
    assets: files.flatMap(name => [{name,size:12},{name:`${name}.sig`,size:80}])};
  assert.doesNotThrow(() => verifyRemoteRelease(release, feed));
  assert.throws(() => verifyRemoteRelease({...release, assets: release.assets.slice(0,-1)}, feed),
    /missing signed platform artifact/);
  await unlink(join(directory, `${files[2]}.sig`));
  await assert.rejects(buildFeed(directory, 'v0.1.1-preview.1', versions, 'Atingaii/Velo'),
    /ENOENT/);
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
