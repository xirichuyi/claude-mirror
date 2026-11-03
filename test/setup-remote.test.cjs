const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const script = path.resolve('scripts/install-claude-remote.sh');
function fixture() {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'mirror-setup-'));
  const bin = path.join(home, '.local/bin'); fs.mkdirSync(bin, { recursive: true });
  const put = (name, body) => fs.writeFileSync(path.join(bin, name), '#!/bin/sh\n' + body + '\n', { mode: 0o755 });
  put('node', 'exit 0');
  return { home, put, run: () => spawnSync('/bin/bash', [script], { encoding: 'utf8', env: { ...process.env, HOME: home, PATH: bin + ':/usr/bin:/bin' } }), close: () => fs.rmSync(home, { recursive: true, force: true }) };
}
test('remote setup preserves existing Claude and never downloads it again', () => {
  const f = fixture(); try {
    f.put('claude', 'echo fixture-version'); f.put('curl', 'exit 99');
    const result = f.run(); assert.equal(result.status, 0, result.stderr); assert.match(result.stdout, /already installed/);
  } finally { f.close(); }
});
test('remote setup installs missing Claude through official stable installer', () => {
  const f = fixture(); try {
    f.put('curl', `case "$*" in *https://claude.ai/install.sh*) ;; *) exit 91;; esac
while [ "$1" != '-o' ]; do shift; done
cat > "$2" <<'INSTALL'
[ "$1" = stable ] || exit 92
printf '#!/bin/sh\\necho fixture-installed\\n' > "$HOME/.local/bin/claude"
chmod +x "$HOME/.local/bin/claude"
INSTALL`);
    const result = f.run(); assert.equal(result.status, 0, result.stderr); assert.match(result.stdout, /fixture-installed/);
  } finally { f.close(); }
});
test('remote setup stops on download failure and preserves broken existing installation', () => {
  const f = fixture(); try {
    f.put('curl', 'exit 22'); assert.equal(f.run().status, 22);
    f.put('claude', 'exit 7'); const result = f.run(); assert.equal(result.status, 1); assert.match(result.stderr, /cannot launch/);
  } finally { f.close(); }
});
test('remote setup enables lingering only where logout kills background sessions', () => {
  const f = fixture(); try {
    f.put('claude', 'echo fixture-version');
    const log = path.join(f.home, 'loginctl.log');
    const loginctl = kill => `echo "$*" >> '${log}'
case "$1" in show-session) echo ${kill};; show-user) echo no;; enable-linger) exit 0;; esac`;
    f.put('loginctl', loginctl('no'));
    let result = f.run(); assert.equal(result.status, 0, result.stderr);
    assert.doesNotMatch(fs.readFileSync(log, 'utf8'), /enable-linger/);
    f.put('loginctl', loginctl('yes'));
    result = f.run(); assert.equal(result.status, 0, result.stderr);
    assert.match(fs.readFileSync(log, 'utf8'), /enable-linger/); assert.match(result.stdout, /enabled user lingering/);
    f.put('loginctl', loginctl('yes').replace('enable-linger) exit 0', 'enable-linger) exit 1'));
    result = f.run(); assert.equal(result.status, 0, result.stderr); assert.match(result.stderr, /sudo loginctl enable-linger/);
  } finally { f.close(); }
});
