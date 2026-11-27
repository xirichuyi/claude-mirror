// Web panel for a shared server, run by systemd as root (see install-claude-remote.sh --panel).
// An administrator adds members here and hands each one a connection code to paste into the app.
// Self-contained on purpose: the server only gets this file and install-claude-remote.sh.
import crypto = require('node:crypto');
import fs = require('node:fs');
import https = require('node:https');
import net = require('node:net');
import path = require('node:path');
import { execFile } from 'node:child_process';
import type { IncomingMessage, ServerResponse } from 'node:http';

interface Config { port: number; path: string; user: string; salt: string; hash: string }
interface Member { name: string; fingerprint: string; state: 'active' | 'pending' | 'expired'; expires?: string }

const SESSION_MS = 12 * 3600_000;
const NAME = /^[a-z_][a-z0-9_-]{0,31}$/;

function hash(password: string, salt: string) {
  return crypto.scryptSync(password, Buffer.from(salt, 'base64'), 32).toString('base64');
}
function credentials(config: Partial<Config>) {
  const user = 'admin' + crypto.randomBytes(3).toString('hex');
  const password = crypto.randomBytes(12).toString('base64url');
  const salt = crypto.randomBytes(16).toString('base64');
  Object.assign(config, { user, salt, hash: hash(password, salt) });
  return `Account: ${user}\nPassword: ${password}`;
}
function save(file: string, config: Config) {
  fs.writeFileSync(file + '.new', JSON.stringify(config, null, 2) + '\n', { mode: 0o600 });
  fs.renameSync(file + '.new', file);
}
function free(port: number) {
  return new Promise<boolean>(resolve => {
    const probe = net.createServer().once('error', () => resolve(false));
    probe.listen(port, () => probe.close(() => resolve(true)));
  });
}

