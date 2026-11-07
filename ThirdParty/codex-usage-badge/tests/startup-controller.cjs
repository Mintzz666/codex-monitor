'use strict';
const assert=require('node:assert/strict');
const {StartupController}=require(process.env.STARTUP_CONTROLLER_PATH || '../macos/startup/controller.cjs');
const app=(key='new',overrides={})=>({key,pid:20,launchedAt:99500,finishedLaunching:true,argumentsKnown:true,debugPort:null,...overrides});
async function scenario({baseline=[],fresh=[app()],snapshot={},quit=true,exit=true,launch=true,failReceipt=false,lastAttemptAt=0,lastAttemptInputStamp=null,onSleep,onLaunch,portInUse=false,foreground=20}={},verify) {
  let now=100000, calls=[], records=[], apps=baseline, input='1', frontmost=foreground;
  const adapter={
    snapshot:async()=>({apps,frontmostPid:frontmost,inputStamp:input,inputIdleMs:10000,...snapshot}),
    portInUse:async()=>portInUse,
    record:async(event,details)=>{records.push(event);if(event==='attempt'&&failReceipt)throw Error('disk full');},
    quit:async(a,stamp)=>{calls.push('quit');if(exit&&quit){apps=[];frontmost=30;}return {accepted:quit};},
    launch:async()=>{calls.push('launch');apps=[app('replacement',{debugPort:'39222'})];onLaunch?.();return {launched:launch,key:'replacement',pid:21};},
    show:async(a,stamp,front)=>{if(input!==stamp||frontmost!==front)return {shown:false};calls.push('show');return {shown:true};}
  };
  const control=new StartupController(adapter,{now:()=>now,sleep:async ms=>{now+=ms;onSleep?.({setApps:v=>apps=v,setInput:v=>input=v,stop:()=>control.stop()});},lastAttemptAt,lastAttemptInputStamp});
  await control.tick();apps=fresh;await control.tick();
  await verify({calls,records,control,adapter,setApps:v=>apps=v,setNow:v=>now=v,setInput:v=>input=v,setFrontmost:v=>frontmost=v});
}
(async()=>{
  await scenario({},({calls})=>assert.deepEqual(calls,['quit','launch','show']));
  await scenario({baseline:[app('old',{launchedAt:1000})],fresh:[]},({calls})=>assert.deepEqual(calls,[]));
  await scenario({baseline:[app()],fresh:[]},({calls})=>assert.deepEqual(calls,['quit','launch','show']));
  await scenario({baseline:[app()],snapshot:{inputIdleMs:100}},({calls})=>assert.deepEqual(calls,[]));
  await scenario({baseline:[app('restored',{launchedAt:60000})],fresh:[],foreground:30,snapshot:{inputIdleMs:50000}},({calls})=>assert.deepEqual(calls,['quit','launch']));
  await scenario({fresh:[app('slow',{launchedAt:70000})],snapshot:{inputIdleMs:40000}},({calls})=>assert.deepEqual(calls,['quit','launch','show']));
  await scenario({snapshot:{inputIdleMs:100}},({calls})=>assert.deepEqual(calls,[]));
  await scenario({foreground:30},({calls})=>assert.deepEqual(calls,['quit','launch']));
  for(const overrides of [{launchedAt:1000},{launchedAt:101000},{argumentsKnown:false},{debugPort:'39222'},{debugPort:'9222'}])await scenario({fresh:[app('new',overrides)]},({calls})=>assert.deepEqual(calls,[]));
  await scenario({fresh:[app(),app('other',{pid:99})]},({calls})=>assert.deepEqual(calls,[]));
  await scenario({lastAttemptAt:99000},({calls})=>assert.deepEqual(calls,[]));
  await scenario({lastAttemptAt:99000,lastAttemptInputStamp:'1'},({calls})=>assert.deepEqual(calls,[]));
  await scenario({lastAttemptAt:99000,lastAttemptInputStamp:'previous-session'},({calls})=>assert.deepEqual(calls,['quit','launch','show']));
  await scenario({lastAttemptAt:101000},({calls})=>assert.deepEqual(calls,['quit','launch','show']));
  await scenario({portInUse:true},({calls,records})=>{assert.deepEqual(calls,[]);assert.ok(records.includes('port-in-use'));});
  await scenario({fresh:[app('new',{finishedLaunching:false})]},async({calls,control,setApps})=>{
    assert.deepEqual(calls,[]);assert.equal(control.pendingLaunch,true);
    setApps([app()]);await control.tick();assert.deepEqual(calls,['quit','launch','show']);
  });
  await scenario({baseline:[app('new',{argumentsKnown:false})],fresh:[app('new',{argumentsKnown:false})]},async({calls,control,setApps})=>{
    assert.deepEqual(calls,[]);assert.equal(control.pendingLaunch,true);
    setApps([app()]);await control.tick();assert.deepEqual(calls,['quit','launch','show']);
  });
  // A partially initialized background restore remains eligible until it finishes.
  await scenario({foreground:30,fresh:[app('new',{finishedLaunching:false})]},async({calls,control,setApps})=>{
    assert.equal(control.pendingLaunch,true);assert.deepEqual(calls,[]);
    setApps([app()]);await control.tick();assert.deepEqual(calls,['quit','launch']);
  });
  const background={frontmostPid:30};
  await scenario({snapshot:background,fresh:[app('new',{finishedLaunching:false})]},async({calls,control,setNow})=>{
    setNow(170000);await control.tick();assert.equal(control.pendingLaunch,false);
    background.frontmostPid=20;await control.tick();assert.deepEqual(calls,[]);
  });
  await scenario({failReceipt:true},({calls,records})=>{assert.deepEqual(calls,[]);assert.ok(records.includes('error'));});
  await scenario({quit:false},async({calls,control})=>{await control.tick();assert.deepEqual(calls,['quit']);});
  await scenario({exit:false},({calls,records})=>{assert.deepEqual(calls,['quit']);assert.ok(records.includes('quit-timeout'));});
  await scenario({onSleep:({setInput})=>setInput('2')},({calls})=>assert.deepEqual(calls,['quit']));
  await scenario({onSleep:({setApps})=>setApps([app('manual-reopen')])},({calls})=>assert.deepEqual(calls,['quit']));
  await scenario({onSleep:({stop})=>stop()},({calls})=>assert.deepEqual(calls,['quit']));
  await scenario({launch:false},({calls})=>assert.deepEqual(calls,['quit','launch']));
  await scenario({},async({calls,control,setApps,setNow})=>{
    await control.tick();setApps([app('stripped-args')]);await control.tick();
    setNow(500000);await control.tick(); // do not restart an ignored instance after cooldown
    assert.deepEqual(calls,['quit','launch','show']);
  });
  await scenario({},async({calls,control,setApps,setNow,setInput,setFrontmost})=>{
    setInput('2');setNow(101000);setFrontmost(20);setApps([app('manual-reopen',{launchedAt:100500})]);
    await control.tick();
    assert.deepEqual(calls,['quit','launch','show','quit','launch','show']);
  });
  // Switch to a browser during the launch callback: never activate Codex afterwards.
  let input='1', calls=[], now=100000, apps=[];
  const adapter={snapshot:async()=>({apps,frontmostPid:apps.length?20:30,inputStamp:input,inputIdleMs:10000}),portInUse:async()=>false,record:async()=>{},quit:async()=>{calls.push('quit');apps=[];return{accepted:true};},launch:async()=>{calls.push('launch');input='2';return{launched:true,key:'newer',pid:21};},show:async(a,stamp)=>{if(stamp===input)calls.push('show');return{shown:false};}};
  const control=new StartupController(adapter,{now:()=>now,sleep:async ms=>{now+=ms;}});
  await control.tick();apps=[app()];await control.tick();assert.deepEqual(calls,['quit','launch']);
  console.log('PASS startup recovery: pre-watcher login restore, slow launch, hidden background restore; guards for old/interactive/ambiguous instances, flags, receipts, cooldown, no retry, refusal/timeout, cancellation, stop and focus');
})().catch(error=>{console.error(error);process.exitCode=1;});
