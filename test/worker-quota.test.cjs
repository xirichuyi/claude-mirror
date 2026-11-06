const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { once } = require('node:events');

async function runWorker(mode) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mirror-quota-'));
  let child;
  try {
    for (const file of ['task-worker.cjs', 'session-input.cjs', 'steers.cjs', 'account-quota.cjs','quota-coordinator.cjs', 'runtime-controls.cjs', 'idle-policy.cjs'])
      fs.copyFileSync(path.join(__dirname, '../src', file), path.join(dir, file));
    // Accelerate only the monitor clock; exercise the real worker and quota policy.
    const worker = path.join(dir, 'task-worker.cjs');
    fs.writeFileSync(worker, fs.readFileSync(worker, 'utf8').replace('}, 5000)', '}, 25)').replace('path.dirname(folder)', 'folder'));
    fs.writeFileSync(path.join(dir, 'claude-launch.cjs'), 'exports.resolveClaudeLaunch=d=>({cwd:d,executable:"unused"});exports.validateDirectory=()=>{};');
    fs.writeFileSync(path.join(dir, 'checkpoint-control.cjs'), 'exports.checkpointControl=()=>()=>{};');
    fs.writeFileSync(path.join(dir, 'capabilities.cjs'), 'exports.catalogue=async()=>({});');
    fs.writeFileSync(path.join(dir, 'transcript.cjs'), 'exports.Transcript=class{};');
    fs.writeFileSync(path.join(dir, 'chat-service.cjs'), `exports.ChatService=class {
      constructor(store){this.store=store;this.runs=new Map();this.timers=new Map();}
      options(){return {}}
      finish(session,run){this.runs.delete(session.id);session.status=run.message.error?'error':'idle';this.store.save();}
    };`);
    fs.writeFileSync(path.join(dir, 'sdk.mjs'), `import fs from 'node:fs';
      let reads=0;
      export function query({prompt}) { return {
        async usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET(){
          reads++;
          if (${JSON.stringify(mode)}==='unknown') return {};
          const used = ${JSON.stringify(mode)}==='monitor' && reads===1 ? 10 : 95;
          return {rate_limits_available:true,rate_limits:{five_hour:{utilization:0},seven_day:{utilization:used}}};
        },
        async *[Symbol.asyncIterator](){for await(const input of prompt) fs.writeFileSync(${JSON.stringify(path.join(dir, 'sent'))},'yes');},
        close(){prompt.close()}
      }; }`);
    fs.mkdirSync(path.join(dir, 'commands'));
    fs.writeFileSync(path.join(dir, 'request.json'), JSON.stringify({ session: { id: 's', directory: dir, messages: [{ id: 'm', blocks: [] }] }, prompt: 'test' }));
    child = spawn(process.execPath, [worker, dir], { stdio: ['ignore', 'ignore', 'pipe'] });
    let errors = ''; child.stderr.on('data', data => errors += data);
    const [code] = await once(child, 'exit');
    assert.equal(code, 0, errors);
    return { state: JSON.parse(fs.readFileSync(path.join(dir, 'state.json'))), sent: fs.existsSync(path.join(dir, 'sent')) };
  } finally { child?.kill(); fs.rmSync(dir, { recursive: true, force: true }); }
}

test('remote worker blocks first prompt before SDK input at 95%', { timeout: 5000 }, async () => {
  const { state, sent } = await runWorker('blocked');
  assert.equal(sent, false);
  assert.equal(state.done, true);
  assert.match(state.message.error, /保留 5%/);
});
test('remote worker fails closed when account quota is unknown', { timeout: 5000 }, async () => {
  const { state, sent } = await runWorker('unknown');
  assert.equal(sent, false);
  assert.match(state.message.error, /无法确认/);
});
test('remote monitor stops a running owner without any connected client', { timeout: 5000 }, async () => {
  const { state, sent } = await runWorker('monitor');
  assert.equal(sent, true);
  assert.equal(state.done, true);
  assert.match(state.message.error, /保留 5%/);
});
