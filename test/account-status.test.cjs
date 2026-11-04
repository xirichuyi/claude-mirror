const { test } = require('node:test');
const assert = require('node:assert/strict');
const { accountMetadata, accountStatus, environmentStatus } = require('../src/account-status.cjs');

test('only display metadata crosses the account boundary', () => {
  const result = accountMetadata({ account: { email: 'user@example.test', subscriptionType: 'max', accessToken: 'secret', apiKey: 'secret' }, secret: 'secret' });
  assert.deepEqual(result.account, { email: 'user@example.test', subscriptionType: 'max' });
  assert.equal(JSON.stringify(result).includes('secret'), false);
});
test('quota failure does not hide account identity', async () => {
  const result = await accountStatus({ initializationResult: async () => ({ account: { email: 'user@example.test' } }) });
  assert.equal(result.account.email, 'user@example.test');
  assert.match(result.quotaError, /不支持/);
});
test('account failure does not hide quota', async () => {
  const result = await accountStatus({ initializationResult: async () => { throw new Error('identity unavailable'); },
    usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET: async () => ({ rate_limits_available: true,
      rate_limits: { five_hour: { utilization: 25 }, seven_day: { utilization: 20 } } }) });
  assert.equal(result.accountError, 'identity unavailable');
  assert.equal(result.quota.windows[1].used, 20);
});
test('MCP failure preserves discovered capabilities', async () => {
  const result = await environmentStatus({ supportedCommands: async () => [], supportedModels: async () => [{ value: 'model' }],
    supportedAgents: async () => [], initializationResult: async () => ({ claude_code_version: 'test' }),
    mcpServerStatus: async () => { throw new Error('MCP offline'); } });
  assert.equal(result.capabilities.models[0].value, 'model');
  assert.equal(result.mcpError, 'MCP offline');
});
