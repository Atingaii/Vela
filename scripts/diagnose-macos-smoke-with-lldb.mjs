// Failure-only fallback when macOS did not write a matching crash report.
// The inferior uses the same installed binary, args and inherited environment
// as smoke-installed.mjs, but gets its own empty, disposable smoke root.
import { spawn } from 'node:child_process';
import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const MAX_INPUT_BYTES = 256 * 1024;
const MAX_OUTPUT_BYTES = 192 * 1024;
const MAX_FRAMES = 400;
const TIMEOUT_MS = 30_000;

async function smallJson(path) {
  const info = await stat(path);
  if (info.size > MAX_INPUT_BYTES) throw new Error('diagnostic input too large');
  return JSON.parse(await readFile(path, 'utf8'));
}

export function shouldRunLldb(smoke, crashDiagnostic, platform = process.platform) {
  return platform === 'darwin' && smoke?.success === false
    && (!Array.isArray(crashDiagnostic?.matching_crashes)
      || crashDiagnostic.matching_crashes.length === 0);
}

function limitedLine(value, max) {
  return value.replace(/[\x00-\x1f\x7f]/g, ' ').trim().slice(0, max);
}

export function summarizeLldb(transcript, arch) {
  const lines = transcript.split(/\r?\n/);
  const register = arch === 'arm64' ? 'x0' : 'rdi';
  const breakpointHit = lines.some((line) => /stop reason = breakpoint 1(?:\.\d+)?\b/.test(line));
  const expression = (field, max) => {
    if (!breakpointHit) return null;
    const command = `[(id)$${register} ${field}]`;
    const start = lines.findIndex((line) => line.startsWith('(lldb) expression ') && line.includes(command));
    if (start < 0) return null;
    const answer = lines.slice(start + 1, start + 5)
      .find((line) => line.trim() && !line.startsWith('(lldb)') && !/^error:/i.test(line.trim()));
    return answer ? limitedLine(answer, max) : null;
  };
  const frames = lines.filter((line) => /^\s*(?:\* )?(?:thread|frame) #\d+\b/i.test(line));
  const debuggerStatus = /attach failed.*not allowed to attach/i.test(transcript)
    ? 'attach_denied'
    : /process launch failed/i.test(transcript) ? 'launch_failed'
      : /^error:/m.test(transcript) ? 'lldb_command_error' : null;
  return {
    breakpoint_hit: breakpointHit,
    debugger_status: debuggerStatus,
    exception_name: expression('name', 256),
    exception_reason: expression('reason', 512),
    backtrace: frames.slice(0, MAX_FRAMES).map((line) => limitedLine(line, 700)),
    backtrace_limited: frames.length > MAX_FRAMES,
  };
}

function stopGroup(child) {
  if (!child.pid) return;
  try { process.kill(-child.pid, 'SIGKILL'); }
  catch (error) { if (error.code !== 'ESRCH') throw error; }
}

export async function runLldbFallback({ executable, smokeReport, crashReport, output,
  platform = process.platform, arch = process.arch, timeoutMs = TIMEOUT_MS,
  lldbExecutable = 'lldb', lldbArgsPrefix = [], env = process.env }) {
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > TIMEOUT_MS) {
    throw new Error('LLDB timeout must be an integer from 1 to 30000');
  }
  // Missing/invalid smoke reports do not authorize another native launch.
  let smoke;
  try { smoke = await smallJson(smokeReport); } catch { return null; }
  let crashDiagnostic;
  try { crashDiagnostic = await smallJson(crashReport); } catch { /* Collector may have failed. */ }
  if (!shouldRunLldb(smoke, crashDiagnostic, platform)) return null;

  const binary = resolve(executable);
  const root = await mkdtemp(join(tmpdir(), 'velo-install-smoke-lldb-'));
  const register = arch === 'arm64' ? 'x0' : arch === 'x64' ? 'rdi' : null;
  let child;
  let timedOut = false;
  let outputTruncated = false;
  let capturedBytes = 0;
  const chunks = [];
  let exit = { code: null, signal: null, error: null };
  let cleanupError = null;
  try {
    if (!register) throw new Error('unsupported_arch');
    const args = [
      ...lldbArgsPrefix, '--batch', '--no-lldbinit',
      '-o', 'breakpoint set --name objc_exception_throw',
      '-o', 'run',
      '-o', `expression -l objc -O -t 1000000 -- [(id)$${register} name]`,
      '-o', `expression -l objc -O -t 1000000 -- [(id)$${register} reason]`,
      '-o', 'thread backtrace all',
      '--file', binary, '--', '--smoke-test', root,
    ];
    child = spawn(lldbExecutable, args, { env, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
    for (const stream of [child.stdout, child.stderr]) {
      stream.on('data', (chunk) => {
        const left = MAX_OUTPUT_BYTES - capturedBytes;
        if (left > 0) {
          const kept = chunk.subarray(0, left);
          chunks.push(kept);
          capturedBytes += kept.length;
        }
        if (chunk.length > left) outputTruncated = true;
      });
    }
    let timer;
    const finished = new Promise((done) => {
      child.once('error', (error) => done({ code: null, signal: null, error: error.code ?? 'spawn_error' }));
      child.once('close', (code, signal) => done({ code, signal, error: null }));
    });
    const deadline = new Promise((done) => {
      timer = setTimeout(() => done(null), timeoutMs);
    });
    const result = await Promise.race([finished, deadline]);
    clearTimeout(timer);
    if (result) exit = result;
    else {
      timedOut = true;
      stopGroup(child);
      exit = await Promise.race([
        finished,
        new Promise((done) => setTimeout(() => done({ code: null, signal: null, error: 'kill_not_reaped' }), 1_000)),
      ]);
      if (exit.error === 'kill_not_reaped') child.unref();
    }
  } catch (error) {
    exit.error = error.message === 'unsupported_arch' ? 'unsupported_arch' : 'lldb_error';
    if (child) stopGroup(child);
  } finally {
    // root is created here and nowhere else; never remove caller-owned paths.
    try { await rm(root, { recursive: true, force: true }); }
    catch { cleanupError = 'temporary_root_cleanup_failed'; }
  }
  const summary = summarizeLldb(Buffer.concat(chunks).toString('utf8'), arch);
  const report = {
    kind: 'first_objc_exception_throw',
    interpretation: 'First Objective-C throw under LLDB; the exception may be handled internally.',
    executable: binary,
    arch,
    timeout_ms: timeoutMs,
    timed_out: timedOut,
    lldb_exit_code: exit.code,
    lldb_exit_signal: exit.signal,
    error: exit.error,
    output_truncated: outputTruncated,
    cleanup_error: cleanupError,
    ...summary,
  };
  await mkdir(dirname(resolve(output)), { recursive: true });
  await writeFile(output, `${JSON.stringify(report, null, 2)}\n`);
  return report;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [executable, smokeReport, crashReport, output] = process.argv.slice(2);
  if (!executable || !smokeReport || !crashReport || !output) {
    throw new Error('Usage: node scripts/diagnose-macos-smoke-with-lldb.mjs <binary> <smoke.json> <crash-diagnostic.json> <output.json>');
  }
  const report = await runLldbFallback({ executable, smokeReport, crashReport, output });
  console.log(report ? 'Bounded LLDB fallback captured for failed native smoke.' : 'LLDB fallback not needed.');
}
