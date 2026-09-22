// One helper build, then one Tauri build. No parallel Cargo processes.
import {spawnSync} from 'node:child_process';
import {copyFileSync, mkdirSync} from 'node:fs';
const mode=process.argv[2];
if(!['dev','build'].includes(mode)) throw new Error('Expected dev or build');
function run(cmd,args){const r=spawnSync(cmd,args,{stdio:'inherit',env:{...process.env,CARGO_BUILD_JOBS:'1'}});if(r.status!==0) process.exit(r.status??1);}
const target=spawnSync('rustc',['--print','host-tuple'],{encoding:'utf8'}).stdout?.trim();
if(!target) throw new Error('Install Rust stable and restart your terminal');
const ext=process.platform==='win32'?'.exe':'';
const release=mode==='build';
run('cargo',['build','--locked','-p','vela-hook',...(release?['--release']:[])]);
mkdirSync('src-tauri/binaries',{recursive:true});
copyFileSync(`target/${release?'release':'debug'}/vela-hook${ext}`,`src-tauri/binaries/vela-hook-${target}${ext}`);
run(process.execPath,['node_modules/@tauri-apps/cli/tauri.js',mode,'--config','src-tauri/tauri.bundle.conf.json',...process.argv.slice(3)]);
