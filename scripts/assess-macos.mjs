// Read-only distribution assessment. Never changes quarantine or system policy.
import {spawnSync} from 'node:child_process';
import {writeFileSync, appendFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';

export function verdict(checks) {
  const integrity = checks.signature.status === 0;
  const developerId = checks.identity.status === 0 && /Authority=Developer ID Application:/.test(checks.identity.output);
  const gatekeeper = checks.gatekeeper.status === 0;
  const notarized = checks.ticket.status === 0;
  return {integrity, developer_id:developerId, gatekeeper_accepted:gatekeeper,
    notarization_ticket:notarized, ready_for_default_open:integrity && developerId && gatekeeper && notarized};
}

export function exitCode(result, allowPreview) {
  return result.ready_for_default_open || (allowPreview && result.integrity) ? 0 : 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [app, report, flag] = process.argv.slice(2);
  if (process.platform !== 'darwin' || !app || !report || (flag && flag !== '--allow-unnotarized-preview')) {
    throw new Error('macOS only: node scripts/assess-macos.mjs <app> <report.json> [--allow-unnotarized-preview]');
  }
  const run = (cmd,args) => {
    const r=spawnSync(cmd,args,{encoding:'utf8',timeout:120000});
    return {status:r.status,output:[r.stdout,r.stderr,r.error?.message].filter(Boolean).join('\n').trim()};
  };
  const path=resolve(app);
  const checks={
    signature:run('codesign',['--verify','--deep','--strict','--verbose=2',path]),
    identity:run('codesign',['--display','--verbose=2',path]),
    gatekeeper:run('spctl',['--assess','--type','execute','--verbose=2',path]),
    ticket:run('xcrun',['stapler','validate',path]),
  };
  const result={...verdict(checks),preview_exception:flag==='--allow-unnotarized-preview',checks};
  writeFileSync(report,JSON.stringify(result,null,2)+'\n');
  console.log(JSON.stringify({...verdict(checks),report}));
  if (!result.ready_for_default_open) {
    const message='macOS default-open verification NOT passed: this preview requires explicit per-app user approval. Smoke success does not imply Gatekeeper acceptance.';
    console.error(process.env.GITHUB_ACTIONS ? `::warning::${message}` : message);
  }
  if(process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY,
    `\n### macOS distribution trust\n\nSignature integrity: ${result.integrity}\n\nDeveloper ID: ${result.developer_id}\n\nGatekeeper accepted: ${result.gatekeeper_accepted}\n\nStapled notarization ticket: ${result.notarization_ticket}\n\n**Default-open ready: ${result.ready_for_default_open}**\n\n${result.preview_exception?'Explicit unnotarized preview exception; this is not a normal-install pass.':''}\n`);
  process.exitCode=exitCode(result,result.preview_exception);
}
