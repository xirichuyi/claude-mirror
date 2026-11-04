const fs = require('node:fs');
const path = require('node:path');
const { requireQuota } = require('./account-quota.cjs');

// All owners under one remote login share a circuit breaker. Near the limit,
// only one owner may consume at a time; this is not a token reservation API.
class QuotaCoordinator {
  constructor(directory) {
    this.directory = directory;
    this.lease = path.join(directory, 'lease');
    this.owned = false;
    fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  }

  record(report) {
    if (!report.available || !report.blocked) return;
    const target = path.join(this.directory, `${process.pid}.json`);
    const temporary = target + '.tmp';
    fs.writeFileSync(temporary, JSON.stringify({ report, expires: Date.now() + 60000 }), { mode: 0o600 });
    fs.renameSync(temporary, target);
  }

  check() {
    for (const name of fs.readdirSync(this.directory)) {
      if (!name.endsWith('.json')) continue;
      let entry;
      try { entry = JSON.parse(fs.readFileSync(path.join(this.directory, name), 'utf8')); }
      catch (error) { if (error.code === 'ENOENT') continue; throw error; }
      if (entry.expires <= Date.now()) continue;
      requireQuota(entry.report);
    }
  }

  claim(report) {
    this.check();
    requireQuota(report);
    if (this.owned || !report.windows.some(window => window.used >= 90)) return;
    try { fs.mkdirSync(this.lease, { mode: 0o700 }); }
    catch (error) {
      if (error.code !== 'EEXIST') throw error;
      return this.recover(report);
    }

    fs.writeFileSync(path.join(this.lease, 'pid'), String(process.pid), { mode: 0o600 });
    this.owned = true;
  }

  recover(report) {
    const cleanup = path.join(this.directory, 'lease-cleanup');
    // Serialize stale-owner cleanup so two contenders cannot delete a new lease.
    try { fs.mkdirSync(cleanup, { mode: 0o700 }); }
    catch (error) {
      if (error.code !== 'EEXIST') throw error;
      throw new Error('额度保护：正在恢复另一会话的执行锁，请稍后重试');
    }
    try {
      let owner;
      try { owner = Number(fs.readFileSync(path.join(this.lease, 'pid'), 'utf8')); }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
      let alive = true;
      if (owner) {
        try { process.kill(owner, 0); }
        catch (error) { if (error.code === 'ESRCH') alive = false; }
      } else {
        try { alive = Date.now() - fs.statSync(this.lease).mtimeMs < 30000; }
        catch (error) { if (error.code === 'ENOENT') return this.claim(report); throw error; }
      }
      if (alive) throw new Error('额度保护：已用达到 90%，另一会话正在执行；请等待结束后重试');
      fs.rmSync(this.lease, { recursive: true, force: true });
      return this.claim(report);
    } finally { fs.rmdirSync(cleanup); }
  }

  release() {
    if (!this.owned) return;
    fs.rmSync(this.lease, { recursive: true, force: true });
    this.owned = false;
  }
}
module.exports = { QuotaCoordinator };
