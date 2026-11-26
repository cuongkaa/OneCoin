const express = require('express');
const { pool } = require('../config/database');
const authMiddleware = require('../middleware/auth');

const router = express.Router();
router.use(authMiddleware);

// GET /loans
router.get('/', async (req, res) => {
  try {
    const { type, status } = req.query;
    let query = 'SELECT * FROM loans WHERE "userId" = $1 AND ("isDeleted" = false OR "isDeleted" IS NULL)';
    const params = [req.userId];
    let paramIdx = 2;

    if (type) {
      query += ` AND type = $${paramIdx++}`;
      params.push(type);
    }
    if (status) {
      query += ` AND status = $${paramIdx++}`;
      params.push(status);
    }

    query += ' ORDER BY date DESC';
    const result = await pool.query(query, params);
    res.json(result.rows);
  } catch (err) {
    console.error('Get loans error:', err.message);
    res.status(500).json({ error: 'Lỗi hệ thống' });
  }
});

// POST /loans
router.post('/', async (req, res) => {
  try {
    if (req.checkIdempotency && await req.checkIdempotency()) {
      return res.status(409).json({ message: 'Request đã được xử lý' });
    }

    const { id, personName, amount, paidAmount, type, date, dueDate, note, status, currency, walletId, phoneNumber, remindBeforeDays, remindTime } = req.body || {};
    if (!id) {
      return res.status(400).json({ error: 'Thiếu mã khoản vay (id)' });
    }

    const r = await pool.query(
      `INSERT INTO loans (id, "personName", amount, "paidAmount", type, date, "dueDate", note, status, currency, "walletId", "phoneNumber", "remindBeforeDays", "remindTime", "userId", "updatedAt")
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, NOW())
       ON CONFLICT (id) DO UPDATE SET
         "personName" = EXCLUDED."personName",
         amount = EXCLUDED.amount,
         "paidAmount" = EXCLUDED."paidAmount",
         type = EXCLUDED.type,
         date = EXCLUDED.date,
         "dueDate" = EXCLUDED."dueDate",
         note = EXCLUDED.note,
         status = EXCLUDED.status,
         currency = EXCLUDED.currency,
         "walletId" = EXCLUDED."walletId",
         "phoneNumber" = EXCLUDED."phoneNumber",
         "remindBeforeDays" = EXCLUDED."remindBeforeDays",
         "remindTime" = EXCLUDED."remindTime",
         "updatedAt" = NOW()
       WHERE loans."userId" = EXCLUDED."userId"
       RETURNING id`,
      [id, personName, amount ?? 0, paidAmount || 0, type || 'borrow', date, dueDate, note, status || 'unpaid', currency || 'VND', walletId, phoneNumber, remindBeforeDays, remindTime, req.userId]
    );

    if (r.rows.length === 0) {
      return res.status(403).json({ error: 'Không có quyền truy cập khoản vay này' });
    }

    if (req.markProcessed) await req.markProcessed();
    res.status(201).json({ message: 'Thêm khoản vay thành công', id });
  } catch (err) {
    console.error('Create loan error:', err.message);
    res.status(500).json({ error: 'Lỗi hệ thống' });
  }
});

// PUT /loans/:id
router.put('/:id', async (req, res) => {
  try {
    if (req.checkIdempotency && await req.checkIdempotency()) {
      return res.status(409).json({ message: 'Request đã được xử lý' });
    }

    const { personName, amount, paidAmount, type, date, dueDate, note, status, currency, walletId, phoneNumber, remindBeforeDays, remindTime, isDeleted } = req.body || {};
    const boolIsDeleted = isDeleted === undefined ? null : Boolean(isDeleted);

    await pool.query(
      `UPDATE loans SET
        "personName" = COALESCE($1, "personName"),
        amount = COALESCE($2, amount),
        "paidAmount" = COALESCE($3, "paidAmount"),
        type = COALESCE($4, type),
        date = COALESCE($5, date),
        "dueDate" = COALESCE($6, "dueDate"),
        note = COALESCE($7, note),
        status = COALESCE($8, status),
        currency = COALESCE($9, currency),
        "walletId" = COALESCE($10, "walletId"),
        "phoneNumber" = COALESCE($11, "phoneNumber"),
        "remindBeforeDays" = COALESCE($12, "remindBeforeDays"),
        "remindTime" = COALESCE($13, "remindTime"),
        "isDeleted" = COALESCE($14, "isDeleted"),
        "updatedAt" = NOW()
       WHERE id = $15 AND "userId" = $16`,
      [personName, amount, paidAmount, type, date, dueDate, note, status, currency, walletId, phoneNumber, remindBeforeDays, remindTime, boolIsDeleted, req.params.id, req.userId]
    );

    if (req.markProcessed) await req.markProcessed();
    res.json({ message: 'Cập nhật khoản vay thành công' });
  } catch (err) {
    console.error('Update loan error:', err.message);
    res.status(500).json({ error: 'Lỗi hệ thống' });
  }
});

