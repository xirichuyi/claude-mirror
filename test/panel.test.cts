import test = require('node:test');
import assert = require('node:assert/strict');
import fs = require('node:fs');
import os = require('node:os');
import path = require('node:path');
import { execFileSync } from 'node:child_process';
import type { AddressInfo } from 'node:net';
const panel = require('../src/panel.cjs');

test('members show whether their invitation is still open', () => {
  const keys: Record<string, string> = {
    alice: 'ssh-ed25519 AAAA mac\n',
    bob: 'expiry-time="203001011200" ssh-ed25519 BBBB claude-mirror-invite\n',
    carol: 'expiry-time="202001011200" ssh-ed25519 CCCC claude-mirror-invite\n',
    dave: 'ssh-ed25519 DDDD claude-mirror-invite\n'
  };
  const members = panel.parseMembers('member alice SHA256:a\nmember bob SHA256:b\nmember carol -\nmember dave -\nnoise\n', name => keys[name]);
  assert.deepEqual(members.map(m => [m.name, m.state]), [['alice', 'active'], ['bob', 'pending'], ['carol', 'expired'], ['dave', 'pending']]);
  assert.equal(new Date(members[1].expires).getFullYear(), 2030);
});

test('the connection code uses the address the panel was opened by', () => {
  const at = host => panel.addressOf({ headers: { host } });
  assert.equal(at('203.0.113.5:4433'), '203.0.113.5');
  assert.equal(at('[2001:db8::1]:4433'), '2001:db8::1');
  assert.equal(at('example.com'), 'example.com');
  assert.equal(at('a b;rm'), '');
});

test('script errors become short messages', () => {
  assert.equal(panel.shortError('Account alice already exists. Choose another name; existing accounts are never modified.'), '账号 alice 已存在');
  assert.equal(panel.shortError('bob is not a member added by Claude Mirror.'), 'bob 不是成员');
});

test('panel answers only under its random path and only after login', { skip: !fs.existsSync('/usr/bin/openssl') }, async () => {
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'mirror-panel-'));
  const script = path.join(folder, 'script.sh');
  fs.writeFileSync(script, 'case "$1" in --list-users) echo "member alice SHA256:x";; --invite) echo "invite cm1.$2-$4";; esac\n');
  execFileSync('openssl', ['req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1', '-nodes', '-days', '1', '-subj', '/CN=t',
    '-keyout', path.join(folder, 'key.pem'), '-out', path.join(folder, 'cert.pem')], { stdio: 'ignore' });
  const account = execFileSync(process.execPath, [require.resolve('../src/panel.cjs'), 'init', folder], { encoding: 'utf8' });
  const [, user, password] = /Account: (\S+)\nPassword: (\S+)/.exec(account);
  const config = JSON.parse(fs.readFileSync(path.join(folder, 'config.json'), 'utf8'));
  assert.equal(fs.statSync(path.join(folder, 'config.json')).mode & 0o777, 0o600);
  config.port = 0; fs.writeFileSync(path.join(folder, 'config.json'), JSON.stringify(config));
  process.env.CLAUDE_MIRROR_SCRIPT = script;
  const previous = process.env.NODE_TLS_REJECT_UNAUTHORIZED; process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';
  const server = panel.serve(folder);
  try {
    await new Promise(resolve => server.listening ? resolve(null) : server.once('listening', resolve));
    const origin = `https://127.0.0.1:${(server.address() as AddressInfo).port}`;
    const base = `${origin}/${config.path}`;
    let cookie = '';
    const call = (route, init: RequestInit = {}) => fetch(base + route, { ...init, headers: { 'content-type': 'application/json', cookie, ...(init.headers ?? {}) } });
    assert.equal((await fetch(origin + '/')).status, 404);
    assert.equal((await fetch(`${origin}/wrong/api/members`)).status, 404);
    assert.equal((await call('/api/members')).status, 401);
    assert.equal((await fetch(base + '/api/login', { method: 'POST', body: 'user=a' })).status, 415);
    assert.equal((await call('/api/login', { method: 'POST', body: JSON.stringify({ user, password: 'wrong' }) })).status, 401);
    const login = await call('/api/login', { method: 'POST', body: JSON.stringify({ user, password }) });
    assert.equal(login.status, 200);
    cookie = login.headers.get('set-cookie').split(';')[0];
    assert.match(login.headers.get('set-cookie'), /HttpOnly; Secure; SameSite=Strict/);
    const members = await (await call('/api/members')).json();
    assert.deepEqual(members.members.map(m => m.name), ['alice']);
    const invite = await (await call('/api/members', { method: 'POST', body: JSON.stringify({ name: 'bob' }) })).json();
    assert.equal(invite.code, 'cm1.bob-127.0.0.1');
    assert.equal((await call('/api/members', { method: 'POST', body: JSON.stringify({ name: '../x' }) })).status, 400);
    for (let i = 0; i < 5; i++) await call('/api/login', { method: 'POST', body: JSON.stringify({ user, password: 'wrong' }) });
    assert.equal((await call('/api/login', { method: 'POST', body: JSON.stringify({ user, password }) })).status, 429);
  } finally {
    server.close(); server.closeAllConnections?.();
    if (previous === undefined) delete process.env.NODE_TLS_REJECT_UNAUTHORIZED; else process.env.NODE_TLS_REJECT_UNAUTHORIZED = previous;
    fs.rmSync(folder, { recursive: true, force: true });
  }
});
