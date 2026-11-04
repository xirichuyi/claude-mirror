const methods = { reconnectMcp: 'reconnectMcpServer', toggleMcp: 'toggleMcpServer',
  reloadSkills: 'reloadSkills', reloadOutputStyles: 'reloadOutputStyles', reloadPlugins: 'reloadPlugins' };

async function runtimeStatus(client) {
  const servers = await client.mcpServerStatus();
  return { actions: Object.keys(methods).filter(action => typeof client[methods[action]] === 'function'),
    servers: servers.map(server => ({ name: server.name, status: server.status, error: server.error, scope: server.scope, source: server.source, serverInfo: server.serverInfo,
      tools: server.tools?.map(tool => ({ name: tool.name, description: tool.description })) })) };
}

async function manageRuntime(client, request) {
  const method = methods[request?.action];
  if (!method || typeof client[method] !== 'function') throw new Error('远端不支持此操作，请升级 Claude Code 并重新建立会话');
  if (['reconnectMcp', 'toggleMcp'].includes(request.action)) {
    if (typeof request.name !== 'string' || !(await client.mcpServerStatus()).some(server => server.name === request.name))
      throw new Error('MCP 服务器不存在，请刷新列表');
    if (request.action === 'toggleMcp') {
      if (typeof request.enabled !== 'boolean') throw new Error('无效 MCP 开关');
      await client[method](request.name, request.enabled);
    } else await client[method](request.name);
    return runtimeStatus(client);
  }
  // Respect the CLI's prompt-cache protection. A held reload remains held.
  return await client[method](...(request.action === 'reloadPlugins' ? [{ holdOnCacheImpact: true }] : [])) || {};
}
async function updateRuntime(client, session, request) {
  const result = await manageRuntime(client, request);
  if (request.action === 'reloadPlugins' && !result.held && Array.isArray(result.plugins))
    session.plugins = result.plugins;
  return result;
}
module.exports = { runtimeStatus, manageRuntime, updateRuntime };
