// A preview feed is published only after the tagged release owns every signed
// updater artifact. The final Git ref update swaps latest.json in one step.
import {readFile, stat, writeFile} from 'node:fs/promises';
import {join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const ARTIFACTS = [
  ['darwin-aarch64', 'Velo-macos-arm64.app.tar.gz'],
  ['darwin-x86_64', 'Velo-macos-x64.app.tar.gz'],
  ['windows-x86_64', 'Velo-windows-x64-setup.exe'],
];

export function releaseVersion(tag, versions) {
  const match = /^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)-preview\.(0|[1-9]\d*)$/.exec(tag);
  if (!match) throw new Error('Expected a versioned preview tag');
  const version = tag.slice(1);
  for (const [source, value] of Object.entries(versions)) {
    if (value !== version) throw new Error(`${source} version does not match ${tag}`);
  }
  return version;
}

export function comparePreviewVersions(left, right) {
  function parts(version) {
    const match = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-preview\.(0|[1-9]\d*))?$/.exec(version);
    if (!match) throw new Error(`Unsupported feed version: ${version}`);
    return [Number(match[1]), Number(match[2]), Number(match[3]),
      match[4] === undefined ? Number.POSITIVE_INFINITY : Number(match[4])];
  }
  const a = parts(left), b = parts(right);
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return a[i] > b[i] ? 1 : -1;
  return 0;
}

export async function buildFeed(directory, tag, versions, repository, now = new Date()) {
  const version = releaseVersion(tag, versions);
  if (!/^[\w.-]+\/[\w.-]+$/.test(repository)) throw new Error('Invalid repository');
  const platforms = {};
  for (const [platform, filename] of ARTIFACTS) {
    const bundle = join(directory, filename);
    const signaturePath = `${bundle}.sig`;
    const [bundleStat, sigStat, signature] = await Promise.all([
      stat(bundle), stat(signaturePath), readFile(signaturePath, 'utf8'),
    ]);
    if (!bundleStat.isFile() || bundleStat.size === 0 || !sigStat.isFile()
        || sigStat.size === 0 || !signature.trim() || signature.includes('\0')) {
      throw new Error(`Missing or invalid signed updater artifact: ${filename}`);
    }
    platforms[platform] = {
      url: `https://github.com/${repository}/releases/download/${tag}/${filename}`,
      signature: signature.trim(),
    };
  }
  return {version, pub_date: now.toISOString(), platforms};
}

export function verifyRemoteRelease(release, feed) {
  if (release.draft || !release.prerelease || release.tag_name !== `v${feed.version}`) {
    throw new Error('Tagged preview release is unavailable');
  }
  const uploaded = new Map((release.assets || []).map(asset => [asset.name, asset.size]));
  for (const [, filename] of ARTIFACTS) {
    if (!(uploaded.get(filename) > 0) || !(uploaded.get(`${filename}.sig`) > 0)) {
      throw new Error(`Release is missing signed platform artifact: ${filename}`);
    }
  }
}

async function github(path, token, method = 'GET', data) {
  const response = await fetch(`https://api.github.com/repos/${path}`, {
    method,
    headers: {
      Accept: 'application/vnd.github+json',
      Authorization: `Bearer ${token}`,
      'X-GitHub-Api-Version': '2022-11-28',
      ...(data && {'Content-Type': 'application/json'}),
    },
    ...(data && {body: JSON.stringify(data)}),
  });
  if (response.status === 404 && method === 'GET') return null;
  if (!response.ok) throw new Error(`GitHub ${method} ${path}: HTTP ${response.status}`);
  return response.json();
}

export async function publishFeed(repository, token, feed) {
  if (!token) throw new Error('Missing GitHub token');
  const tag = `v${feed.version}`;
  const release = await github(`${repository}/releases/tags/${tag}`, token);
  if (!release) throw new Error('Tagged preview release was not published');
  verifyRemoteRelease(release, feed);

  const ref = await github(`${repository}/git/ref/heads/updates-preview`, token);
  let parent = null, baseTree = null;
  if (ref) {
    parent = ref.object.sha;
    const current = await github(`${repository}/contents/latest.json?ref=updates-preview`, token);
    if (current?.encoding === 'base64') {
      const previous = JSON.parse(Buffer.from(current.content, 'base64').toString('utf8'));
      const relation = comparePreviewVersions(feed.version, previous.version);
      if (relation < 0) throw new Error('Refusing to replace a newer preview feed');
      if (relation === 0) {
        if (JSON.stringify(previous.platforms) === JSON.stringify(feed.platforms)) return 'unchanged';
        throw new Error('A feed for this version already has different signatures');
      }
    }
    const commit = await github(`${repository}/git/commits/${parent}`, token);
    baseTree = commit.tree.sha;
  }

  const blob = await github(`${repository}/git/blobs`, token, 'POST', {
    content: `${JSON.stringify(feed, null, 2)}\n`, encoding: 'utf-8',
  });
  const tree = await github(`${repository}/git/trees`, token, 'POST', {
    ...(baseTree && {base_tree: baseTree}),
    tree: [{path: 'latest.json', mode: '100644', type: 'blob', sha: blob.sha}],
  });
  const commit = await github(`${repository}/git/commits`, token, 'POST', {
    message: `Preview update feed ${tag}`, tree: tree.sha, parents: parent ? [parent] : [],
  });
  if (parent) {
    await github(`${repository}/git/refs/heads/updates-preview`, token, 'PATCH',
      {sha: commit.sha, force: false});
  } else {
    await github(`${repository}/git/refs`, token, 'POST',
      {ref: 'refs/heads/updates-preview', sha: commit.sha});
  }
  return commit.sha;
}

async function main() {
  const [directory, tag] = process.argv.slice(2);
  if (!directory || !tag) throw new Error('Usage: preview-update-feed.mjs <assets-dir> <tag>');
  const root = fileURLToPath(new URL('..', import.meta.url));
  const [pkg, tauri, cargo] = await Promise.all([
    readFile(join(root, 'package.json'), 'utf8').then(JSON.parse),
    readFile(join(root, 'src-tauri/tauri.conf.json'), 'utf8').then(JSON.parse),
    readFile(join(root, 'src-tauri/Cargo.toml'), 'utf8'),
  ]);
  const rustVersion = /^version\s*=\s*"([^"]+)"/m.exec(cargo)?.[1];
  const repository = process.env.GITHUB_REPOSITORY;
  const feed = await buildFeed(directory, tag,
    {package: pkg.version, tauri: tauri.version, rust: rustVersion}, repository);
  await writeFile(join(directory, 'latest.json'), `${JSON.stringify(feed, null, 2)}\n`);
  if (process.argv.includes('--publish')) {
    const sha = await publishFeed(repository, process.env.GITHUB_TOKEN, feed);
    process.stdout.write(`Published preview feed ${feed.version} at ${sha}\n`);
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  main().catch(error => {console.error(error.message); process.exitCode = 1;});
}
