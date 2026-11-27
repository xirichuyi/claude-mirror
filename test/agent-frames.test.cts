import test = require('node:test');
import assert = require('node:assert/strict');
import fs = require('node:fs');
import os = require('node:os');
import path = require('node:path');
import crypto = require('node:crypto');
import { spawn } from 'node:child_process';

const AGENT = path.join(__dirname, '../src/remote-agent.cjs');

function frame(type: number, id: number, payload = Buffer.alloc(0)) {
  const head = Buffer.alloc(9);
  head.writeUInt32BE(5 + payload.length, 0); head.writeUInt8(type, 4); head.writeUInt32BE(id, 5);
  return Buffer.concat([head, payload]);
}
const credit = (id: number, bytes: number) => { const value = Buffer.alloc(4); value.writeUInt32BE(bytes); return frame(5, id, value); };

function framedAgent(env: Record<string, string> = {}) {
  const child = spawn(process.execPath, [AGENT], { stdio: ['pipe', 'pipe', 'inherit'], env: { ...process.env, ...env } });
  const frames: { type: number; id: number; payload: Buffer }[] = [];
  let waiters: (() => void)[] = [];
  let buffered = Buffer.alloc(0), framed = false;
  child.stdout.on('data', (data: Buffer) => {
    buffered = Buffer.concat([buffered, data]);
    for (;;) {
      if (!framed) {
        const index = buffered.indexOf(10);
        if (index < 0) break;
        const line = JSON.parse(buffered.subarray(0, index).toString());
        buffered = buffered.subarray(index + 1);
        if (line.result?.version === 1) framed = true;
        continue;
      }
      if (buffered.length < 4 || buffered.length < 4 + buffered.readUInt32BE(0)) break;
      const length = buffered.readUInt32BE(0);
      frames.push({ type: buffered[4], id: buffered.readUInt32BE(5), payload: buffered.subarray(9, 4 + length) });
      buffered = buffered.subarray(4 + length);
    }
    const ready = waiters; waiters = []; ready.forEach(wake => wake());
  });
  const until = async <T,>(find: () => T | undefined, timeout = 5000): Promise<T> => {
    const deadline = Date.now() + timeout;
    for (;;) {
      const found = find();
      if (found !== undefined) return found;
      if (Date.now() > deadline) throw new Error('timed out; frames: ' + frames.map(item => item.type).join(','));
      await new Promise<void>(wake => { waiters.push(wake); setTimeout(wake, 50); });
    }
  };
  const json = (predicate: (message: any) => boolean) => until(() => {
    for (const item of frames) if (item.type === 1) { const message = JSON.parse(item.payload.toString()); if (predicate(message)) return message; }
    return undefined;
  });
  const request = (id: number, op: string, params: object) => child.stdin.write(frame(1, 0, Buffer.from(JSON.stringify({ id, op, params }))));
  child.stdin.write(JSON.stringify({ id: 1, op: 'frames', params: { version: 1 } }) + '\n');
  return { child, frames, until, json, request, close: () => child.kill() };
}

const data = (frames: { type: number; id: number; payload: Buffer }[], id: number) =>
  Buffer.concat(frames.filter(item => item.type === 3 && item.id === id).map(item => item.payload));

test('framed read streams within the granted credit and resumes from an offset', async () => {
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'frames-'));
  const file = path.join(folder, 'big.bin');
  const content = crypto.randomBytes(3 * 1024 * 1024 + 123);
  fs.writeFileSync(file, content);
  const agent = framedAgent();
  try {
    agent.request(2, 'file', { operation: 'read', path: file, window: 512 * 1024 });
    const reply = await agent.json(message => message.id === 2);
    assert.equal(reply.result.size, content.length); assert.equal(reply.result.offset, 0);
    await agent.until(() => data(agent.frames, 2).length === 512 * 1024 || undefined);
    await new Promise(wake => setTimeout(wake, 150));
    assert.equal(data(agent.frames, 2).length, 512 * 1024, 'the agent waits for more credit');
    // A control request is answered while the stream is stalled.
    agent.request(3, 'file', { operation: 'stat', path: file });
    assert.equal((await agent.json(message => message.id === 3)).result.size, content.length);
    agent.child.stdin.write(credit(2, 8 * 1024 * 1024));
    const end = await agent.until(() => agent.frames.find(item => item.type === 4 && item.id === 2));
    assert.equal(end.payload.length, 0);
    assert.ok(data(agent.frames, 2).equals(content));

    agent.request(4, 'file', { operation: 'read', path: file, offset: 3 * 1024 * 1024, version: reply.result.version });
    assert.equal((await agent.json(message => message.id === 4)).result.offset, 3 * 1024 * 1024);
    await agent.until(() => agent.frames.find(item => item.type === 4 && item.id === 4));
    assert.ok(data(agent.frames, 4).equals(content.subarray(3 * 1024 * 1024)));

    agent.request(5, 'file', { operation: 'read', path: file, version: 'stale' });
    assert.match((await agent.json(message => message.id === 5)).error, /已变化/);
  } finally { agent.close(); fs.rmSync(folder, { recursive: true, force: true }); }
});

