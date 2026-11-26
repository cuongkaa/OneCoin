const express = require('express');
const { pool } = require('../config/database');
const authMiddleware = require('../middleware/auth');

const router = express.Router();
router.use(authMiddleware);

const BUDGET_COLS = `COALESCE("clientId", id) AS id, title, budget, unit, type, "fromDate", "toDate", note, "isRepeat", "walletId", "groupId", "budgetType", "userId", "isDeleted", "updatedAt"`;

// GET /budgets
router.get('/', async (req, res) => {
  try {
    const { walletId } = req.query;
    let query = `SELECT ${BUDGET_COLS} FROM budgets WHERE "userId" = $1 AND ("isDeleted" = false OR "isDeleted" IS NULL)`;
    const params = [req.userId];
    let paramIdx = 2;

    if (walletId) {
      query += ` AND "walletId" = $${paramIdx++}`;
      params.push(walletId);
    }

    query += ' ORDER BY "fromDate" DESC';
    const result = await pool.query(query, params);
    res.json(result.rows);
  } catch (err) {
    console.error('Get budgets error:', err.message);
    res.status(500).json({ error: 'Lỗi hệ thống' });
  }
});

// POST /budgets
router.post('/', async (req, res) => {
  try {
    if (req.checkIdempotency && await req.checkIdempotency()) {
      return res.status(409).json({ message: 'Request đã được xử lý' });
    }

    const { id: rawClientId, title, budget, unit, type, fromDate, toDate, note, isRepeat, walletId, groupId, budgetType } = req.body || {};
    const clientId = rawClientId !== undefined && rawClientId !== null ? parseInt(rawClientId) : null;
    const boolIsRepeat = Boolean(isRepeat);

    let result;
    if (clientId && !Number.isNaN(clientId)) {
      result = await pool.query(
        `INSERT INTO budgets ("clientId", title, budget, unit, type, "fromDate", "toDate", note, "isRepeat", "walletId", "groupId", "budgetType", "userId", "isDeleted", "updatedAt")
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, false, NOW())
         ON CONFLICT ("userId", "clientId") DO UPDATE SET
           title = EXCLUDED.title,
           budget = EXCLUDED.budget,
           unit = EXCLUDED.unit,
           type = EXCLUDED.type,
           "fromDate" = EXCLUDED."fromDate",
           "toDate" = EXCLUDED."toDate",
           note = EXCLUDED.note,
           "isRepeat" = EXCLUDED."isRepeat",
           "walletId" = EXCLUDED."walletId",
           "groupId" = EXCLUDED."groupId",
           "budgetType" = EXCLUDED."budgetType",
           "isDeleted" = false,
           "updatedAt" = NOW()
         RETURNING ${BUDGET_COLS}`,
        [clientId, title, budget ?? 0, unit || 'VND', type || 'expense', fromDate, toDate, note, boolIsRepeat, walletId, groupId, budgetType || 'month', req.userId]
      );
    } else {
      const inserted = await pool.query(
        `INSERT INTO budgets (title, budget, unit, type, "fromDate", "toDate", note, "isRepeat", "walletId", "groupId", "budgetType", "userId", "updatedAt")
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, NOW())
         RETURNING id`,
        [title, budget ?? 0, unit || 'VND', type || 'expense', fromDate, toDate, note, boolIsRepeat, walletId, groupId, budgetType || 'month', req.userId]
      );
      result = await pool.query(
        `UPDATE budgets SET "clientId" = id WHERE id = $1 RETURNING ${BUDGET_COLS}`,
        [inserted.rows[0].id]
      );
    }

    if (req.markProcessed) await req.markProcessed();
    res.status(201).json(result.rows[0]);
  } catch (err) {
    console.error('Create budget error:', err.message);
    res.status(500).json({ error: 'Lỗi hệ thống' });
  }
});

// PUT /budgets/:id
router.put('/:id', async (req, res) => {
  try {
    if (req.checkIdempotency && await req.checkIdempotency()) {
      return res.status(409).json({ message: 'Request đã được xử lý' });
    }

    const budgetId = parseInt(req.params.id);
    if (Number.isNaN(budgetId)) {
      return res.status(400).json({ error: 'Mã ngân sách không hợp lệ' });
    }

    const { title, budget, unit, type, fromDate, toDate, note, isRepeat, walletId, groupId, budgetType, isDeleted } = req.body || {};
    const boolIsRepeat = isRepeat === undefined ? null : Boolean(isRepeat);
    const boolIsDeleted = isDeleted === undefined ? null : Boolean(isDeleted);

    await pool.query(
      `UPDATE budgets SET
        title = COALESCE($1, title),
        budget = COALESCE($2, budget),
        unit = COALESCE($3, unit),
        type = COALESCE($4, type),
        "fromDate" = COALESCE($5, "fromDate"),
        "toDate" = COALESCE($6, "toDate"),
        note = COALESCE($7, note),
        "isRepeat" = COALESCE($8, "isRepeat"),
        "walletId" = COALESCE($9, "walletId"),
        "groupId" = COALESCE($10, "groupId"),
        "budgetType" = COALESCE($11, "budgetType"),
        "isDeleted" = COALESCE($12, "isDeleted"),
        "updatedAt" = NOW()
       WHERE ("clientId" = $13 OR id = $13) AND "userId" = $14`,
      [title, budget, unit, type, fromDate, toDate, note, boolIsRepeat, walletId, groupId, budgetType, boolIsDeleted, budgetId, req.userId]
    );

    if (req.markProcessed) await req.markProcessed();
    res.json({ message: 'Cập nhật ngân sách thành công' });
  } catch (err) {
    console.error('Update budget error:', err.message);
    res.status(500).json({ error: 'Lỗi hệ thống' });
  }
});

// DELETE /budgets/:id - Soft delete
router.delete('/:id', async (req, res) => {
  try {
    const budgetId = parseInt(req.params.id);
    if (Number.isNaN(budgetId)) {
      return res.status(400).json({ error: 'Mã ngân sách không hợp lệ' });
    }

    await pool.query(
      'UPDATE budgets SET "isDeleted" = true, "updatedAt" = NOW() WHERE ("clientId" = $1 OR id = $1) AND "userId" = $2',
      [budgetId, req.userId]
    );
    res.json({ message: 'Xóa ngân sách thành công' });
  } catch (err) {
    console.error('Delete budget error:', err.message);
    res.status(500).json({ error: 'Lỗi hệ thống' });
  }
});

module.exports = router;
