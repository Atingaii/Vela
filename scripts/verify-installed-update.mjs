// Verify a real signed preview update only inside a disposable installation. The input must be
// a deliberately built older verification bundle with the current updater key/feed, never the
// public 0.1.0 preview (which shipped before signing was configured).
import {spawn} from 'node:child_process';
import {cp, mkdir, mkdtemp, readFile, realpath, rm, stat, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {basename, dirname, join, resolve, sep} from 'node:path';
import {comparePreviewVersions} from './preview-update-feed.mjs';

const [source, expected, reportPath] = process.argv.slice(2);
if (!source || !expected || !reportPath) {
  throw new Error('Usage: verify-installed-update.mjs <older Velo.app or signed NSIS setup.exe> <new-version> <report.json>');
}
if (process.platform === 'win32' && process.env.CI !== 'true') {
  throw new Error('Windows updater verification requires a fresh isolated CI runner');
}
if (comparePreviewVersions(expected, '0.1.0') <= 0) {
  throw new Error('Expected preview version must be newer than public 0.1.0');
}

const root = await realpath(await mkdtemp(join(tmpdir(), 'velo-update-verify-')));
let child;
let report = {success: false, expected, source: resolve(source), isolated_root: root};

async function withinRoot(path) {
  if (typeof path !== 'string') return false;
  try {
    const canonical = await realpath(path);
    const normalize = process.platform === 'win32' ? (value) => value.toLowerCase() : (value) => value;
    return normalize(canonical).startsWith(normalize(`${root}${sep}`));
  } catch { return false; }
}

function powerShellQuoted(value) {
  return `'${value.replaceAll("'", "''")}'`;
}

async function windowsPowerShell(source, timeoutMs = 15_000) {
  const encoded = Buffer.from(`$ErrorActionPreference = 'Stop'; ${source}`, 'utf16le').toString('base64');
  return new Promise((done, fail) => {
    const proc = spawn('pwsh', ['-NoProfile', '-NonInteractive', '-EncodedCommand', encoded], {
      windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'],
    });
    let output = '', errors = '';
    const timer = setTimeout(() => { proc.kill(); fail(new Error('Isolated registry check timed out')); }, timeoutMs);
    proc.stdout.on('data', (part) => { output += part; if (output.length > 64_000) proc.kill(); });
    proc.stderr.on('data', (part) => { errors += part; if (errors.length > 64_000) proc.kill(); });
    proc.once('error', (error) => { clearTimeout(timer); fail(error); });
    proc.once('close', (code) => {
      clearTimeout(timer);
      if (code !== 0) fail(new Error(`Isolated registry check failed: ${errors.slice(0, 3000)}`));
      else done(output.trim());
    });
  });
}

async function windowsRegistration(mode, destination, version) {
  const location = powerShellQuoted(destination);
  const expectedVersion = powerShellQuoted(version || '');
  // Tauri's NSIS template stores the install directory both at the Velo uninstall key
  // and Software/<manufacturer>/Velo. `/UPDATE` restores the latter, so verify both.
  // The before check refuses an existing installation rather than rewriting its keys.
  const source = `
    $uninstall = 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Velo';
    $machine = 'HKLM:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Velo';
    $wow = 'HKLM:\\Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Velo';
    $vendor = @(Get-ChildItem 'HKCU:\\Software' | Where-Object { Test-Path (Join-Path $_.PSPath 'Velo') });
    $uninstallRoots = @('HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall',
      'HKLM:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall',
      'HKLM:\\Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall');
    if ((Test-Path $machine) -or (Test-Path $wow)) { throw 'Machine-wide Velo is already registered'; }
    if (${powerShellQuoted(mode)} -eq 'before') {
      $existing = @($uninstallRoots | ForEach-Object { Get-ChildItem $_ -ErrorAction SilentlyContinue } |
        ForEach-Object { Get-ItemProperty $_.PSPath } | Where-Object { $_.DisplayName -eq 'Velo' });
      if ((Test-Path $uninstall) -or $vendor.Count -ne 0 -or $existing.Count -ne 0) {
        throw 'Velo is already registered on this runner';
      }
      'clean';
    } elseif (${powerShellQuoted(mode)} -eq 'after') {
      if (-not (Test-Path $uninstall)) { throw 'Isolated NSIS did not register an installation'; }
      $entry = Get-ItemProperty $uninstall;
      $expected = [IO.Path]::GetFullPath(${location}).TrimEnd('\\');
      $actual = [IO.Path]::GetFullPath($entry.InstallLocation.Trim('"')).TrimEnd('\\');
      if (-not [string]::Equals($actual, $expected, [StringComparison]::OrdinalIgnoreCase)) { throw 'NSIS InstallLocation escaped the isolated root'; }
      if (${expectedVersion} -ne '' -and $entry.DisplayVersion -ne ${expectedVersion}) { throw 'NSIS registered an unexpected version'; }
      if ($vendor.Count -ne 1) { throw 'Expected exactly one manufacturer install key'; }
      $child = $vendor[0].OpenSubKey('Velo');
      $saved = [IO.Path]::GetFullPath($child.GetValue('')).TrimEnd('\\');
      $child.Close();
      if (-not [string]::Equals($saved, $expected, [StringComparison]::OrdinalIgnoreCase)) { throw 'NSIS update would restore a different install location'; }
      'isolated';
    } elseif (${powerShellQuoted(mode)} -eq 'cleanup') {
      if (Test-Path $uninstall) { throw 'Isolated uninstaller left the uninstall registration'; }
      $expected = [IO.Path]::GetFullPath(${location}).TrimEnd('\\');
      foreach ($parent in $vendor) {
        $child = $parent.OpenSubKey('Velo');
        if (-not $child) { continue; }
        $saved = [IO.Path]::GetFullPath($child.GetValue('')).TrimEnd('\\');
        $child.Close();
        if ([string]::Equals($saved, $expected, [StringComparison]::OrdinalIgnoreCase)) {
          Remove-Item (Join-Path $parent.PSPath 'Velo') -Force;
        }
      }
      'cleaned';
    }
  `;
  return windowsPowerShell(source);
}

async function windowsInstaller(installer, args, timeoutMs) {
  const processHandle = spawn(installer, args, {windowsHide: true, stdio: 'inherit'});
  const exit = new Promise((done) => {
    processHandle.once('error', (error) => done({error: error.message}));
    processHandle.once('close', (code, signal) => done({code, signal}));
  });
  let timer;
  const result = await Promise.race([exit, new Promise((done) => {
    timer = setTimeout(() => done({timeout: true}), timeoutMs);
  })]);
  clearTimeout(timer);
  if (result.timeout) await stopProcessTree(processHandle);
  if (result.timeout || result.error || result.code !== 0) {
    throw new Error(`Isolated NSIS install failed: ${JSON.stringify(result)}`);
  }
}

async function ownedPosixProcessGroup(pgid) {
  const listing = await new Promise((done, fail) => {
    const probe = spawn('ps', ['-ww', '-axo', 'pid=,pgid=,command='], {stdio: ['ignore', 'pipe', 'ignore']});
    let output = '';
    probe.stdout.on('data', (part) => {
      output += part;
      if (output.length > 1_000_000) probe.kill();
    });
    probe.once('error', fail);
    probe.once('close', (code) => code === 0 ? done(output) : fail(new Error('Could not inspect the isolated process group')));
  });
  return listing.split('\n').some((line) => {
    const match = /^\s*\d+\s+(\d+)\s+(.+)$/.exec(line);
    return match && Number(match[1]) === pgid && match[2].includes(root);
  });
}

async function stopProcessTree(processHandle) {
  if (!processHandle?.pid) return;
  if (process.platform === 'win32') {
    // A completed PID can be reused by an unrelated process. Remaining installer/child
    // processes are located by their executable path inside the owned temp root below.
    if (processHandle.exitCode !== null || processHandle.signalCode !== null) return;
    await new Promise((done) => {
      const killer = spawn('taskkill', ['/PID', String(processHandle.pid), '/T', '/F'], {windowsHide: true, stdio: 'ignore'});
      killer.once('error', done);
      killer.once('close', done);
    });
  } else {
    // Tauri restart inherits the isolated argv and may outlive the old group leader.
    // Check a live member still names this unique root before signaling the group;
    // a recycled numeric PGID alone is never sufficient evidence of ownership.
    if (!(await ownedPosixProcessGroup(processHandle.pid))) return;
    try { process.kill(-processHandle.pid, 'SIGTERM'); }
    catch (error) { if (error.code !== 'ESRCH') throw error; }
    await new Promise((done) => setTimeout(done, 500));
    if (await ownedPosixProcessGroup(processHandle.pid)) {
      try { process.kill(-processHandle.pid, 'SIGKILL'); }
      catch (error) { if (error.code !== 'ESRCH') throw error; }
    }
  }
}

async function stopRemainingIsolatedExecutables() {
  if (process.platform !== 'win32') return;
  // NSIS may outlive the process that launched it. Only target executables whose resolved path
  // is inside this runner's freshly created root, or its spawned installer whose command
  // line contains this unique root via `/ARGS`; never search by product name alone.
  const escaped = root.replaceAll("'", "''");
  const source = `$root = '${escaped}'; Get-CimInstance Win32_Process | Where-Object { ($_.ExecutablePath -and $_.ExecutablePath.StartsWith($root + '\\', [StringComparison]::OrdinalIgnoreCase)) -or ($_.CommandLine -and $_.CommandLine.Contains($root, [StringComparison]::OrdinalIgnoreCase) -and $_.Name -match 'setup|install') } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }`;
  const encoded = Buffer.from(source, 'utf16le').toString('base64');
  await new Promise((done, fail) => {
    const killer = spawn('pwsh', ['-NoProfile', '-NonInteractive', '-EncodedCommand', encoded], {
      stdio: 'ignore', windowsHide: true,
    });
    const timer = setTimeout(() => { killer.kill(); fail(new Error('Could not bound isolated Windows process cleanup')); }, 10_000);
    killer.once('error', (error) => { clearTimeout(timer); fail(error); });
    killer.once('close', (code) => {
      clearTimeout(timer);
      code === 0 ? done() : fail(new Error('Could not stop isolated Windows processes'));
    });
  });
}

async function run(executable, timeoutMs) {
  child = spawn(executable, ['--verify-update', root, '--expect', expected], {
    detached: process.platform !== 'win32', windowsHide: true, stdio: 'inherit',
    env: process.env,
  });
  const exited = new Promise((done) => {
    child.once('error', (error) => done({error: error.message}));
    child.once('close', (code, signal) => done({code, signal}));
  });
  let timer;
  const timeout = new Promise((done) => {timer = setTimeout(() => done({timeout: true}), timeoutMs);});
  const result = await Promise.race([exited, timeout]);
  clearTimeout(timer);
  if (result.timeout) {
    await stopProcessTree(child);
    throw new Error(`Isolated updater process timed out after ${timeoutMs}ms`);
  }
  if (result.error || result.code !== 0) {
    throw new Error(`Isolated updater exited unsuccessfully: ${JSON.stringify(result)}`);
  }
  return result;
}

async function waitForReport(path, timeoutMs) {
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    try { return JSON.parse(await readFile(path, 'utf8')); }
    catch { await new Promise((done) => setTimeout(done, 250)); }
  }
  throw new Error(`No isolated update report arrived: ${basename(path)}`);
}

