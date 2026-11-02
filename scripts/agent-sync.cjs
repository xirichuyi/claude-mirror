#!/usr/bin/env node
// Syncs agent memory and session hand-offs between machines over plain SSH. Only an allowlist is ever read: Claude project memory, Claude
// and Codex session transcripts. Credentials and settings are never touched.
'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn, spawnSync } = require('node:child_process');

const HOME = os.homedir();
const ROOT = process.env.AGENT_SYNC_HOME || path.join(HOME, '.agent-sync');
const CLAUDE = process.env.CLAUDE_CONFIG_DIR || path.join(HOME, '.claude');
const CODEX = process.env.CODEX_HOME || path.join(HOME, '.codex');
const WORK = path.join(ROOT, 'hub');
const CONFIG = path.join(ROOT, 'config.json');
const STATE = path.join(ROOT, 'state.json');
const LOCK = path.join(ROOT, 'lock');
const PENDING = path.join(ROOT, 'pending');
const LOG = path.join(ROOT, 'sync.log');
const DEFAULT_EXCLUDE = ['/tmp/', '/private/tmp/', '/var/folders/'];
const SSH = process.env.AGENT_SYNC_SSH || 'ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=10 -o ServerAliveCountMax=3';
const MAX_TURNS = 40;
const MAX_TEXT = 4000;
const HEAD_BYTES = 256 * 1024;
const TAIL_BYTES = 8 * 1024 * 1024;

