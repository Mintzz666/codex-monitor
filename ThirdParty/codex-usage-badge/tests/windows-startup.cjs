'use strict';
const assert=require('node:assert/strict');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
const {EventEmitter}=require('node:events');
const {PassThrough}=require('node:stream');
const {NativeBridge,readReceipt,writeReceipt}=require('../startup/windows.cjs');
(async()=>{
  const temp=fs.mkdtempSync(path.join(os.tmpdir(),'badge-startup-'));
  const oldSystemRoot=process.env.SystemRoot;process.env.SystemRoot=temp;
  try {
    const receipt=path.join(temp,'state.json');
    assert.deepEqual(readReceipt(receipt),{});
    writeReceipt(receipt,{lastAttemptAt:123,event:'attempt'});
    assert.equal(readReceipt(receipt).lastAttemptAt,123);
    writeReceipt(receipt,{...readReceipt(receipt),event:'watching'});
    assert.equal(readReceipt(receipt).lastAttemptAt,123);
    fs.writeFileSync(receipt,'{"lastAttemptAt":"bad"}');assert.throws(()=>readReceipt(receipt),/Invalid/);
    fs.writeFileSync(receipt,'broken');assert.throws(()=>readReceipt(receipt));
    let child,args,opts;
    const bridge=new NativeBridge(path.join(temp,'App name.exe'),path.join(temp,'stop.request'),{spawnProcess:(exe,a,o)=>{
      args=a;opts=o;child=new EventEmitter();child.stdin=new PassThrough();child.stdout=new PassThrough();child.stderr=new PassThrough();return child;
    }});
    assert.equal(opts.windowsHide,true);assert.ok(args.includes('-NonInteractive'));
    const pending=bridge.call('snapshot');
    const request=JSON.parse(child.stdin.read().toString());
    assert.equal(request.action,'snapshot');
    child.stdout.write(JSON.stringify({id:request.id,result:{apps:[]}})+'\n');
    assert.deepEqual(await pending,{apps:[]});
    const failed=bridge.call('quit',{pid:1,key:'old',stamp:'3'});
    const second=JSON.parse(child.stdin.read().toString());
    child.stdout.write(JSON.stringify({id:second.id,error:'refused'})+'\n');
    await assert.rejects(failed,/refused/);
    const exited=bridge.call('snapshot');child.emit('exit',1);await assert.rejects(exited,/exited/);
    await assert.rejects(bridge.call('launch'),/unavailable/);bridge.close();
    console.log('PASS Windows startup receipts, invalid-state refusal, hidden persistent RPC, response errors and helper exit');
  } finally {if(oldSystemRoot===undefined)delete process.env.SystemRoot;else process.env.SystemRoot=oldSystemRoot;fs.rmSync(temp,{recursive:true,force:true});}
})().catch(error=>{console.error(error);process.exitCode=1;});
