const assert = require('node:assert/strict');
const { test } = require('node:test');
const { createKeyedRateLimiter } = require('../rate_limiter');

test('limits each key independently and returns retry timing when exceeded', () => {
  const limiter = createKeyedRateLimiter(1, 60_000, (req) => req.ip);
  const responses = [];
  const call = (ip) => {
    let nextCalled = false;
    const headers = {};
    const response = {
      set: (name, value) => { headers[name] = value; return response; },
      status: (status) => {
        responses.push({ status, headers });
        return { json: (body) => ({ status, body, headers }) };
      },
    };
    const result = limiter({ ip }, response, () => { nextCalled = true; });
    return { nextCalled, result };
  };

  assert.equal(call('192.0.2.1').nextCalled, true);
  assert.equal(call('192.0.2.2').nextCalled, true);
  const blocked = call('192.0.2.1');
  assert.equal(blocked.nextCalled, false);
  assert.equal(blocked.result.status, 429);
  assert.equal(blocked.result.headers['Retry-After'], '60');
  assert.equal(responses.length, 1);
});