const log = message => {
  try {
    fs.mkdirSync(ROOT, { recursive: true, mode: 0o700 });
    fs.appendFileSync(LOG, `${new Date().toISOString()} ${message}\n`, { mode: 0o600 });
  } catch { /* Logging must never break a hook. */ }
};
const readJson = (file, fallback) => { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; } };
const writeJson = (file, value) => {
  const temp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(temp, JSON.stringify(value, null, 2) + '\n', { mode: 0o600 });
  fs.renameSync(temp, file);
};
const sha = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const shellQuote = text => `'${String(text).replace(/'/g, `'\\''`)}'`;
const encodeCwd = cwd => cwd.replace(/[^a-zA-Z0-9]/g, '-');
const safeName = text => String(text).replace(/[^a-zA-Z0-9._-]/g, '_');

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    encoding: 'utf8', timeout: options.timeout || 120000, cwd: options.cwd,
    env: { ...process.env, GIT_SSH_COMMAND: SSH, GIT_TERMINAL_PROMPT: '0' }
  });
  return { ok: result.status === 0, out: (result.stdout || '').trim(), err: (result.stderr || result.error?.message || '').trim() };
}
const git = (...args) => run('git', ['-c', 'user.name=agent-sync', '-c', 'user.email=agent-sync@localhost', '-c', 'core.quotepath=off', ...args], { cwd: WORK });

function config() {
  const value = readJson(CONFIG, null);
  if (!value) throw new Error(`未安装：缺少 ${CONFIG}，请先运行 install`);
  return { hubPath: '.agent-sync', peers: [], links: {}, excludeCwd: DEFAULT_EXCLUDE, ...value };
}
const remoteSpec = (cfg, target) => cfg.hub ? `${cfg.hub}:${target}` : target;
const hubRoot = cfg => cfg.role === 'hub' ? ROOT : cfg.hubPath;
const gitRemote = cfg => cfg.role === 'hub' ? path.join(ROOT, 'hub.git') : remoteSpec(cfg, `${cfg.hubPath}/hub.git`);

// Secrets can appear in chat text, so hand-offs and index entries are scrubbed.
const SECRET_PATTERNS = [
  /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)/g,
  /\bsk-[a-zA-Z0-9_-]{16,}/g,
  /\b(ghp|gho|ghs|ghu|github_pat)_[a-zA-Z0-9_]{16,}/g,
  /\b(AKIA|ASIA)[A-Z0-9]{16}\b/g,
  /\bxox[abprs]-[a-zA-Z0-9-]{10,}/g,
  /\beyJ[a-zA-Z0-9_-]{10,}\.[a-zA-Z0-9_-]{10,}\.[a-zA-Z0-9_-]{5,}/g,
  /\btskey-[a-zA-Z0-9-]{10,}/g,
  /((?:password|passwd|pwd|secret|token|api[_-]?key|authorization)["']?\s*[:=]\s*["']?(?:bearer\s+)?)[^\s"',;]{4,}/gi,
  /(\bbearer\s+)[a-zA-Z0-9._~+/=-]{12,}/gi
];
function redact(text) {
  let result = String(text);
  for (const pattern of SECRET_PATTERNS) result = result.replace(pattern, (match, prefix) => (typeof prefix === 'string' && /[:=\s]$/.test(prefix)) ? `${prefix}[已脱敏]` : '[已脱敏]');
  return result;
}

// Large transcripts are read as head + tail: metadata lives early, recent turns late.
function readLines(file) {
  const size = fs.statSync(file).size;
  const fd = fs.openSync(file, 'r');
  try {
    const read = (start, length) => { const buffer = Buffer.alloc(length); fs.readSync(fd, buffer, 0, length, start); return buffer.toString('utf8'); };
    if (size <= HEAD_BYTES + TAIL_BYTES) return { head: [], lines: read(0, size).split('\n') };
    const head = read(0, HEAD_BYTES).split('\n').slice(0, -1);
    const tail = read(size - TAIL_BYTES, TAIL_BYTES).split('\n').slice(1);
    return { head, lines: tail };
  } finally { fs.closeSync(fd); }
}
const parseLines = lines => lines.flatMap(line => { if (!line.trim()) return []; try { return [JSON.parse(line)]; } catch { return []; } });

function toolSummary(name, input) {
  const value = typeof input === 'string' ? input : input?.description || input?.command || input?.file_path || input?.path || input?.pattern || input?.prompt || input?.url || '';
  return `${name}${value ? ': ' + String(value).split('\n')[0].slice(0, 160) : ''}`;
}

function parseClaude(file) {
  const { head, lines } = readLines(file);
  const meta = { id: path.basename(file, '.jsonl'), agent: 'claude', title: '', cwd: '', branch: '', turns: [] };
  for (const event of [...parseLines(head), ...parseLines(lines)]) {
    if (event.cwd && !meta.cwd) meta.cwd = event.cwd;
    if (event.gitBranch) meta.branch = event.gitBranch;
    if (event.type === 'ai-title' && event.aiTitle) meta.title = event.aiTitle;
  }
  for (const event of parseLines(lines)) {
    if (event.isSidechain || event.isMeta) continue;
    if (event.type === 'user') {
      const content = event.message?.content;
      const text = typeof content === 'string' ? content : Array.isArray(content) ? content.filter(b => b.type === 'text').map(b => b.text).join('\n') : '';
      if (text.trim() && !/^\s*<(local-command|command-|system-reminder|task-notification)/.test(text)) meta.turns.push({ role: 'user', text, tools: [], at: event.timestamp });
    }
    if (event.type === 'assistant' && Array.isArray(event.message?.content)) {
      const text = event.message.content.filter(b => b.type === 'text').map(b => b.text).join('\n');
      const tools = event.message.content.filter(b => b.type === 'tool_use').map(b => toolSummary(b.name, b.input));
      if (text.trim() || tools.length) meta.turns.push({ role: 'assistant', text, tools, at: event.timestamp });
    }
  }
  return meta;
}

function parseCodex(file) {
  const { head, lines } = readLines(file);
  const fromName = /([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/.exec(file);
  const meta = { id: fromName?.[1] || path.basename(file, '.jsonl'), agent: 'codex', title: '', cwd: '', branch: '', turns: [] };
  for (const event of [...parseLines(head), ...parseLines(lines)]) {
    if (event.type === 'session_meta' && event.payload) {
      meta.id = event.payload.id || meta.id;
      meta.cwd = meta.cwd || event.payload.cwd || '';
    }
    if (event.type === 'turn_context' && event.payload?.cwd) meta.cwd = event.payload.cwd;
  }
  for (const event of parseLines(lines)) {
    const item = event.payload;
    if (event.type !== 'response_item' || !item) continue;
    if (item.type === 'message' && (item.role === 'user' || item.role === 'assistant')) {
      const text = (item.content || []).filter(b => /text$/.test(b.type || '')).map(b => b.text).join('\n');
      if (!text.trim() || /^\s*(<[a-z_-]+[ >]|# AGENTS)/.test(text)) continue;
      meta.turns.push({ role: item.role, text, tools: [], at: event.timestamp });
    }
    if (item.type === 'custom_tool_call' || item.type === 'function_call') {
      const previous = meta.turns.at(-1);
      const summary = toolSummary(item.name, item.input ?? item.arguments);
      if (previous?.role === 'assistant') previous.tools.push(summary);
      else meta.turns.push({ role: 'assistant', text: '', tools: [summary], at: event.timestamp });
    }
  }
  if (!meta.title) meta.title = (meta.turns.find(t => t.role === 'user')?.text || '').split('\n')[0].slice(0, 80);
  return meta;
}

function renderHandoff(meta, host, updatedAt) {
  const turns = meta.turns.slice(-MAX_TURNS);
  const out = [
    `# 会话交接：${redact(meta.title || meta.id)}`, '',
    `- 来源：${host} / ${meta.agent}`, `- 会话 ID：${meta.id}`, `- 工作目录：${meta.cwd || '未知'}`,
    ...(meta.branch ? [`- Git 分支：${meta.branch}`] : []), `- 最后更新：${updatedAt}`,
    `- 收录范围：最近 ${turns.length}/${meta.turns.length} 段对话；工具只记录摘要，不含输出和思考内容`, '',
    '接手前先核对工作目录里的实际文件状态，这份记录可能落后于现场。', ''
  ];
  for (const turn of turns) {
    out.push(`## ${turn.role === 'user' ? '用户' : '助手'}${turn.at ? ` · ${turn.at}` : ''}`, '');
    if (turn.text.trim()) {
      const text = turn.text.length > MAX_TEXT ? `${turn.text.slice(0, MAX_TEXT)}\n…（已截断）` : turn.text;
      out.push(redact(text), '');
    }
    if (turn.tools.length) out.push(...turn.tools.map(tool => `- 工具 ${redact(tool)}`), '');
  }
  return out.join('\n');
}