// DELETE /loans/:id - Soft delete
router.delete('/:id', async (req, res) => {
  try {
    await pool.query(
      `UPDATE loan_payments SET "isDeleted" = true, "updatedAt" = NOW() WHERE "loanId" = $1 AND "userId" = $2`,
      [req.params.id, req.userId]
    );
    await pool.query(
      `UPDATE loans SET "isDeleted" = true, "updatedAt" = NOW() WHERE id = $1 AND "userId" = $2`,
      [req.params.id, req.userId]
    );
    res.json({ message: 'Xóa khoản vay thành công' });
  } catch (err) {
    console.error('Delete loan error:', err.message);
    res.status(500).json({ error: 'Lỗi hệ thống' });
  }
});

// GET /loans/:id/payments
router.get('/:id/payments', async (req, res) => {
  try {
    const result = await pool.query(
      'SELECT * FROM loan_payments WHERE "loanId" = $1 AND "userId" = $2 AND ("isDeleted" = false OR "isDeleted" IS NULL) ORDER BY date DESC',
      [req.params.id, req.userId]
    );
    res.json(result.rows);
  } catch (err) {
    console.error('Get loan payments error:', err.message);
    res.status(500).json({ error: 'Lỗi hệ thống' });
  }
});

// POST /loans/payments (Direct SyncQueue endpoint cho tableName = 'loan_payments')
router.post('/payments', async (req, res) => {
  const client = await pool.connect();
  try {
    if (req.checkIdempotency && await req.checkIdempotency()) {
      return res.status(409).json({ message: 'Request đã được xử lý' });
    }

    const { id: paymentId, loanId, amount, date, note, walletId } = req.body || {};
    if (!paymentId || !loanId) {
      return res.status(400).json({ error: 'Thiếu mã thanh toán hoặc mã khoản vay' });
    }

    await client.query('BEGIN');
    // Kiểm tra quyền sở hữu khoản vay TRƯỚC khi chèn thanh toán (chống IDOR)
    const loan = await client.query(
      'SELECT id, amount, "paidAmount" FROM loans WHERE id = $1 AND "userId" = $2',
      [loanId, req.userId]
    );
    if (loan.rows.length === 0) {
      await client.query('ROLLBACK');
      return res.status(404).json({ error: 'Không tìm thấy khoản vay hợp lệ' });
    }

    await client.query(
      `INSERT INTO loan_payments (id, "loanId", amount, date, note, "walletId", "userId", "updatedAt")
       VALUES ($1, $2, $3, $4, $5, $6, $7, NOW())
       ON CONFLICT (id) DO UPDATE SET
         amount = EXCLUDED.amount,
         date = EXCLUDED.date,
         note = EXCLUDED.note,
         "walletId" = EXCLUDED."walletId",
         "updatedAt" = NOW()
       WHERE loan_payments."userId" = EXCLUDED."userId"`,
      [paymentId, loanId, amount ?? 0, date, note, walletId, req.userId]
    );

    // Tính lại tổng paidAmount chính xác từ các bản ghi chưa xóa
    const sumRes = await client.query(
      `SELECT COALESCE(SUM(amount), 0) as total FROM loan_payments WHERE "loanId" = $1 AND "userId" = $2 AND ("isDeleted" = false OR "isDeleted" IS NULL)`,
      [loanId, req.userId]
    );
    const totalPaid = parseFloat(sumRes.rows[0].total) || 0;
    const loanAmount = parseFloat(loan.rows[0].amount) || 0;
    const newStatus = totalPaid >= loanAmount ? 'paid' : totalPaid > 0 ? 'partial' : 'unpaid';

    await client.query(
      'UPDATE loans SET "paidAmount" = $1, status = $2, "updatedAt" = NOW() WHERE id = $3 AND "userId" = $4',
      [Math.min(totalPaid, loanAmount), newStatus, loanId, req.userId]
    );

    await client.query('COMMIT');
    if (req.markProcessed) await req.markProcessed();
    res.status(201).json({ message: 'Đồng bộ thanh toán khoản vay thành công' });
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    console.error('Sync loan payment error:', err.message);
    res.status(500).json({ error: 'Lỗi hệ thống' });
  } finally {
    client.release();
  }
});

