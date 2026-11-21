// Runs the real worker, the real Agent SDK and the real Claude Code CLI against a
// scripted API. Only the account quota read is replaced: it needs a claude.ai login.
import { test } from 'node:test';
import assert = require('node:assert/strict');
import fs = require('node:fs');
import os = require('node:os');
import path = require('node:path');
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { mockAnthropic } from './support/mock-anthropic.cjs';

const sdk = require.resolve('@anthropic-ai/claude-agent-sdk');
function bundledClaude() {
  for (const suffix of ['', '-musl']) {
    try { return require.resolve(`@anthropic-ai/claude-agent-sdk-${process.platform}-${process.arch}${suffix}/claude`); } catch { /* Try the next build. */ }
  }
}
const claude = bundledClaude();

async function until<T>(read: () => T, label: string, timeout = 20000): Promise<T> {
  const deadline = Date.now() + timeout;
  for (;;) {
    const value = read();
    if (value) return value;
    if (Date.now() > deadline) throw new Error('timed out waiting for ' + label);
    await new Promise(resolve => setTimeout(resolve, 50));
  }
}

async function withWorker(prompt: string, body: (worker: { state: () => any; command: (value: any) => Promise<any> }) => Promise<void>) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mirror-e2e-'));
  const api = await mockAnthropic();
  let child;
  try {
    const bundle = path.join(dir, 'bundle'), task = path.join(dir, 'tasks', 'task'), project = path.join(dir, 'project'), home = path.join(dir, 'home');
    for (const folder of [bundle, path.join(task, 'commands'), project, path.join(home, '.local/bin')]) fs.mkdirSync(folder, { recursive: true });
    for (const name of fs.readdirSync(path.join(__dirname, '../src'))) {
      if (/\.c?js$/.test(name)) fs.copyFileSync(path.join(__dirname, '../src', name), path.join(bundle, name));
    }
    fs.writeFileSync(path.join(bundle, 'sdk.mjs'), `import { query as create } from ${JSON.stringify(pathToFileURL(sdk).href)};
      export function query(input) {
        const value = create(input);
        value.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET = async () => ({ rate_limits_available: true, rate_limits: { five_hour: { utilization: 1 }, seven_day: { utilization: 1 } } });
        return value;
      }`);
    fs.symlinkSync(claude, path.join(home, '.local/bin/claude'));
    fs.writeFileSync(path.join(task, 'request.json'), JSON.stringify({ prompt,
      session: { id: 's', directory: project, status: 'working', permissions: [], preferences: { permissionMode: 'bypassPermissions' }, messages: [{ id: randomUUID(), role: 'assistant', blocks: [] }] } }));
    child = spawn(process.execPath, [path.join(bundle, 'task-worker.cjs'), task], { stdio: ['ignore', 'ignore', 'pipe'],
      env: { PATH: `${path.join(home, '.local/bin')}:${process.env.PATH}`, HOME: home, ANTHROPIC_BASE_URL: api.url, ANTHROPIC_API_KEY: 'sk-ant-test',
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1', DISABLE_AUTOUPDATER: '1' } });
    let errors = ''; child.stderr.on('data', data => { errors += data; });
    const state = () => { try { return JSON.parse(fs.readFileSync(path.join(task, 'state.json'), 'utf8')); } catch { return null; } };
    const command = async value => {
      const file = path.join(task, 'commands', `${Date.now()}-${randomUUID()}.json`);
      fs.writeFileSync(file + '.tmp', JSON.stringify(value)); fs.renameSync(file + '.tmp', file);
      const result = await until(() => fs.existsSync(file + '.result') && JSON.parse(fs.readFileSync(file + '.result', 'utf8')), 'command result');
      if (!result.ok) throw new Error(result.error);
      return result.value;
    };
    try { await body({ state, command }); }
    catch (error) { error.message += '\n' + JSON.stringify(state()) + '\n' + errors; throw error; }
    await command({ kind: 'close' });
  } finally { child?.kill(); api.close(); fs.rmSync(dir, { recursive: true, force: true }); }
}

const options = { timeout: 60000, skip: claude ? false : 'no bundled Claude Code CLI for this platform' };
const blocks = (state, type) => state.message.blocks.filter(block => block.type === type);
const running = state => state?.message.blocks.some(block => block.type === 'tool' && block.status === 'running') && state;
const steer = { kind: 'steer', id: randomUUID(), text: 'STEER', prompt: 'STEER' };

test('a steer sent during a tool call is read by the same turn', options, () => withWorker('FIRST SLOWTOOL', async ({ state, command }) => {
  await until(() => running(state()), 'running tool');
  await command(steer);
  assert.equal(blocks(state(), 'user')[0].pending, true);
  assert.deepEqual(await command(steer), {}, 'a replayed command must not send the message twice');
  // Context usage is read after the turn ends, so it lands one snapshot later.
  const done = await until(() => state()?.status === 'idle' && state().context && state(), 'idle with context usage');
  assert.deepEqual(blocks(done, 'user'), [{ type: 'user', id: steer.id, text: 'STEER' }]);
  assert.deepEqual(done.message.blocks.map(block => block.type), ['tool', 'user', 'text']);
  assert.match(blocks(done, 'text')[0].text, /SAW FIRST STEER/);
  assert.ok(done.context.usedTokens > 0 && done.context.maxTokens > done.context.usedTokens);
}));

test('a steer sent while text streams runs as the next turn of the same reply', options, () => withWorker('FIRST SLOWTEXT', async ({ state, command }) => {
  await until(() => state()?.message.blocks.some(block => block.type === 'text' && block.text), 'streaming text');
  await command(steer);
  const done = await until(() => state()?.status === 'idle' && state(), 'idle');
  assert.deepEqual(done.message.blocks.map(block => block.type), ['text', 'user', 'text']);
  assert.match(blocks(done, 'text')[1].text, /SAW FIRST STEER/);
}));

test('stop cancels a waiting steer and the owner still takes the next message', options, () => withWorker('FIRST SLOWTOOL', async ({ state, command }) => {
  await until(() => running(state()), 'running tool');
  await command(steer);
  await command({ kind: 'stop' });
  const stopped = await until(() => state()?.status === 'stopped' && state(), 'stopped');
  assert.equal(stopped.message.interrupted, true);
  assert.deepEqual(blocks(stopped, 'user'), [{ type: 'user', id: steer.id, text: 'STEER', cancelled: true }]);
  await assert.rejects(command({ ...steer, id: randomUUID() }), /当前回复已结束/);
  const message = { id: randomUUID(), role: 'assistant', blocks: [] };
  await command({ kind: 'send', prompt: 'SECOND', message });
  const done = await until(() => state()?.status === 'idle' && state().message.id === message.id && state(), 'second reply');
  assert.match(blocks(done, 'text')[0].text, /SAW FIRST SECOND$/, 'the cancelled steer must never reach Claude');
}));
