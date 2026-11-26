const express = require('express');
const { pool } = require('../config/database');
const authMiddleware = require('../middleware/auth');

const router = express.Router();
router.use(authMiddleware);

// POST /sync/upload - Đồng bộ toàn bộ dữ liệu local lên server (Atomic Transaction + Upsert an toàn)
router.post('/upload', async (req, res) => {
  const client = await pool.connect();
  try {
    const { wallets, groups, transactions, budgets, loans, loanPayments, reminders } = req.body || {};
    const stats = { wallets: 0, groups: 0, transactions: 0, budgets: 0, loans: 0, loanPayments: 0, reminders: 0 };

    await client.query('BEGIN');

    // 1. Upsert Wallets theo (userId, clientId) -> Không bao giờ nhân bản ví
    if (Array.isArray(wallets)) {
      for (const w of wallets) {
        if (!w || w.id === undefined || w.id === null) continue;
        await client.query(
          `INSERT INTO wallets ("clientId", name, icon, currency, balance, "isReport", "index", "isDeleted", "userId", "updatedAt")
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, NOW())
           ON CONFLICT ("userId", "clientId") DO UPDATE SET
             name = EXCLUDED.name,
             icon = EXCLUDED.icon,
             currency = EXCLUDED.currency,
             balance = EXCLUDED.balance,
             "isReport" = EXCLUDED."isReport",
             "index" = EXCLUDED."index",
             "isDeleted" = EXCLUDED."isDeleted",
             "updatedAt" = NOW()`,
          [
            parseInt(w.id),
            w.name,
            w.icon,
            w.currency || 'VND',
            w.balance ?? 0,
            w.isReport !== undefined ? Boolean(w.isReport) : true,
            w.index ?? 0,
            Boolean(w.isDeleted),
            req.userId,
          ]
        );
        stats.wallets++;
      }
    }

    // 2. Upsert Groups theo (userId, clientId)
    if (Array.isArray(groups)) {
      for (const g of groups) {
        if (!g || g.id === undefined || g.id === null) continue;
        await client.query(
          `INSERT INTO groups ("clientId", name, type, icon, color, "parentId", "index", "isDeleted", "userId", "updatedAt")
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, NOW())
           ON CONFLICT ("userId", "clientId") DO UPDATE SET
             name = EXCLUDED.name,
             type = EXCLUDED.type,
             icon = EXCLUDED.icon,
             color = EXCLUDED.color,
             "parentId" = EXCLUDED."parentId",
             "index" = EXCLUDED."index",
             "isDeleted" = EXCLUDED."isDeleted",
             "updatedAt" = NOW()`,
          [
            parseInt(g.id),
            g.name,
            g.type || 'expense',
            g.icon,
            g.color,
            g.parentId,
            g.index ?? 1,
            Boolean(g.isDeleted),
            req.userId,
          ]
        );
        stats.groups++;
      }
    }

    // 3. Upsert Transactions có ràng buộc WHERE userId (chống IDOR + giữ categorySource & isDeleted)
    if (Array.isArray(transactions)) {
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
            String(t.id),
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
        if (r.rows.length > 0) stats.transactions++;
      }
    }

    // 4. Upsert Budgets theo (userId, clientId)
    if (Array.isArray(budgets)) {
      for (const b of budgets) {
        if (!b || b.id === undefined || b.id === null) continue;
        await client.query(
          `INSERT INTO budgets ("clientId", title, budget, unit, type, "fromDate", "toDate", note, "isRepeat", "walletId", "groupId", "budgetType", "isDeleted", "userId", "updatedAt")
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, NOW())
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
             "isDeleted" = EXCLUDED."isDeleted",
             "updatedAt" = NOW()`,
          [
            parseInt(b.id),
            b.title,
            b.budget ?? 0,
            b.unit || 'VND',
            b.type || 'expense',
            b.fromDate,
            b.toDate,
            b.note,
            Boolean(b.isRepeat),
            b.walletId,
            b.groupId,
            b.budgetType || 'month',
            Boolean(b.isDeleted),
            req.userId,
          ]
        );
        stats.budgets++;
      }
    }

    // 5. Upsert Loans có ràng buộc userId
    if (Array.isArray(loans)) {
      for (const l of loans) {
        if (!l || !l.id) continue;
        const r = await client.query(
          `INSERT INTO loans (id, "personName", amount, "paidAmount", type, date, "dueDate", note, status, currency, "walletId", "phoneNumber", "remindBeforeDays", "remindTime", "isDeleted", "userId", "updatedAt")
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, NOW())
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
             "isDeleted" = EXCLUDED."isDeleted",
             "updatedAt" = NOW()
           WHERE loans."userId" = EXCLUDED."userId"
           RETURNING id`,
          [
            String(l.id),
            l.personName,
            l.amount ?? 0,
            l.paidAmount ?? 0,
            l.type || 'borrow',
            l.date,
            l.dueDate,
            l.note,
            l.status || 'unpaid',
            l.currency || 'VND',
            l.walletId,
            l.phoneNumber,
            l.remindBeforeDays,
            l.remindTime,
            Boolean(l.isDeleted),
            req.userId,
          ]
        );
        if (r.rows.length > 0) stats.loans++;
      }
    }

    // 6. Upsert Loan Payments (kiểm tra quyền sở hữu gộp trong 1 câu SQL duy nhất thay vì N+1 SELECT)
    if (Array.isArray(loanPayments)) {
      for (const p of loanPayments) {
        if (!p || !p.id || !p.loanId) continue;
        const r = await client.query(
          `INSERT INTO loan_payments (id, "loanId", amount, date, note, "walletId", "isDeleted", "userId", "updatedAt")
           SELECT $1, $2, $3, $4, $5, $6, $7, $8, NOW()
           WHERE EXISTS (SELECT 1 FROM loans WHERE id = $2 AND "userId" = $8)
           ON CONFLICT (id) DO UPDATE SET
             amount = EXCLUDED.amount,
             date = EXCLUDED.date,
             note = EXCLUDED.note,
             "walletId" = EXCLUDED."walletId",
             "isDeleted" = EXCLUDED."isDeleted",
             "updatedAt" = NOW()
           WHERE loan_payments."userId" = EXCLUDED."userId"
           RETURNING id`,
          [String(p.id), String(p.loanId), p.amount ?? 0, p.date, p.note, p.walletId, Boolean(p.isDeleted), req.userId]
        );
        if (r.rows.length > 0) stats.loanPayments++;
      }
    }

    // 7. Upsert Reminders có ràng buộc userId
    if (Array.isArray(reminders)) {
      for (const r of reminders) {
        if (!r || !r.id) continue;
        const resRem = await client.query(
          `INSERT INTO reminders (id, title, amount, type, "dueDate", "remindBeforeDays", "remindTime", "isPaid", note, "isDeleted", "userId", "updatedAt")
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, NOW())
           ON CONFLICT (id) DO UPDATE SET
             title = EXCLUDED.title,
             amount = EXCLUDED.amount,
             type = EXCLUDED.type,
             "dueDate" = EXCLUDED."dueDate",
             "remindBeforeDays" = EXCLUDED."remindBeforeDays",
             "remindTime" = EXCLUDED."remindTime",
             "isPaid" = EXCLUDED."isPaid",
             note = EXCLUDED.note,
             "isDeleted" = EXCLUDED."isDeleted",
             "updatedAt" = NOW()
           WHERE reminders."userId" = EXCLUDED."userId"
           RETURNING id`,
          [
            String(r.id),
            r.title,
            r.amount ?? 0,
            r.type,
            r.dueDate,
            r.remindBeforeDays ?? 0,
            r.remindTime || '08:00',
            Boolean(r.isPaid),
            r.note,
            Boolean(r.isDeleted),
            req.userId,
          ]
        );
        if (resRem.rows.length > 0) stats.reminders++;
      }
    }

    await client.query('COMMIT');
    res.json({ message: 'Đồng bộ dữ liệu thành công', stats });
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    console.error('Sync upload error:', err.message);
    res.status(500).json({ error: 'Lỗi hệ thống' });
  } finally {
    client.release();
  }
});

