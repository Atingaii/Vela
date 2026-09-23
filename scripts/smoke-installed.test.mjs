import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runInstalledSmoke } from './smoke-installed-core.mjs';

async function fixture() {
  const dir = await mkdtemp(join(tmpdir(), 'velo-smoke-runner-test-'));
  const script = join(dir, 'fixture.mjs');
  await writeFile(script, `
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
  return { dir, script };
}

async function run(script, reportPath, env = {}, timeoutMs = 2_000) {
  const report = await runInstalledSmoke({
    executable: process.execPath,
    argsForDirectory: (dir) => [script, '--smoke-test', dir],
    reportPath,
    timeoutMs,
    env: { ...process.env, ...env },
    stdio: 'ignore',
  });
  assert.deepEqual(report, JSON.parse(await readFile(reportPath, 'utf8')));
  return report;
}

// The fixture tests the same process lifecycle on macOS and Windows with the native node.exe.
// Production still invokes the real installed binary with --smoke-test <fresh directory>.
test('installed smoke runner records success and cleans its own directory', async () => {
  const { dir, script } = await fixture();
  try {
    const report = await run(script, join(dir, 'pass.json'), { SMOKE_FIXTURE_MODE: 'pass' });
    assert.equal(report.success, true);
    assert.equal(report.smoke_runner.exit_code, 0);
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('installed smoke runner preserves failure report without child output', async () => {
  const { dir, script } = await fixture();
  try {
    const report = await run(script, join(dir, 'fail.json'), { SMOKE_FIXTURE_MODE: 'fail' });
    assert.equal(report.success, false);
    assert.equal(report.smoke_runner.exit_code, 9);
    assert.match(report.smoke_runner.error, /smoke-result.json unavailable/);
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('installed smoke runner times out and terminates its process tree', async () => {
  const { dir, script } = await fixture();
  const heartbeat = join(dir, 'heartbeat');
  const pidPath = join(dir, 'grandchild.pid');
  let grandchildPid;
  try {
    const report = await run(script, join(dir, 'timeout.json'), {
      SMOKE_FIXTURE_MODE: 'hang', SMOKE_HEARTBEAT: heartbeat, SMOKE_CHILD_PID: pidPath,
    }, process.platform === 'win32' ? 2_500 : 500);
    assert.equal(report.success, false);
    assert.equal(report.smoke_runner.timed_out, true);
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
