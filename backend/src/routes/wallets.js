const express = require('express');
const { pool } = require('../config/database');
const authMiddleware = require('../middleware/auth');

const router = express.Router();
router.use(authMiddleware);

const WALLET_COLS = `COALESCE("clientId", id) AS id, name, icon, currency, balance, "isReport", "index", "userId", "isDeleted", "updatedAt"`;

// GET /wallets
router.get('/', async (req, res) => {
  try {
    const result = await pool.query(
      `SELECT ${WALLET_COLS} FROM wallets WHERE "userId" = $1 AND ("isDeleted" = false OR "isDeleted" IS NULL) ORDER BY "index" ASC, id ASC`,
      [req.userId]
    );
    res.json(result.rows);
  } catch (err) {
    console.error('Get wallets error:', err.message);
    res.status(500).json({ error: 'Lỗi hệ thống' });
  }
});

// GET /wallets/:id
router.get('/:id', async (req, res) => {
  try {
    const walletId = parseInt(req.params.id);
    if (Number.isNaN(walletId)) {
      return res.status(400).json({ error: 'Mã ví không hợp lệ' });
    }
    const result = await pool.query(
      `SELECT ${WALLET_COLS} FROM wallets WHERE ("clientId" = $1 OR id = $1) AND "userId" = $2 AND ("isDeleted" = false OR "isDeleted" IS NULL)`,
      [walletId, req.userId]
    );
    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'Không tìm thấy ví' });
    }
    res.json(result.rows[0]);
  } catch (err) {
    console.error('Get wallet error:', err.message);
    res.status(500).json({ error: 'Lỗi hệ thống' });
  }
});

// POST /wallets
router.post('/', async (req, res) => {
  try {
    if (req.checkIdempotency && await req.checkIdempotency()) {
      return res.status(409).json({ message: 'Request đã được xử lý' });
    }

    const { id: rawClientId, name, icon, currency, balance, isReport, index } = req.body || {};
    const clientId = rawClientId !== undefined && rawClientId !== null ? parseInt(rawClientId) : null;
    const boolIsReport = isReport !== undefined ? Boolean(isReport) : true;

    let result;
    if (clientId && !Number.isNaN(clientId)) {
      result = await pool.query(
        `INSERT INTO wallets ("clientId", name, icon, currency, balance, "isReport", "index", "userId", "isDeleted", "updatedAt")
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, false, NOW())
         ON CONFLICT ("userId", "clientId") DO UPDATE SET
           name = EXCLUDED.name,
           icon = EXCLUDED.icon,
           currency = EXCLUDED.currency,
           balance = EXCLUDED.balance,
           "isReport" = EXCLUDED."isReport",
           "index" = EXCLUDED."index",
           "isDeleted" = false,
           "updatedAt" = NOW()
         RETURNING ${WALLET_COLS}`,
        [clientId, name, icon, currency || 'VND', balance ?? 0, boolIsReport, index ?? 0, req.userId]
      );
    } else {
      const inserted = await pool.query(
        `INSERT INTO wallets (name, icon, currency, balance, "isReport", "index", "userId", "updatedAt")
         VALUES ($1, $2, $3, $4, $5, $6, $7, NOW())
         RETURNING id`,
        [name, icon, currency || 'VND', balance ?? 0, boolIsReport, index ?? 0, req.userId]
      );
      const newId = inserted.rows[0].id;
      result = await pool.query(
        `UPDATE wallets SET "clientId" = id WHERE id = $1 RETURNING ${WALLET_COLS}`,
        [newId]
      );
    }

    if (req.markProcessed) await req.markProcessed();
    res.status(201).json(result.rows[0]);
  } catch (err) {
    console.error('Create wallet error:', err.message);
    res.status(500).json({ error: 'Lỗi hệ thống' });
  }
});

// PUT /wallets/:id
router.put('/:id', async (req, res) => {
  try {
    if (req.checkIdempotency && await req.checkIdempotency()) {
      return res.status(409).json({ message: 'Request đã được xử lý' });
    }

    const walletId = parseInt(req.params.id);
    if (Number.isNaN(walletId)) {
      return res.status(400).json({ error: 'Mã ví không hợp lệ' });
    }

    const { name, icon, currency, balance, isReport, isDeleted } = req.body || {};
    const boolIsReport = isReport === undefined ? null : Boolean(isReport);
    const boolIsDeleted = isDeleted === undefined ? null : Boolean(isDeleted);

    await pool.query(
      `UPDATE wallets SET
        name = COALESCE($1, name),
        icon = COALESCE($2, icon),
        currency = COALESCE($3, currency),
        balance = COALESCE($4, balance),
        "isReport" = COALESCE($5, "isReport"),
        "isDeleted" = COALESCE($6, "isDeleted"),
        "updatedAt" = NOW()
       WHERE ("clientId" = $7 OR id = $7) AND "userId" = $8`,
      [name, icon, currency, balance, boolIsReport, boolIsDeleted, walletId, req.userId]
    );

    if (boolIsDeleted === true) {
      await pool.query(
        `UPDATE transactions_table SET "isDeleted" = true, "updatedAt" = NOW() WHERE "walletId" = $1 AND "userId" = $2`,
        [walletId, req.userId]
      );
      await pool.query(
        `UPDATE budgets SET "isDeleted" = true, "updatedAt" = NOW() WHERE "walletId" = $1 AND "userId" = $2`,
        [walletId, req.userId]
      );
    }

    if (req.markProcessed) await req.markProcessed();
    res.json({ message: 'Cập nhật ví thành công' });
  } catch (err) {
    console.error('Update wallet error:', err.message);
    res.status(500).json({ error: 'Lỗi hệ thống' });
  }
});

// DELETE /wallets/:id - Soft delete
router.delete('/:id', async (req, res) => {
  try {
    const walletId = parseInt(req.params.id);
    if (Number.isNaN(walletId)) {
      return res.status(400).json({ error: 'Mã ví không hợp lệ' });
    }

    await pool.query(
      `UPDATE wallets SET "isDeleted" = true, "updatedAt" = NOW() WHERE ("clientId" = $1 OR id = $1) AND "userId" = $2`,
      [walletId, req.userId]
    );
    await pool.query(
      `UPDATE transactions_table SET "isDeleted" = true, "updatedAt" = NOW() WHERE "walletId" = $1 AND "userId" = $2`,
      [walletId, req.userId]
    );
    await pool.query(
      `UPDATE budgets SET "isDeleted" = true, "updatedAt" = NOW() WHERE "walletId" = $1 AND "userId" = $2`,
      [walletId, req.userId]
    );

    res.json({ message: 'Xóa ví thành công' });
  } catch (err) {
    console.error('Delete wallet error:', err.message);
    res.status(500).json({ error: 'Lỗi hệ thống' });
  }
});

module.exports = router;