function listClaudeSessions() {
  const projects = path.join(CLAUDE, 'projects');
  if (!fs.existsSync(projects)) return [];
  return fs.readdirSync(projects, { withFileTypes: true }).filter(e => e.isDirectory()).flatMap(dir =>
    fs.readdirSync(path.join(projects, dir.name), { withFileTypes: true })
      .filter(e => e.isFile() && e.name.endsWith('.jsonl'))
      .map(e => ({ agent: 'claude', file: path.join(projects, dir.name, e.name), enc: dir.name })));
}
function listCodexSessions() {
  const found = [];
  const walk = dir => {
    let entries = [];
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.isFile() && /^rollout-.*\.jsonl$/.test(entry.name)) found.push({ agent: 'codex', file: full });
    }
  };
  walk(path.join(CODEX, 'sessions'));
  return found;
}

function projectKey(cfg, cwd, cache) {
  if (cfg.links[cwd]) return cfg.links[cwd];
  if (cache.has(cwd)) return cache.get(cwd);
  let key = `${safeName(cfg.host)}--${encodeCwd(cwd)}`;
  if (fs.existsSync(cwd)) {
    const remote = run('git', ['-C', cwd, 'remote', 'get-url', 'origin'], { timeout: 5000 });
    if (remote.ok && remote.out) {
      const clean = remote.out.replace(/^[a-z+]+:\/\//, '').replace(/^[^@/]+@/, '').replace(/\.git$/, '').replace(/[:/]+/g, '-');
      key = `git-${safeName(clean)}`;
    }
  }
  cache.set(cwd, key);
  return key;
}

function ensureWorktree(cfg) {
  fs.mkdirSync(ROOT, { recursive: true, mode: 0o700 });
  if (cfg.role === 'hub' && !fs.existsSync(path.join(ROOT, 'hub.git'))) {
    const made = run('git', ['init', '--bare', '-b', 'main', path.join(ROOT, 'hub.git')]);
    if (!made.ok) throw new Error(made.err);
  }
  if (!fs.existsSync(path.join(WORK, '.git'))) {
    const cloned = run('git', ['clone', '-q', gitRemote(cfg), WORK], { timeout: 300000 });
    if (!cloned.ok) throw new Error(`无法克隆 hub：${cloned.err}`);
  }
  if (!git('rev-parse', '--verify', 'HEAD').ok) {
    git('checkout', '-q', '-B', 'main');
    fs.writeFileSync(path.join(WORK, '.gitattributes'), '**/MEMORY.md merge=union\n');
    git('add', '-A');
    git('commit', '-q', '-m', 'init agent-sync hub');
    const pushed = git('push', '-q', '-u', 'origin', 'main');
    if (!pushed.ok) log(`initial push failed: ${pushed.err}`);
  }
}

// Conflicts never lose text: the incoming version stays canonical and ours is kept beside it.
function resolveConflicts(cfg) {
  const files = git('diff', '--name-only', '--diff-filter=U').out.split('\n').filter(Boolean);
  const copies = [];
  for (const rel of files) {
    const full = path.join(WORK, rel);
    const ours = spawnSync('git', ['show', `:2:${rel}`], { cwd: WORK });
    const theirs = spawnSync('git', ['show', `:3:${rel}`], { cwd: WORK });
    if (ours.status === 0 && theirs.status === 0) {
      const ext = path.extname(rel);
      const copy = `${rel.slice(0, rel.length - ext.length)}.conflict-${safeName(cfg.host)}-${Date.now()}${ext}`;
      fs.writeFileSync(path.join(WORK, copy), ours.stdout);
      fs.writeFileSync(full, theirs.stdout);
      git('add', '--', copy);
      copies.push(copy);
    } else {
      // One side deleted and the other edited: keep the edit.
      fs.writeFileSync(full, ours.status === 0 ? ours.stdout : theirs.stdout);
    }
    git('add', '--', rel);
  }
  if (!git('commit', '-q', '--no-edit').ok) throw new Error('合并提交失败');
  if (copies.length) log(`memory conflicts kept: ${copies.join(', ')}`);
}

function exchange(cfg) {
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const fetched = git('fetch', '-q', 'origin');
    if (!fetched.ok) { log(`fetch failed, staying offline: ${fetched.err}`); return false; }
    if (git('rev-parse', '--verify', 'origin/main').ok && !git('merge', '-q', '--no-edit', 'origin/main').ok) resolveConflicts(cfg);
    const pushed = git('push', '-q', 'origin', 'HEAD:main');
    if (pushed.ok) return true;
    log(`push retry ${attempt + 1}: ${pushed.err}`);
  }
  return false;
}