test('a cancelled framed read ends with an error', async () => {
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'frames-'));
  const file = path.join(folder, 'big.bin');
  fs.writeFileSync(file, crypto.randomBytes(2 * 1024 * 1024));
  const agent = framedAgent();
  try {
    agent.request(2, 'file', { operation: 'read', path: file, window: 256 * 1024 });
    await agent.json(message => message.id === 2);
    agent.child.stdin.write(frame(1, 0, Buffer.from(JSON.stringify({ cancel: 2 }))));
    const end = await agent.until(() => agent.frames.find(item => item.type === 4 && item.id === 2));
    assert.equal(end.payload.toString(), '已取消');
  } finally { agent.close(); fs.rmSync(folder, { recursive: true, force: true }); }
});

test('an attachment upload resumes after the connection drops', async () => {
  const content = crypto.randomBytes(1536 * 1024);
  const digest = crypto.createHash('sha256').update(content).digest('hex');
  const params = { operation: 'write', attachment: true, digest, name: 'shot.png', size: content.length };
  const first = framedAgent();
  first.request(2, 'file', params);
  assert.equal((await first.json(message => message.stream === 2)).offset, 0);
  await first.until(() => first.frames.find(item => item.type === 5 && item.id === 2));
  first.child.stdin.write(frame(3, 2, content.subarray(0, 700 * 1024)));
  await first.until(() => first.frames.filter(item => item.type === 5 && item.id === 2).length >= 2 || undefined);
  first.child.stdin.end();
  await new Promise(wake => first.child.once('exit', wake));

  const second = framedAgent();
  try {
    second.request(2, 'file', params);
    const announced = await second.json(message => message.stream === 2);
    assert.equal(announced.offset, 700 * 1024);
    second.child.stdin.write(frame(3, 2, content.subarray(announced.offset, announced.offset + 512 * 1024)));
    second.child.stdin.write(frame(3, 2, content.subarray(announced.offset + 512 * 1024)));
    second.child.stdin.write(frame(4, 2));
    const reply = await second.json(message => message.id === 2);
    assert.equal(reply.error, undefined);
    assert.ok(fs.readFileSync(reply.result.path).equals(content));
    assert.ok(!fs.existsSync(path.dirname(reply.result.path) + '.partial'));
  } finally { second.close(); }
});

test('a framed preview carries image bytes in a BLOB frame instead of base64', async () => {
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'frames-'));
  const file = path.join(folder, 'dot.png');
  const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');
  fs.writeFileSync(file, png);
  const agent = framedAgent();
  try {
    agent.request(2, 'file', { operation: 'preview', path: file, inlineMedia: true });
    const blob = await agent.until(() => agent.frames.find(item => item.type === 2 && item.id === 2));
    const length = blob.payload.readUInt32BE(0);
    const reply = JSON.parse(blob.payload.subarray(4, 4 + length).toString());
    assert.equal(reply.result.inlineData, undefined);
    assert.equal(reply.result.inlineBytes, png.length);
    assert.ok(blob.payload.subarray(4 + length).equals(png));
  } finally { agent.close(); fs.rmSync(folder, { recursive: true, force: true }); }
});

