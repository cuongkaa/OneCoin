const express = require('express');
const { pool } = require('../config/database');
const authMiddleware = require('../middleware/auth');

const router = express.Router();
router.use(authMiddleware);

// GET /transactions
router.get('/', async (req, res) => {
  try {
    const { walletId, groupId, fromDate, toDate, limit } = req.query;
    let query = 'SELECT * FROM transactions_table WHERE "userId" = $1 AND ("isDeleted" = false OR "isDeleted" IS NULL)';
    const params = [req.userId];
    let paramIdx = 2;

    if (walletId) {
      query += ` AND "walletId" = $${paramIdx++}`;
      params.push(walletId);
    }
    if (groupId) {
      query += ` AND "groupId" = $${paramIdx++}`;
      params.push(groupId);
    }
    if (fromDate) {
      query += ` AND date >= $${paramIdx++}`;
      params.push(fromDate);
    }
    if (toDate) {
      query += ` AND date <= $${paramIdx++}`;
      params.push(toDate);
    }

    query += ' ORDER BY date DESC';

    if (limit) {
      const parsedLimit = Math.min(Math.max(parseInt(limit) || 50, 1), 1000);
      query += ` LIMIT $${paramIdx++}`;
      params.push(parsedLimit);
    }

    const result = await pool.query(query, params);
    res.json(result.rows);
  } catch (err) {
    console.error('Get transactions error:', err.message);
    res.status(500).json({ error: 'Lỗi hệ thống' });
  }
});

// GET /transactions/:id
router.get('/:id', async (req, res) => {
  try {
    const result = await pool.query(
      'SELECT * FROM transactions_table WHERE id = $1 AND "userId" = $2 AND ("isDeleted" = false OR "isDeleted" IS NULL)',
      [req.params.id, req.userId]
    );
    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'Không tìm thấy giao dịch' });
    }
    res.json(result.rows[0]);
  } catch (err) {
    console.error('Get transaction error:', err.message);
    res.status(500).json({ error: 'Lỗi hệ thống' });
  }
});

// POST /transactions
router.post('/', async (req, res) => {
  try {
    if (req.checkIdempotency && await req.checkIdempotency()) {
      return res.status(409).json({ message: 'Request đã được xử lý' });
    }

    const { id, title, amount, unit, type, date, note, addToReport, notifyDate, walletId, groupId, categorySource } = req.body || {};
    if (!id) {
      return res.status(400).json({ error: 'Thiếu mã giao dịch (id)' });
    }

    const result = await pool.query(
      `INSERT INTO transactions_table (id, title, amount, unit, type, date, note, "addToReport", "notifyDate", "walletId", "groupId", "categorySource", "userId", "updatedAt")
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, NOW())
       ON CONFLICT (id) DO UPDATE SET
         title = EXCLUDED.title,
         amount = EXCLUDED.amount,
         unit = EXCLUDED.unit,
         type = EXCLUDED.type,
         date = EXCLUDED.date,
         note = EXCLUDED.note,
         "addToReport" = EXCLUDED."addToReport",
         "notifyDate" = EXCLUDED."notifyDate",
         "walletId" = EXCLUDED."walletId",
         "groupId" = EXCLUDED."groupId",
         "categorySource" = COALESCE(EXCLUDED."categorySource", transactions_table."categorySource"),
         "updatedAt" = NOW()
       WHERE transactions_table."userId" = EXCLUDED."userId"
       RETURNING id`,
      [id, title, amount ?? 0, unit || 'VND', type || 'expense', date, note, addToReport !== undefined ? Boolean(addToReport) : true, notifyDate, walletId, groupId, categorySource || null, req.userId]
    );

    if (result.rows.length === 0) {
      return res.status(403).json({ error: 'Không có quyền truy cập giao dịch này' });
    }

    if (req.markProcessed) await req.markProcessed();
    res.status(201).json({ message: 'Thêm giao dịch thành công', id });
  } catch (err) {
    console.error('Create transaction error:', err.message);
    res.status(500).json({ error: 'Lỗi hệ thống' });
  }
});