function walkFiles(dir, base = dir) {
  let entries = [];
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return []; }
  return entries.flatMap(entry => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return walkFiles(full, base);
    return entry.isFile() ? [path.relative(base, full)] : []; // Symlinks are never followed.
  });
}
const copyFile = (from, to) => { fs.mkdirSync(path.dirname(to), { recursive: true }); fs.copyFileSync(from, to); };
const removeFile = file => fs.rmSync(file, { force: true });

// Live memory dirs known on this machine: existing ones plus explicitly linked projects.
function memoryTargets(cfg, state, cache) {
  const projects = path.join(CLAUDE, 'projects');
  const targets = new Map();
  let dirs = [];
  try { dirs = fs.readdirSync(projects, { withFileTypes: true }).filter(e => e.isDirectory()).map(e => e.name); } catch { /* No Claude here. */ }
  for (const enc of dirs) {
    const cwd = state.encToCwd[enc];
    if (cwd && cfg.excludeCwd.some(prefix => cwd.startsWith(prefix))) continue;
    const key = cwd ? projectKey(cfg, cwd, cache) : `${safeName(cfg.host)}--${enc}`;
    if (cwd || fs.existsSync(path.join(projects, enc, 'memory'))) targets.set(enc, key);
  }
  for (const [cwd, key] of Object.entries(cfg.links)) targets.set(encodeCwd(cwd), key);
  return targets;
}

function exportMemory(targets, state) {
  for (const [enc, key] of targets) {
    const live = path.join(CLAUDE, 'projects', enc, 'memory');
    const shared = path.join(WORK, 'memory', key);
    // A new key means a new shared folder: its baseline says nothing, and reusing it would delete live files on import.
    if (state.memoryKey[enc] && state.memoryKey[enc] !== key) delete state.memory[enc];
    state.memoryKey[enc] = key;
    const base = state.memory[enc] || {};
    const liveFiles = new Set(walkFiles(live));
    for (const rel of liveFiles) if (sha(path.join(live, rel)) !== base[rel]) copyFile(path.join(live, rel), path.join(shared, rel));
    for (const rel of Object.keys(base)) if (!liveFiles.has(rel)) removeFile(path.join(shared, rel));
  }
}

function importMemory(targets, state) {
  for (const [enc, key] of targets) {
    const live = path.join(CLAUDE, 'projects', enc, 'memory');
    const shared = path.join(WORK, 'memory', key);
    const base = state.memory[enc] || {};
    const sharedFiles = walkFiles(shared);
    const next = {};
    for (const rel of sharedFiles) {
      const source = path.join(shared, rel);
      const target = path.join(live, rel);
      const hash = sha(source);
      if (!fs.existsSync(target) || sha(target) !== hash) copyFile(source, target);
      next[rel] = hash;
    }
    for (const rel of Object.keys(base)) if (!next[rel]) removeFile(path.join(live, rel));
    state.memory[enc] = next;
  }
}

