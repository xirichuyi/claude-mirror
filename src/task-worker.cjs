// One remote owner keeps the SDK and its input stream alive across turns.
const fs = require('node:fs');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { spawn } = require('node:child_process');
const { resolveClaudeLaunch, validateDirectory } = require('./claude-launch.cjs');
const { ChatService } = require('./chat-service.cjs');
const { Transcript } = require('./transcript.cjs');
const { catalogue, preferencePatch } = require('./capabilities.cjs');
const { SessionInput } = require('./session-input.cjs');
const { IdlePolicy } = require('./idle-policy.cjs');
const idle = new IdlePolicy();
const folder = process.argv[2];
const request = JSON.parse(fs.readFileSync(path.join(folder, 'request.json'), 'utf8'));
const session = request.session;
session.permissions = [];
let version = 0, ended = false, hibernating = false, stateBytes = 0;
function atomic(filename, value) {
  const data = JSON.stringify(value);
  fs.writeFileSync(filename + '.tmp', data, { mode: 0o600 });
  fs.renameSync(filename + '.tmp', filename);
  return data.length;
}
// Every streamed update rewrites the whole state, and each watcher parses and diffs it. Past
// 256 KB, widen the coalescing window in proportion so a long reply costs ~5 MB/s at most
// instead of growing per 50 ms tick. Approvals and completion are always written immediately.
const STREAM_BYTES = 256 * 1024;
const streamDelay = () => Math.min(1000, Math.max(50, Math.round(50 * stateBytes / STREAM_BYTES)));
function snapshot() {
  stateBytes = atomic(path.join(folder, 'state.json'), { version: ++version, done: ended, resident: true, hibernated: hibernating,
    status: session.status, permissions: session.permissions, message: session.messages.at(-1),
    remoteSessionId: session.remoteSessionId, model: session.model, preferences: session.preferences,
    capabilities: session.capabilities, tools: session.tools, plugins: session.plugins,
    terminalCommands: session.terminalCommands, usage: session.usage, tasks: session.tasks, forkPending: session.forkPending });
}
session.tasks = []; // Background task membership belongs to this SDK process.
const service = new ChatService({ load: () => [session], save: snapshot });
service.closing = true;
service.streamDelay = streamDelay;
service.spawn = (_session, options, onError) => {
  const child = spawn(service.claudeExecutable, options.args, { cwd: session.directory, stdio: ['pipe', 'pipe', 'pipe'], env: options.env, signal: options.signal });
  child.stderr.setEncoding('utf8'); child.stderr.on('data', onError); return child;
};
const input = new SessionInput();
const run = { stopped: false, stderr: '', message: session.messages.at(-1) };
run.transcript = new Transcript(run.message);
service.runs.set(session.id, run);
let query, handling = false;
const rewind = require('./checkpoint-control.cjs').checkpointControl(() => query, () => service.runs.has(session.id) || session.tasks?.some(task => task.status === 'running'));
async function control(command) {
  idle.touch();
  if (command.kind === 'send') {
    if (run.message.id === command.message.id) return {}; // Replay after an uncertain transport ACK.
    validateDirectory(session.directory);
    if (service.runs.has(session.id)) throw new Error('远端会话正在回复');
    session.messages = [command.message];
    Object.assign(run, { message: command.message, stopped: false, stderr: '', transcript: new Transcript(command.message) });
    service.runs.set(session.id, run); session.status = 'working'; snapshot();
    input.push(command.prompt, command.message.id, session.remoteSessionId);
    return {};
  }
  if (command.kind === 'stop') {
    if (service.runs.has(session.id)) {
      run.stopped = true; session.status = 'stopping'; snapshot();
      for (const permission of [...session.permissions]) service.respond(session.id, permission.id, { allow: false });
      await query.interrupt();
    }
    return {};
  }
  if (command.kind === 'respond') {
    if (service.approvals.has(command.permissionId)) service.respond(session.id, command.permissionId, command.answer);
    return {};
  }
  if (command.kind === 'control') {
    const methods = {
      model: async () => { await query.setModel(command.value || undefined); session.preferences.selectedModel = command.value; },
      effort: async () => { await query.applyFlagSettings({ effortLevel: command.value || null }); session.preferences.effort = command.value; },
      permission: async () => { await query.setPermissionMode(command.value); session.preferences.permissionMode = command.value; },
      configure: async () => {
        const patch = preferencePatch(command.value);
        for (const [key, value] of Object.entries(patch)) {
          if (key === 'selectedModel') await query.setModel(value || undefined);
          else if (key === 'permissionMode') await query.setPermissionMode(value);
          else if (['effort', 'fastMode', 'outputStyle'].includes(key)) await query.applyFlagSettings({ [key === 'effort' ? 'effortLevel' : key]: value === '' ? null : value });
          else throw new Error('此设置需要重新打开会话');
          session.preferences[key] = value; snapshot();
        }
        return session.preferences;
      },
      catalogue: async () => { session.capabilities = await catalogue(query); return session.capabilities; },
      rewind: () => rewind(command.value),
      stopTask: async () => {
        if (typeof command.value !== 'string' || !session.tasks?.some(task => task.id === command.value && task.status === 'running')) throw new Error('任务已结束或不存在');
        if (typeof query.stopTask !== 'function') throw new Error('当前远端版本不支持停止后台任务');
        await query.stopTask(command.value);
      },
      context: () => query.getContextUsage({ detail: 'summary' }),
      mcp: () => query.mcpServerStatus(),
      plugins: () => query.reloadPlugins({ holdOnCacheImpact: true }),
    };
    if (!methods[command.action]) throw new Error('未知会话控制操作');
    const result = await methods[command.action]();
    snapshot(); return result || {};
  }
  if (command.kind === 'close') { input.close(); query.close(); return {}; }
  throw new Error('未知会话请求');
}
const commandDirectory = path.join(folder, 'commands');
const inFlight = new Set(), stopping = new Set();
async function execute(name, command) {
  const filename = path.join(commandDirectory, name);
  inFlight.add(name);
  try {
    // A bad command must never block later answers or stop requests.
    if (!fs.existsSync(filename + '.result')) {
      let result;
      try { result = { ok: true, value: await control(command ?? JSON.parse(fs.readFileSync(filename, 'utf8'))) }; }
      catch (error) { result = { ok: false, error: error.message }; }
      atomic(filename + '.result', result);
    }
    fs.renameSync(filename, filename + '.done');
  } finally { inFlight.delete(name); }
}
// Approvals and stop must not wait behind a slow control (plugin reload, MCP status, catalogue).
// An answer can always go ahead; a stop goes ahead unless an earlier send is still queued,
// because overtaking that send would stop nothing and let the new turn run.
function overtakes(command, earlierSend) {
  return command?.kind === 'respond' || (command?.kind === 'stop' && !earlierSend);
}
let rerun = false;
async function commands() {
  if (!query) return;
  const ordered = [];
  let earlierSend = false;
  for (const name of fs.readdirSync(commandDirectory).sort()) {
    if (!name.endsWith('.json') || inFlight.has(name)) continue;
    let command = null;
    try { command = JSON.parse(fs.readFileSync(path.join(commandDirectory, name), 'utf8')); } catch { /* Reported by execute. */ }
    if (overtakes(command, earlierSend)) {
      const done = execute(name, command).catch(error => console.error(error.message));
      if (command.kind === 'stop') { stopping.add(done); void done.finally(() => stopping.delete(done)); }
    } else {
      if (command?.kind === 'send') earlierSend = true;
      ordered.push([name, command]);
    }
  }
  if (handling) { rerun = true; return; }
  handling = true;
  try {
    for (const [name, command] of ordered) {
      if (inFlight.has(name) || !fs.existsSync(path.join(commandDirectory, name))) continue;
      // A send queued after a stop starts only once that stop has finished.
      if (command?.kind === 'send') await Promise.all(stopping);
      await execute(name, command);
    }
  } finally { handling = false; }
  if (rerun) { rerun = false; return commands(); }
}
// .done/.result files are replay tombstones: a retried command ID must not run twice. Keep them a
// day, then remove them so a long-lived resident session does not rescan an ever-growing folder.
const TOMBSTONE_AGE = 86400000;
let lastPrune = 0;
function pruneTombstones(now = Date.now()) {
  if (now - lastPrune < 3600000) return;
  lastPrune = now;
  for (const name of fs.readdirSync(commandDirectory)) {
    if (!name.endsWith('.json.done')) continue;
    const filename = path.join(commandDirectory, name);
    try {
      if (now - fs.statSync(filename).mtimeMs < TOMBSTONE_AGE) continue;
      fs.rmSync(filename.slice(0, -5) + '.result', { force: true });
      fs.rmSync(filename, { force: true });
    } catch { /* Removed concurrently. */ }
  }
}
session.preferences ||= {};
snapshot();
const runCommands = async () => {
  try {
    await commands();
    pruneTombstones();
    if (!query || handling || inFlight.size || hibernating || ended) return;
    if (idle.expired(session, service.runs.has(session.id))) {
      // Mark completion before closing the SDK, so reconnecting clients can resume
      // from remoteSessionId instead of sending into a dead command queue.
      hibernating = true; ended = true; snapshot();
      input.close(); query.close();
    }
  } catch (error) { console.error(error.message); }
};
// fs.watch makes stop and approvals immediate; the interval covers filesystems without inotify.
const timer = setInterval(runCommands, 1000);
let commandWatcher;
try { commandWatcher = fs.watch(path.join(folder, 'commands'), runCommands); commandWatcher.on('error', () => {}); } catch { /* Interval only. */ }
(async () => {
  const launch = resolveClaudeLaunch(session.directory);
  session.directory = launch.cwd;
  service.claudeExecutable = launch.executable;
  const { query: createQuery } = await import(pathToFileURL(path.join(__dirname, 'sdk.mjs')).href);
  query = createQuery({ prompt: input, options: service.options(session, run) }); run.query = query;
  input.push(request.prompt, run.message.id, session.remoteSessionId);
  session.capabilities = await catalogue(query); snapshot();
  for await (const event of query) {
    if (service.runs.has(session.id)) {
      service.consumeEvent(session, event, run);
      if (event.type === 'result') service.finish(session, run, true);
    } else if (event.type === 'system' && event.subtype === 'commands_changed') {
      session.capabilities.commands = event.commands; snapshot();
    } else if (event.type === 'system' && (event.task_id || event.subtype === 'background_tasks_changed')) {
      const status = session.status;
      service.consumeEvent(session, event, run);
      session.status = status;
      snapshot();
    }
  }
})().catch(error => {
  if (hibernating) return; // SDK cancellation is expected after a deliberate idle shutdown.
  run.message.error = [error.message, run.stderr].filter(Boolean).join('\n');
  session.status = 'error';
}).finally(() => {
  ended = true; clearInterval(timer); commandWatcher?.close(); input.close(); query?.close();
  if (service.runs.has(session.id)) service.finish(session, run, true);
  for (const pending of service.timers.values()) clearTimeout(pending);
  snapshot();
});