// GET /sync/download - Trả về đúng clientId để giữ nguyên liên kết khóa ngoại trên SQLite
router.get('/download', async (req, res) => {
  try {
    const { since } = req.query;

    let extraFilter = '';
    const params = [req.userId];
    if (since) {
      const parsedDate = new Date(since);
      if (!Number.isNaN(parsedDate.getTime())) {
        extraFilter = ' AND "updatedAt" > $2';
        params.push(parsedDate);
      }
    } else {
      // Khi tải toàn bộ lần đầu, chỉ lấy các bản ghi chưa xóa mềm
      extraFilter = ' AND ("isDeleted" = false OR "isDeleted" IS NULL)';
    }

    const [wallets, groups, transactions, budgets, loans, loanPayments, reminders] = await Promise.all([
      pool.query(
        `SELECT COALESCE("clientId", id) AS id, name, icon, currency, balance, "isReport", "index", "isDeleted", "updatedAt" FROM wallets WHERE "userId" = $1${extraFilter} ORDER BY id ASC`,
        params
      ),
      pool.query(
        `SELECT COALESCE("clientId", id) AS id, name, type, icon, color, "parentId", "index", "isDeleted", "updatedAt" FROM groups WHERE "userId" = $1${extraFilter} ORDER BY id ASC`,
        params
      ),
      pool.query(
        `SELECT id, title, amount, unit, type, date, note, "addToReport", "notifyDate", "walletId", "groupId", "categorySource", "isDeleted", "updatedAt" FROM transactions_table WHERE "userId" = $1${extraFilter}`,
        params
      ),
      pool.query(
        `SELECT COALESCE("clientId", id) AS id, title, budget, unit, type, "fromDate", "toDate", note, "isRepeat", "walletId", "groupId", "budgetType", "isDeleted", "updatedAt" FROM budgets WHERE "userId" = $1${extraFilter} ORDER BY id ASC`,
        params
      ),
      pool.query(
        `SELECT id, "personName", amount, "paidAmount", type, date, "dueDate", note, status, currency, "walletId", "phoneNumber", "remindBeforeDays", "remindTime", "isDeleted", "updatedAt" FROM loans WHERE "userId" = $1${extraFilter}`,
        params
      ),
      pool.query(
        `SELECT id, "loanId", amount, date, note, "walletId", "isDeleted", "updatedAt" FROM loan_payments WHERE "userId" = $1${extraFilter}`,
        params
      ),
      pool.query(
        `SELECT id, title, amount, type, "dueDate", "remindBeforeDays", "remindTime", "isPaid", note, "isDeleted", "updatedAt" FROM reminders WHERE "userId" = $1${extraFilter}`,
        params
      ),
    ]);

    res.json({
      wallets: wallets.rows,
      groups: groups.rows,
      transactions: transactions.rows,
      budgets: budgets.rows,
      loans: loans.rows,
      loanPayments: loanPayments.rows,
      reminders: reminders.rows,
      syncedAt: new Date().toISOString(),
    });
  } catch (err) {
    console.error('Sync download error:', err.message);
    res.status(500).json({ error: 'Lỗi hệ thống' });
  }
});

module.exports = router;