function collectSessions(cfg, state, cache) {
  const host = safeName(cfg.host);
  const previous = readJson(path.join(WORK, 'index', `${host}.json`), { sessions: [] }).sessions;
  const byId = new Map(previous.map(item => [`${item.agent}:${item.id}`, item]));
  const changed = [];
  for (const source of [...listClaudeSessions(), ...listCodexSessions()]) {
    let stat;
    try { stat = fs.statSync(source.file); } catch { continue; }
    const signature = `${stat.mtimeMs}:${stat.size}`;
    if (state.sessions[source.file] === signature) continue;
    let meta;
    try { meta = source.agent === 'claude' ? parseClaude(source.file) : parseCodex(source.file); }
    catch (error) { log(`skip ${source.file}: ${error.message}`); continue; }
    state.sessions[source.file] = signature;
    if (source.enc && meta.cwd) state.encToCwd[source.enc] = meta.cwd;
    if (!meta.turns.length || !meta.cwd || cfg.excludeCwd.some(prefix => meta.cwd.startsWith(prefix))) continue;
    const updatedAt = new Date(stat.mtimeMs).toISOString();
    const handoff = `handoffs/${host}/${meta.agent}/${safeName(meta.id)}.md`;
    fs.mkdirSync(path.dirname(path.join(WORK, handoff)), { recursive: true });
    fs.writeFileSync(path.join(WORK, handoff), renderHandoff(meta, cfg.host, updatedAt));
    byId.set(`${meta.agent}:${meta.id}`, {
      id: meta.id, agent: meta.agent, host: cfg.host, cwd: meta.cwd, key: projectKey(cfg, meta.cwd, cache),
      title: redact(meta.title).slice(0, 120), updatedAt, handoff, rawName: path.basename(source.file), rawPath: source.file, relPath: source.agent === 'codex' ? path.relative(path.join(CODEX, 'sessions'), source.file) : undefined
    });
    changed.push(source);
  }
  fs.mkdirSync(path.join(WORK, 'index'), { recursive: true });
  const sessions = [...byId.values()].sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
  fs.writeFileSync(path.join(WORK, 'index', `${host}.json`), JSON.stringify({ host: cfg.host, sessions }, null, 1) + '\n');
  return changed;
}

function ensureRemoteDir(cfg, dir) {
  if (cfg.hub) return `mkdir -p ${dir} && rsync`;
  fs.mkdirSync(dir, { recursive: true });
  return null;
}

// Spokes upload full transcripts so the VPS can resume them; the hub's own stay in place.
function pushRaw(cfg, files) {
  if (cfg.role === 'hub' || cfg.uploadRaw === false) return [];
  const failed = [];
  for (const agent of ['claude', 'codex']) {
    const group = files.filter(item => item.agent === agent && fs.existsSync(item.file));
    if (!group.length) continue;
    const dir = `${cfg.hubPath}/raw/${safeName(cfg.host)}/${agent}`;
    let copied;
    try {
      const rsyncPath = ensureRemoteDir(cfg, dir);
      const args = ['-a', '--partial', '--chmod=Du=rwx,Dgo=,Fu=rw,Fgo=', '-e', SSH, ...(rsyncPath ? [`--rsync-path=${rsyncPath}`] : []), ...group.map(item => item.file), `${remoteSpec(cfg, dir)}/`];
      copied = run('rsync', args, { timeout: 600000 });
    } catch (error) { copied = { ok: false, err: error.message }; }
    if (!copied.ok) { log(`raw upload failed for ${agent}, will retry: ${copied.err}`); failed.push(...group); }
  }
  return failed;
}

function notifyPeers(cfg) {
  for (const peer of cfg.peers) {
    const child = spawn('ssh', [...SSH.split(' ').slice(1), peer, '$HOME/.agent-sync/bin/agent-sync', 'sync', '--from-peer'], { detached: true, stdio: 'ignore' });
    child.on('error', () => {});
    child.unref();
  }
}

function acquireLock() {
  fs.mkdirSync(ROOT, { recursive: true, mode: 0o700 });
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      fs.mkdirSync(LOCK);
      fs.writeFileSync(path.join(LOCK, 'pid'), String(process.pid));
      return true;
    } catch {
      const holder = Number(readJson(path.join(LOCK, 'pid'), 0));
      let alive = false;
      try { if (holder) { process.kill(holder, 0); alive = true; } } catch { /* Holder died. */ }
      if (alive) return false;
      fs.rmSync(LOCK, { recursive: true, force: true });
    }
  }
  return false;
}

function syncOnce(cfg, options) {
  ensureWorktree(cfg);
  const state = { sessions: {}, memory: {}, memoryKey: {}, encToCwd: {}, gitKeys: {}, ...readJson(STATE, {}) };
  // cron on macOS may be denied ~/Desktop, so a git-derived key must survive a failed lookup.
  const cache = new Map(Object.entries(state.gitKeys));
  const changed = collectSessions(cfg, state, cache);
  const targets = memoryTargets(cfg, state, cache);
  exportMemory(targets, state);
  git('add', '-A');
  const dirty = !git('diff', '--cached', '--quiet').ok;
  if (dirty) git('commit', '-q', '-m', `sync from ${cfg.host}`);
  const online = exchange(cfg);
  importMemory(targets, state);
  state.gitKeys = Object.fromEntries([...cache].filter(([, key]) => key.startsWith('git-')));
  // Failed uploads stay queued, because an unchanged transcript is not rescanned.
  const queued = new Map([...(state.rawPending || []), ...changed.map(({ agent, file }) => ({ agent, file }))].map(item => [item.file, item]));
  state.rawPending = online ? pushRaw(cfg, [...queued.values()]) : cfg.role === 'hub' ? [] : [...queued.values()];
  writeJson(STATE, state);
  if (online && dirty && !options.fromPeer) notifyPeers(cfg);
  return { changed: changed.length, online };
}