// PUT /transactions/:id
router.put('/:id', async (req, res) => {
  try {
    if (req.checkIdempotency && await req.checkIdempotency()) {
      return res.status(409).json({ message: 'Request đã được xử lý' });
    }

    const { title, amount, unit, type, date, note, addToReport, notifyDate, walletId, groupId, categorySource, isDeleted } = req.body || {};
    const boolAddToReport = addToReport === undefined ? null : Boolean(addToReport);
    const boolIsDeleted = isDeleted === undefined ? null : Boolean(isDeleted);

    await pool.query(
      `UPDATE transactions_table SET
        title = COALESCE($1, title),
        amount = COALESCE($2, amount),
        unit = COALESCE($3, unit),
        type = COALESCE($4, type),
        date = COALESCE($5, date),
        note = COALESCE($6, note),
        "addToReport" = COALESCE($7, "addToReport"),
        "notifyDate" = COALESCE($8, "notifyDate"),
        "walletId" = COALESCE($9, "walletId"),
        "groupId" = COALESCE($10, "groupId"),
        "categorySource" = COALESCE($11, "categorySource"),
        "isDeleted" = COALESCE($12, "isDeleted"),
        "updatedAt" = NOW()
       WHERE id = $13 AND "userId" = $14`,
      [title, amount, unit, type, date, note, boolAddToReport, notifyDate, walletId, groupId, categorySource, boolIsDeleted, req.params.id, req.userId]
    );

    if (req.markProcessed) await req.markProcessed();
    res.json({ message: 'Cập nhật giao dịch thành công' });
  } catch (err) {
    console.error('Update transaction error:', err.message);
    res.status(500).json({ error: 'Lỗi hệ thống' });
  }
});

// DELETE /transactions/:id - Soft delete
router.delete('/:id', async (req, res) => {
  try {
    await pool.query(
      'UPDATE transactions_table SET "isDeleted" = true, "updatedAt" = NOW() WHERE id = $1 AND "userId" = $2',
      [req.params.id, req.userId]
    );
    res.json({ message: 'Xóa giao dịch thành công' });
  } catch (err) {
    console.error('Delete transaction error:', err.message);
    res.status(500).json({ error: 'Lỗi hệ thống' });
  }
});

// POST /transactions/sync - Bulk sync an toàn (có kiểm tra quyền sở hữu userId chống IDOR)
router.post('/sync', async (req, res) => {
  const client = await pool.connect();
  try {
    const { transactions } = req.body || {};
    if (!Array.isArray(transactions)) {
      return res.status(400).json({ error: 'Dữ liệu không hợp lệ' });
    }

    await client.query('BEGIN');
    let synced = 0;
    for (const t of transactions) {
      if (!t || !t.id) continue;
      const r = await client.query(
        `INSERT INTO transactions_table (id, title, amount, unit, type, date, note, "addToReport", "notifyDate", "walletId", "groupId", "categorySource", "isDeleted", "userId", "updatedAt")
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, NOW())
         ON CONFLICT (id) DO UPDATE SET
           title = EXCLUDED.title,
           amount = EXCLUDED.amount,
           unit = EXCLUDED.unit,
           type = EXCLUDED.type,
           date = EXCLUDED.date,
           note = EXCLUDED.note,
           "addToReport" = EXCLUDED."addToReport",
           "notifyDate" = EXCLUDED."notifyDate",
           "walletId" = EXCLUDED."walletId",
           "groupId" = EXCLUDED."groupId",
           "categorySource" = COALESCE(EXCLUDED."categorySource", transactions_table."categorySource"),
           "isDeleted" = EXCLUDED."isDeleted",
           "updatedAt" = NOW()
         WHERE transactions_table."userId" = EXCLUDED."userId"
         RETURNING id`,
        [
          t.id,
          t.title,
          t.amount ?? 0,
          t.unit || 'VND',
          t.type || 'expense',
          t.date,
          t.note,
          t.addToReport !== undefined ? Boolean(t.addToReport) : true,
          t.notifyDate,
          t.walletId,
          t.groupId,
          t.categorySource || null,
          Boolean(t.isDeleted),
          req.userId,
        ]
      );
      if (r.rows.length > 0) synced++;
    }
    await client.query('COMMIT');

    res.json({ message: `Đồng bộ ${synced} giao dịch thành công` });
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    console.error('Sync transactions error:', err.message);
    res.status(500).json({ error: 'Lỗi hệ thống' });
  } finally {
    client.release();
  }
});

module.exports = router;
