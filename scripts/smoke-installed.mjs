// Run the actual installed executable, not a dev server or mock WebView.
import { resolve } from 'node:path';
import { runInstalledSmoke } from './smoke-installed-core.mjs';

const [binary, reportPath] = process.argv.slice(2);
if (!binary || !reportPath) {
  throw new Error('Usage: node scripts/smoke-installed.mjs <installed binary> <report.json>');
}
const timeoutMs = Number(process.env.VELO_SMOKE_TIMEOUT_MS ?? 45_000);
const report = await runInstalledSmoke({
  executable: resolve(binary),
  argsForDirectory: (dir) => ['--smoke-test', dir],
  reportPath,
  timeoutMs,
});
if (report.success) console.log('Installed native WebView + IPC + helper: PASS', JSON.stringify(report));
else {
  console.error('Installed app smoke failed:', JSON.stringify(report));
  process.exitCode = 1;
}
