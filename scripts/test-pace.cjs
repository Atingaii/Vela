const {readFileSync}=require('node:fs');
const {join}=require('node:path');
const vm=require('node:vm');
const assert=require('node:assert/strict');
const {test}=require('node:test');
const html=readFileSync(join(__dirname,'../src-tauri/ui/notch.html'),'utf8');
const ctx=vm.createContext({});
vm.runInContext(html.split('// BEGIN TESTABLE PACE')[1].split('// END TESTABLE PACE')[0],ctx);
// Same cases as the pinned Swift UsagePaceTests / DailyPaceTests.
test('pace uses the reported duration and keeps sub-tenth deficit/reserve signs',()=>{
 const now=1800000000000,window={used:.98,duration:604800,resets_at:now+86400000};
 assert.equal(ctx.paceSummary(ctx.usagePace(window,now)),'12.3% deficit');
 window.resets_at=now+302400000;window.used=.27;
 assert.equal(ctx.paceSummary(ctx.usagePace(window,now)),'23% reserved');
 window.used=.5004;assert.equal(ctx.paceSummary(ctx.usagePace(window,now)),'<0.1% deficit');
 window.used=.4996;assert.equal(ctx.paceSummary(ctx.usagePace(window,now)),'<0.1% reserved');
 for(const invalid of [{duration:null},{duration:0},{duration:Infinity},{used:null},{used:NaN},{used:-.1},{resets_at:null},{resets_at:now},{count:10,has_fraction:false}])assert.equal(ctx.usagePace({...window,...invalid},now),null);
 assert.notEqual(ctx.usagePace({...window,count:10,has_fraction:true},now),null);
 assert.equal(ctx.usagePace({...window,used:.2,resets_at:now+604801000},now),20);
});
test('daily ring uses cumulative seventh shares and moves only Claude accounts',()=>{
 const day=86400000,end=1800000000000,start=end-7*day,weekly={id:'weekly_all',used:.1,resets_at:end};
 const first=ctx.dailyPace(weekly,start+day/2);assert.ok(Math.abs(first.used-.7)<1e-9);assert.equal(first.resets_at,start+day);assert.equal(ctx.usagePace(first,start),null);
 const heavy=ctx.dailyPace({...weekly,used:.5},start+2*day);assert.ok(heavy.used>1);
 assert.equal(ctx.dailyPace(weekly,start-day).resets_at,start+day);assert.equal(ctx.dailyPace(weekly,end+day).resets_at,end);
 const provider={base:'claude-work',snap:{windows:[weekly]}};
 const paced=ctx.pacedProvider(provider,true,start);assert.equal(paced.snap.windows[0].id,'daily_pace');assert.equal(ctx.pacedProvider(paced,true,start).snap.windows.length,2);assert.equal(provider.snap.windows.length,1);
 assert.equal(ctx.pacedProvider(provider,false,start),provider);
 const codex={...provider,base:'codex'};assert.equal(ctx.pacedProvider(codex,true,start),codex);
});
