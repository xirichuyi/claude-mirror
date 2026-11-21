#!/usr/bin/env node
// Packages the compiled server programs. Use `npm run prepare-server -- <output>`.
import fs = require('node:fs');
import path = require('node:path');
import { createHash } from 'node:crypto';
const source = path.resolve(__dirname, '../../src');
import { taskBundle } from '../../src/persistent-tasks.cjs';

const output = path.resolve(process.argv[2] || path.join(__dirname, '../../../macos/Resources/server'));
fs.mkdirSync(output, { recursive: true });
const agent = fs.readFileSync(path.join(source, 'remote-agent.cjs'));
fs.writeFileSync(path.join(output, 'remote-agent.cjs'), agent);
// The app runs this over its own SSH connection for one-click server setup.
fs.copyFileSync(path.resolve(__dirname, '../../../scripts/install-claude-remote.sh'), path.join(output, 'install-claude-remote.sh'));
const bundle = taskBundle();
fs.writeFileSync(path.join(output, 'manifest.json'), JSON.stringify({
  agentDigest: createHash('sha256').update(agent).digest('hex'),
  bundleDigest: bundle.digest, bundlePayload: bundle.payload,
}));
console.log('server resources written to ' + output);
