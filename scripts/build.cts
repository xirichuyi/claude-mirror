// Compile locally before shipping plain JavaScript to Electron or remote Node hosts.
import fs = require('node:fs');
import path = require('node:path');
import { execFileSync } from 'node:child_process';
const root = path.resolve(__dirname, '../..');
function build() {
  const output = path.join(root, 'build/src');
  // Fail before emitting on type errors; remove stale modules only after validation.
  const compiler = path.join(path.dirname(require.resolve('typescript/package.json')), 'bin/tsc');
  execFileSync(process.execPath, [compiler, '-p', path.join(root, 'tsconfig.json'), '--noEmit'], { cwd: root, stdio: 'inherit' });
  for (const directory of ['src', 'test', 'scripts', 'macos']) {
    fs.rmSync(path.join(root, 'build', directory), { recursive: true, force: true });
  }
  execFileSync(process.execPath, [compiler, '-p', path.join(root, 'tsconfig.json')], { cwd: root, stdio: 'inherit' });
  for (const name of ['style.css', 'third-party']) {
    fs.cpSync(path.join(root, 'src', name), path.join(output, name), { recursive: true });
  }
  fs.copyFileSync(path.join(root, 'scripts/elicitation-server.py'), path.join(root, 'build/scripts/elicitation-server.py'));
  const html = fs.readFileSync(path.join(root, 'src/index.html'), 'utf8');
  fs.writeFileSync(path.join(output, 'index.html'), html.replaceAll('../node_modules/', '../../node_modules/'));
}
if (require.main === module) build();
export { build };
