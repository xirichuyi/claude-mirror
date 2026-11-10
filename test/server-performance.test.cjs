const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { randomUUID } = require('node:crypto');
const { historyOperations } = require('../src/remote-agent.cjs');

function historyRoot() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mirror-server-perf-'));
  const project = path.join(root, 'projects', '-tmp-perf');
  fs.mkdirSync(project, { recursive: true });
  const call = async request => {
    const previous = process.env.CLAUDE_CONFIG_DIR;
    process.env.CLAUDE_CONFIG_DIR = root;
    try { return await historyOperations[request.operation](request); }
    finally { if (previous === undefined) delete process.env.CLAUDE_CONFIG_DIR; else process.env.CLAUDE_CONFIG_DIR = previous; }
  };
  return { root, project, call };
}

const row = (uuid, parentUuid, text) => JSON.stringify({ type: 'user', uuid, parentUuid, cwd: '/tmp/perf', message: { content: text } }) + '\n';

test('history list keeps only the newest snapshots, so repeated refreshes cannot grow memory', async () => {
  const h = historyRoot();
  try {
    for (let index = 0; index < 201; index++) fs.writeFileSync(path.join(h.project, randomUUID() + '.jsonl'), row(randomUUID(), null, 'm' + index));
    const first = await h.call({ operation: 'list' });
    assert.ok(first.nextOffset);
    let latest;
    for (let index = 0; index < 4; index++) latest = await h.call({ operation: 'list' });
    await assert.rejects(() => h.call({ operation: 'list', offset: first.nextOffset }), /已过期/);
    assert.equal((await h.call({ operation: 'list', offset: latest.nextOffset })).sessions.length, 1);
  } finally { fs.rmSync(h.root, { recursive: true, force: true }); }
});

test('concurrent history reads share one index; appends are served at once but persisted lazily', async () => {
  const h = historyRoot();
  try {
    const id = randomUUID(), file = path.join(h.project, id + '.jsonl'), reference = '-tmp-perf/' + id + '.jsonl';
    let parent = null, text = '';
    for (let index = 0; index < 20; index++) { const uuid = randomUUID(); text += row(uuid, parent, 'm' + index); parent = uuid; }
    fs.writeFileSync(file, text);
    const [a, b] = await Promise.all([h.call({ operation: 'messages', reference }), h.call({ operation: 'messages', reference })]);
    assert.deepEqual(a.records.map(item => item.uuid), b.records.map(item => item.uuid));
    const indexFile = fs.readdirSync(path.join(h.root, 'remotecc-index')).find(name => name !== 'listing.json');
    const persisted = fs.readFileSync(path.join(h.root, 'remotecc-index', indexFile), 'utf8');
    fs.appendFileSync(file, row(randomUUID(), parent, 'appended'));
    const after = await h.call({ operation: 'messages', reference });
    assert.equal(after.records.at(-1).message.content[0].text, 'appended');
    // The full build was written immediately; the append is not rewritten on this read.
    assert.equal(fs.readFileSync(path.join(h.root, 'remotecc-index', indexFile), 'utf8'), persisted);
  } finally { fs.rmSync(h.root, { recursive: true, force: true }); }
});

