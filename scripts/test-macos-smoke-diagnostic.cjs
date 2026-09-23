const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

test('isolated macOS diagnostic accepts only the matching executable and retains exception frames', async () => {
  const { summarizeIps, summarizeCrash } = await import('./collect-macos-smoke-diagnostic.mjs');
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'velo-diagnostic-fixture-'));
  try {
    const binary = path.join(root, 'installed', 'velo');
    fs.mkdirSync(path.dirname(binary));
    fs.writeFileSync(binary, 'fixture');
    // Directory junctions exercise realpath on Windows without requiring the
    // optional permission to create file symlinks on a normal installation.
    const aliasDirectory = path.join(root, 'alias');
    fs.symlinkSync(path.dirname(binary), aliasDirectory, process.platform === 'win32' ? 'junction' : 'dir');
    const alias = path.join(aliasDirectory, 'velo');
    const contents = (procPath) => [
      JSON.stringify({ incident_id: 'fixture-id' }),
      JSON.stringify({
        procName: 'velo', procPath, captureTime: 'fixture-time',
        osVersion: { train: 'macOS 15.7' },
        exception: { type: 'EXC_CRASH' },
        asi: { libc: ['-[Missing selector]'] },
        usedImages: [{ path: '/System/Library/AppKit.framework/AppKit' }],
        lastExceptionBacktrace: [{ symbol: 'objc_exception_throw', imageIndex: 0, imageOffset: 12 }],
        faultingThread: 0,
        threads: [{ frames: [{ symbol: 'startup', imageIndex: 0, imageOffset: 24 }] }],
      }),
    ].join('\n');
    const result = summarizeIps(contents(alias), binary);
    assert.equal(result.report_id, 'fixture-id');
    assert.equal(result.application_specific_information.libc[0], '-[Missing selector]');
    assert.equal(result.last_exception_backtrace[0].symbol, 'objc_exception_throw');
    assert.equal(result.faulting_thread[0].image, 'AppKit');
    assert.equal(summarizeIps(contents(path.join(root, 'other')), binary), null);
    const legacy = summarizeCrash([
      'Process: velo [1]', `Path: ${alias}`, 'Exception Type: EXC_CRASH',
      'Application Specific Information:',
      "*** Terminating app due to uncaught exception 'NSInvalidArgumentException', reason: 'missing selector'",
      '', 'Last Exception Backtrace:', '0 CoreFoundation objc_exception_throw',
      '1 AppKit startup', '', 'Thread 0 Crashed:', '0 startup',
    ].join('\n'), binary);
    assert.match(legacy.application_specific_information[0], /missing selector/);
    assert.equal(legacy.last_exception_backtrace[0], '0 CoreFoundation objc_exception_throw');
    assert.equal(legacy.last_exception_backtrace[1], '1 AppKit startup');
    assert.equal(legacy.faulting_thread[1], '0 startup');
    assert.equal(summarizeCrash(`Process: other [1]\nPath: ${alias}`, binary), null);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
