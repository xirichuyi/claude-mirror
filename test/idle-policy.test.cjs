const { test } = require('node:test');
const assert = require('node:assert/strict');
const { IdlePolicy } = require('../src/idle-policy.cjs');
test('idle sessions expire, resumed activity resets the grace period', () => {
  const policy = new IdlePolicy(100);
  const session = { status: 'idle' };
  assert.equal(policy.expired(session, false, 0), false);
  assert.equal(policy.expired(session, false, 100), true);
  assert.equal(policy.expired(session, true, 101), false);
  assert.equal(policy.expired(session, false, 200), false);
  assert.equal(policy.expired(session, false, 300), true);
  policy.touch();
  assert.equal(policy.expired(session, false, 400), false);
});
test('pending permissions and background work never expire, even when transport is gone', () => {
  for (const extra of [{permissions:[{}]}, {tasks:[{status:'running'}]}, {tasks:[{status:'pending'}]}, {tasks:[{status:'queued'}]}]) {
    const policy = new IdlePolicy(1), session = {status:'idle', ...extra};
    assert.equal(policy.expired(session, false, 0), false);
    assert.equal(policy.expired(session, false, 1e9), false);
  }
  for (const status of ['working','connecting','permission','stopping']) {
    const policy = new IdlePolicy(1);
    assert.equal(policy.expired({status}, false, 0), false);
    assert.equal(policy.expired({status}, false, 1e9), false);
  }
});
