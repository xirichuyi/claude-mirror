const { test } = require('node:test');
const assert = require('node:assert/strict');
const { quotaReport, readAccountQuota, requireQuota } = require('../src/account-quota.cjs');
const report = (five = 10, seven = 20, extra = {}) => quotaReport({ rate_limits_available: true,
  rate_limits: { five_hour: { utilization: five }, seven_day: { utilization: seven }, ...extra } });

test('reserve 5% at the exact boundary in either five-hour or weekly window', () => {
  assert.doesNotThrow(() => requireQuota(report(94.99, 94.99)));
  assert.throws(() => requireQuota(report(95, 10)), /五小时/);
  assert.throws(() => requireQuota(report(10, 95)), /本周/);
});
test('model-specific limits do not trigger the reserve', () => {
  assert.doesNotThrow(() => requireQuota(report(0, 0, { seven_day_opus: { utilization: 96 } })));
  assert.doesNotThrow(() => requireQuota(report(0, 0, { model_scoped: [{ display_name: 'Model', utilization: 100 }] })));
});
test('missing, unsupported and malformed reports fail closed', () => {
  for (const value of [null, {}, { rate_limits_available: false }, report(0, null), report(0, '20'), report(0, -1), report(0, 101), report(null), report('20'), report(-1), report(101)]) {
    assert.throws(() => requireQuota(value?.windows ? value : quotaReport(value)), /无法确认/);
  }
});
test('extra usage does not bypass the subscription reserve', () => {
  assert.throws(() => requireQuota(report(0, 99, { extra_usage: { is_enabled: true, utilization: 0 } })), /保留 5%/);
});
test('adapter skips transcript scanning and never exposes the raw SDK response', async () => {
  const result = await readAccountQuota({ async usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET(options) {
    assert.deepEqual(options, { skipBehaviors: true });
    return { rate_limits_available: true, rate_limits: { five_hour: { utilization: 1 }, seven_day: { utilization: 2 } }, session: { private: true } };
  } });
  assert.equal(result.available, true);
  assert.equal(result.session, undefined);
  await assert.rejects(readAccountQuota({}), /不支持/);
  await assert.rejects(readAccountQuota({ usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET() { throw new Error('offline'); } }), /offline/);
});

test('both primary windows are required and only these two are displayed', () => {
  assert.throws(() => requireQuota(report(null, 20)), /无法确认/);
  const result = report(25, 20, { seven_day_opus: { utilization: 99 } });
  assert.doesNotThrow(() => requireQuota(result));
  assert.deepEqual(result.windows.map(row => [row.id, row.used]), [['five_hour', 25], ['seven_day', 20]]);
});
