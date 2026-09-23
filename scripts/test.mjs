import { readdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
const files = readdirSync('scripts')
  .filter(f => /^test-.*\.cjs$/.test(f) || /^.*\.test\.mjs$/.test(f))
  .map(f => `scripts/${f}`);
const result = spawnSync(process.execPath, ['--test','--test-concurrency=1', ...files], {stdio:'inherit'});
process.exit(result.status ?? 1);
