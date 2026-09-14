#!/usr/bin/env node
/* Unit boundary checks for VelaContent.blocks/change using the shipped marked vendor in a Node VM. */
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
const root=new URL('..',import.meta.url);
const markedSource=await readFile(new URL('Sources/VelaApp/Resources/UI/vendor/marked.js',root),'utf8');
const contentSource=await readFile(new URL('Sources/VelaApp/Resources/UI/content.js',root),'utf8');
const listeners=[];
const document={addEventListener:(...args)=>listeners.push(args),getElementById:()=>null,body:{classList:{toggle:()=>false,contains:()=>false}}};
const context={window:{Prism:{languages:{}},DOMPurify:{sanitize:value=>String(value)},addEventListener:()=>{}},document,TextEncoder,innerHeight:800,innerWidth:1200};
context.window.window=context.window;
vm.createContext(context);vm.runInContext(markedSource,context,{filename:'marked.js'});context.window.marked=context.marked;
vm.runInContext(contentSource,context,{filename:'content.js'});
const {blocks,change}=context.window.VelaContent;
const check=(name,fn)=>{fn();console.log(JSON.stringify({check:name,passed:true}));};
const exact=(source,items)=>items.forEach(item=>assert.equal(source.slice(item.start,item.end),item.source));
check('top-level-blocks-keep-exact-offsets-and-ignore-space',()=>{
 const source='# Heading\n\nParagraph\n\n- one\n  - two\n\n> quote\n\n```js\nconst x = 1;\n```\n';
 const items=blocks(source);assert.equal(Array.from(items,x=>x.kind).join(','),'heading,paragraph,list,blockquote,code');exact(source,items);assert.equal(items[2].source,'- one\n  - two');assert.equal(items[4].end,source.length);
});
check('crlf-normalization-including-metadata-only-falls-back-without-guessed-offsets',()=>{
 assert.equal(blocks('one\r\n\r\ntwo\r\n').length,0);
 assert.equal(blocks('---\r\nname: review\r\n---\r\n').length,0);
});
check('frontmatter-is-one-metadata-block-before-markdown',()=>{
 const source='---\nname: review\ntags: [safe]\n---\n\n# H\n\nBody\n';const items=blocks(source);assert.equal(Array.from(items,x=>x.kind).join(','),'metadata,heading,paragraph');assert.equal(items[0].source,'---\nname: review\ntags: [safe]\n---\n');exact(source,items);
});
check('nested-fence-stays-in-one-top-level-list-block',()=>{
 const source='- outer\n  ```js\n  const nested = true;\n  ```\n';const items=blocks(source);assert.equal(items.length,1);assert.equal(items[0].kind,'list');assert.equal(items[0].source,source);exact(source,items);
});
check('duplicate-paragraphs-have-distinct-byte-ranges',()=>{
 const source='same\n\nsame\n\nend';const items=blocks(source);assert.equal(items.length,3);assert.equal(items[0].source,items[1].source);assert.notEqual(items[0].start,items[1].start);exact(source,items);
});
check('change-escapes-malicious-html-and-preserves-full-after-and-indent',()=>{
 const before='head\n  <img src=x onerror=alert(1)>\ntail\n';const after='head\n    <svg onload=alert(2)>after</svg>\ntail\n';const html=change(before,after);assert.ok(html.includes('&lt;svg onload=alert(2)&gt;after&lt;/svg'));assert.ok(html.includes('tail\n'));assert.ok(!html.includes('<svg'));assert.ok(!html.includes('<img'));assert.ok(html.includes('  &lt;svg'));assert.ok(html.includes('&lt;img src=x onerror=alert(1)'));assert.ok(html.includes('reading.changeRemoved')&&html.includes('reading.changeAdded')&&html.includes('reading.changeUnchanged'));assert.ok(html.includes(`data-after-bytes="${new TextEncoder().encode(after).length}"`));
});
check('change-keeps-whole-lines-for-disjoint-edits-emoji-and-final-newline',()=>{
 const before='alpha\nkeep 😀\nold one\nmiddle stays\nold two\nlast\n';
 const after='alpha\nkeep 😀\nnew one\nmiddle stays\nnew two\nlast\n';
 const html=change(before,after);
 assert.match(html,/data-review-complete="true"/);
 assert.ok(html.includes('alpha\nkeep 😀\n'));
 assert.ok(html.includes('old one\nmiddle stays\nold two\n'));
 assert.ok(html.includes('new one\nmiddle stays\nnew two\n'));
 assert.ok(html.includes('last\n'));
 // One pre per contiguous region, not one DOM node per line (including 2,049-line inputs).
 assert.equal((html.match(/<pre /g)||[]).length,4);
});
check('oversized-blocks-fail-closed-and-many-short-lines-stay-complete',()=>{
 assert.equal(blocks('x'.repeat(65537)).length,0);
 const oversized=change('x'.repeat(65537),'');assert.match(oversized,/reading\.changeTooLarge/);assert.match(oversized,/data-review-complete="false"/);
 assert.equal(blocks(Array.from({length:257},(_,i)=>'p'+i+'\n\n').join('')).length,0);
 const shortLines=Array.from({length:2049},()=> 'x').join('\n')+'\n';
 const html=change(shortLines,`y\n${shortLines.slice(2)}`);
 assert.match(html,/data-review-complete="true"/);assert.ok(html.includes('x\n'));
});