// A worker with fake SDK and service, recording when each command's result appears.
function workerFixture(prepare) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mirror-worker-commands-'));
  for (const file of ['task-worker.cjs', 'session-input.cjs']) fs.copyFileSync(path.join(__dirname, '../src', file), path.join(dir, file));
  fs.writeFileSync(path.join(dir, 'idle-policy.cjs'), `module.exports=require(${JSON.stringify(path.resolve(__dirname, '../src/idle-policy.cjs'))});`);
  fs.writeFileSync(path.join(dir, 'claude-launch.cjs'), 'exports.resolveClaudeLaunch=d=>({cwd:d,executable:"unused"});exports.validateDirectory=()=>{};');
  fs.writeFileSync(path.join(dir, 'checkpoint-control.cjs'), 'exports.checkpointControl=()=>()=>{};');
  fs.writeFileSync(path.join(dir, 'capabilities.cjs'), 'exports.catalogue=async()=>({});exports.preferencePatch=x=>x;');
  fs.writeFileSync(path.join(dir, 'transcript.cjs'), 'exports.Transcript=class{};');
  fs.writeFileSync(path.join(dir, 'chat-service.cjs'), `exports.ChatService=class{
    constructor(store){this.store=store;this.runs=new Map();this.timers=new Map();this.approvals=new Map([['p1',true]]);}
    options(){return {}}
    respond(){}
    consumeEvent(){}
    finish(session){this.runs.delete(session.id);session.status='idle';this.store.save();}
  };`);
  fs.writeFileSync(path.join(dir, 'sdk.mjs'), `export function query({prompt}) {
    return {async *[Symbol.asyncIterator](){for await (const input of prompt) yield {type:'result'};},close(){prompt.close()},
      reloadPlugins:()=>new Promise(done=>setTimeout(done,1500)),interrupt:async()=>{}};
  }`);
  fs.mkdirSync(path.join(dir, 'commands'));
  fs.writeFileSync(path.join(dir, 'request.json'), JSON.stringify({ session: { id: 's', directory: dir, messages: [{ id: 'm', blocks: [] }] }, prompt: 'test' }));
  prepare?.(dir);
  const seen = new Map();
  const write = (index, command) => {
    const name = `0000000${index}-0000-0000-0000-000000000000.json`;
    fs.writeFileSync(path.join(dir, 'commands', name), JSON.stringify(command));
    return name;
  };
  const poll = setInterval(() => {
    for (const name of fs.readdirSync(path.join(dir, 'commands')).sort()) {
      const command = name.slice(0, -'.result'.length);
      if (name.endsWith('.result') && !seen.has(command)) seen.set(command, seen.size);
    }
  }, 5);
  const child = spawn(process.execPath, [path.join(dir, 'task-worker.cjs'), dir], { stdio: ['ignore', 'ignore', 'pipe'] });
  const until = async (predicate, ms = 5000) => {
    const deadline = Date.now() + ms;
    while (!predicate()) { if (Date.now() > deadline) throw new Error('timed out'); await new Promise(done => setTimeout(done, 10)); }
  };
  const close = () => { clearInterval(poll); child.kill(); fs.rmSync(dir, { recursive: true, force: true }); };
  return { dir, write, seen, until, close, state: () => { try { return JSON.parse(fs.readFileSync(path.join(dir, 'state.json'))); } catch { return null; } } };
}

test('an approval is not held behind a slow control command', { timeout: 10000 }, async () => {
  const w = workerFixture();
  try {
    await w.until(() => w.state()?.status === 'idle');
    const slow = w.write(1, { kind: 'control', action: 'plugins' });
    const answer = w.write(2, { kind: 'respond', permissionId: 'p1', answer: { allow: true } });
    // The slow control takes 1.5 s; the answer must be done well before it.
    await w.until(() => w.seen.has(answer), 1000);
    assert.equal(w.seen.has(slow), false);
    await w.until(() => w.seen.has(slow));
  } finally { w.close(); }
});

test('a stop never overtakes an earlier queued send', { timeout: 10000 }, async () => {
  const w = workerFixture();
  try {
    await w.until(() => w.state()?.status === 'idle');
    const slow = w.write(1, { kind: 'control', action: 'plugins' });
    const send = w.write(2, { kind: 'send', prompt: 'next', message: { id: 'm2', blocks: [] } });
    const stop = w.write(3, { kind: 'stop' });
    await w.until(() => w.seen.has(stop));
    assert.ok(w.seen.get(slow) < w.seen.get(send) && w.seen.get(send) < w.seen.get(stop), JSON.stringify([...w.seen]));
  } finally { w.close(); }
});

test('command tombstones older than a day are pruned; recent ones are kept for replay safety', { timeout: 10000 }, async () => {
  let old, recent;
  const w = workerFixture(dir => {
    old = path.join(dir, 'commands', 'old.json'); recent = path.join(dir, 'commands', 'recent.json');
    for (const file of [old, recent]) { fs.writeFileSync(file + '.done', '{}'); fs.writeFileSync(file + '.result', '{}'); }
    const past = new Date(Date.now() - 2 * 86400000);
    fs.utimesSync(old + '.done', past, past);
  });
  try {
    await w.until(() => !fs.existsSync(old + '.done'));
    assert.equal(fs.existsSync(old + '.result'), false);
    assert.ok(fs.existsSync(recent + '.done') && fs.existsSync(recent + '.result'));
  } finally { w.close(); }
});

test('a host can widen the streaming save window; without one it stays at 50 ms', async () => {
  const { ChatService } = require('../src/chat-service.cjs');
  const measure = async streamDelay => {
    let saved = 0;
    const service = new ChatService({ load: () => [], save: () => { saved = Date.now(); } });
    if (streamDelay) service.streamDelay = streamDelay;
    const session = { id: 's', messages: [{}] }, started = Date.now();
    service.changed(session);
    await new Promise(done => setTimeout(done, 400));
    return saved - started;
  };
  const standard = await measure(), widened = await measure(() => 250);
  assert.ok(standard >= 40 && standard < 200, String(standard));
  assert.ok(widened >= 240, String(widened));
});
