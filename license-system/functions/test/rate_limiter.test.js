const assert = require('node:assert/strict');
const { test } = require('node:test');
const { createInstanceRateLimiter, createKeyedRateLimiter, trustedClientIp } = require('../rate_limiter');

test('shared write guard blocks the next request even when the device changes', () => {
  const limiter = createInstanceRateLimiter(2, 600_000);
  const response = {
    set: () => response,
    status: (status) => ({ json: () => status }),
  };
  let accepted = 0;
  limiter({ body: { deviceId: 'A' } }, response, () => { accepted++; });
  limiter({ body: { deviceId: 'B' } }, response, () => { accepted++; });
  const blocked = limiter({ body: { deviceId: 'C' } }, response, () => { accepted++; });
  assert.equal(accepted, 2);
  assert.equal(blocked, 429);
});

test('uses the client IP appended by the load balancer, not a spoofed first value', () => {
  const request = { get: () => '203.0.113.9, 198.51.100.23, 192.0.2.5', ip: '127.0.0.1' };
  assert.equal(trustedClientIp(request), '198.51.100.23');
  assert.equal(trustedClientIp({ get: () => '', ip: '127.0.0.1' }), '127.0.0.1');
});

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