test('an upload never treats an existing attachment as its partial, and concurrent uploads stay apart', async () => {
  const content = crypto.randomBytes(1536 * 1024);
  const digest = crypto.createHash('sha256').update(content).digest('hex');
  const upload = async (agent: ReturnType<typeof framedAgent>, name: string) => {
    agent.request(2, 'file', { operation: 'write', attachment: true, digest, name, size: content.length });
    assert.equal((await agent.json(message => message.stream === 2)).offset, 0);
    return async () => {
      for (let at = 0; at < content.length; at += 256 * 1024) {
        await agent.until(() => agent.frames.filter(item => item.type === 5 && item.id === 2).length * 1024 * 1024 >= at + 1 || undefined);
        agent.child.stdin.write(frame(3, 2, content.subarray(at, at + 256 * 1024)));
      }
      agent.child.stdin.write(frame(4, 2));
      const reply = await agent.json(message => message.id === 2);
      assert.equal(reply.error, undefined);
      return reply.result.path as string;
    };
  };
  const first = framedAgent(), second = framedAgent();
  try {
    const [finishFirst, finishSecond] = await Promise.all([upload(first, 'report.partial'), upload(second, 'report')]);
    const [one, two] = await Promise.all([finishFirst(), finishSecond()]);
    assert.ok(fs.readFileSync(one).equals(content));
    assert.ok(fs.readFileSync(two).equals(content));
  } finally { first.close(); second.close(); }
});

test('an upload dropped before its first byte can be retried', async () => {
  const content = crypto.randomBytes(1000);
  const digest = crypto.createHash('sha256').update(content).digest('hex');
  const params = { operation: 'write', attachment: true, digest, name: 'empty-start.bin', size: content.length };
  const first = framedAgent();
  first.request(2, 'file', params);
  await first.until(() => first.frames.find(item => item.type === 5 && item.id === 2));
  first.child.stdin.end();
  await new Promise(wake => first.child.once('exit', wake));
  const second = framedAgent();
  try {
    second.request(2, 'file', params);
    assert.equal((await second.json(message => message.stream === 2)).offset, 0);
    second.child.stdin.write(frame(3, 2, content));
    second.child.stdin.write(frame(4, 2));
    const reply = await second.json(message => message.id === 2);
    assert.equal(reply.error, undefined);
    assert.ok(fs.readFileSync(reply.result.path).equals(content));
    assert.deepEqual(fs.readdirSync(path.dirname(reply.result.path)), ['empty-start.bin']);
  } finally { second.close(); }
});

test('a workspace upload cut off by a disconnect leaves no file behind', async () => {
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'frames-workspace-'));
  const agent = framedAgent();
  agent.request(2, 'file', { operation: 'write', directory: folder, name: 'cut.bin', size: 4096 });
  await agent.until(() => agent.frames.find(item => item.type === 5 && item.id === 2));
  agent.child.stdin.write(frame(3, 2, crypto.randomBytes(1024)));
  agent.child.stdin.end();
  await new Promise(wake => agent.child.once('exit', wake));
  try { assert.deepEqual(fs.readdirSync(folder), []); } finally { fs.rmSync(folder, { recursive: true, force: true }); }
});

test('an attachment for an execution account is handed over into that account home', async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'mirror-account-'));
  const content = crypto.randomBytes(300 * 1024);
  const digest = crypto.createHash('sha256').update(content).digest('hex');
  const agent = framedAgent({ HOME: home });
  try {
    // A login that is not root cannot switch accounts, so it keeps the copy in its own home.
    agent.request(2, 'file', { operation: 'write', attachment: true, digest, name: 'shot.png', size: content.length, account: 'claude-runner' });
    await agent.json(message => message.stream === 2);
    agent.child.stdin.write(frame(3, 2, content));
    agent.child.stdin.write(frame(4, 2));
    const reply = await agent.json(message => message.id === 2);
    assert.equal(reply.error, undefined);
    assert.equal(reply.result.path, path.join(home, '.cache/claude-mirror/attachments', digest, 'shot.png'));
    assert.ok(fs.readFileSync(reply.result.path).equals(content));
    assert.equal(fs.statSync(reply.result.path).mode & 0o777, 0o600);
    fs.rmSync(path.dirname(reply.result.path), { recursive: true });
    agent.request(3, 'file', { operation: 'attachmentLookup', digest, name: 'shot.png', account: 'claude-runner' });
    const lookup = await agent.json(message => message.id === 3);
    assert.ok(fs.readFileSync(lookup.result.file.path).equals(content));
  } finally { agent.close(); fs.rmSync(home, { recursive: true, force: true }); }
});
