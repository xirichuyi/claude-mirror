import fs = require('node:fs');
import path = require('node:path');
import { execFileSync } from 'node:child_process';
import { resolveClaudeLaunch } from '../src/claude-launch.cjs';

// Explicit provisioning only; the application never creates accounts or copies credentials.
const args = process.argv.slice(2);
function fail(message: string): never { throw new Error(message); }
function run(command: string, values: string[]) {
  return execFileSync(command, values, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
}
function main() {
  const options: Record<string, string> = {};
  for (let i = 0; i < args.length; i += 2) {
    if (!['--user', '--project', '--copy-login-from'].includes(args[i]) || !args[i + 1] || options[args[i]]) fail('用法：setup-claude-user --user claude-runner --project /absolute/project [--copy-login-from /root]');
    options[args[i]] = args[i + 1];
  }
  const user = options['--user'];
  const project = options['--project'];
  if (!user || !/^[a-z_][a-z0-9_-]{0,31}$/.test(user) || user === 'root') fail('请指定普通执行账号');
  if (!project || !path.isAbsolute(project) || !fs.statSync(project).isDirectory()) fail('请指定项目绝对路径');
  const realProject = fs.realpathSync(project);
  if (['/', '/root', '/home', '/etc', '/usr', '/var', '/opt'].includes(realProject) || realProject.startsWith('/root/')) fail('请使用独立项目目录，例如 /opt/projects/my-project；不要授权整个系统目录或 /root');
  if (process.platform !== 'linux' || process.getuid?.() !== 0) fail('此工具需要 Linux root；其他环境请直接通过普通用户 SSH 连接');
  const binary = fs.realpathSync(resolveClaudeLaunch(project).executable);
  try { run('setfacl', ['--version']); } catch { fail('缺少 setfacl，请先安装 acl 软件包'); }
  let exists = false;
  try { run('getent', ['passwd', user]); exists = true; } catch { /* New dedicated account. */ }
  if (exists) fail('账号已存在；此安装工具仅创建专用新账号，不修改已有账号。已有账号请自行安装 Claude 并授权项目目录');
  const loginSource = options['--copy-login-from'];
  const loginFile = loginSource ? path.join(loginSource, '.claude/.credentials.json') : undefined;
  if (loginSource && (!path.isAbsolute(loginSource) || !fs.statSync(loginFile).isFile())) fail('登录来源必须是包含 Claude 登录凭据的绝对 home 路径');
  run('useradd', ['--create-home', '--shell', '/bin/bash', '--', user]);
  const entry = run('getent', ['passwd', user]);
  const fields = entry.split(':');
  const uid = Number(fields[2]), gid = Number(fields[3]), home = fields[5];
  if (fields.length !== 7 || fields[0] !== user || uid <= 0 || !Number.isSafeInteger(uid) || !path.isAbsolute(home) || home === '/root' || home === '/') fail('执行账号无效');
  const credentials = path.join(home, '.claude/.credentials.json');
  if (loginSource && fs.existsSync(credentials)) fail('目标账号已有登录凭据，拒绝覆盖；请去掉 --copy-login-from');
  if (fs.lstatSync(home).isSymbolicLink() || fs.realpathSync(home) !== home) fail('账号 home 不能通过符号链接访问');
  for (const folder of ['.local', '.local/bin', '.claude']) {
    const target = path.join(home, folder);
    if (fs.existsSync(target) && (fs.lstatSync(target).isSymbolicLink() || !fs.statSync(target).isDirectory())) fail('账号配置目录必须是普通目录');
  }
  const mkdir = (folder: string, mode: number) => { fs.mkdirSync(folder, { recursive: true, mode }); fs.chownSync(folder, uid, gid); };
  mkdir(path.join(home, '.local'), 0o755); mkdir(path.join(home, '.local/bin'), 0o755);
  const target = path.join(home, '.local/bin/claude');
  // Replace via rename, never follow a target user's executable symlink as root.
  const temporary = path.join(home, '.local/bin', `.claude-install-${process.pid}`);
  fs.copyFileSync(binary, temporary, fs.constants.COPYFILE_EXCL);
  fs.chownSync(temporary, uid, gid); fs.chmodSync(temporary, 0o755); fs.renameSync(temporary, target);
  if (loginSource) {
    if (!path.isAbsolute(loginSource)) fail('登录来源必须是绝对 home 路径');
    mkdir(path.join(home, '.claude'), 0o700);
    fs.writeFileSync(credentials, fs.readFileSync(loginFile), { flag: 'wx', mode: 0o600 });
    fs.chmodSync(credentials, 0o600); fs.chownSync(credentials, uid, gid);
  }
  // Only project contents receive write access; parent directories receive traversal only.
  for (let parent = path.dirname(realProject); parent !== '/'; parent = path.dirname(parent)) run('setfacl', ['-m', `u:${user}:--x`, '--', parent]);
  run('setfacl', ['-R', '-P', '-m', `u:${user}:rwX`, '--', realProject]);
  run('find', [realProject, '-type', 'd', '-exec', 'setfacl', '-m', `d:u:${user}:rwx`, '--', '{}', '+']);
  console.log(`已配置 ${user} 和项目访问权限。请在 macOS 新对话中选择 Full Access，并填写执行账号 ${user}。`);
  if (!loginSource) console.log(`请先以 ${user} 身份运行 claude auth login，完成独立登录。`);
}
try { main(); } catch (error) { console.error(error.message); process.exitCode = 1; }
