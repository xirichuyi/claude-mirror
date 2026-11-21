// Runs one capability query with the remote SDK for clients that do not embed it.
import path = require('node:path');
import { pathToFileURL } from 'node:url';
import { resolveClaudeExecution, spawnClaudeExecution, permissionStatus } from './claude-launch.cjs';
import { ChatService } from './chat-service.cjs';
import { inspectRemote, catalogue } from './capabilities.cjs';

import { readAccountQuota } from './account-quota.cjs';

import { accountStatus, environmentStatus } from './account-status.cjs';

import { runtimeStatus } from './runtime-controls.cjs';

const request = JSON.parse(process.argv[2]);
let execution: ReturnType<typeof resolveClaudeExecution>;
const actions = {
  catalogue: async client => ({ ...await catalogue(client), permissionStatus: permissionStatus(execution) }),
  permissionStatus: () => permissionStatus(execution),
  runtimeStatus,
  accountStatus,
  environmentStatus,
  accountQuota: readAccountQuota,
  context: client => client.getContextUsage({ detail: 'summary' }),
  mcp: async client => (await client.mcpServerStatus()).map(server => ({ name: server.name, status: server.status, error: server.error,
    tools: server.tools?.map(tool => ({ name: tool.name, description: tool.description })) })),
  plugins: async client => {
    const result = await client.reloadPlugins({ holdOnCacheImpact: true });
    return { plugins: result.plugins || [], errorCount: result.error_count || 0, held: result.held || false };
  },
  model: async client => { await client.setModel(request.value || undefined); return {}; },
  effort: async client => { await client.applyFlagSettings({ effortLevel: request.value || null }); return {}; },
};
(async () => {
  if (!actions[request.action]) throw new Error('未知查询');
  const launch = execution = resolveClaudeExecution(request.directory, request.preferences);
  if (request.action === 'permissionStatus') {
    process.stdout.write(JSON.stringify({ result: permissionStatus(execution) }) + '\n'); return;
  }
  request.directory = launch.cwd;
  const { query } = await import(pathToFileURL(path.join(__dirname, 'sdk.mjs')).href);
  const service = new ChatService({ load: () => [], save() {} }, async () => query);
  service.closing = true;
  service.claudeExecutable = launch.executable;
  service.fullAccessAvailable = launch.uid !== 0;
  service.spawn = (_session, options, onError) => {
    const child = spawnClaudeExecution(execution, options);
    child.stderr.setEncoding('utf8'); child.stderr.on('data', onError);
    return child;
  };
  const session = { id: 'inspect', directory: request.directory, messages: [], permissions: [], preferences: request.preferences || {} };
  const result = await inspectRemote(service, session, actions[request.action]);
  // The last stdout line is the result; anything earlier is library noise.
  process.stdout.write('\n' + JSON.stringify({ result }) + '\n', () => process.exit(0));
})().catch(error => process.stdout.write('\n' + JSON.stringify({ error: error.message }) + '\n', () => process.exit(0)));
