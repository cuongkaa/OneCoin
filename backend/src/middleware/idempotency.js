const { pool } = require('../config/database');

/**
 * Idempotency Middleware (PostgreSQL) — Scoped by userId
 */
function idempotencyMiddleware(req, res, next) {
  const requestId = req.body?.requestId;

  if (!requestId || typeof requestId !== 'string' || requestId.length > 128) {
    return next();
  }

  req.requestId = requestId;

  req.checkIdempotency = async () => {
    try {
      const userId = req.userId || 'anonymous';
      const result = await pool.query(
        'SELECT id FROM processed_requests WHERE "requestId" = $1 AND "userId" = $2',
        [requestId, userId]
      );
      return result.rows.length > 0;
    } catch (err) {
      console.error('Idempotency check error:', err.message);
      return false;
    }
  };

  req.markProcessed = async () => {
    try {
      const userId = req.userId || 'anonymous';
      await pool.query(
        `INSERT INTO processed_requests ("requestId", "userId", endpoint, "processedAt")
         VALUES ($1, $2, $3, NOW())
         ON CONFLICT ("requestId") DO NOTHING`,
        [requestId, userId, `${req.method} ${req.originalUrl}`]
      );

      // Dọn dẹp ngẫu nhiên 2% các requestId quá hạn > 7 ngày để bảng không phình vô hạn
      if (Math.random() < 0.02) {
        pool
          .query(`DELETE FROM processed_requests WHERE "processedAt" < NOW() - INTERVAL '7 days'`)
          .catch(() => {});
      }
    } catch (err) {
      console.error('Mark processed error:', err.message);
    }
  };

  next();
}

module.exports = idempotencyMiddleware;
