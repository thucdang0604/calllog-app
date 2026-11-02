const { isIP } = require('node:net');

function trustedClientIp(req) {
  const addresses = String(req.get('X-Forwarded-For') || '').split(',').map((value) => value.trim());
  // Google Cloud's load balancer appends client IP, then load balancer IP.
  const clientIp = addresses.length >= 2 ? addresses[addresses.length - 2] : '';
  return isIP(clientIp) ? clientIp : String(req.ip || req.socket?.remoteAddress || '');
}

function createInstanceRateLimiter(maxRequests, windowMs = 60_000) {
  let windowStartedAt = 0;
  let requestCount = 0;
  return (_req, res, next) => {
    const now = Date.now();
    if (now - windowStartedAt >= windowMs) {
      windowStartedAt = now;
      requestCount = 0;
    }
    if (requestCount >= maxRequests) {
      res.set('Retry-After', String(Math.max(1, Math.ceil((windowStartedAt + windowMs - now) / 1000))));
      return res.status(429).json({ success: false, error: 'Máy chủ đang nhận quá nhiều yêu cầu. Hãy thử lại sau.' });
    }
    requestCount += 1;
    return next();
  };
}

function createKeyedRateLimiter(maxRequests, windowMs, keyForRequest) {
  const buckets = new Map();
  const maxKeys = 4096;
  return (req, res, next) => {
    const key = keyForRequest(req);
    if (!key) return next();
    const now = Date.now();
    let bucket = buckets.get(key);
    if (!bucket || now >= bucket.resetAt) {
      if (!bucket && buckets.size >= maxKeys) {
        for (const [existingKey, existingBucket] of buckets) {
          if (now >= existingBucket.resetAt) buckets.delete(existingKey);
        }
      }
      if (!bucket && buckets.size >= maxKeys) {
        res.set('Retry-After', String(Math.ceil(windowMs / 1000)));
        return res.status(429).json({ success: false, error: 'Máy chủ đang nhận quá nhiều yêu cầu. Hãy thử lại sau.' });
      }
      bucket = { count: 0, resetAt: now + windowMs };
      buckets.set(key, bucket);
    }
    if (bucket.count >= maxRequests) {
      res.set('Retry-After', String(Math.max(1, Math.ceil((bucket.resetAt - now) / 1000))));
      return res.status(429).json({ success: false, error: 'Bạn thao tác quá nhanh. Hãy thử lại sau.' });
    }
    bucket.count += 1;
    return next();
  };
}

module.exports = { createInstanceRateLimiter, createKeyedRateLimiter, trustedClientIp };
