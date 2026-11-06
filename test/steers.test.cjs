const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { Steers } = require('../src/steers.cjs');
const { SessionInput } = require('../src/session-input.cjs');

const lifecycle = (id, state) => ({ type: 'command_lifecycle', command_uuid: id, state });

test('a steer taken at a tool boundary appears in the reply where Claude read it', () => {
  const session = {}, run = { stopped: false, message: { blocks: [{ type: 'tool', id: 't' }] } };
  const steers = new Steers(session);
  assert.equal(steers.add({ id: 's1', prompt: 'also say BETA', text: 'also say BETA' }, run.message), true);
  assert.equal(steers.add({ id: 's1', prompt: 'also say BETA' }, run.message), false, 'replays are ignored');
  assert.equal(steers.lifecycle(lifecycle('s1', 'queued'), run), true);
  assert.deepEqual(session.steers, [{ id: 's1', text: 'also say BETA', queued: true }]);
  assert.equal(steers.lifecycle(lifecycle('unknown', 'started'), run), false);
  assert.equal(steers.lifecycle(lifecycle('s1', 'started'), run), true);
  assert.deepEqual(session.steers, []);
  assert.deepEqual(run.message.blocks.at(-1), { type: 'user', id: 's1', text: 'also say BETA' });
  assert.equal(steers.add({ id: 's1', prompt: 'also say BETA' }, run.message), false, 'a delivered steer is not re-added');
  assert.equal(steers.holdTurn(run), false, 'nothing pending: the turn may end');
});

test('a pending steer keeps the reply open, and interrupting sends it instead of discarding it', () => {
  const session = { status: 'stopping' }, run = { stopped: true, message: { blocks: [] } };
  const steers = new Steers(session);
  steers.add({ id: 's1', prompt: 'p' }, run.message);
  steers.lifecycle(lifecycle('s1', 'queued'), run);
  assert.equal(steers.holdTurn(run), true);
  assert.equal(run.stopped, false);
  assert.equal(session.status, 'working');
  assert.equal(run.message.blocks.at(-1).type, 'notice');
  assert.equal(session.steers.length, 1, 'still waiting for the CLI to start it');
});

test('without lifecycle frames (older CLI) the pending steer is shown as the next turn', () => {
  const session = {}, run = { stopped: false, message: { blocks: [] } };
  const steers = new Steers(session);
  steers.add({ id: 's1', prompt: 'p', text: 'shown' }, run.message);
  assert.equal(steers.holdTurn(run), true);
  assert.deepEqual(run.message.blocks, [{ type: 'user', id: 's1', text: 'shown' }]);
  assert.deepEqual(session.steers, []);
});

test('cancelled steers are reported and invalid steers rejected', () => {
  const session = {}, run = { message: { blocks: [] } };
  const steers = new Steers(session);
  assert.throws(() => steers.add({ id: '', prompt: 'x' }), /无效/);
  assert.throws(() => steers.add({ id: 'a', prompt: '  ' }), /无效/);
  steers.add({ id: 'a', prompt: 'x' }, run.message);
  steers.lifecycle(lifecycle('a', 'cancelled'), run);
  assert.deepEqual(session.steers, []);
  assert.equal(run.message.blocks[0].level, 'error');
});

test('session input marks steers with priority next and leaves new turns unmarked', async () => {
  const input = new SessionInput();
  input.push('turn', 'u1', 's');
  input.push('steer', 'u2', 's', 'next');
  const first = (await input.next()).value, second = (await input.next()).value;
  assert.equal('priority' in first, false);
  assert.equal(second.priority, 'next');
  assert.equal(second.uuid, 'u2');
});

