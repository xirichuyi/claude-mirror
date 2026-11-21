import { test } from 'node:test';
import assert = require('node:assert/strict');
import fs = require('node:fs');
import path = require('node:path');
import vm = require('node:vm');
import { createHash } from 'node:crypto';
import { gunzipSync } from 'node:zlib';
const output = path.resolve(__dirname, '../src');

test('compiled renderer scripts remain classic scripts and all local assets resolve', () => {
  const html = fs.readFileSync(path.join(output, 'index.html'), 'utf8');
  for (const [, reference] of html.matchAll(/(?:src|href)="([^"#]+\.(?:js|css))"/g)) {
    const file = path.resolve(output, reference);
    assert.ok(fs.existsSync(file), reference);
    if (reference.endsWith('.js') && !reference.includes('node_modules')) {
      const source = fs.readFileSync(file, 'utf8');
      assert.doesNotMatch(source, /Object\.defineProperty\(exports|require\(/, reference);
      new vm.Script(source, { filename: reference });
    }
  }
});

test('compiled preload exposes the bridge and forwards typed calls to IPC', async () => {
  const calls = [];
  let bridge;
  vm.runInNewContext(fs.readFileSync(path.join(output, 'preload.cjs'), 'utf8'), {
    exports: {},
    require(name) {
      assert.equal(name, 'electron');
      return {
        contextBridge: { exposeInMainWorld(name, api) { assert.equal(name, 'remoteCC'); bridge = api; } },
        ipcRenderer: { invoke: async (...args) => { calls.push(args); return []; }, on() {} },
        webUtils: { getPathForFile: file => file.path },
      };
    },
  });
  await bridge.configure('session', { fastMode: true });
  await bridge.list();
  assert.deepEqual(calls, [['chat:configure', 'session', { fastMode: true }], ['chats:list']]);
});

test('remote bundle contains executable JavaScript with a digest of the emitted bytes', () => {
  const { taskBundle } = require('../src/persistent-tasks.cjs');
  const bundle = taskBundle();
  const bytes = gunzipSync(Buffer.from(bundle.payload, 'base64'));
  assert.equal(bundle.digest, createHash('sha256').update(bytes).digest('hex'));
  const files = JSON.parse(bytes.toString('utf8'));
  for (const [name, source] of Object.entries(files)) {
    assert.match(name, /\.(?:cjs|mjs|js)$/);
    if (name === 'sdk.mjs') continue;
    assert.equal(source, fs.readFileSync(path.join(output, name), 'utf8'));
    new vm.Script(source, { filename: name });
    for (const [, dependency] of source.matchAll(/require\(["']\.\/([^"']+)["']\)/g)) {
      assert.ok(dependency in files, `${name} needs ${dependency}`);
    }
  }
});

test('all repository-owned JavaScript sources have TypeScript replacements', () => {
  const { execFileSync } = require('node:child_process');
  const root = path.resolve(__dirname, '../..');
  const files = execFileSync('git', ['ls-files', '--cached', '--others', '--exclude-standard', '-z'], { cwd: root, encoding: 'utf8' }).split('\0');
  const remaining = files.filter(file => /\.(?:[cm]?js|jsx)$/.test(file)
    && !/^(?:vendor\/|src\/third-party\/)/.test(file)
    && fs.existsSync(path.join(root, file)));
  assert.deepEqual(remaining, [], 'Maintain TypeScript source; keep generated JavaScript in build/.');
});

test('native resource preparer runs from another working directory using only compiled programs', () => {
  const { execFileSync } = require('node:child_process');
  const os = require('node:os');
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'remotecc-native-build-'));
  const destination = path.join(temporary, 'resources with spaces');
  try {
    execFileSync(process.execPath, [path.resolve(__dirname, '../macos/scripts/prepare-server.cjs'), destination], { cwd: temporary });
    const manifest = JSON.parse(fs.readFileSync(path.join(destination, 'manifest.json'), 'utf8'));
    const agent = fs.readFileSync(path.join(destination, 'remote-agent.cjs'));
    assert.equal(manifest.agentDigest, createHash('sha256').update(agent).digest('hex'));
    const bundle = gunzipSync(Buffer.from(manifest.bundlePayload, 'base64'));
    assert.equal(manifest.bundleDigest, createHash('sha256').update(bundle).digest('hex'));
    assert.ok(JSON.parse(bundle.toString('utf8'))['task-worker.cjs']);
    assert.equal(fs.readFileSync(path.join(destination, 'install-claude-remote.sh'), 'utf8'),
      fs.readFileSync(path.resolve(__dirname, '../../scripts/install-claude-remote.sh'), 'utf8'));
  } finally { fs.rmSync(temporary, { recursive: true, force: true }); }
});
