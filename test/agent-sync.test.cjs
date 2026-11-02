const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const script = path.resolve('scripts/agent-sync.cjs');
const { redact } = require(script);

function machine(base, name) {
  const home = path.join(base, name);
  fs.mkdirSync(home, { recursive: true });
  const env = { ...process.env, HOME: home, AGENT_SYNC_HOME: path.join(home, '.agent-sync'), CLAUDE_CONFIG_DIR: path.join(home, '.claude'), CODEX_HOME: path.join(home, '.codex') };
  const run = (...args) => {
    const result = spawnSync(process.execPath, [script, ...args], { encoding: 'utf8', env });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout;
  };
  const project = cwd => path.join(home, '.claude/projects', cwd.replace(/[^a-zA-Z0-9]/g, '-'));
  const memory = (cwd, rel) => path.join(project(cwd), 'memory', rel);
  const put = (file, text) => { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, text); };
  return { home, env, run, project, memory, put, root: env.AGENT_SYNC_HOME };
}

function pair() {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-sync-'));
  const vps = machine(base, 'vps');
  const laptop = machine(base, 'laptop');
  const flags = ['--no-cron', '--no-codex'];
  vps.run('install', '--role', 'hub', '--host', 'vps', ...flags);
  laptop.run('install', '--role', 'spoke', '--host', 'laptop', '--hub-host', 'vps', '--hub-path', vps.root, ...flags);
  vps.run('link', 'shared', '/work/vps-app');
  laptop.run('link', 'shared', '/Users/me/app');
  return { base, vps, laptop, close: () => fs.rmSync(base, { recursive: true, force: true }) };
}

const claudeLines = (id, cwd, text) => [
  { type: 'ai-title', aiTitle: '修复登录', sessionId: id },
  { type: 'user', cwd, gitBranch: 'main', timestamp: '2026-11-01T00:00:00Z', message: { role: 'user', content: text } },
  { type: 'assistant', cwd, timestamp: '2026-11-01T00:00:01Z', message: { role: 'assistant', content: [{ type: 'thinking', thinking: 'PRIVATE-THOUGHT' }, { type: 'text', text: '已修复' }, { type: 'tool_use', name: 'Bash', input: { command: 'npm test' } }] } },
  { type: 'user', cwd, message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'x', content: 'TOOL-OUTPUT' }] } }
].map(line => JSON.stringify(line)).join('\n') + '\n';

test('memory created on one machine reaches the other project path, including deletes', () => {
  const { vps, laptop, close } = pair(); try {
    vps.put(vps.memory('/work/vps-app', 'fact.md'), 'from vps');
    vps.run('sync'); laptop.run('sync');
    assert.equal(fs.readFileSync(laptop.memory('/Users/me/app', 'fact.md'), 'utf8'), 'from vps');
    laptop.put(laptop.memory('/Users/me/app', 'fact.md'), 'edited on laptop');
    laptop.run('sync'); vps.run('sync');
    assert.equal(fs.readFileSync(vps.memory('/work/vps-app', 'fact.md'), 'utf8'), 'edited on laptop');
    fs.rmSync(vps.memory('/work/vps-app', 'fact.md'));
    vps.run('sync'); laptop.run('sync');
    assert.equal(fs.existsSync(laptop.memory('/Users/me/app', 'fact.md')), false);
  } finally { close(); }
});

test('linking a project later moves its memory and never deletes it', () => {
  const { vps, close } = pair(); try {
    const id = '77777777-2222-4333-8444-555555555555';
    vps.put(path.join(vps.project('/work/late'), `${id}.jsonl`), claudeLines(id, '/work/late', '任务'));
    vps.put(vps.memory('/work/late', 'keep.md'), 'precious');
    vps.run('sync'); vps.run('sync');
    vps.run('link', 'late-shared', '/work/late');
    vps.run('sync'); vps.run('sync');
    assert.equal(fs.readFileSync(vps.memory('/work/late', 'keep.md'), 'utf8'), 'precious');
    assert.equal(fs.readFileSync(path.join(vps.root, 'hub/memory/late-shared/keep.md'), 'utf8'), 'precious');
  } finally { close(); }
});

