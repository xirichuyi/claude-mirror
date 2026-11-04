const { test } = require('node:test');
const assert = require('node:assert/strict');
const { runtimeStatus, manageRuntime } = require('../src/runtime-controls.cjs');

test('MCP status exposes display fields without server credentials', async () => {
  const result = await runtimeStatus({ mcpServerStatus: async () => [{ name: 'test', status: 'connected', config: { token: 'secret' } }], toggleMcpServer() {} });
  assert.deepEqual(result.actions, ['toggleMcp']);
  assert.equal(JSON.stringify(result).includes('secret'), false);
});
test('MCP mutations validate server membership and boolean input', async () => {
  const calls = [];
  const client = { mcpServerStatus: async () => [{ name: 'known', status: 'connected' }],
    toggleMcpServer: async (...args) => calls.push(args) };
  await assert.rejects(manageRuntime(client, { action: 'toggleMcp', name: 'missing', enabled: false }), /不存在/);
  await assert.rejects(manageRuntime(client, { action: 'toggleMcp', name: 'known', enabled: 'false' }), /无效/);
  await manageRuntime(client, { action: 'toggleMcp', name: 'known', enabled: false });
  assert.deepEqual(calls, [['known', false]]);
});
test('reload respects cache hold and rejects unknown controls', async () => {
  const client = { reloadPlugins: async options => { assert.deepEqual(options, { holdOnCacheImpact: true }); return { held: true }; } };
  assert.equal((await manageRuntime(client, { action: 'reloadPlugins' })).held, true);
  await assert.rejects(manageRuntime(client, { action: 'close' }), /不支持/);
  await assert.rejects(manageRuntime({}, { action: 'reloadSkills' }), /不支持/);
});
test('reload skills and styles invoke the exact SDK methods', async () => {
  for (const action of ['reloadSkills', 'reloadOutputStyles']) {
    let called = 0;
    await manageRuntime({ [action]: async () => { called++; return { refreshed: true }; } }, { action });
    assert.equal(called, 1);
  }
});

test('plugin reload updates the canonical snapshot only when applied', async () => {
  const { updateRuntime } = require('../src/runtime-controls.cjs');
  const session = { plugins: [{ name: 'old' }] };
  await updateRuntime({ reloadPlugins: async () => ({ held: true, plugins: [] }) }, session, { action: 'reloadPlugins' });
  assert.deepEqual(session.plugins, [{ name: 'old' }]);
  await updateRuntime({ reloadPlugins: async () => ({ plugins: [{ name: 'new' }] }) }, session, { action: 'reloadPlugins' });
  assert.deepEqual(session.plugins, [{ name: 'new' }]);
  await updateRuntime({ reloadPlugins: async () => ({ plugins: [] }) }, session, { action: 'reloadPlugins' });
  assert.deepEqual(session.plugins, []);
});