function sync(options = {}) {
  const cfg = config();
  if (!acquireLock()) {
    fs.writeFileSync(PENDING, '');
    return { skipped: true };
  }
  try {
    let result = syncOnce(cfg, options);
    if (fs.existsSync(PENDING)) { removeFile(PENDING); result = syncOnce(cfg, options); }
    return result;
  } finally { fs.rmSync(LOCK, { recursive: true, force: true }); }
}

function allSessions() {
  return walkFiles(path.join(WORK, 'index')).flatMap(rel => readJson(path.join(WORK, 'index', rel), { sessions: [] }).sessions)
    .sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
}
function findSession(prefix, host) {
  const matches = allSessions().filter(item => item.id.startsWith(prefix) && (!host || item.host === host));
  if (!matches.length) throw new Error(`找不到会话 ${prefix}`);
  if (new Set(matches.map(item => `${item.host}/${item.agent}/${item.id}`)).size > 1) {
    throw new Error(`会话 ${prefix} 有多个匹配，请用更长的 ID 或 --host：\n${matches.map(item => `  ${item.host} ${item.agent} ${item.id}`).join('\n')}`);
  }
  return matches[0];
}

function resumeSession(cfg, session, cwd, force) {
  const target = session.agent === 'claude'
    ? path.join(CLAUDE, 'projects', encodeCwd(cwd), `${session.id}.jsonl`)
    : path.join(CODEX, 'sessions', session.relPath || session.rawName);
  if (session.rawPath === target) return { target, command: resumeCommand(session) };
  if (fs.existsSync(target) && !force) throw new Error(`目标已存在，未覆盖：${target}（确认后加 --force，旧文件会备份）`);
  if (fs.existsSync(target)) fs.copyFileSync(target, `${target}.bak-${Date.now()}`);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  let source;
  const peer = cfg.peers.find(item => session.host === item || item.endsWith(`@${session.host}`)) || cfg.peers[0];
  const uploaded = path.join(ROOT, 'raw', safeName(session.host), session.agent, session.rawName);
  if (session.host === cfg.host) source = session.rawPath;
  else if (cfg.role === 'hub' && !fs.existsSync(uploaded) && peer) source = `${peer}:${session.rawPath}`;
  else if (session.host === cfg.hubHost && cfg.role !== 'hub') source = remoteSpec(cfg, session.rawPath);
  else source = cfg.role === 'hub'
    ? path.join(ROOT, 'raw', safeName(session.host), session.agent, session.rawName)
    : remoteSpec(cfg, `${cfg.hubPath}/raw/${safeName(session.host)}/${session.agent}/${session.rawName}`);
  const copied = run('rsync', ['-a', '--partial', '-e', SSH, source, target], { timeout: 600000 });
  if (!copied.ok) throw new Error(`下载原始会话失败：${copied.err}`);
  return { target, command: resumeCommand(session) };
}
const resumeCommand = session => session.agent === 'claude' ? `claude --resume ${session.id}` : `codex resume ${session.id}`;

function sessionStartContext(cfg, cwd) {
  const key = cfg.links[cwd] || projectKey(cfg, cwd, new Map());
  const latest = allSessions().find(item => item.key === key && item.host !== cfg.host);
  const conflicts = walkFiles(path.join(WORK, 'memory', key)).filter(rel => /\.conflict-/.test(rel));
  const lines = [];
  if (latest) lines.push(`[agent-sync] 另一台机器 ${latest.host} 上该项目最近的 ${latest.agent} 会话（${latest.updatedAt}）：${latest.title}。需要接手时读取交接记录：${path.join(WORK, latest.handoff)}`);
  if (conflicts.length) lines.push(`[agent-sync] 记忆同步留下了 ${conflicts.length} 个冲突副本，需要合并后删除：${conflicts.join(', ')}`);
  return lines.join('\n');
}

// ---------- install ----------
function backup(file) {
  if (fs.existsSync(file)) fs.copyFileSync(file, `${file}.agent-sync-bak-${Date.now()}`);
}

function mergeClaudeHooks(settingsFile, wrapper) {
  const settings = readJson(settingsFile, fs.existsSync(settingsFile) ? null : {});
  if (!settings) throw new Error(`${settingsFile} 不是合法 JSON，未修改`);
  settings.hooks ||= {};
  const quoted = shellQuote(wrapper);
  const wanted = {
    SessionStart: { type: 'command', command: `${quoted} hook session-start`, timeout: 20 },
    Stop: { type: 'command', command: `${quoted} sync --quiet`, async: true, timeout: 300 },
    SessionEnd: { type: 'command', command: `${quoted} sync --quiet`, async: true, timeout: 300 }
  };
  const before = JSON.stringify(settings.hooks);
  for (const [event, hook] of Object.entries(wanted)) {
    settings.hooks[event] = (settings.hooks[event] || []).filter(group => !(group.hooks || []).some(item => String(item.command || '').includes('agent-sync')));
    settings.hooks[event].push({ hooks: [hook] });
  }
  if (JSON.stringify(settings.hooks) === before) return false;
  backup(settingsFile);
  fs.mkdirSync(path.dirname(settingsFile), { recursive: true });
  writeJson(settingsFile, settings);
  return true;
}

