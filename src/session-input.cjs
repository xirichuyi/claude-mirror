// Keeps the SDK input stream open between turns; closing a client does not close it.
class SessionInput {
  constructor() { this.items = []; this.waiter = null; this.closed = false; }
  [Symbol.asyncIterator]() { return this; }
  next() {
    if (this.items.length) return Promise.resolve({ value: this.items.shift(), done: false });
    if (this.closed) return Promise.resolve({ done: true });
    return new Promise(resolve => { this.waiter = resolve; });
  }
  // priority 'next' joins a running turn at its next tool boundary; omitted means a new turn.
  push(prompt, id, sessionId, priority) {
    if (this.closed) throw new Error('远端会话已关闭');
    const value = { type: 'user', uuid: id, session_id: sessionId || '', parent_tool_use_id: null, message: { role: 'user', content: prompt }, ...(priority ? { priority } : {}) };
    if (this.waiter) { const resolve = this.waiter; this.waiter = null; resolve({ value, done: false }); }
    else this.items.push(value);
  }
  close() { this.closed = true; this.waiter?.({ done: true }); this.waiter = null; }
}
module.exports = { SessionInput };
