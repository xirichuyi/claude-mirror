// Keeps the SDK input stream open between turns; closing a client does not close it.
interface UserInput {
  type: 'user'; uuid: string; session_id: string; parent_tool_use_id: null;
  message: { role: 'user'; content: string | any[] };
  priority?: 'now' | 'next' | 'later';
}
type InputResult = { done: false; value: UserInput } | { done: true; value?: undefined };
class SessionInput {
  declare items: UserInput[];
  declare waiter: ((value: InputResult) => void) | null;
  declare closed: boolean;

  constructor() { this.items = []; this.waiter = null; this.closed = false; }
  [Symbol.asyncIterator]() { return this; }
  next(): Promise<InputResult> {
    if (this.items.length) return Promise.resolve({ value: this.items.shift(), done: false });
    if (this.closed) return Promise.resolve({ done: true });
    return new Promise<InputResult>(resolve => { this.waiter = resolve; });
  }
  /** `priority: 'next'` lets a running turn read the message at its next step instead of after it ends. */
  push(prompt: UserInput['message']['content'], id: string, sessionId?: string, priority?: UserInput['priority']) {
    if (this.closed) throw new Error('远端会话已关闭');
    const value: UserInput = { type: 'user', uuid: id, session_id: sessionId || '', parent_tool_use_id: null, message: { role: 'user', content: prompt }, ...(priority ? { priority } : {}) };
    if (this.waiter) { const resolve = this.waiter; this.waiter = null; resolve({ value, done: false }); }
    else this.items.push(value);
  }
  close() { this.closed = true; this.waiter?.({ done: true }); this.waiter = null; }
}
export { SessionInput };
