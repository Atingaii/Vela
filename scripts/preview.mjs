// Static UI preview only. Tests inject fixture IPC; production never loads mock data.
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
const pages=new Set(['notch.html','settings.html','dropzones.html','workbench.html','whats_new.html']);
const scripts=new Set(['source-localizations.js','notch-motion.js']);
const server=createServer(async(req,res)=>{
 const name=req.url==='/'?'settings.html':req.url.slice(1);
 if(!pages.has(name)&&!scripts.has(name)){res.writeHead(404).end();return;}
 try {res.writeHead(200,{'Content-Type':`${scripts.has(name)?'text/javascript':'text/html'}; charset=utf-8`});res.end(await readFile(new URL(`../src-tauri/ui/${name}`,import.meta.url)));}
 catch{res.writeHead(500).end();}
});
server.listen(4173,'127.0.0.1',()=>console.log('Velo UI preview: http://127.0.0.1:4173 (desktop IPC requires Tauri)'));