// PUT /loans/payments/:paymentId (Hỗ trợ cập nhật / xóa mềm từ SyncQueue)
router.put('/payments/:paymentId', async (req, res) => {
  const client = await pool.connect();
  try {
    if (req.checkIdempotency && await req.checkIdempotency()) {
      return res.status(409).json({ message: 'Request đã được xử lý' });
    }

    const { amount, date, note, walletId, isDeleted } = req.body || {};
    const boolIsDeleted = isDeleted === undefined ? null : Boolean(isDeleted);

    await client.query('BEGIN');
    const updated = await client.query(
      `UPDATE loan_payments SET
        amount = COALESCE($1, amount),
        date = COALESCE($2, date),
        note = COALESCE($3, note),
        "walletId" = COALESCE($4, "walletId"),
        "isDeleted" = COALESCE($5, "isDeleted"),
        "updatedAt" = NOW()
       WHERE id = $6 AND "userId" = $7
       RETURNING "loanId"`,
      [amount, date, note, walletId, boolIsDeleted, req.params.paymentId, req.userId]
    );

    if (updated.rows.length > 0) {
      const loanId = updated.rows[0].loanId;
      const loanRes = await client.query('SELECT amount FROM loans WHERE id = $1 AND "userId" = $2', [loanId, req.userId]);
      const sumRes = await client.query(
        `SELECT COALESCE(SUM(amount), 0) as total FROM loan_payments WHERE "loanId" = $1 AND "userId" = $2 AND ("isDeleted" = false OR "isDeleted" IS NULL)`,
        [loanId, req.userId]
      );
      if (loanRes.rows.length > 0) {
        const totalPaid = parseFloat(sumRes.rows[0].total) || 0;
        const loanAmount = parseFloat(loanRes.rows[0].amount) || 0;
        const newStatus = totalPaid >= loanAmount ? 'paid' : totalPaid > 0 ? 'partial' : 'unpaid';
        await client.query(
          'UPDATE loans SET "paidAmount" = $1, status = $2, "updatedAt" = NOW() WHERE id = $3 AND "userId" = $4',
          [Math.min(totalPaid, loanAmount), newStatus, loanId, req.userId]
        );
      }
    }

    await client.query('COMMIT');
    if (req.markProcessed) await req.markProcessed();
    res.json({ message: 'Cập nhật thanh toán khoản vay thành công' });
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    console.error('Update loan payment error:', err.message);
    res.status(500).json({ error: 'Lỗi hệ thống' });
  } finally {
    client.release();
  }
});

// POST /loans/:id/payments
router.post('/:id/payments', async (req, res) => {
  const client = await pool.connect();
  try {
    if (req.checkIdempotency && await req.checkIdempotency()) {
      return res.status(409).json({ message: 'Request đã được xử lý' });
    }

    const { id: paymentId, amount, date, note, walletId } = req.body || {};
    await client.query('BEGIN');

    // Kiểm tra quyền sở hữu khoản vay TRƯỚC khi chèn vào loan_payments
    const loan = await client.query(
      'SELECT amount, "paidAmount" FROM loans WHERE id = $1 AND "userId" = $2',
      [req.params.id, req.userId]
    );

    if (loan.rows.length === 0) {
      await client.query('ROLLBACK');
      return res.status(404).json({ error: 'Không tìm thấy khoản vay' });
    }

    await client.query(
      `INSERT INTO loan_payments (id, "loanId", amount, date, note, "walletId", "userId", "updatedAt")
       VALUES ($1, $2, $3, $4, $5, $6, $7, NOW())`,
      [paymentId, req.params.id, amount ?? 0, date, note, walletId, req.userId]
    );

    const sumRes = await client.query(
      `SELECT COALESCE(SUM(amount), 0) as total FROM loan_payments WHERE "loanId" = $1 AND "userId" = $2 AND ("isDeleted" = false OR "isDeleted" IS NULL)`,
      [req.params.id, req.userId]
    );
    const newPaidAmount = parseFloat(sumRes.rows[0].total) || 0;
    const loanAmount = parseFloat(loan.rows[0].amount) || 0;
    const newStatus = newPaidAmount >= loanAmount ? 'paid' : newPaidAmount > 0 ? 'partial' : 'unpaid';

    await client.query(
      'UPDATE loans SET "paidAmount" = $1, status = $2, "updatedAt" = NOW() WHERE id = $3 AND "userId" = $4',
      [Math.min(newPaidAmount, loanAmount), newStatus, req.params.id, req.userId]
    );

    await client.query('COMMIT');
    if (req.markProcessed) await req.markProcessed();
    res.status(201).json({ message: 'Thêm thanh toán thành công' });
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    console.error('Create loan payment error:', err.message);
    res.status(500).json({ error: 'Lỗi hệ thống' });
  } finally {
    client.release();
  }
});

module.exports = router;
