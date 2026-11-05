const test = require('node:test');
const assert = require('node:assert/strict');
const { ChatService } = require('../src/chat-service.cjs');
const { preferencePatch } = require('../src/capabilities.cjs');
const { Transcript, newAssistant } = require('../src/transcript.cjs');
test('settings are validated and sent to remote query, branches preserve context without mutating source', async () => {
  const service = new ChatService({ load: () => [], save() {} });
  const source = service.create({ host: 'axi', directory: '/tmp' });
  source.remoteSessionId = 'original';
  source.messages.push({ role: 'user', text: 'remember' });
  service.configure(source.id, { selectedModel: 'sonnet', effort: 'low', permissionMode: 'plan', additionalDirectories: ['/tmp/a'] });
  const branch = service.fork(source.id);
  const options = service.options(branch, { stderr: '' });
  assert.equal(options.model, 'sonnet');
  assert.equal(options.effort, 'low');
  assert.equal(options.permissionMode, 'plan');
  assert.equal(options.forkSession, true);
  assert.equal(options.resume, 'original');
  branch.messages[0].text = 'changed';
  assert.equal(source.messages[0].text, 'remember');
  assert.throws(() => preferencePatch({ permissionMode: 'bypassPermissions' }));
  assert.throws(() => preferencePatch({ additionalDirectories: ['relative'] }));
  assert.throws(() => preferencePatch({ selectedModel: 'sonnet\n--unsafe' }));
  await service.close();
});
test('local slash command output appears in transcript', () => {
  const message = newAssistant('test');
  new Transcript(message).consume({ type: 'system', subtype: 'local_command_output', content: 'Context compacted' });
  assert.ok(message.blocks.some(block => block.text?.includes('Context compacted')));
});

test('remote command catalogue preserves names, aliases and metadata without a local allowlist', async () => {
  const { catalogue } = require('../src/capabilities.cjs');
  const commands = [
    { name: 'model', description: 'remote model description', argumentHint: '[remote options]', aliases: ['choose-model'], builtin: true },
    { name: 'team.review', description: 'project command', aliases: ['审阅'], customMetadata: 'preserved' },
  ];
  const result = await catalogue({
    supportedCommands: async () => commands, supportedModels: async () => [],
    supportedAgents: async () => [], initializationResult: async () => ({}),
  });
  assert.deepEqual(result.commands, commands);
  assert.equal(result.commands.some(command => command.name === 'ports'), false);
});

test('selecting a remote agent passes its exact name to Claude and preserves it in branches', async () => {
  const service = new ChatService({load:()=>[],save(){}});
  try {
    const session=service.create({host:'axi',directory:'/project'});
    session.capabilities={agents:[{name:'project-reviewer',description:'Remote definition'}],models:[]};
    session.remoteSessionId='remote';
    service.configure(session.id,{agent:'project-reviewer'});
    assert.equal(service.options(session,{stderr:''}).agent,'project-reviewer');
    assert.deepEqual(service.options(session,{stderr:''}).systemPrompt,{type:'preset',preset:'claude_code'});
    assert.equal(service.options(service.fork(session.id),{stderr:''}).agent,'project-reviewer');
    assert.throws(()=>service.configure(session.id,{agent:'invented-agent'}),/远端列表/);
    service.configure(session.id,{agent:''});
    assert.equal(service.options(session,{stderr:''}).agent,undefined);
  } finally {await service.close();}
});

test('a new session receives a changed event when reusing the remote catalogue cache', async () => {
  const service=new ChatService({load:()=>[],save(){}},async()=>()=>({
    supportedCommands:async()=>[{name:'usage'}],supportedModels:async()=>[],supportedAgents:async()=>[],initializationResult:async()=>({}),close(){}
  }));
  try {
    const a=service.create({host:'axi'}),b=service.create({host:'axi'});
    await service.capabilities(a.id);
    let changed=false;service.on('changed',session=>{if(session.id===b.id)changed=true;});
    await service.capabilities(b.id);
    assert.equal(changed,true);assert.equal(b.capabilities.commands[0].name,'usage');
  }finally{await service.close();}
});

test('capability inspection does not persist a throwaway session or fork history', async () => {
  const {inspectRemote}=require('../src/capabilities.cjs');
  let received;
  const client={close(){}};
  const service={runs:new Map(),options:()=>({forkSession:true,resume:'existing'}),loadQuery:async()=>({options})=>{received=options;return client;}};
  await inspectRemote(service,{id:'test'},async()=>{});
  assert.equal(received.persistSession,false);
  assert.equal(received.forkSession,undefined);
  assert.equal(received.resume,'existing');
});

test('native slash output preserves line breaks and a plain-text display marker', () => {
  const message = newAssistant('usage');
  new Transcript(message).consume({ type: 'system', subtype: 'local_command_output', content: 'Session: 20%\nWeek: 30%' });
  assert.equal(message.blocks[0].format, 'command');
  assert.equal(message.blocks[0].text, 'Session: 20%\nWeek: 30%');
});

test('CLI result-only usage packet renders as command output without invoking model text formatting', () => {
  const message = newAssistant('usage-result');
  const transcript = new Transcript(message);
  transcript.consume({ type: 'result', subtype: 'success', local_command: 'usage', is_error: false,
    num_turns: 0, total_cost_usd: 0, result: 'Current session: 94% used\nCurrent week: 10% used' });
  assert.equal(message.blocks.length, 1);
  assert.equal(message.blocks[0].format, 'command');
  assert.match(message.blocks[0].text, /Current week/);
  assert.equal(message.costUSD, 0);
});

test('cache TTL inherits remote defaults and changes only on an idle resumable session', async () => {
  const service = new ChatService({ load: () => [], save() {} });
  try {
    const session = service.create({ host: 'axi', directory: '/tmp' });
    session.remoteSessionId = 'preserved-history';
    assert.equal(service.options(session, {}).settings, undefined);
    assert.throws(() => preferencePatch({ promptCacheTtl: 'forever' }), /缓存时长/);
    session.capabilities = { version: '2.1.241', models: [] };
    assert.throws(() => service.configure(session.id, { promptCacheTtl: '1h' }), /2.1.242/);
    session.capabilities.version = '2.1.312';
    service.runs.set(session.id, {});
    assert.throws(() => service.configure(session.id, { promptCacheTtl: '1h' }), /回复完成/);
    service.runs.delete(session.id);
    session.remoteOwner = 'old-worker';
    let released = false;
    service.persistent = { release: async current => { released = true; delete current.remoteOwner; } };
    await service.configure(session.id, { promptCacheTtl: '1h' });
    assert.equal(released, true);
    const options = service.options(session, {});
    assert.equal(options.settings.promptCacheTtl, '1h');
    assert.equal(options.resume, 'preserved-history');
    assert.deepEqual(options.settingSources, ['user', 'project', 'local']);
    service.configure(session.id, { promptCacheTtl: '5m' });
    assert.equal(service.options(session, {}).settings.promptCacheTtl, '5m');
    service.configure(session.id, { promptCacheTtl: '' });
    assert.equal(service.options(session, {}).settings, undefined);
  } finally { service.persistent = null; await service.close(); }
});
