require('dotenv').config();
const express = require('express');
const cors = require('cors');
const rateLimit = require('express-rate-limit');
const winston = require('winston');
const morgan = require('morgan');
const requestIdMiddleware = require('./middleware/requestId');
const idempotencyMiddleware = require('./middleware/idempotency');
const { pool } = require('./config/database');
const { initDatabase } = require('./scripts/initDb');

const authRoutes = require('./routes/auth');
const walletRoutes = require('./routes/wallets');
const groupRoutes = require('./routes/groups');
const transactionRoutes = require('./routes/transactions');
const budgetRoutes = require('./routes/budgets');
const loanRoutes = require('./routes/loans');
const reminderRoutes = require('./routes/reminders');
const syncRoutes = require('./routes/sync');
const adminRoutes = require('./routes/admin');
const aiRoutes = require('./routes/ai');

const app = express();
const PORT = process.env.PORT || 3000;
const isProduction = process.env.NODE_ENV === 'production';

// Trust reverse proxy (Render load balancer)
app.set('trust proxy', 1);
app.disable('x-powered-by');

// ========================
// WINSTON LOGGER
// ========================
const logger = winston.createLogger({
  level: 'info',
  format: winston.format.combine(
    winston.format.timestamp(),
    winston.format.json()
  ),
  transports: [
    new winston.transports.File({
      filename: 'logs/error.log',
      level: 'error',
      maxsize: 5 * 1024 * 1024,
      maxFiles: 5,
    }),
    new winston.transports.File({
      filename: 'logs/combined.log',
      maxsize: 5 * 1024 * 1024,
      maxFiles: 14,
    }),
  ],
});

logger.add(new winston.transports.Console({
  format: winston.format.combine(
    winston.format.colorize(),
    winston.format.simple()
  ),
}));

app.locals.logger = logger;

// ========================
// SECURITY HEADERS & CORS
// ========================
app.use((req, res, next) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Referrer-Policy', 'no-referrer');
  next();
});

const allowedOrigins = process.env.CORS_ORIGINS
  ? process.env.CORS_ORIGINS.split(',').map((o) => o.trim())
  : true;

app.use(
  cors({
    origin: allowedOrigins,
    methods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'],
    allowedHeaders: ['Content-Type', 'Authorization', 'X-Request-Id'],
    credentials: true,
  })
);

// Giới hạn JSON body 6MB để hỗ trợ tải ảnh hóa đơn/QR nén khi quét Vision AI nhưng vẫn chống OOM DoS
app.use(express.json({ limit: '6mb' }));
app.use(express.urlencoded({ extended: true, limit: '6mb' }));
app.use(requestIdMiddleware);

// ========================
// RATE LIMITING
// ========================
const globalLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 120,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Quá nhiều yêu cầu. Vui lòng thử lại sau.' },
});

const authLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 10,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Quá nhiều lần thử xác thực. Vui lòng thử lại sau 1 phút.' },
});

const syncLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 15,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Đồng bộ quá thường xuyên. Vui lòng thử lại sau.' },
});

app.use(globalLimiter);

// Morgan HTTP logging with requestId
const morganFormat = ':method :url :status :response-time ms - :req[x-request-id]';
app.use(morgan(morganFormat, {
  stream: {
    write: (message) => logger.info(message.trim()),
  },
}));

// Idempotency middleware (cho tất cả POST/PUT/DELETE routes)
app.use(idempotencyMiddleware);

// ========================
// ROUTES
// ========================
app.use('/auth', authLimiter, authRoutes);
app.use('/wallets', walletRoutes);
app.use('/groups', groupRoutes);
app.use('/transactions', transactionRoutes);
app.use('/budgets', budgetRoutes);
app.use('/loans', loanRoutes);
app.use('/reminders', reminderRoutes);
app.use('/sync', syncLimiter, syncRoutes);
app.use('/admin', adminRoutes);
app.use('/ai', aiRoutes);

// Health check (không lộ chi tiết SQL trên môi trường production)
app.get('/health', async (req, res) => {
  try {
    await pool.query('SELECT 1 FROM users LIMIT 1');
  } catch (err) {
    logger.error({ message: 'Health check database error', error: err.message, code: err.code });
    return res.status(503).json({
      status: 'UNAVAILABLE',
      error: 'Cơ sở dữ liệu chưa sẵn sàng',
      ...(isProduction ? {} : { detail: err.message }),
    });
  }
  res.json({
    status: 'OK',
    timestamp: new Date().toISOString(),
    uptime: process.uptime(),
    requestId: req.id,
  });
});

// 404 handler
app.use((req, res) => {
  res.status(404).json({ error: 'Endpoint không tồn tại' });
});

// Error handler
app.use((err, req, res, next) => {
  logger.error({
    message: err.message,
    stack: err.stack,
    requestId: req.id,
    userId: req.userId,
    method: req.method,
    url: req.originalUrl,
  });
  if (err.type === 'entity.too.large') {
    return res.status(413).json({ error: 'Dữ liệu gửi lên vượt quá giới hạn cho phép (2MB)' });
  }
  res.status(500).json({ error: 'Lỗi hệ thống', requestId: req.id });
});

// Start server
if (require.main === module) {
  app.listen(PORT, () => {
    console.log(`🚀 OnMoreCoin API Server running on port ${PORT}`);
    if (!process.env.JWT_SECRET) {
      console.error('❌ CRITICAL: JWT_SECRET environment variable is missing!');
    }
    if (!process.env.DATABASE_URL) {
      console.error('❌ WARNING: DATABASE_URL environment variable is missing!');
    }

    initDatabase()
      .then(() => {
        console.log('✅ Database tables initialized successfully');
      })
      .catch((err) => {
        console.error('❌ Database initialization error:', err.message, err.code);
        logger.error({ message: 'Database initialization failed', error: err.message, code: err.code });
      });
  });
}

module.exports = app;
