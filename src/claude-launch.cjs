const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');

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
module.exports = { resolveClaudeLaunch, validateDirectory };
