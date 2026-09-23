// Make a disposable older-version source tree from the *current* updater implementation.
// This only prepares files; the caller builds it serially with the normal release command.
// The public 0.1.0 preview cannot serve as a verification base because it had no signing key.
import {cp, mkdtemp, mkdir, readFile, realpath, rm, symlink, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const oldVersion = '0.1.1-preview.0';
const currentVersion = '0.1.1-preview.1';

function replaceOnce(contents, pattern, replacement, name) {
  const matches = [...contents.matchAll(new RegExp(pattern.source, pattern.flags.includes('g') ? pattern.flags : `${pattern.flags}g`))];
  if (matches.length !== 1) throw new Error(`${name}: expected exactly one current-version field, found ${matches.length}`);
  return contents.replace(pattern, replacement);
}

export function rewriteCargoLockVersion(contents, name = 'Cargo.lock') {
  return replaceOnce(contents,
    /(\[\[package\]\]\r?\nname = "vela"\r?\nversion = ")0\.1\.1-preview\.1(")/m,
    (_match, before, after) => `${before}${oldVersion}${after}`, name);
}

async function rewriteVersions(root) {
  const cargo = join(root, 'src-tauri', 'Cargo.toml');
  await writeFile(cargo, replaceOnce(await readFile(cargo, 'utf8'),
    /^version = "0\.1\.1-preview\.1"$/m, `version = "${oldVersion}"`, cargo));

  const lock = join(root, 'Cargo.lock');
  await writeFile(lock, rewriteCargoLockVersion(await readFile(lock, 'utf8'), lock));

  const tauriPath = join(root, 'src-tauri', 'tauri.conf.json');
  const tauri = JSON.parse(await readFile(tauriPath, 'utf8'));
  if (tauri.version !== currentVersion || tauri.bundle?.createUpdaterArtifacts !== true
      || !tauri.plugins?.updater?.requireSignedVersion || !tauri.plugins.updater.pubkey
      || !tauri.plugins.updater.endpoints?.length) {
    throw new Error('Current Tauri package lacks the expected signed-updater configuration');
  }
  tauri.version = oldVersion;
  await writeFile(tauriPath, `${JSON.stringify(tauri, null, 2)}\n`);

  for (const name of ['package.json', 'package-lock.json']) {
    const path = join(root, name);
    const value = JSON.parse(await readFile(path, 'utf8'));
    if (value.version !== currentVersion) throw new Error(`${name} does not match ${currentVersion}`);
    value.version = oldVersion;
    if (name === 'package-lock.json') {
      if (value.packages?.['']?.version !== currentVersion) throw new Error('Lockfile root version differs');
      value.packages[''].version = oldVersion;
    }
    await writeFile(path, `${JSON.stringify(value, null, 2)}\n`);
  }
}

async function prepare() {
const source = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const root = await mkdtemp(join(tmpdir(), 'velo-old-update-source-'));
const copy = async (relative, filter) => {
  const destination = join(root, relative);
  await mkdir(dirname(destination), {recursive: true});
  await cp(join(source, relative), destination, {recursive: true, force: false, filter});
};
try {
  for (const path of ['Cargo.toml', 'Cargo.lock', 'package.json', 'package-lock.json',
    '.cargo', 'crates/vela-hook', 'scripts/desktop.mjs', 'tests/fixtures/updater']) {
    await copy(path);
  }
  await copy('src-tauri', (path) => {
    const relative = path.slice(source.length).replaceAll('\\', '/');
    return !['/src-tauri/binaries', '/src-tauri/gen'].some((ignored) =>
      relative === ignored || relative.startsWith(`${ignored}/`));
  });
  // Reuse the project-local CLI; neither npm nor Cargo dependencies are downloaded here.
  await symlink(join(source, 'node_modules'), join(root, 'node_modules'),
    process.platform === 'win32' ? 'junction' : 'dir');
  await rewriteVersions(root);
  await writeFile(join(root, 'PREPARED-VERIFICATION.json'), `${JSON.stringify({
    purpose: 'isolated signed update verification', from: oldVersion, to: currentVersion,
    build: 'node scripts/desktop.mjs build', source, prepared_root: root,
  }, null, 2)}\n`);
  console.log(JSON.stringify({prepared_root: root, old_version: oldVersion,
    build: `cd '${root}' && node scripts/desktop.mjs build`,
    note: 'Build serially; supply signing credentials only through the normal secure build environment. Remove this disposable source after verification.'}, null, 2));
} catch (error) {
  let cleaned = false;
  try {
    await rm(root, {recursive: true, force: true});
    cleaned = true;
  } catch (cleanupError) {
    console.error(`Could not remove failed preparation at ${root}: ${cleanupError.message}`);
  }
  console.log(JSON.stringify({success: false, prepared_root: root, cleaned, error: error.message}));
  console.error(`Could not prepare isolated old-version source at ${root}: ${error.message}`);
  process.exitCode = 1;
}
}

if (process.argv[1] && await realpath(resolve(process.argv[1])).catch(() => null)
    === await realpath(fileURLToPath(import.meta.url))) {
  await prepare();
}