// Top-level TOML keys must precede the first table, so notify is prepended.
function installCodexNotify(wrapper) {
  const file = path.join(CODEX, 'config.toml');
  if (!fs.existsSync(CODEX)) return '未检测到 Codex，已跳过';
  const text = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '';
  if (/^\s*notify\s*=/m.test(text)) return text.includes('agent-sync') ? 'Codex notify 已配置' : 'Codex 已有其他 notify，未覆盖；本机靠定时任务同步 Codex 会话';
  backup(file);
  fs.writeFileSync(file, `notify = [${JSON.stringify(wrapper)}, "sync", "--quiet"]\n${text}`, { mode: 0o600 });
  return 'Codex notify 已写入';
}

const AGENTS_BEGIN = '<!-- agent-sync:begin -->';
const AGENTS_END = '<!-- agent-sync:end -->';
function installCodexInstructions(wrapper) {
  if (!fs.existsSync(CODEX)) return;
  const file = path.join(CODEX, 'AGENTS.md');
  const block = [AGENTS_BEGIN,
    '## 跨机器记忆与会话',
    `共享记忆在 \`${path.join(WORK, 'memory')}\`，按项目分目录；开始项目工作前读取对应目录的 MEMORY.md。`,
    `其他机器的会话用 \`${wrapper} sessions --project\` 查看，用 \`${wrapper} show <会话ID>\` 读取交接记录后接手。`,
    AGENTS_END].join('\n');
  const text = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '';
  const pattern = new RegExp(`${AGENTS_BEGIN}[\\s\\S]*?${AGENTS_END}`);
  const next = pattern.test(text) ? text.replace(pattern, block) : `${text}${text && !text.endsWith('\n') ? '\n\n' : ''}${block}\n`;
  if (next !== text) { backup(file); fs.writeFileSync(file, next); }
}

function installCron(wrapper) {
  const line = `*/5 * * * * ${shellQuote(wrapper)} sync --quiet >/dev/null 2>&1 # agent-sync`;
  const current = run('crontab', ['-l']);
  const kept = (current.ok ? current.out.split('\n') : []).filter(item => item.trim() && !item.includes('# agent-sync'));
  const result = spawnSync('crontab', ['-'], { input: [...kept, line, ''].join('\n'), encoding: 'utf8' });
  return result.status === 0;
}

function install(flags) {
  const previous = readJson(CONFIG, {});
  const role = flags.role || previous.role;
  if (!['hub', 'spoke'].includes(role)) throw new Error('需要 --role hub 或 --role spoke');
  const cfg = {
    ...previous, role,
    host: flags.host || previous.host || os.hostname().split('.')[0],
    peers: flags.peer.length ? flags.peer : previous.peers || [],
    hub: flags.hub || previous.hub,
    hubHost: flags['hub-host'] || previous.hubHost,
    hubPath: flags['hub-path'] || previous.hubPath || '.agent-sync',
    links: previous.links || {}, excludeCwd: previous.excludeCwd || DEFAULT_EXCLUDE
  };
  if (role === 'hub') { delete cfg.hub; delete cfg.hubHost; }
  if (role === 'spoke' && !cfg.hubHost) throw new Error('spoke 需要 --hub-host <hub 的 --host 名称>');
  fs.mkdirSync(path.join(ROOT, 'bin'), { recursive: true, mode: 0o700 });
  fs.chmodSync(ROOT, 0o700);
  writeJson(CONFIG, cfg);
  const script = path.join(ROOT, 'bin', 'agent-sync.cjs');
  if (path.resolve(__filename) !== script) fs.copyFileSync(__filename, script);
  const wrapper = path.join(ROOT, 'bin', 'agent-sync');
  const searchPath = [path.dirname(process.execPath), '/opt/homebrew/bin', '/usr/local/bin', '/usr/bin', '/bin'].join(':');
  fs.writeFileSync(wrapper, `#!/bin/sh\nPATH=${shellQuote(searchPath)}:"$PATH"\nexport PATH\nexec node ${shellQuote(script)} "$@"\n`, { mode: 0o755 });
  const report = [];
  if (!flags['no-hooks']) report.push(mergeClaudeHooks(path.join(CLAUDE, 'settings.json'), wrapper) ? 'Claude hooks 已写入' : 'Claude hooks 无变化');
  if (!flags['no-codex']) { report.push(installCodexNotify(wrapper)); installCodexInstructions(wrapper); }
  if (!flags['no-cron']) report.push(installCron(wrapper) ? '定时任务已写入（每 5 分钟）' : '定时任务写入失败');
  ensureWorktree(cfg);
  console.log(report.join('\n'));
  console.log(`安装完成：${wrapper}`);
}

