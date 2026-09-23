import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { chmod, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const runner = new URL('./smoke-installed.mjs', import.meta.url).pathname;

async function fixture() {
  const dir = await mkdtemp(join(tmpdir(), 'velo-smoke-runner-test-'));
  const binary = join(dir, 'fixture.mjs');
  await writeFile(binary, `#!/usr/bin/env node
import {spawn} from 'node:child_process';
import {writeFileSync} from 'node:fs';
import {join} from 'node:path';
const output=process.argv.at(-1);
if(process.env.SMOKE_FIXTURE_MODE==='pass') {
  writeFileSync(join(output,'smoke-result.json'),JSON.stringify({success:true,settings_webview_and_ipc:true,bundled_helper:true,providers_started:false}));
} else if(process.env.SMOKE_FIXTURE_MODE==='fail') {
  process.exit(9);
} else {
  const grandchild=spawn(process.execPath,['-e',"setInterval(()=>require('fs').writeFileSync(process.env.SMOKE_HEARTBEAT,String(Date.now())),30)"],{stdio:'ignore'});
  writeFileSync(process.env.SMOKE_CHILD_PID,String(grandchild.pid));
  setInterval(()=>{},1000);
}
`);
  await chmod(binary, 0o755);
  return { dir, binary };
}

async function run(binary, report, env = {}) {
  const child = spawn(process.execPath, [runner, binary, report], {
    env: { ...process.env, ...env }, stdio: ['ignore', 'pipe', 'pipe'],
  });
  let stderr = '';
  child.stderr.on('data', (chunk) => { stderr += chunk; });
  const status = await new Promise((resolve) => child.once('close', (code, signal) => resolve({ code, signal })));
  return { ...status, stderr, report: JSON.parse(await readFile(report, 'utf8')) };
}

// The fixture is a process-contract test only. The production runner always launches the actual
// installed binary; its WebView/IPC behavior is verified by the installed-app smoke itself.
test('installed smoke runner records success and cleans its own directory', { skip: process.platform === 'win32' }, async () => {
  const { dir, binary } = await fixture();
  try {
    const result = await run(binary, join(dir, 'pass.json'), { SMOKE_FIXTURE_MODE: 'pass' });
    assert.equal(result.code, 0);
    assert.equal(result.report.success, true);
    assert.equal(result.report.smoke_runner.exit_code, 0);
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('installed smoke runner preserves failure report without child output', { skip: process.platform === 'win32' }, async () => {
  const { dir, binary } = await fixture();
  try {
    const result = await run(binary, join(dir, 'fail.json'), { SMOKE_FIXTURE_MODE: 'fail' });
    assert.equal(result.code, 1);
    assert.equal(result.report.success, false);
    assert.equal(result.report.smoke_runner.exit_code, 9);
    assert.match(result.report.smoke_runner.error, /smoke-result.json unavailable/);
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('installed smoke runner times out and terminates its process tree', { skip: process.platform === 'win32' }, async () => {
  const { dir, binary } = await fixture();
  const heartbeat = join(dir, 'heartbeat');
  const pidPath = join(dir, 'grandchild.pid');
  let grandchildPid;
  try {
    const result = await run(binary, join(dir, 'timeout.json'), {
      SMOKE_FIXTURE_MODE: 'hang', SMOKE_HEARTBEAT: heartbeat, SMOKE_CHILD_PID: pidPath,
      VELO_SMOKE_TIMEOUT_MS: '500',
    });
    assert.equal(result.code, 1);
    assert.equal(result.report.success, false);
    assert.equal(result.report.smoke_runner.timed_out, true);
    grandchildPid = Number(await readFile(pidPath, 'utf8'));
    const before = await readFile(heartbeat, 'utf8');
    await new Promise((resolve) => setTimeout(resolve, 250));
    const after = await readFile(heartbeat, 'utf8');
    assert.equal(after, before, 'grandchild must not keep writing after the timeout');
  } finally {
    if (grandchildPid) { try { process.kill(grandchildPid, 'SIGKILL'); } catch {} }
    await rm(dir, { recursive: true, force: true });
  }
});