try {
  const input = resolve(source);
  const mac = process.platform === 'darwin';
  const destination = mac ? join(root, 'Velo.app') : join(root, 'Velo-installed');
  if (mac) {
    if (basename(input) !== 'Velo.app' || !(await stat(input)).isDirectory()) {
      throw new Error('macOS input must be an older Velo.app bundle');
    }
    await cp(input, destination, {recursive: true, force: false});
  } else if (process.platform === 'win32') {
    if (!basename(input).toLowerCase().endsWith('-setup.exe') || !(await stat(input)).isFile()) {
      throw new Error('Windows input must be an older signed NSIS setup.exe');
    }
    await windowsRegistration('before', destination);
    await windowsInstaller(input, ['/S', `/D=${destination}`], 3 * 60_000);
    await windowsRegistration('after', destination);
  } else {
    throw new Error('Updater verification is supported only on macOS and Windows');
  }
  const executable = mac
    ? join(destination, 'Contents', 'MacOS', 'velo')
    : join(destination, 'velo.exe');
  if (!(await withinRoot(executable)) || !(await stat(executable)).isFile()) {
    throw new Error('Isolated executable is missing or escaped the temporary root');
  }
  report.isolated_executable = executable;
  await run(executable, 12 * 60_000);
  const staged = await waitForReport(join(root, 'update-verification-result.json'), 5_000);
  if (!staged.success || staged.phase !== 'staged' || staged.detail !== expected
      || staged.version !== staged.package_version
      || comparePreviewVersions(staged.version, expected) >= 0
      || !(await withinRoot(staged.executable))) {
    throw new Error(`The older bundle did not stage the expected signed release: ${JSON.stringify(staged)}`);
  }
  if (!(await stat(join(root, 'update-staged.json'))).isFile()) {
    throw new Error('Verified package metadata was not staged');
  }
  report.staging = staged;
  if (process.platform === 'win32') {
    await windowsRegistration('after', destination, staged.version);
  }
  await run(executable, 4 * 60_000);
  const installed = await waitForReport(join(root, 'smoke-result.json'), 4 * 60_000);
  if (installed.success !== true || installed.version !== expected
      || installed.package_version !== expected
      || installed.settings_webview_and_ipc !== true || installed.bundled_helper !== true
      || installed.providers_started !== false
      || !(await withinRoot(installed.update_verification_executable))) {
    throw new Error(`Updated isolated bundle failed native IPC/helper verification: ${JSON.stringify(installed)}`);
  }
  if (process.platform === 'win32') {
    await windowsRegistration('after', destination, expected);
  }
  report.installed = installed;
  report.success = true;
} catch (error) {
  report.error = error.message;
} finally {
  let safeToRemove = true;
  for (const cleanup of [() => stopProcessTree(child), () => stopRemainingIsolatedExecutables()]) {
    try { await cleanup(); }
    catch (error) {
      report.cleanup_error = error.message;
      report.success = false;
      safeToRemove = false;
    }
  }
  if (safeToRemove && process.platform === 'win32') {
    try {
      const uninstall = join(root, 'Velo-installed', 'uninstall.exe');
      if ((await stat(uninstall).catch(() => null))?.isFile()) {
        await windowsRegistration('after', join(root, 'Velo-installed'));
        await windowsInstaller(uninstall, ['/S'], 2 * 60_000);
      }
      // Also inspect a failed or partial install. Never erase the temporary binaries while an
      // uninstall registration still points at them, even if NSIS omitted its uninstaller.
      await windowsRegistration('cleanup', join(root, 'Velo-installed'));
    } catch (error) { report.cleanup_error = error.message; report.success = false; safeToRemove = false; }
  }
  if (safeToRemove) {
    try { await rm(root, {recursive: true, force: true}); }
    catch (error) { report.cleanup_error = error.message; report.success = false; }
  } else {
    report.retained_isolated_root = true;
  }
  await mkdir(dirname(resolve(reportPath)), {recursive: true});
  await writeFile(resolve(reportPath), `${JSON.stringify(report, null, 2)}\n`);
}

if (!report.success) {
  console.error('Isolated signed update verification failed:', JSON.stringify(report));
  process.exitCode = 1;
} else {
  console.log('Isolated signed update verification passed:', JSON.stringify(report));
}