function doctor() {
  const cfg = config();
  const rows = [['角色', `${cfg.role} / ${cfg.host}`]];
  const remote = git('ls-remote', '--heads', 'origin');
  rows.push(['Hub 连通', remote.ok ? '正常' : `失败：${remote.err.split('\n')[0]}`]);
  for (const peer of cfg.peers) {
    const reached = run('ssh', [...SSH.split(' ').slice(1), peer, 'true'], { timeout: 15000 });
    rows.push([`对端 ${peer}`, reached.ok ? '正常' : `失败：${reached.err.split('\n')[0]}`]);
  }
  rows.push(['会话数', String(allSessions().length)]);
  rows.push(['记忆冲突', String(walkFiles(path.join(WORK, 'memory')).filter(rel => /\.conflict-/.test(rel)).length)]);
  for (const [name, value] of rows) console.log(`${name}: ${value}`);
  return remote.ok;
}

function parseFlags(argv) {
  const flags = { _: [], peer: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const item = argv[i];
    if (!item.startsWith('--')) { flags._.push(item); continue; }
    const name = item.slice(2);
    if (['quiet', 'from-peer', 'force', 'project', 'no-cron', 'no-codex', 'no-hooks'].includes(name)) flags[name] = true;
    else if (name === 'peer') flags.peer.push(argv[++i]);
    else flags[name] = argv[++i];
  }
  return flags;
}

function main() {
  const [command, ...rest] = process.argv.slice(2);
  const flags = parseFlags(rest);
  if (command === 'install') return install(flags);
  if (command === 'sync') {
    const result = sync({ fromPeer: flags['from-peer'] });
    if (!flags.quiet) console.log(result.skipped ? '已有同步在运行，已排队' : `同步完成：${result.changed} 个会话更新，${result.online ? '已连接 hub' : 'hub 不可达，仅本地提交'}`);
    return undefined;
  }
  if (command === 'hook' && flags._[0] === 'session-start') {
    const input = readJson(0, {});
    const cfg = config();
    try { sync({}); } catch (error) { log(`session-start: ${error.message}`); }
    const context = sessionStartContext(cfg, input.cwd || process.cwd());
    if (context) console.log(context);
    return undefined;
  }
  if (command === 'sessions') {
    const cfg = config();
    const cwd = flags.cwd || process.cwd();
    const key = flags.project ? (cfg.links[cwd] || projectKey(cfg, cwd, new Map())) : null;
    for (const item of allSessions().filter(s => !key || s.key === key)) console.log(`${item.updatedAt}  ${item.host}/${item.agent}  ${item.id}  ${item.cwd}  ${item.title}`);
    return undefined;
  }
  if (command === 'show') {
    const session = findSession(flags._[0] || '', flags.host);
    process.stdout.write(fs.readFileSync(path.join(WORK, session.handoff), 'utf8'));
    return undefined;
  }
  if (command === 'resume') {
    const cfg = config();
    const session = findSession(flags._[0] || '', flags.host);
    const cwd = path.resolve(flags.cwd || process.cwd());
    const result = resumeSession(cfg, session, cwd, flags.force);
    console.log(`原始会话已就位：${result.target}\n在 ${cwd} 运行：${result.command}`);
    return undefined;
  }
  if (command === 'link') {
    const cfg = readJson(CONFIG, null);
    if (!cfg || !flags._[0]) throw new Error('用法：agent-sync link <共享项目名> [路径]');
    cfg.links = { ...cfg.links, [path.resolve(flags._[1] || process.cwd())]: safeName(flags._[0]) };
    writeJson(CONFIG, cfg);
    console.log('已关联，下次同步生效');
    return undefined;
  }
  if (command === 'doctor') { if (!doctor()) process.exitCode = 1; return undefined; }
  console.log('用法：agent-sync install|sync|sessions [--project]|show <id>|resume <id> [--cwd 路径] [--force]|link <名称> [路径]|doctor');
  return undefined;
}

if (require.main === module) {
  try { main(); } catch (error) {
    log(`error: ${error.message}`);
    // Hooks must not interrupt the agent; interactive commands report the failure.
    if (process.argv.includes('--quiet') || process.argv[2] === 'hook') process.exit(0);
    console.error(error.message);
    process.exit(1);
  }
}
module.exports = { redact, parseClaude, parseCodex, renderHandoff, encodeCwd };
