// Run the actual installed executable, not a dev server or mock WebView.
import { spawn } from 'node:child_process';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';

const [binary, reportPath] = process.argv.slice(2);
if (!binary || !reportPath) {
  throw new Error('Usage: node scripts/smoke-installed.mjs <installed binary> <report.json>');
}

const timeoutMs = Number(process.env.VELO_SMOKE_TIMEOUT_MS ?? 45_000);
if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 45_000) {
  throw new Error('VELO_SMOKE_TIMEOUT_MS must be an integer from 1 to 45000');
}

function waitFor(promise, ms) {
  let timer;
  const deadline = new Promise((resolve) => { timer = setTimeout(() => resolve(null), ms); });
  return Promise.race([promise, deadline]).finally(() => clearTimeout(timer));
}

function signalChild(child, signal) {
  if (!child.pid) return;
  try {
    // The child owns a new POSIX process group so its own helper processes are reaped too.
    if (process.platform === 'win32') child.kill(signal);
    else process.kill(-child.pid, signal);
  } catch (error) {
    if (error.code !== 'ESRCH') throw error;
  }
}

async function hardStop(child) {
  if (process.platform !== 'win32' || !child.pid) {
    signalChild(child, 'SIGKILL');
    return;
  }
  // Windows child.kill does not terminate descendants; taskkill /T only targets this PID tree.
  const killer = spawn('taskkill', ['/PID', String(child.pid), '/T', '/F'], {
    stdio: 'ignore', windowsHide: true,
  });
  const finished = new Promise((resolve) => {
    killer.once('error', () => resolve(true));
    killer.once('close', () => resolve(true));
  });
  if (await waitFor(finished, 2_000) === null) killer.kill();
  child.kill('SIGKILL');
}

async function stopChild(child, exited) {
  if (process.platform === 'win32') {
    // Terminate the tree while the parent PID still identifies its descendants.
    await hardStop(child);
  } else {
    signalChild(child, 'SIGTERM');
    const graceful = await waitFor(exited, 2_000);
    if (graceful !== null) return graceful;
    await hardStop(child);
  }
  const stopped = await waitFor(exited, 2_000);
  if (stopped !== null) return stopped;
  child.unref();
  return { code: null, signal: null, error: 'child did not exit after SIGKILL' };
}

const dir = await mkdtemp(join(tmpdir(), 'velo-install-smoke-'));
let child;
let exited;
let interrupt;
let wakeInterrupt;
const interrupted = new Promise((resolve) => { wakeInterrupt = resolve; });
const onSigint = () => { interrupt = 'SIGINT'; wakeInterrupt({ kind: 'interrupted' }); };
const onSigterm = () => { interrupt = 'SIGTERM'; wakeInterrupt({ kind: 'interrupted' }); };
process.once('SIGINT', onSigint);
process.once('SIGTERM', onSigterm);
let outcome = { code: null, signal: null, error: null };
let timedOut = false;
let appReport = {};
let cleanupError = null;
try {
  child = spawn(resolve(binary), ['--smoke-test', dir], {
    stdio: 'inherit', detached: process.platform !== 'win32', windowsHide: true,
  });
  exited = new Promise((resolveExit) => {
    child.once('error', (error) => resolveExit({ code: null, signal: null, error: error.message }));
    child.once('close', (code, signal) => resolveExit({ code, signal, error: null }));
  });
  let timeoutTimer;
  const deadline = new Promise((resolveDeadline) => {
    timeoutTimer = setTimeout(() => resolveDeadline({ kind: 'timeout' }), timeoutMs);
  });
  const first = await Promise.race([
    exited.then((value) => ({ kind: 'exit', value })),
    interrupted,
    deadline,
  ]);
  clearTimeout(timeoutTimer);
  if (first.kind === 'exit') {
    outcome = first.value;
  } else {
    timedOut = first.kind === 'timeout';
    outcome = await stopChild(child, exited);
  }
  try {
    const parsed = JSON.parse(await readFile(join(dir, 'smoke-result.json'), 'utf8'));
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) appReport = parsed;
    else outcome.error ??= 'smoke-result.json was not an object';
  } catch (error) {
    outcome.error ??= `smoke-result.json unavailable: ${error.message}`;
  }
} catch (error) {
  outcome.error ??= error.message;
  if (child && exited && child.exitCode === null && child.signalCode === null) {
    try {
      const stopped = await stopChild(child, exited);
      outcome.code = stopped.code;
      outcome.signal = stopped.signal;
      outcome.error ??= stopped.error;
    } catch (stopError) {
      outcome.error += `; cleanup failed: ${stopError.message}`;
      child.unref();
    }
  }
} finally {
  process.removeListener('SIGINT', onSigint);
  process.removeListener('SIGTERM', onSigterm);
  // This path is freshly created by this runner; never clean a caller-owned directory.
  try { await rm(dir, { recursive: true, force: true }); }
  catch (error) { cleanupError = error.message; }
}

const success = outcome.code === 0 && !timedOut && !interrupt && !outcome.error
  && appReport.success === true && appReport.settings_webview_and_ipc === true
  && appReport.bundled_helper === true && appReport.providers_started === false
  && !cleanupError;
const report = {
  ...appReport,
  success,
  smoke_runner: {
    exit_code: outcome.code,
    exit_signal: outcome.signal,
    timed_out: timedOut,
    interrupted_by: interrupt ?? null,
    error: outcome.error,
    cleanup_error: cleanupError,
  },
};
await mkdir(dirname(resolve(reportPath)), { recursive: true });
await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`);
if (success) console.log('Installed native WebView + IPC + helper: PASS', JSON.stringify(report));
else {
  console.error('Installed app smoke failed:', JSON.stringify(report));
  process.exitCode = 1;
}
