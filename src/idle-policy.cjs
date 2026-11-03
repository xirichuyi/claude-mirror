// Only quiescent sessions may hibernate. Transport disconnection is not a stop signal.
class IdlePolicy {
  constructor(timeout = 15 * 60 * 1000) { this.timeout = timeout; this.since = null; }
  touch() { this.since = null; }
  expired(session, active, now = Date.now()) {
    const busy = active || session.permissions?.length || session.tasks?.some(task => ['running', 'pending', 'queued'].includes(task.status));
    if (busy || !['idle', 'stopped', 'error'].includes(session.status)) { this.touch(); return false; }
    this.since ??= now;
    return now - this.since >= this.timeout;
  }
}
module.exports = { IdlePolicy };
