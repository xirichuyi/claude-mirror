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
test('remote setup installs a checksummed user-local Node.js when the system one is too old', () => {
  const f = fixture(); try {
    f.put('claude', 'echo fixture-version');
    f.put('node', 'case "$1" in --version) echo v16.0.0;; *) exit 1;; esac');
    const dist = path.join(f.home, 'dist'); fs.mkdirSync(path.join(dist, 'pkg/bin'), { recursive: true });
    fs.writeFileSync(path.join(dist, 'pkg/bin/node'), '#!/bin/sh\n[ "$1" = --version ] && echo v22.99.0\nexit 0\n', { mode: 0o755 });
    const os = process.platform === 'darwin' ? 'darwin' : 'linux';
    const arch = ['arm64', 'aarch64'].includes(require('node:os').machine()) ? 'arm64' : 'x64';
    const name = `node-v22.99.0-${os}-${arch}.tar.gz`;
    spawnSync('tar', ['-czf', path.join(dist, name), '-C', dist, 'pkg']);
    const digest = require('node:crypto').createHash('sha256').update(fs.readFileSync(path.join(dist, name))).digest('hex');
    fs.writeFileSync(path.join(dist, 'SHASUMS256.txt'), `${'0'.repeat(64)}  node-v22.99.0-aix-ppc64.tar.gz\n${digest}  ${name}\n`);
    f.put('curl', `url=""; out=""; while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift;; https://*) url="$1";; esac; shift; done
cp "${dist}/\${url##*/}" "$out"`);
    const run = () => spawnSync('/bin/bash', [script], { encoding: 'utf8', env: { ...process.env, HOME: f.home, PATH: path.join(f.home, '.local/bin') + ':/usr/bin:/bin', CLAUDE_MIRROR_NODE_DIST: 'https://example.invalid/dist' } });
    let result = run();
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.match(result.stdout, /Installed Node\.js v22\.99\.0/);
    assert.match(fs.readFileSync(path.join(f.home, '.local/bin/node'), 'utf8'), /v16\.0\.0/, "the user's own node is left alone");
    assert.ok(fs.existsSync(path.join(f.home, '.local/share/claude-mirror/node/bin/node')));
    result = run(); assert.equal(result.status, 0, result.stderr); assert.match(result.stdout, /Node\.js ready: v22\.99\.0/);
    // A tampered download is refused and leaves the previous installation alone.
    fs.rmSync(path.join(f.home, '.local/share/claude-mirror'), { recursive: true });
    fs.appendFileSync(path.join(dist, name), 'tampered');
    result = run(); assert.equal(result.status, 3); assert.match(result.stderr, /checksum/);
    assert.equal(fs.existsSync(path.join(f.home, '.local/share/claude-mirror/node')), false);
  } finally { f.close(); }
});
