// Capture only the crash from this isolated Velo smoke run. Never upload the
// runner's complete DiagnosticReports directory or unified system log.
import { realpathSync } from 'node:fs';
import { readFile, readdir, realpath, stat, writeFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { basename, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const MAX_REPORT_BYTES = 8 * 1024 * 1024;
const WAIT_MS = 8_000;

function asObject(value) {
  return value && typeof value === 'object' && !Array.isArray(value) ? value : {};
}

function sameExecutable(path, expected) {
  if (typeof path !== 'string') return false;
  try {
    return realpathSync(path) === realpathSync(expected);
  } catch {
    return false;
  }
}

function frames(thread, images) {
  return (asObject(thread).frames ?? []).slice(0, 80).map((frame) => {
    const image = images[frame.imageIndex];
    return {
      symbol: frame.symbol ?? null,
      image: image ? basename(image.path ?? image.name ?? '') : null,
      image_offset: frame.imageOffset ?? null,
    };
  });
}

export function summarizeIps(contents, executable) {
  const separator = contents.indexOf('\n');
  if (separator < 0) return null;
  let header;
  let body;
  try {
    header = JSON.parse(contents.slice(0, separator));
    body = JSON.parse(contents.slice(separator + 1));
  } catch {
    return null;
  }
  if (!sameExecutable(asObject(body).procPath, executable) || body.procName !== 'velo') return null;
  const images = Array.isArray(body.usedImages) ? body.usedImages : [];
  const threads = Array.isArray(body.threads) ? body.threads : [];
  const faultingThread = Number.isInteger(body.faultingThread) ? body.faultingThread : 0;
  return {
    report_id: header.incident_id ?? body.incident ?? null,
    capture_time: body.captureTime ?? null,
    process: body.procName,
    executable: body.procPath,
    os_version: body.osVersion ?? null,
    exception: body.exception ?? null,
    termination: body.termination ?? null,
    application_specific_information: body.asi ?? null,
    last_exception_backtrace: Array.isArray(body.lastExceptionBacktrace)
      ? frames({ frames: body.lastExceptionBacktrace }, images)
      : [],
    faulting_thread: frames(threads[faultingThread], images),
  };
}

export function summarizeCrash(contents, executable) {
  const path = contents.match(/^Path:\s*(.+)$/m)?.[1]?.trim();
  if (!sameExecutable(path, executable) || !/^Process:\s*velo(?:\s|$)/m.test(contents)) return null;
  const lines = contents.split(/\r?\n/);
  const section = (heading, limit) => {
    const start = lines.findIndex((line) => line === heading);
    if (start < 0) return [];
    const result = [];
    for (const line of lines.slice(start + 1, start + 1 + limit)) {
      if (!line.trim() || /^[A-Z][A-Za-z0-9 /()]+:\s*$/.test(line)) break;
      result.push(line);
    }
    return result;
  };
  const fault = lines.findIndex((line) => /^Thread \d+ Crashed:/.test(line));
  return {
    process: 'velo',
    executable: path,
    exception: lines.filter((line) => /^(Exception Type|Exception Codes|Termination Reason):/.test(line)).slice(0, 12),
    application_specific_information: section('Application Specific Information:', 30),
    last_exception_backtrace: section('Last Exception Backtrace:', 60),
    faulting_thread: fault >= 0 ? lines.slice(fault, fault + 82) : [],
  };
}

export async function collect({ executable, reportsDirectory, sinceMs, smokeReport }) {
  const target = await realpath(executable);
  let macosVersion = null;
  if (process.platform === 'darwin') {
    try {
      macosVersion = execFileSync('sw_vers', ['-productVersion'], { encoding: 'utf8' }).trim();
    } catch {
      // The crash report may still carry its own OS version.
    }
  }
  const outcome = {
    executable: target,
    arch: process.arch,
    os: process.platform,
    macos_version: macosVersion,
    started_ms: sinceMs,
    smoke: null,
    matching_crashes: [],
  };
  try {
    const smoke = JSON.parse(await readFile(smokeReport, 'utf8'));
    outcome.smoke = { success: smoke.success, runner: smoke.smoke_runner ?? null };
  } catch {
    outcome.smoke = { report_unavailable: true };
  }
  if (process.platform !== 'darwin') return outcome;
  const deadline = Date.now() + (outcome.smoke?.success ? 0 : WAIT_MS);
  do {
    const names = await readdir(reportsDirectory).catch(() => []);
    for (const name of names) {
      if (!/^velo[-_.].*\.(ips|crash)$/i.test(name)) continue;
      const path = join(reportsDirectory, name);
      const info = await stat(path).catch(() => null);
      if (!info || info.mtimeMs + 1000 < sinceMs || info.size > MAX_REPORT_BYTES) continue;
      const contents = await readFile(path, 'utf8').catch(() => null);
      if (!contents) continue;
      const summary = name.endsWith('.ips')
        ? summarizeIps(contents, target)
        : summarizeCrash(contents, target);
      if (summary) outcome.matching_crashes.push(summary);
    }
    if (outcome.matching_crashes.length || Date.now() >= deadline) break;
    await new Promise((resolveWait) => setTimeout(resolveWait, 500));
  } while (true);
  return outcome;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [executable, output, since, smokeReport] = process.argv.slice(2);
  if (!executable || !output || !since || !smokeReport) {
    throw new Error('Usage: node scripts/collect-macos-smoke-diagnostic.mjs <binary> <output.json> <since-ms> <smoke.json>');
  }
  const result = await collect({
    executable,
    reportsDirectory: join(process.env.HOME, 'Library/Logs/DiagnosticReports'),
    sinceMs: Number(since),
    smokeReport,
  });
  await writeFile(output, `${JSON.stringify(result, null, 2)}\n`);
  console.log(`Isolated Velo smoke diagnostic: ${result.matching_crashes.length} matching crash report(s)`);
}
