// A scripted Anthropic Messages API, so the real Claude Code CLI can run offline in tests.
// Prompt keywords: SLOWTOOL runs a 2s Bash call first, SLOWTEXT streams for ~3s first.
import http = require('node:http');
import type { AddressInfo } from 'node:net';

const text = content => typeof content === 'string' ? content :
  (content || []).map(block => block.type === 'text' ? block.text : `[${block.type}]`).join(' ');
const count = (value, pattern) => (value.match(pattern) || []).length;

function reply(body) {
  // The CLI delivers a message folded into a running turn as a mid-conversation system message.
  const said = body.messages.filter(message => message.role !== 'assistant').map(message => text(message.content)).join('\n');
  const answers = body.messages.filter(message => message.role === 'assistant');
  const tools = answers.flatMap(message => Array.isArray(message.content) ? message.content.filter(block => block.type === 'tool_use') : []);
  if (count(said, /SLOWTOOL/g) > tools.length) return { tool: { command: 'sleep 2; echo slept', description: 'wait' } };
  if (count(said, /SLOWTEXT/g) > answers.filter(message => text(message.content).startsWith('slow ')).length) return { text: 'slow '.repeat(20), delay: 150 };
  return { text: 'SAW ' + [...new Set(said.match(/\b(?:FIRST|STEER|SECOND)\b/g))].join(' ') };
}

export async function mockAnthropic() {
  const server = http.createServer((request, response) => {
    let data = '';
    request.on('data', chunk => { data += chunk; });
    request.on('end', async () => {
      if (!request.url.startsWith('/v1/messages') || request.url.includes('count_tokens')) {
        response.writeHead(404, { 'content-type': 'application/json' });
        return response.end('{"type":"error","error":{"type":"not_found_error","message":"not mocked"}}');
      }
      const body = JSON.parse(data);
      const plan = body.tools?.length ? reply(body) : { text: 'title' };
      const usage = { input_tokens: 100, output_tokens: 10, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 };
      const block = plan.tool ? { type: 'tool_use', id: 'toolu_' + Date.now(), name: 'Bash', input: plan.tool } : { type: 'text', text: plan.text };
      const stop = { stop_reason: plan.tool ? 'tool_use' : 'end_turn', stop_sequence: null };
      const message = { id: 'msg_' + Date.now(), type: 'message', role: 'assistant', model: body.model, usage };
      if (!body.stream) {
        response.writeHead(200, { 'content-type': 'application/json' });
        return response.end(JSON.stringify({ ...message, content: [block], ...stop }));
      }
      response.writeHead(200, { 'content-type': 'text/event-stream' });
      const emit = (type, value) => response.write(`event: ${type}\ndata: ${JSON.stringify({ type, ...value })}\n\n`);
      emit('message_start', { message: { ...message, content: [], stop_reason: null, stop_sequence: null } });
      if (plan.tool) {
        emit('content_block_start', { index: 0, content_block: { ...block, input: {} } });
        emit('content_block_delta', { index: 0, delta: { type: 'input_json_delta', partial_json: JSON.stringify(plan.tool) } });
      } else {
        emit('content_block_start', { index: 0, content_block: { type: 'text', text: '' } });
        for (const word of plan.text.match(/\S+\s*/g)) {
          if (plan.delay) await new Promise(resolve => setTimeout(resolve, plan.delay));
          if (response.destroyed) return;
          emit('content_block_delta', { index: 0, delta: { type: 'text_delta', text: word } });
        }
      }
      emit('content_block_stop', { index: 0 });
      emit('message_delta', { delta: stop, usage: { output_tokens: 10 } });
      emit('message_stop', {});
      response.end();
    });
  });
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  return { url: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, close: () => { server.closeAllConnections(); server.close(); } };
}
