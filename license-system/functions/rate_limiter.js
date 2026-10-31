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

module.exports = { createKeyedRateLimiter };
