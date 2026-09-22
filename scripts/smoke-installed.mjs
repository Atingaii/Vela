// Run the actual installed executable, not a dev server or mock WebView.
import {spawn} from 'node:child_process';
import {mkdtemp,readFile,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
const [binary, reportPath] = process.argv.slice(2);
if(!binary || !reportPath)throw new Error('Usage: node scripts/smoke-installed.mjs <installed binary> <report.json>');
const dir=await mkdtemp(join(tmpdir(),'velo-install-smoke-'));
const child=spawn(resolve(binary),['--smoke-test',dir],{stdio:'inherit'});
const timer=setTimeout(()=>child.kill(),45000);
const code=await new Promise((res,rej)=>{child.once('error',rej);child.once('exit',res);});
clearTimeout(timer);
const report=JSON.parse(await readFile(join(dir,'smoke-result.json'),'utf8'));
if(code!==0||!report.success||!report.settings_webview_and_ipc||!report.bundled_helper||report.providers_started)throw new Error('Installed app smoke failed: '+JSON.stringify({code,report}));
await writeFile(reportPath,JSON.stringify(report,null,2)+'\n');
console.log('Installed native WebView + IPC + helper: PASS',JSON.stringify(report));
// dir is created by this process; it cannot be a pre-existing user directory.
const {rm}=await import('node:fs/promises');await rm(dir,{recursive:true});
