const express = require('express');
const { pool } = require('../config/database');
const authMiddleware = require('../middleware/auth');

const router = express.Router();
router.use(authMiddleware);

const GROUP_COLS = `COALESCE("clientId", id) AS id, name, type, icon, color, "parentId", "index", "userId", "isDeleted", "updatedAt"`;

// GET /groups
router.get('/', async (req, res) => {
  try {
    const result = await pool.query(
      `SELECT ${GROUP_COLS} FROM groups WHERE "userId" = $1 AND ("isDeleted" = false OR "isDeleted" IS NULL) ORDER BY "index" ASC, id ASC`,
      [req.userId]
    );
    res.json(result.rows);
  } catch (err) {
    console.error('Get groups error:', err.message);
    res.status(500).json({ error: 'Lỗi hệ thống' });
  }
});

// POST /groups
router.post('/', async (req, res) => {
  try {
    if (req.checkIdempotency && await req.checkIdempotency()) {
      return res.status(409).json({ message: 'Request đã được xử lý' });
    }

    const { id: rawClientId, name, type, icon, color, parentId, index } = req.body || {};
    const clientId = rawClientId !== undefined && rawClientId !== null ? parseInt(rawClientId) : null;

    let result;
    if (clientId && !Number.isNaN(clientId)) {
      result = await pool.query(
        `INSERT INTO groups ("clientId", name, type, icon, color, "parentId", "index", "userId", "isDeleted", "updatedAt")
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, false, NOW())
         ON CONFLICT ("userId", "clientId") DO UPDATE SET
           name = EXCLUDED.name,
           type = EXCLUDED.type,
           icon = EXCLUDED.icon,
           color = EXCLUDED.color,
           "parentId" = EXCLUDED."parentId",
           "index" = EXCLUDED."index",
           "isDeleted" = false,
           "updatedAt" = NOW()
         RETURNING ${GROUP_COLS}`,
        [clientId, name, type || 'expense', icon, color, parentId, index || 1, req.userId]
      );
    } else {
      const inserted = await pool.query(
        `INSERT INTO groups (name, type, icon, color, "parentId", "index", "userId", "updatedAt")
         VALUES ($1, $2, $3, $4, $5, $6, $7, NOW())
         RETURNING id`,
        [name, type || 'expense', icon, color, parentId, index || 1, req.userId]
      );
      result = await pool.query(
        `UPDATE groups SET "clientId" = id WHERE id = $1 RETURNING ${GROUP_COLS}`,
        [inserted.rows[0].id]
      );
    }

    if (req.markProcessed) await req.markProcessed();
    res.status(201).json(result.rows[0]);
  } catch (err) {
    console.error('Create group error:', err.message);
    res.status(500).json({ error: 'Lỗi hệ thống' });
  }
});

// PUT /groups/:id
router.put('/:id', async (req, res) => {
  try {
    if (req.checkIdempotency && await req.checkIdempotency()) {
      return res.status(409).json({ message: 'Request đã được xử lý' });
    }

    const groupId = parseInt(req.params.id);
    if (Number.isNaN(groupId)) {
      return res.status(400).json({ error: 'Mã nhóm không hợp lệ' });
    }

    const { name, type, icon, color, parentId, isDeleted } = req.body || {};
    const boolIsDeleted = isDeleted === undefined ? null : Boolean(isDeleted);

    await pool.query(
      `UPDATE groups SET
        name = COALESCE($1, name),
        type = COALESCE($2, type),
        icon = COALESCE($3, icon),
        color = COALESCE($4, color),
        "parentId" = COALESCE($5, "parentId"),
        "isDeleted" = COALESCE($6, "isDeleted"),
        "updatedAt" = NOW()
       WHERE ("clientId" = $7 OR id = $7) AND "userId" = $8`,
      [name, type, icon, color, parentId, boolIsDeleted, groupId, req.userId]
    );

    if (req.markProcessed) await req.markProcessed();
    res.json({ message: 'Cập nhật nhóm thành công' });
  } catch (err) {
    console.error('Update group error:', err.message);
    res.status(500).json({ error: 'Lỗi hệ thống' });
  }
});

// DELETE /groups/:id - Soft delete
router.delete('/:id', async (req, res) => {
  try {
    const groupId = parseInt(req.params.id);
    if (Number.isNaN(groupId)) {
      return res.status(400).json({ error: 'Mã nhóm không hợp lệ' });
    }

    await pool.query(
      'UPDATE groups SET "isDeleted" = true, "updatedAt" = NOW() WHERE ("clientId" = $1 OR id = $1) AND "userId" = $2',
      [groupId, req.userId]
    );
    res.json({ message: 'Xóa nhóm thành công' });
  } catch (err) {
    console.error('Delete group error:', err.message);
    res.status(500).json({ error: 'Lỗi hệ thống' });
  }
});

// POST /groups/init — Khởi tạo nhóm mặc định có clientId đồng nhất với SQLite client
router.post('/init', async (req, res) => {
  try {
    const defaultGroups = [
      { clientId: 1, name: 'Ăn uống', type: 'expense', icon: '59555', color: '#FF5722' },
      { clientId: 2, name: 'Di chuyển', type: 'expense', icon: '57756', color: '#2196F3' },
      { clientId: 3, name: 'Mua sắm', type: 'expense', icon: '59597', color: '#E91E63' },
      { clientId: 4, name: 'Sức khỏe', type: 'expense', icon: '59518', color: '#F44336' },
      { clientId: 5, name: 'Giải trí', type: 'expense', icon: '58923', color: '#9C27B0' },
      { clientId: 6, name: 'Tiền nhà', type: 'expense', icon: '59530', color: '#795548' },
      { clientId: 7, name: 'Tiền nước', type: 'expense', icon: '60048', color: '#00BCD4' },
      { clientId: 8, name: 'Tiền internet', type: 'expense', icon: '58956', color: '#3F51B5' },
      { clientId: 9, name: 'Tiền điện thoại', type: 'expense', icon: '59473', color: '#607D8B' },
      { clientId: 10, name: 'Tiền học', type: 'expense', icon: '59583', color: '#FF9800' },
      { clientId: 11, name: 'Tiền khác', type: 'expense', icon: '57424', color: '#9E9E9E' },
      { clientId: 12, name: 'Lương', type: 'income', icon: '57739', color: '#4CAF50' },
      { clientId: 13, name: 'Thưởng', type: 'income', icon: '58260', color: '#FFEB3B' },
      { clientId: 14, name: 'Lãi', type: 'income', icon: '58893', color: '#8BC34A' },
      { clientId: 15, name: 'Bán đồ', type: 'income', icon: '58737', color: '#FF9800' },
      { clientId: 16, name: 'Khác', type: 'income', icon: '57424', color: '#9E9E9E' },
      { clientId: 17, name: 'Tiền điện', type: 'expense', icon: '57630', color: '#FFC107' },
    ];

    for (const g of defaultGroups) {
      await pool.query(
        `INSERT INTO groups ("clientId", name, type, icon, color, "index", "userId", "updatedAt")
         VALUES ($1, $2, $3, $4, $5, 1, $6, NOW())
         ON CONFLICT ("userId", "clientId") DO NOTHING`,
        [g.clientId, g.name, g.type, g.icon, g.color, req.userId]
      );
    }

    res.status(201).json({ message: 'Đã khởi tạo nhóm mặc định' });
  } catch (err) {
    console.error('Init groups error:', err.message);
    res.status(500).json({ error: 'Lỗi hệ thống' });
  }
});

module.exports = router;
