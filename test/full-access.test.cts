import { test } from 'node:test';
import assert = require('node:assert/strict');
import fs = require('node:fs');
import os = require('node:os');
import path = require('node:path');
import { once } from 'node:events';
import { requireFullAccessIdentity, executionEnvironment, spawnClaudeExecution, permissionStatus } from '../src/claude-launch.cjs';
import { preferencePatch } from '../src/capabilities.cjs';

test('Full Access requires a real non-root identity and validates execution usernames', () => {
  assert.throws(() => requireFullAccessIdentity('bypassPermissions', { uid: 0 }), /root/);
  requireFullAccessIdentity('default', { uid: 0 });
  requireFullAccessIdentity('bypassPermissions', { uid: 1000 });
  assert.throws(() => preferencePatch({ executionUser: 'test;id' }));
  assert.equal(preferencePatch({ executionUser: 'claude-runner' }).executionUser, 'claude-runner');
});

test('switching identity isolates credentials and configuration', () => {
  const execution = { uid: 1000, user: 'runner', home: '/home/runner', cwd: '/tmp', executable: '/bin/true', launcher: '/usr/sbin/runuser' };
  const env = executionEnvironment(execution, { HOME: '/root', ANTHROPIC_API_KEY: 'secret', AWS_SECRET_ACCESS_KEY: 'secret', IS_SANDBOX: '1', CLAUDE_CONFIG_DIR: '/root/.claude', CLAUDE_CODE_ENTRYPOINT: 'sdk-ts', LANG: 'C.UTF-8' });
  assert.equal(env.HOME, '/home/runner');
  assert.equal(env.CLAUDE_CODE_ENTRYPOINT, 'sdk-ts');
  for (const key of ['ANTHROPIC_API_KEY', 'AWS_SECRET_ACCESS_KEY', 'IS_SANDBOX', 'CLAUDE_CONFIG_DIR']) assert.equal(env[key], undefined);
  assert.equal(permissionStatus(execution).fullAccessAvailable, true);
});

test('launcher actually drops UID and preserves argument boundaries', { skip: process.getuid?.() !== 0 || !fs.existsSync('/usr/sbin/runuser') }, async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'claude-identity-'));
  fs.chmodSync(dir, 0o755);
  try {
    const child = spawnClaudeExecution({ uid: 65534, user: 'nobody', home: dir, cwd: dir, executable: '/bin/sh', launcher: '/usr/sbin/runuser' }, {
      args: ['-c', 'id -u; printf "%s\\n" "$HOME" "$1"', 'test', 'a b; echo injection'], env: process.env,
    });
    let output = ''; child.stdout.on('data', chunk => output += chunk);
    const [code] = await once(child, 'close');
    assert.equal(code, 0);
    assert.deepEqual(output.trim().split('\n'), ['65534', dir, 'a b; echo injection']);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('root preflight reports the missing identity before loading the SDK', { skip: process.getuid?.() !== 0 }, async () => {
  const { execFileSync } = await import('node:child_process');
  const inspect = (preferences: object) => JSON.parse(execFileSync(process.execPath, [path.join(__dirname, '../src/task-inspect.cjs'), JSON.stringify({ action: 'permissionStatus', directory: '/tmp', preferences })], { encoding: 'utf8', env: { ...process.env, REMOTECC_CLAUDE_PATH: '/bin/true' } }).trim());
  assert.equal(inspect({}).result.requiresExecutionUser, true);
  assert.match(inspect({ permissionMode: 'bypassPermissions' }).error, /root/);
  assert.match(inspect({ executionUser: 'bad;id' }).error, /无效/);
});