test('conflicting memory edits keep both versions and MEMORY.md merges by union', () => {
  const { vps, laptop, close } = pair(); try {
    vps.put(vps.memory('/work/vps-app', 'fact.md'), 'base\n');
    vps.put(vps.memory('/work/vps-app', 'MEMORY.md'), '- base\n');
    vps.run('sync'); laptop.run('sync');
    vps.put(vps.memory('/work/vps-app', 'fact.md'), 'vps side\n');
    vps.put(vps.memory('/work/vps-app', 'MEMORY.md'), '- base\n- vps\n');
    laptop.put(laptop.memory('/Users/me/app', 'fact.md'), 'laptop side\n');
    laptop.put(laptop.memory('/Users/me/app', 'MEMORY.md'), '- base\n- laptop\n');
    vps.run('sync'); laptop.run('sync'); vps.run('sync');
    const dir = path.dirname(vps.memory('/work/vps-app', 'fact.md'));
    const contents = fs.readdirSync(dir).filter(name => name.startsWith('fact')).map(name => fs.readFileSync(path.join(dir, name), 'utf8')).sort();
    assert.deepEqual(contents, ['laptop side\n', 'vps side\n']);
    const index = fs.readFileSync(path.join(dir, 'MEMORY.md'), 'utf8');
    assert.match(index, /- vps/); assert.match(index, /- laptop/);
  } finally { close(); }
});

test('sessions hand off across machines without thinking, tool output or secrets', () => {
  const { vps, laptop, close } = pair(); try {
    const id = '11111111-2222-4333-8444-555555555555';
    vps.put(path.join(vps.project('/work/vps-app'), `${id}.jsonl`), claudeLines(id, '/work/vps-app', '修复登录 password=hunter2secret'));
    vps.run('sync'); laptop.run('sync');
    assert.match(laptop.run('sessions'), /vps\/claude/);
    const handoff = laptop.run('show', '11111111');
    assert.match(handoff, /已修复/); assert.match(handoff, /Bash: npm test/);
    assert.doesNotMatch(handoff, /PRIVATE-THOUGHT|TOOL-OUTPUT|hunter2secret/);
  } finally { close(); }
});

test('a laptop Codex session reaches the hub with its raw transcript and can be resumed there', () => {
  const { vps, laptop, close } = pair(); try {
    const id = '01a18051-c3e0-7103-b807-4d878f67dd6c';
    const rollout = path.join(laptop.home, `.codex/sessions/2026/11/01/rollout-2026-11-01T00-00-00-${id}.jsonl`);
    const lines = [
      { type: 'session_meta', payload: { id, cwd: '/Users/me/app' } },
      { type: 'response_item', timestamp: 't', payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text: '<environment_context>noise</environment_context>' }] } },
      { type: 'response_item', timestamp: 't', payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text: '继续做同步' }] } },
      { type: 'response_item', timestamp: 't', payload: { type: 'custom_tool_call', name: 'exec', input: 'ls' } },
      { type: 'response_item', timestamp: 't', payload: { type: 'message', role: 'assistant', content: [{ type: 'output_text', text: '做完了' }] } }
    ];
    laptop.put(rollout, lines.map(line => JSON.stringify(line)).join('\n') + '\n');
    laptop.run('sync'); vps.run('sync');
    const handoff = vps.run('show', id.slice(0, 8));
    assert.match(handoff, /继续做同步/); assert.match(handoff, /做完了/); assert.match(handoff, /exec: ls/);
    assert.doesNotMatch(handoff, /environment_context/);
    assert.match(vps.run('resume', id.slice(0, 8)), new RegExp(`codex resume ${id}`));
    const restored = path.join(vps.home, `.codex/sessions/2026/11/01/${path.basename(rollout)}`);
    assert.equal(fs.readFileSync(restored, 'utf8'), fs.readFileSync(rollout, 'utf8'));
  } finally { close(); }
});

test('a raw upload missed while offline is retried once the hub returns', () => {
  const { vps, laptop, close } = pair(); try {
    const id = '66666666-2222-4333-8444-555555555555';
    const file = path.join(laptop.project('/Users/me/app'), `${id}.jsonl`);
    laptop.put(file, claudeLines(id, '/Users/me/app', '离线任务'));
    const bare = path.join(vps.root, 'hub.git'); const hidden = `${bare}.off`;
    fs.renameSync(bare, hidden);
    laptop.run('sync');
    const raw = path.join(vps.root, 'raw/laptop/claude', `${id}.jsonl`);
    assert.equal(fs.existsSync(raw), false);
    fs.renameSync(hidden, bare);
    laptop.run('sync');
    assert.equal(fs.readFileSync(raw, 'utf8'), fs.readFileSync(file, 'utf8'));
  } finally { close(); }
});

test('uploadRaw false keeps transcripts on the spoke while hand-offs still sync', () => {
  const { vps, laptop, close } = pair(); try {
    const file = path.join(laptop.root, 'config.json');
    fs.writeFileSync(file, JSON.stringify({ ...JSON.parse(fs.readFileSync(file, 'utf8')), uploadRaw: false }));
    const id = '88888888-2222-4333-8444-555555555555';
    laptop.put(path.join(laptop.project('/Users/me/app'), `${id}.jsonl`), claudeLines(id, '/Users/me/app', '本地任务'));
    laptop.run('sync'); vps.run('sync');
    assert.equal(fs.existsSync(path.join(vps.root, 'raw')), false);
    assert.match(vps.run('show', '88888888'), /本地任务/);
  } finally { close(); }
});

