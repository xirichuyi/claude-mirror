const { readAccountQuota } = require('./account-quota.cjs');
const { catalogue } = require('./capabilities.cjs');

// Explicitly select display metadata; never forward credentials or arbitrary init fields.
function accountMetadata(init) {
  const account = {};
  for (const key of ['email', 'organization', 'subscriptionType', 'tokenSource', 'apiKeySource', 'apiProvider'])
    if (typeof init.account?.[key] === 'string') account[key] = init.account[key];
  return { account, version: init.claude_code_version || null,
    outputStyle: init.output_style || null, fastMode: init.fast_mode_state || null,
    fastModeDisabledReason: init.fast_mode_disabled_reason || null };
}

async function accountStatus(client) {
  const [identity, quota] = await Promise.allSettled([
    client.initializationResult().then(accountMetadata), readAccountQuota(client),
  ]);
  return { ...(identity.status === 'fulfilled' ? identity.value : { accountError: identity.reason.message }),
    ...(quota.status === 'fulfilled' ? { quota: quota.value } : { quotaError: quota.reason.message }),
    fetchedAt: Date.now() };
}

async function environmentStatus(client) {
  const [capabilities, mcp] = await Promise.allSettled([catalogue(client), client.mcpServerStatus()]);
  return { ...(capabilities.status === 'fulfilled' ? { capabilities: capabilities.value } : { capabilitiesError: capabilities.reason.message }),
    ...(mcp.status === 'fulfilled' ? { mcp: mcp.value.map(server => ({ name: server.name, status: server.status,
      error: server.error, tools: server.tools?.map(tool => ({ name: tool.name, description: tool.description })) })) } : { mcpError: mcp.reason.message }) };
}
module.exports = { accountMetadata, accountStatus, environmentStatus };
