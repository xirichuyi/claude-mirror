const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { QuotaCoordinator } = require('../src/quota-coordinator.cjs');
const report = used => ({ available: true, blocked: used >= 95, limitPercent: 95,
  windows: [{ id: 'seven_day', title: '本周', used }] });

function fixture(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'quota-coordinator-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  return [new QuotaCoordinator(directory), new QuotaCoordinator(directory), directory];
}

test('near limit owners cannot consume concurrently; releasing allows the next owner', t => {
  const [first, second] = fixture(t);
  first.claim(report(90));
  assert.throws(() => second.claim(report(90)), /另一会话/);
  first.release();
  second.claim(report(90));
  second.release();
});
test('below warning level parallel owners remain available', t => {
  const [first, second] = fixture(t);
  first.claim(report(50)); second.claim(report(50));
  assert.equal(first.owned, false);
  assert.equal(second.owned, false);
});
test('one owner reaching the limit stops other owners despite their older reports', t => {
  const [first, second] = fixture(t);
  first.record(report(95));
  assert.throws(() => second.check(), /额度保护/);
  assert.throws(() => second.claim(report(30)), /额度保护/);
});
test('expired shared reports allow fresh quota checks after reset', t => {
  const [first, second, directory] = fixture(t);
  first.record(report(95));
  fs.writeFileSync(path.join(directory, `${process.pid}.json`), JSON.stringify({ report: report(95), expires: 0 }));
  second.claim(report(0));
});

test('a dead worker lease is recovered without leaving a permanent lock', t => {
  const [first, second, directory] = fixture(t);
  fs.mkdirSync(path.join(directory, 'lease'));
  fs.writeFileSync(path.join(directory, 'lease', 'pid'), '2147483647');
  second.claim(report(92));
  assert.equal(second.owned, true);
  assert.throws(() => first.claim(report(92)), /另一会话/);
  second.release();
});
