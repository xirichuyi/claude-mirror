const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { resolveClaudeLaunch } = require('../src/claude-launch.cjs');

test('missing project reports the directory instead of a libc error', () => {
  assert.throws(() => resolveClaudeLaunch('/missing-claudock-project', { PATH: '' }), /项目目录不存在/);
});

test('Claude comes from the remote PATH, including paths with spaces', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'claudock-launch-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const bin = path.join(root, 'my bin'); fs.mkdirSync(bin);
  const executable = path.join(bin, 'claude');
  fs.writeFileSync(executable, '#!/bin/sh\nexit 0\n', { mode: 0o700 });
  assert.deepEqual(resolveClaudeLaunch(root, { PATH: bin }), { cwd: root, executable });
  assert.throws(() => resolveClaudeLaunch(executable, { PATH: bin }), /不是目录/);
  assert.throws(() => resolveClaudeLaunch(root, { PATH: bin, REMOTECC_CLAUDE_PATH: '/missing-explicit-cli' }), /未找到/);
  assert.deepEqual(resolveClaudeLaunch(root, { PATH: '', REMOTECC_CLAUDE_PATH: executable }), { cwd: root, executable });
});
