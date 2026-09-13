import {mkdir,copyFile} from 'node:fs/promises';
await mkdir(new URL('./dist/',import.meta.url),{recursive:true});
for(const name of ['index.js','index.d.ts','journal.js','safety.js'])await copyFile(new URL('./src/'+name,import.meta.url),new URL('./dist/'+name,import.meta.url));
