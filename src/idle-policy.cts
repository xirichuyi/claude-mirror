// Only quiescent sessions may hibernate. Transport disconnection is not a stop signal.
class IdlePolicy {
  declare timeout: number;
  declare since: number | null;

  constructor(timeout = 15 * 60 * 1000) { this.timeout = timeout; this.since = null; }
  touch() { this.since = null; }
  expired(session: Pick<import('./contracts.js').ChatSession, 'status' | 'permissions' | 'tasks'>, active: boolean, now = Date.now()) {
    const busy = active || session.permissions?.length || session.tasks?.some(task => ['running', 'pending', 'queued'].includes(task.status));
    if (busy || !['idle', 'stopped', 'error'].includes(session.status)) { this.touch(); return false; }
    this.since ??= now;
    return now - this.since >= this.timeout;
  }
}
export { IdlePolicy };
