const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { once } = require('node:events');

test('worker exits after quiescence and retains the resumable Claude session', {timeout:10000}, async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(),'mirror-idle-worker-'));
  let child;
  try {
    for (const file of ['task-worker.cjs','session-input.cjs','account-quota.cjs','quota-coordinator.cjs', 'runtime-controls.cjs']) fs.copyFileSync(path.join(__dirname,'../src',file),path.join(dir,file));
    const policy = path.resolve(__dirname,'../src/idle-policy.cjs');
    fs.writeFileSync(path.join(dir,'idle-policy.cjs'), `const {IdlePolicy:Base}=require(${JSON.stringify(policy)});exports.IdlePolicy=class extends Base{constructor(){super(50)}};`);
    const workerPath = path.join(dir, 'task-worker.cjs');
    fs.writeFileSync(workerPath, fs.readFileSync(workerPath, 'utf8').replace('path.dirname(folder)', 'folder'));
    fs.writeFileSync(path.join(dir,'claude-launch.cjs'), 'exports.resolveClaudeLaunch=d=>({cwd:d,executable:"unused"});exports.validateDirectory=()=>{};');
    fs.writeFileSync(path.join(dir,'checkpoint-control.cjs'), 'exports.checkpointControl=()=>()=>{};');
    fs.writeFileSync(path.join(dir,'capabilities.cjs'), 'exports.catalogue=async()=>({});exports.preferencePatch=x=>x;');
    fs.writeFileSync(path.join(dir,'transcript.cjs'), 'exports.Transcript=class{};');
    fs.writeFileSync(path.join(dir,'chat-service.cjs'), `exports.ChatService=class{
      constructor(store){this.store=store;this.runs=new Map();this.timers=new Map();}
      options(){return {}}
      consumeEvent(session,event){session.remoteSessionId='saved-session';session.messages.at(-1).blocks=[{type:'text',text:'finished'}];}
      finish(session){this.runs.delete(session.id);session.status='idle';this.store.save();}
    };`);
    fs.writeFileSync(path.join(dir,'sdk.mjs'), `export function query({prompt}) {
      return {async usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET(){return {rate_limits_available:true,rate_limits:{five_hour:{utilization:0},seven_day:{utilization:0}}}},async *[Symbol.asyncIterator](){for await (const input of prompt) yield {type:'result'};},close(){prompt.close()}};
    }`);
    fs.mkdirSync(path.join(dir,'commands'));
    fs.writeFileSync(path.join(dir,'request.json'),JSON.stringify({session:{id:'s',directory:dir,messages:[{id:'m',blocks:[]}]},prompt:'test'}));
    child=spawn(process.execPath,[path.join(dir,'task-worker.cjs'),dir],{stdio:['ignore','ignore','pipe']});
    let errors='';child.stderr.on('data',data=>errors+=data);
    const [code]=await once(child,'exit');
    assert.equal(code,0,errors);
    const state=JSON.parse(fs.readFileSync(path.join(dir,'state.json')));
    assert.equal(state.done,true);assert.equal(state.hibernated,true);
    assert.equal(state.remoteSessionId,'saved-session');assert.equal(state.status,'idle');
    assert.equal(state.message.blocks[0].text,'finished');
  } finally { child?.kill(); fs.rmSync(dir,{recursive:true,force:true}); }
});
