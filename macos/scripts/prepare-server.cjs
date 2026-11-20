#!/usr/bin/env node
// Builds the server-side programs into the app's resources. Run from any directory after `npm ci`.
const fs = require('node:fs');
const path = require('node:path');
const { createHash } = require('node:crypto');
const source = path.resolve(__dirname, '../../src');
const { taskBundle } = require(path.join(source, 'persistent-tasks.cjs'));

const output = path.resolve(process.argv[2] || path.join(__dirname, '../Resources/server'));
fs.mkdirSync(output, { recursive: true });
const agent = fs.readFileSync(path.join(source, 'remote-agent.cjs'));
fs.writeFileSync(path.join(output, 'remote-agent.cjs'), agent);
// The app runs this over its own SSH connection for one-click server setup.
fs.copyFileSync(path.resolve(__dirname, '../../scripts/install-claude-remote.sh'), path.join(output, 'install-claude-remote.sh'));
const bundle = taskBundle();
fs.writeFileSync(path.join(output, 'manifest.json'), JSON.stringify({
  agentDigest: createHash('sha256').update(agent).digest('hex'),
  bundleDigest: bundle.digest, bundlePayload: bundle.payload,
}));
console.log('server resources written to ' + output);