test('a Claude session from the hub is restored under the local project path', () => {
  const { vps, laptop, close } = pair(); try {
    const id = '22222222-2222-4333-8444-555555555555';
    const source = path.join(vps.project('/work/vps-app'), `${id}.jsonl`);
    vps.put(source, claudeLines(id, '/work/vps-app', '任务'));
    vps.run('sync'); laptop.run('sync');
    const cwd = path.join(laptop.home, 'app'); fs.mkdirSync(cwd);
    assert.match(laptop.run('resume', '22222222', '--cwd', cwd), /claude --resume/);
    assert.equal(fs.readFileSync(path.join(laptop.project(cwd), `${id}.jsonl`), 'utf8'), fs.readFileSync(source, 'utf8'));
    const again = spawnSync(process.execPath, [script, 'resume', '22222222', '--cwd', cwd], { encoding: 'utf8', env: laptop.env });
    assert.equal(again.status, 1); assert.match(again.stderr, /未覆盖/);
  } finally { close(); }
});

test('credentials and temp-dir sessions never enter the hub', () => {
  const { vps, close } = pair(); try {
    vps.put(path.join(vps.home, '.claude/.credentials.json'), 'CRED-MARKER');
    vps.put(path.join(vps.home, '.claude/settings.json'), '{"env":{"X":"CRED-MARKER"}}');
    vps.put(path.join(vps.home, '.codex/auth.json'), 'CRED-MARKER');
    const id = '33333333-2222-4333-8444-555555555555';
    vps.put(path.join(vps.project('/tmp/scratch'), `${id}.jsonl`), claudeLines(id, '/tmp/scratch', 'TEMP-MARKER'));
    vps.run('sync');
    const found = spawnSync('grep', ['-rlE', 'CRED-MARKER|TEMP-MARKER', '--exclude-dir=.git', path.join(vps.root, 'hub')], { encoding: 'utf8' });
    assert.equal(found.stdout, '');
    const history = spawnSync('git', ['-C', path.join(vps.root, 'hub'), 'log', '-p', '--all'], { encoding: 'utf8', maxBuffer: 1 << 26 });
    assert.doesNotMatch(history.stdout, /CRED-MARKER|TEMP-MARKER/);
  } finally { close(); }
});

test('install keeps existing hooks, is idempotent and never fails a hook when the hub is unreachable', () => {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-sync-')); try {
    const box = machine(base, 'box');
    const settings = path.join(box.home, '.claude/settings.json');
    box.put(settings, JSON.stringify({ model: 'x', hooks: { Stop: [{ hooks: [{ type: 'command', command: 'mine' }] }] } }));
    fs.mkdirSync(path.join(box.home, '.codex'));
    box.put(path.join(box.home, '.codex/config.toml'), '[tui]\nx = 1\n');
    box.run('install', '--role', 'hub', '--host', 'box', '--no-cron');
    box.run('install', '--role', 'hub', '--no-cron');
    const saved = JSON.parse(fs.readFileSync(settings, 'utf8'));
    assert.equal(saved.model, 'x');
    assert.equal(saved.hooks.Stop.length, 2);
    assert.equal(saved.hooks.Stop[0].hooks[0].command, 'mine');
    assert.equal(saved.hooks.Stop[1].hooks[0].async, true);
    const toml = fs.readFileSync(path.join(box.home, '.codex/config.toml'), 'utf8');
    assert.match(toml, /^notify = /); assert.equal(toml.match(/notify =/g).length, 1); assert.ok(toml.indexOf('notify') < toml.indexOf('[tui]'));
    fs.rmSync(path.join(box.root, 'hub.git'), { recursive: true });
    const quiet = spawnSync(process.execPath, [script, 'sync', '--quiet'], { encoding: 'utf8', env: box.env });
    assert.equal(quiet.status, 0);
  } finally { fs.rmSync(base, { recursive: true, force: true }); }
});

test('redact removes common credentials and keeps ordinary text', () => {
  const samples = ['sk-ant-abcdefghijklmnopqrstuvwx', 'ghp_abcdefghijklmnopqrstuvwx', 'AKIAABCDEFGHIJKLMNOP', 'tskey-auth-abcdefghijkl', 'Authorization: Bearer abcdefghijklmnop123'];
  for (const sample of samples) assert.match(redact(sample), /已脱敏/, sample);
  assert.doesNotMatch(redact('TOKEN=abc12345'), /abc12345/);
  assert.equal(redact('普通文本 token 的说明'), '普通文本 token 的说明');
});