function parseMembers(output: string, keys: (name: string) => string, now = Date.now()): Member[] {
  return output.split('\n').filter(line => line.startsWith('member ')).map(line => {
    const [, name, fingerprint] = line.split(' ');
    const invite = keys(name).split('\n').find(entry => entry.endsWith(' claude-mirror-invite'));
    if (!invite) return { name, fingerprint, state: 'active' as const };
    const stamp = /expiry-time="(\d{12})"/.exec(invite)?.[1];
    if (!stamp) return { name, fingerprint, state: 'pending' as const };
    const at = new Date(+stamp.slice(0, 4), +stamp.slice(4, 6) - 1, +stamp.slice(6, 8), +stamp.slice(8, 10), +stamp.slice(10, 12));
    return { name, fingerprint, state: at.getTime() > now ? 'pending' as const : 'expired' as const, expires: at.toISOString() };
  });
}
function homeOf(name: string) {
  const line = fs.readFileSync('/etc/passwd', 'utf8').split('\n').find(entry => entry.startsWith(name + ':'));
  return line?.split(':')[5];
}
function authorizedKeys(name: string) {
  // The member owns this file: only a small regular file is read, never a link, pipe or device.
  let fd: number | undefined;
  try {
    fd = fs.openSync(path.join(homeOf(name) ?? '/nonexistent', '.ssh/authorized_keys'), fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
    const stat = fs.fstatSync(fd);
    if (!stat.isFile() || stat.size > 1 << 16) return '';
    const buffer = Buffer.alloc(stat.size);
    return buffer.subarray(0, fs.readSync(fd, buffer, 0, stat.size, 0)).toString('utf8');
  } catch { return ''; } finally { if (fd !== undefined) fs.closeSync(fd); }
}
function shortError(reason: string) {
  const account = /(?:Account|account) (\S+)/.exec(reason)?.[1] ?? /^(\S+) is not/.exec(reason)?.[1];
  if (/already exists/.test(reason)) return `账号 ${account} 已存在`;
  if (/is not a member/.test(reason)) return `${account} 不是成员`;
  if (/Invalid account name/.test(reason)) return '账号名无效';
  return reason;
}
/** The address the administrator reached the panel by is the one members reach SSH by. */
function addressOf(request: IncomingMessage) {
  const host = request.headers.host ?? '';
  const value = host.startsWith('[') ? host.slice(1, host.indexOf(']')) : host.split(':')[0];
  return /^[A-Za-z0-9._:-]{1,253}$/.test(value) ? value : '';
}

function serve(folder: string) {
  const file = path.join(folder, 'config.json');
  let config: Config = JSON.parse(fs.readFileSync(file, 'utf8'));
  const script = process.env.CLAUDE_MIRROR_SCRIPT ?? path.join(__dirname, 'install-claude-remote.sh');
  const base = '/' + config.path;
  const sessions = new Map<string, number>();
  const failures = new Map<string, { count: number; until: number }>();
  let queue: Promise<unknown> = Promise.resolve();

  // One account change at a time: useradd and authorized_keys are not safe to race.
  const run = (...args: string[]) => {
    const next = queue.then(() => new Promise<string>((resolve, reject) => {
      execFile('bash', [script, ...args], { timeout: 15 * 60_000, maxBuffer: 1 << 20 }, (error, stdout, stderr) => {
        if (!error) return resolve(stdout);
        const reason = (stderr || stdout).trim().split('\n').filter(Boolean).pop() ?? error.message;
        reject(new Error(shortError(reason)));
      });
    }));
    queue = next.catch(() => undefined);
    return next;
  };
  const send = (response: ServerResponse, status: number, body: unknown, headers: Record<string, string> = {}) => {
    const text = typeof body === 'string' ? body : JSON.stringify(body);
    response.writeHead(status, {
      'content-type': typeof body === 'string' ? 'text/plain; charset=utf-8' : 'application/json',
      'cache-control': 'no-store', ...headers
    });
    response.end(text);
  };
  const page = (response: ServerResponse, type: string, body: string) => {
    response.writeHead(200, {
      'content-type': type, 'cache-control': 'no-store',
      'content-security-policy': "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
      'x-content-type-options': 'nosniff', 'referrer-policy': 'no-referrer'
    });
    response.end(body);
  };
  const body = (request: IncomingMessage) => new Promise<Record<string, unknown>>((resolve, reject) => {
    let text = '';
    request.setEncoding('utf8');
    request.on('data', chunk => { text += chunk; if (text.length > 4096) { reject(new Error('Too large')); request.destroy(); } });
    request.on('end', () => { try { resolve(text ? JSON.parse(text) : {}); } catch { reject(new Error('Bad request')); } });
    request.on('error', reject);
  });
  const signedIn = (request: IncomingMessage) => {
    const token = /(?:^|;\s*)cmp=([A-Za-z0-9_-]+)/.exec(request.headers.cookie ?? '')?.[1];
    const until = token && sessions.get(token);
    if (!until || until < Date.now()) { if (token) sessions.delete(token); return false; }
    return true;
  };
  const matches = (password: string) => {
    const expected = Buffer.from(config.hash, 'base64');
    const actual = Buffer.from(hash(password, config.salt), 'base64');
    return expected.length === actual.length && crypto.timingSafeEqual(expected, actual);
  };

  async function api(request: IncomingMessage, response: ServerResponse, route: string) {
    const method = request.method ?? 'GET';
    // JSON only, so another site cannot post a plain form here with the cookie.
    if (method !== 'GET' && !(request.headers['content-type'] ?? '').startsWith('application/json')) return send(response, 415, { error: 'JSON only' });
    if (route === 'login' && method === 'POST') {
      const client = request.socket.remoteAddress ?? '';
      const record = failures.get(client);
      if (record && record.count >= 5 && record.until > Date.now()) return send(response, 429, { error: '尝试过多，稍后再试' });
      const { user, password } = await body(request);
      if (user !== config.user || typeof password !== 'string' || !matches(password)) {
        const count = record && record.until > Date.now() ? record.count + 1 : 1;
        failures.set(client, { count, until: Date.now() + 10 * 60_000 });
        return send(response, 401, { error: '账号或密码错误' });
      }
      failures.delete(client);
      const token = crypto.randomBytes(24).toString('base64url');
      sessions.set(token, Date.now() + SESSION_MS);
      return send(response, 200, {}, { 'set-cookie': `cmp=${token}; Path=${base}/; HttpOnly; Secure; SameSite=Strict; Max-Age=${SESSION_MS / 1000}` });
    }
    if (!signedIn(request)) return send(response, 401, { error: '请登录' });
    if (route === 'logout' && method === 'POST') {
      for (const [token] of sessions) if ((request.headers.cookie ?? '').includes(token)) sessions.delete(token);
      return send(response, 200, {}, { 'set-cookie': `cmp=; Path=${base}/; HttpOnly; Secure; SameSite=Strict; Max-Age=0` });
    }
    if (route === 'members' && method === 'GET') {
      return send(response, 200, { server: require('node:os').hostname(), members: parseMembers(await run('--list-users'), authorizedKeys) });
    }
    if (route === 'members' && method === 'POST') {
      const { name } = await body(request);
      if (typeof name !== 'string' || !NAME.test(name) || name === 'root') return send(response, 400, { error: '账号名：小写字母开头，可含数字、- 和 _' });
      const host = addressOf(request);
      const output = await run('--invite', name, ...(host ? ['--host', host] : []));
      const code = /^invite (cm1\.\S+)$/m.exec(output)?.[1];
      return code ? send(response, 200, { code }) : send(response, 500, { error: '没有生成连接码' });
    }
    const member = /^members\/([a-z_][a-z0-9_-]{0,31})$/.exec(route)?.[1];
    if (member && method === 'DELETE') {
      await run('--remove-user', member);
      return send(response, 200, {});
    }
    if (route === 'password' && method === 'POST') {
      const { current, next } = await body(request);
      if (typeof current !== 'string' || !matches(current)) return send(response, 403, { error: '当前密码错误' });
      if (typeof next !== 'string' || next.length < 10) return send(response, 400, { error: '新密码至少 10 位' });
      const salt = crypto.randomBytes(16).toString('base64');
      config = { ...config, salt, hash: hash(next, salt) };
      save(file, config);
      sessions.clear();
      return send(response, 200, {});
    }
    return send(response, 404, { error: 'Not found' });
  }

  const server = https.createServer({
    key: fs.readFileSync(path.join(folder, 'key.pem')),
    cert: fs.readFileSync(path.join(folder, 'cert.pem')),
    minVersion: 'TLSv1.2'
  }, (request, response) => {
    let url: URL;
    try { url = new URL(request.url ?? '/', 'https://panel'); } catch { response.writeHead(404); return response.end(); }
    // Everything outside the random path looks like nothing is here.
    if (url.pathname === base) { response.writeHead(302, { location: base + '/' }); return response.end(); }
    if (!url.pathname.startsWith(base + '/')) { response.writeHead(404); return response.end(); }
    const route = url.pathname.slice(base.length + 1);
    if (route === '' && request.method === 'GET') return page(response, 'text/html; charset=utf-8', HTML);
    if (route === 'app.js') return page(response, 'text/javascript; charset=utf-8', SCRIPT);
    if (route === 'app.css') return page(response, 'text/css; charset=utf-8', STYLE);
    if (!route.startsWith('api/')) { response.writeHead(404); return response.end(); }
    api(request, response, route.slice(4)).catch(error => {
      if (!response.headersSent) send(response, 500, { error: error.message });
    });
  });
  setInterval(() => {
    const now = Date.now();
    for (const [token, until] of sessions) if (until < now) sessions.delete(token);
    for (const [client, record] of failures) if (record.until < now) failures.delete(client);
  }, 60_000).unref();
  server.listen(config.port, () => console.log(`Panel on port ${config.port}`));
  return server;
}

async function main() {
  const [command, folder] = process.argv.slice(2);
  if (!folder) throw new Error('Usage: claude-mirror-panel.cjs init|reset|address|serve FOLDER');
  const file = path.join(folder, 'config.json');
  if (command === 'serve') return void serve(folder);
  if (command === 'init' && !fs.existsSync(file)) {
    let port = 0;
    while (!port) { const candidate = 20000 + crypto.randomInt(40000); if (await free(candidate)) port = candidate; }
    const config = { port, path: crypto.randomBytes(9).toString('base64url') } as Config;
    const account = credentials(config);
    save(file, config);
    return console.log(account);
  }
  const config: Config = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (command === 'reset') { const account = credentials(config); save(file, config); return console.log(account); }
  if (command === 'address') return console.log(`${config.port} ${config.path}`);
  if (command !== 'init') throw new Error(`Unknown command: ${command}`);
}

const HTML = `<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Claude Mirror</title><link rel="stylesheet" href="app.css"><script src="app.js" defer></script></head>
<body>
<header><b>Claude Mirror</b><span id="server"></span><span class="grow"></span>
<button id="password-open" class="ghost" hidden title="修改密码">密码</button><button id="logout" class="ghost" hidden title="退出">退出</button></header>
<main>
<form id="login" hidden><input id="user" autocomplete="username" placeholder="账号" required>
<input id="password" type="password" autocomplete="current-password" placeholder="密码" required><button>登录</button></form>
<section id="members" hidden>
<form id="add"><input id="name" placeholder="账号名" pattern="[a-z_][a-z0-9_\\-]{0,31}" maxlength="32" required><button>添加</button></form>
<table><thead><tr><th>成员</th><th>状态</th><th></th></tr></thead><tbody id="rows"></tbody></table>
<p id="empty" class="muted" hidden>暂无成员</p>
</section>
<p id="error" class="error" hidden></p>
</main>
<dialog id="code-dialog"><h3 id="code-title"></h3><textarea id="code" readonly rows="6"></textarea>
<p class="muted">24 小时内有效 · 仅限一次</p><div class="row"><button id="copy">复制</button><button id="code-close" class="ghost">关闭</button></div></dialog>
<dialog id="password-dialog"><form id="password-form"><h3>修改密码</h3>
<input id="current" type="password" autocomplete="current-password" placeholder="当前密码" required>
<input id="next" type="password" autocomplete="new-password" placeholder="新密码" minlength="10" required>
<div class="row"><button>保存</button><button type="button" id="password-close" class="ghost">取消</button></div></form></dialog>
</body></html>`;

const STYLE = `:root{color-scheme:light dark;--bg:#faf9f5;--fg:#1f1e1d;--muted:#8a8780;--line:#e6e3da;--accent:#c96442}
@media(prefers-color-scheme:dark){:root{--bg:#1f1e1d;--fg:#f0eee6;--muted:#9c998f;--line:#3a3935}}
[hidden]{display:none!important}*{box-sizing:border-box}body{margin:0;font:14px/1.5 -apple-system,system-ui,"PingFang SC","Microsoft YaHei",sans-serif;background:var(--bg);color:var(--fg)}
header{display:flex;gap:12px;align-items:center;padding:14px 24px;border-bottom:1px solid var(--line)}#server{color:var(--muted)}.grow{flex:1}
main{max-width:720px;margin:32px auto;padding:0 24px}form{display:flex;gap:8px;margin:0 0 20px}
input,textarea{flex:1;font:inherit;padding:8px 10px;border:1px solid var(--line);border-radius:8px;background:transparent;color:inherit}
textarea{width:100%;font:12px ui-monospace,Menlo,monospace;word-break:break-all;resize:none}
button{font:inherit;padding:8px 14px;border:0;border-radius:8px;background:var(--accent);color:#fff;cursor:pointer}button:disabled{opacity:.5}
button.ghost{background:transparent;color:inherit;border:1px solid var(--line)}button.small{padding:4px 10px}
table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:10px 6px;border-bottom:1px solid var(--line)}th{color:var(--muted);font-weight:normal}
td:last-child{text-align:right;white-space:nowrap}td:last-child button{margin-left:6px}
.state-active{color:#3f8f5a}.state-pending{color:var(--accent)}.state-expired,.muted{color:var(--muted)}.error{color:#c0392b}
dialog{border:1px solid var(--line);border-radius:12px;background:var(--bg);color:var(--fg);width:min(520px,92vw)}dialog form{display:block}dialog input{width:100%;margin-bottom:10px}
.row{display:flex;gap:8px;justify-content:flex-end}h3{margin:0 0 12px}`;

const SCRIPT = `'use strict';
const $ = id => document.getElementById(id);
const call = async (route, method = 'GET', data) => {
  const response = await fetch('api/' + route, { method, headers: data ? { 'content-type': 'application/json' } : {}, body: data ? JSON.stringify(data) : undefined });
  const result = await response.json().catch(() => ({}));
  if (response.status === 401 && route !== 'login') { show(false); throw new Error(''); }
  if (!response.ok) throw new Error(result.error || response.statusText);
  return result;
};
const fail = error => { $('error').textContent = error.message; $('error').hidden = !error.message; };
const busy = async (button, work) => { button.disabled = true; fail({ message: '' }); try { await work(); } catch (error) { fail(error); } finally { button.disabled = false; } };
const show = signed => { $('login').hidden = signed; $('members').hidden = !signed; $('logout').hidden = !signed; $('password-open').hidden = !signed; };
const label = member => member.state === 'active' ? '已连接' : member.state === 'expired' ? '已过期'
  : '待使用' + (member.expires ? ' · ' + new Date(member.expires).toLocaleString([], { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' }) : '');
const button = (text, title, action, ghost = true) => { const b = document.createElement('button'); b.textContent = text; b.title = title; b.className = (ghost ? 'ghost ' : '') + 'small'; b.onclick = () => busy(b, action); return b; };
const showCode = (name, code) => { $('code-title').textContent = name; $('code').value = code; $('copy').textContent = '复制'; $('code-dialog').showModal(); };
const invite = async name => showCode(name, (await call('members', 'POST', { name })).code);
async function load() {
  const { server, members } = await call('members');
  show(true); $('server').textContent = server; $('rows').replaceChildren(); $('empty').hidden = members.length > 0;
  for (const member of members) {
    const row = $('rows').insertRow();
    row.insertCell().textContent = member.name;
    const state = row.insertCell(); state.textContent = label(member); state.className = 'state-' + member.state;
    const actions = row.insertCell();
    actions.append(button('连接码', '重新生成连接码', async () => { await invite(member.name); await load(); }),
      button('删除', '删除账号和文件', async () => { if (confirm('删除 ' + member.name + ' 及其全部文件？')) { await call('members/' + member.name, 'DELETE'); await load(); } }));
  }
}
$('login').onsubmit = event => { event.preventDefault(); busy(event.submitter, async () => { await call('login', 'POST', { user: $('user').value, password: $('password').value }); $('password').value = ''; await load(); }); };
$('add').onsubmit = event => { event.preventDefault(); busy(event.submitter, async () => { await invite($('name').value); $('name').value = ''; await load(); }); };
$('logout').onclick = () => busy($('logout'), async () => { await call('logout', 'POST', {}); show(false); });
$('copy').onclick = async () => { await navigator.clipboard.writeText($('code').value).catch(() => { $('code').select(); document.execCommand('copy'); }); $('copy').textContent = '已复制'; };
$('code-close').onclick = () => $('code-dialog').close();
$('password-open').onclick = () => $('password-dialog').showModal();
$('password-close').onclick = () => $('password-dialog').close();
$('password-form').onsubmit = event => { event.preventDefault(); busy(event.submitter, async () => { await call('password', 'POST', { current: $('current').value, next: $('next').value }); $('password-dialog').close(); show(false); }).then(() => { $('current').value = ''; $('next').value = ''; }); };
load().catch(() => show(false));`;

if (require.main === module) main().catch(error => { console.error(error.message); process.exit(1); });
export { parseMembers, addressOf, shortError, serve };
