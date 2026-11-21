import { execFileSync, spawn } from 'node:child_process';
import fs = require('node:fs');
import path = require('node:path');
import os = require('node:os');

function validateDirectory(directory) {
  const resolved = directory === '~' ? os.homedir() : directory?.startsWith('~/') ? path.join(os.homedir(), directory.slice(2)) : directory;
  if (!resolved || !path.isAbsolute(resolved)) throw new Error('请选择远端项目的绝对路径');
  try {
    if (!fs.statSync(resolved).isDirectory()) throw new Error('NOT_DIRECTORY');
    fs.accessSync(resolved, fs.constants.X_OK);
  } catch (error) {
    const reason = error.code === 'ENOENT' ? '不存在（可能已被删除）' : '不可访问或不是目录';
    throw new Error(`远端项目目录${reason}：${resolved}。请切换到有效项目目录后重试；未启动 Claude。`);
  }
  return resolved;
}

function resolveClaudeLaunch(directory, env = process.env) {
  const cwd = validateDirectory(directory);
  const candidates = env.REMOTECC_CLAUDE_PATH ? [env.REMOTECC_CLAUDE_PATH] :
    (env.PATH || '').split(path.delimiter).filter(Boolean).map(folder => path.resolve(cwd, folder, 'claude'));
  for (const executable of candidates) {
    try {
      if (!fs.statSync(executable).isFile()) continue;
      fs.accessSync(executable, fs.constants.X_OK);
      return { cwd, executable };
    } catch { /* Try the next PATH entry. */ }
  }
  throw new Error('远端环境未找到可执行的 Claude Code。请检查 PATH 或 REMOTECC_CLAUDE_PATH。');
}
export { resolveClaudeLaunch, validateDirectory };

export interface ClaudeExecution {
  cwd: string;
  executable: string;
  uid: number;
  user: string;
  home: string;
  launcher?: string;
}

/** Resolve a real OS identity. Never use environment flags to pretend root is a sandbox. */
export function resolveClaudeExecution(directory: string, preferences: import('./contracts.js').Preferences = {}, env = process.env): ClaudeExecution {
  const current = os.userInfo();
  const requested = preferences.executionUser || '';
  if (!requested || requested === current.username) {
    const execution = { ...resolveClaudeLaunch(directory, env), uid: current.uid, user: current.username, home: current.homedir };
    requireFullAccessIdentity(preferences.permissionMode, execution);
    return execution;
  }
  if (!/^[a-z_][a-z0-9_-]{0,31}$/.test(requested)) throw new Error('无效的 Claude 执行账号');
  if (current.uid !== 0) throw new Error('当前 SSH 用户不能切换执行账号，请直接连接目标普通用户');
  if (process.platform !== 'linux') throw new Error('此系统请直接通过 SSH 连接普通用户后启用 Full Access');
  const launcher = ['/usr/sbin/runuser', '/sbin/runuser'].find(file => fs.existsSync(file));
  if (!launcher) throw new Error('服务器缺少 runuser，请安装 util-linux 或直接连接普通用户');
  let fields: string[];
  try { fields = execFileSync('getent', ['passwd', requested], { encoding: 'utf8', timeout: 5000 }).trim().split(':'); }
  catch { throw new Error(`执行账号 ${requested} 不存在，请先运行远端 setup-claude-user 工具或直接连接普通用户`); }
  const uid = Number(fields[2]);
  if (fields.length !== 7 || fields[0] !== requested || !Number.isSafeInteger(uid) || uid <= 0 || !path.isAbsolute(fields[5])) throw new Error('Full Access 执行账号必须是有效的非 root 用户');
  const home = fields[5];
  const cwd = validateDirectory(directory);
  const executable = path.join(home, '.local/bin/claude');
  const execution = { cwd, executable, uid, user: requested, home, launcher };
  // Validate as the target user, including traversal of absolute paths. No ownership changes here.
  try {
    execFileSync(launcher, ['--preserve-environment', '-u', requested, '--', '/bin/sh', '-c',
      'cd -- "$1" && test -r . && test -w . && test -x "$2"', 'remotecc-check', cwd, executable],
    { env: executionEnvironment(execution, env), encoding: 'utf8', timeout: 5000, stdio: ['ignore', 'pipe', 'pipe'] });
  } catch {
    throw new Error(`账号 ${requested} 无法读写项目 ${cwd}，或其 ~/.local/bin/claude 不可执行。请完成账号安装与项目授权；不要把整个 /root 开放给普通用户。`);
  }
  return execution;
}

export function requireFullAccessIdentity(mode: string | undefined, execution: Pick<ClaudeExecution, 'uid'>) {
  if (mode === 'bypassPermissions' && execution.uid === 0)
    throw new Error('Claude 不允许 root 使用 Full Access。请在新对话中选择已配置的普通执行账号（例如 claude-runner），或使用普通用户 SSH 连接。');
}

export function permissionStatus(execution: ClaudeExecution) {
  return { fullAccessAvailable: execution.uid !== 0, requiresExecutionUser: execution.uid === 0, executionUser: execution.user };
}

export function executionEnvironment(execution: ClaudeExecution, environment: NodeJS.ProcessEnv): NodeJS.ProcessEnv {
  if (!execution.launcher) return environment;
  const env: NodeJS.ProcessEnv = {};
  // Preserve protocol metadata and locale, never inherit root's credentials or config.
  for (const key of ['LANG', 'LC_ALL', 'LC_CTYPE', 'TZ', 'TERM', 'NO_COLOR',
    'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_AGENT_SDK_VERSION']) {
    if (environment[key] !== undefined) env[key] = environment[key];
  }
  env.HOME = execution.home; env.USER = execution.user; env.LOGNAME = execution.user;
  env.PATH = `${path.join(execution.home, '.local/bin')}:/usr/local/bin:/usr/bin:/bin`;
  return env;
}

export function spawnClaudeExecution(execution: ClaudeExecution, options: { args: string[]; env?: NodeJS.ProcessEnv; signal?: AbortSignal }) {
  const args = execution.launcher ? ['--preserve-environment', '-u', execution.user, '--', execution.executable, ...options.args] : options.args;
  return spawn(execution.launcher || execution.executable, args, { cwd: execution.cwd, stdio: ['pipe', 'pipe', 'pipe'],
    env: executionEnvironment(execution, options.env || process.env), signal: options.signal });
}
