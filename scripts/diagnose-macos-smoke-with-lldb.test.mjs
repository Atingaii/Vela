import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runLldbFallback, shouldRunLldb, summarizeLldb } from './diagnose-macos-smoke-with-lldb.mjs';

test('LLDB fallback gate requires a failed macOS smoke without a matching crash', () => {
  assert.equal(shouldRunLldb({ success: false }, { matching_crashes: [] }, 'darwin'), true);
  assert.equal(shouldRunLldb({ success: true }, { matching_crashes: [] }, 'darwin'), false);
  assert.equal(shouldRunLldb({ success: false }, { matching_crashes: [{}] }, 'darwin'), false);
  assert.equal(shouldRunLldb({ success: false }, { matching_crashes: [] }, 'linux'), false);
});

test('LLDB transcript retains only bounded exception values and thread frames', () => {
  const transcript = [
    '(lldb) thread backtrace all',
    '* thread #1, stop reason = breakpoint 1.1',
    '  * frame #0: objc_exception_throw',
    'SECRET_COOKIE=do-not-upload',
    '(lldb) expression -l objc -O -t 1000000 -- [(id)$rdi name]',
    'NSInvalidArgumentException',
    '(lldb) expression -l objc -O -t 1000000 -- [(id)$rdi reason]',
    'unrecognized selector',
  ].join('\n');
  const result = summarizeLldb(transcript, 'x64');
  assert.equal(result.breakpoint_hit, true);
  assert.equal(result.exception_name, 'NSInvalidArgumentException');
  assert.equal(result.exception_reason, 'unrecognized selector');
  assert.equal(result.backtrace.length, 2);
  assert.doesNotMatch(JSON.stringify(result), /SECRET_COOKIE/);
  assert.equal(summarizeLldb(transcript.replaceAll('$rdi', '$x0'), 'arm64').exception_name,
    'NSInvalidArgumentException');
  const denied = summarizeLldb('error: attach failed (Not allowed to attach to process.)', 'x64');
  assert.equal(denied.debugger_status, 'attach_denied');
  assert.equal(denied.exception_name, null);
});

test('failure rerun uses the same binary and a new empty smoke root, then cleans it', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'velo-lldb-test-'));
  try {
    const binary = join(dir, 'velo');
    const smoke = join(dir, 'smoke.json');
    const crash = join(dir, 'crash.json');
    const output = join(dir, 'lldb.json');
    const record = join(dir, 'invocation.json');
    const fixture = join(dir, 'fake-lldb.mjs');
    await writeFile(binary, 'fixture');
    await writeFile(smoke, JSON.stringify({ success: false }));
    await writeFile(crash, JSON.stringify({ matching_crashes: [] }));
    await writeFile(fixture, `
import { readdirSync, writeFileSync } from 'node:fs';
const args = process.argv.slice(2);
const root = args.at(-1);
writeFileSync(process.env.LLDB_FIXTURE_RECORD, JSON.stringify({ args, root, entries: readdirSync(root) }));
console.log('(lldb) thread backtrace all');
console.log('* thread #1, stop reason = breakpoint 1.1');
console.log('  * frame #0: objc_exception_throw');
console.log('SECRET_COOKIE=do-not-upload');
console.log('(lldb) expression -l objc -O -t 1000000 -- [(id)$rdi name]');
console.log('NSInvalidArgumentException');
console.log('(lldb) expression -l objc -O -t 1000000 -- [(id)$rdi reason]');
console.log('bad selector');
`);
    const result = await runLldbFallback({
      executable: binary, smokeReport: smoke, crashReport: crash, output,
      platform: 'darwin', arch: 'x64', lldbExecutable: process.execPath,
      lldbArgsPrefix: [fixture], env: { ...process.env, LLDB_FIXTURE_RECORD: record },
    });
    const invocation = JSON.parse(await readFile(record, 'utf8'));
    assert.deepEqual(invocation.entries, []);
    assert.equal(invocation.args[invocation.args.indexOf('--file') + 1], binary);
    assert.deepEqual(invocation.args.slice(-3), ['--', '--smoke-test', invocation.root]);
    assert.ok(invocation.args.includes('--no-lldbinit'));
    await assert.rejects(stat(invocation.root), { code: 'ENOENT' });
    assert.equal(result.exception_name, 'NSInvalidArgumentException');
    assert.equal(result.timed_out, false);
    assert.deepEqual(JSON.parse(await readFile(output, 'utf8')), result);
    assert.doesNotMatch(JSON.stringify(result), /SECRET_COOKIE/);

    await writeFile(crash, JSON.stringify({ matching_crashes: [{ report_id: 'matched' }] }));
    assert.equal(await runLldbFallback({ executable: binary, smokeReport: smoke,
      crashReport: crash, output, platform: 'darwin', arch: 'x64',
      lldbExecutable: '/no/such/lldb' }), null);
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('hanging LLDB is killed within the configured bound and its root is removed', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'velo-lldb-timeout-test-'));
  try {
    const smoke = join(dir, 'smoke.json');
    const crash = join(dir, 'crash.json');
    const output = join(dir, 'lldb.json');
    const record = join(dir, 'root.txt');
    const fixture = join(dir, 'hang.mjs');
    await writeFile(smoke, '{"success":false}');
    await writeFile(crash, '{"matching_crashes":[]}');
    await writeFile(fixture, `
import { writeFileSync } from 'node:fs';
writeFileSync(process.env.LLDB_FIXTURE_RECORD, process.argv.at(-1));
setInterval(() => {}, 1000);
`);
    const result = await runLldbFallback({
      executable: join(dir, 'velo'), smokeReport: smoke, crashReport: crash, output,
      platform: 'darwin', arch: 'x64', timeoutMs: 500,
      lldbExecutable: process.execPath, lldbArgsPrefix: [fixture],
      env: { ...process.env, LLDB_FIXTURE_RECORD: record },
    });
    assert.equal(result.timed_out, true);
    await assert.rejects(stat(await readFile(record, 'utf8')), { code: 'ENOENT' });
  } finally { await rm(dir, { recursive: true, force: true }); }
});