// Drives the real worker with a fake SDK that reproduces the two orderings observed from
// Claude Code 2.1.316: folding into the turn at a tool boundary, and running after the result.
function worker(script) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mirror-steer-worker-'));
  for (const file of ['task-worker.cjs', 'session-input.cjs', 'steers.cjs', 'account-quota.cjs', 'quota-coordinator.cjs', 'runtime-controls.cjs'])
    fs.copyFileSync(path.join(__dirname, '../src', file), path.join(dir, file));
  const workerPath = path.join(dir, 'task-worker.cjs');
  fs.writeFileSync(workerPath, fs.readFileSync(workerPath, 'utf8').replace('path.dirname(folder)', 'folder'));
  fs.writeFileSync(path.join(dir, 'idle-policy.cjs'), 'exports.IdlePolicy=class{touch(){}expired(){return false}};');
  fs.writeFileSync(path.join(dir, 'claude-launch.cjs'), 'exports.resolveClaudeLaunch=d=>({cwd:d,executable:"unused"});exports.validateDirectory=()=>{};');
  fs.writeFileSync(path.join(dir, 'checkpoint-control.cjs'), 'exports.checkpointControl=()=>()=>{};');
  fs.writeFileSync(path.join(dir, 'capabilities.cjs'), 'exports.catalogue=async()=>({});exports.preferencePatch=x=>x;');
  fs.writeFileSync(path.join(dir, 'transcript.cjs'), 'exports.Transcript=class{};');
  fs.writeFileSync(path.join(dir, 'chat-service.cjs'), `exports.ChatService=class{
    constructor(store){this.store=store;this.runs=new Map();this.timers=new Map();}
    options(){return {}}
    consumeEvent(session,event,run){if(event.type==='assistant')run.message.blocks.push({type:'text',text:event.text});session.status='working';this.store.save();}
    finish(session){this.runs.delete(session.id);session.status='idle';this.store.save();}
  };`);
  fs.writeFileSync(path.join(dir, 'sdk.mjs'), `export function query({prompt}) {
    const pending = [];
    let wake;
    const take = async () => { const next = await prompt.next(); if (!next.done) { pending.push(next.value); wake?.(); } return next; };
    return {
      async usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET(){return {rate_limits_available:true,rate_limits:{five_hour:{utilization:0},seven_day:{utilization:0}}}},
      async *[Symbol.asyncIterator]() {
        const first = (await take()).value;
        void (async () => { while (!(await take()).done); })();
        const steer = async () => { while (!pending.some(item => item.priority === 'next')) await new Promise(resolve => { wake = resolve; }); return pending.find(item => item.priority === 'next'); };
        ${script}
        await new Promise(resolve => setTimeout(resolve, 60000));
      },
      close(){prompt.close()}
    };
  }`);
  fs.mkdirSync(path.join(dir, 'commands'));
  fs.writeFileSync(path.join(dir, 'request.json'), JSON.stringify({ session: { id: 's', directory: dir, messages: [{ id: 'reply', blocks: [] }] }, prompt: 'first' }));
  const child = spawn(process.execPath, [workerPath, dir], { stdio: ['ignore', 'ignore', 'pipe'] });
  let errors = ''; child.stderr.on('data', data => { errors += data; });
  const state = () => { try { return JSON.parse(fs.readFileSync(path.join(dir, 'state.json'), 'utf8')); } catch { return null; } };
  const until = async (check, label) => {
    for (let i = 0; i < 200; i++) { const value = state(); if (value && check(value)) return value; await new Promise(resolve => setTimeout(resolve, 25)); }
    throw new Error('timed out waiting for ' + label + '\n' + JSON.stringify(state()) + '\n' + errors);
  };
  let commandIndex = 0;
  const send = (command) => {
    const name = String(++commandIndex).padStart(4, '0') + '.json';
    fs.writeFileSync(path.join(dir, 'commands', name), JSON.stringify(command));
    const result = path.join(dir, 'commands', name + '.result');
    return until(() => fs.existsSync(result), 'command result').then(() => JSON.parse(fs.readFileSync(result, 'utf8')));
  };
  return { send, until, close: () => { child.kill(); fs.rmSync(dir, { recursive: true, force: true }); } };
}

test('worker folds a steer into the running reply at the tool boundary', { timeout: 15000 }, async () => {
  const w = worker(`
    yield {type:'assistant', text:'running tool'};
    const s = await steer();
    yield {type:'command_lifecycle', command_uuid:s.uuid, state:'queued'};
    yield {type:'command_lifecycle', command_uuid:s.uuid, state:'started'};
    yield {type:'assistant', text:'ALPHA BETA'};
    yield {type:'result'};
  `);
  try {
    await w.until(state => state.message.blocks.length === 1, 'first output');
    assert.deepEqual(await w.send({ kind: 'steer', id: 'st1', prompt: 'also BETA', text: 'also BETA' }), { ok: true, value: {} });
    const done = await w.until(state => state.status === 'idle', 'turn end');
    assert.deepEqual(done.message.blocks.map(block => block.type + ':' + block.text), ['text:running tool', 'user:also BETA', 'text:ALPHA BETA']);
    assert.deepEqual(done.steers, []);
  } finally { w.close(); }
});

test('worker keeps the reply open when the steer runs as its own turn after the result', { timeout: 15000 }, async () => {
  const w = worker(`
    yield {type:'assistant', text:'story'};
    const s = await steer();
    yield {type:'command_lifecycle', command_uuid:s.uuid, state:'queued'};
    yield {type:'result'};
    await new Promise(resolve => setTimeout(resolve, 200));
    yield {type:'command_lifecycle', command_uuid:s.uuid, state:'started'};
    yield {type:'assistant', text:'second answer'};
    yield {type:'result'};
  `);
  try {
    await w.until(state => state.message.blocks.length === 1, 'first output');
    assert.equal((await w.send({ kind: 'steer', id: 'st1', prompt: 'p', text: 'follow-up' })).ok, true);
    const held = await w.until(state => state.steers?.[0]?.queued, 'queued steer');
    assert.notEqual(held.status, 'idle');
    const done = await w.until(state => state.status === 'idle', 'second turn end');
    assert.deepEqual(done.message.blocks.map(block => block.type + ':' + block.text), ['text:story', 'user:follow-up', 'text:second answer']);
    assert.match((await w.send({ kind: 'steer', id: 'late', prompt: 'p' })).error, /未在回复/, 'no reply running: client queues instead');
  } finally { w.close(); }
});
