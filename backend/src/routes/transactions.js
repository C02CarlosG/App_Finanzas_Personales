const express = require('express');
const { pool } = require('../db/pool');
const validate = require('../middleware/validate');
const { AppError, notFound } = require('../utils/errors');
const { transactionIsBacked, changesLockedFields } = require('../services/links');
const { z, money, uuid, isoDate, idParams } = require('../utils/schemas');

const router = express.Router();

const createBody = z.object({
  id: uuid.optional(), // el cliente offline puede generar el UUID
  type: z.enum(['income', 'expense']),
  amount: money,
  account_id: uuid,
  category_id: uuid,
  occurred_on: isoDate,
  description: z.string().trim().max(500).optional(),
  counterparty: z.string().trim().max(100).optional(),
});
const updateBody = z.object({
  type: z.enum(['income', 'expense']),
  amount: money,
  account_id: uuid,
  category_id: uuid,
  occurred_on: isoDate,
  description: z.string().trim().max(500).nullable(),
  counterparty: z.string().trim().max(100).nullable(),
}).partial().refine((v) => Object.keys(v).length > 0, 'Sin cambios');

const listQuery = z.object({
  type: z.enum(['income', 'expense']).optional(),
  category_id: uuid.optional(),
  account_id: uuid.optional(),
  bank_id: uuid.optional(),
  q: z.string().trim().min(1).max(100).optional(),
  from: isoDate.optional(),
  to: isoDate.optional(),
  limit: z.coerce.number().int().min(1).max(200).default(50),
  offset: z.coerce.number().int().min(0).default(0),
});

const SELECT = `
  SELECT t.id, t.type, t.amount, t.occurred_on, t.description, t.counterparty,
         t.account_id, a.name AS account_name, a.type AS account_type, b.name AS bank_name, b.logo_key,
         t.category_id, c.name AS category_name, c.color AS category_color, c.icon AS category_icon,
         t.created_at, t.updated_at
  FROM transactions t
  JOIN accounts a ON a.id = t.account_id
  JOIN categories c ON c.id = t.category_id
  LEFT JOIN banks b ON b.id = a.bank_id`;

async function findOne(userId, id) {
  const { rows } = await pool.query(`${SELECT} WHERE t.id = $1 AND t.user_id = $2 AND t.deleted_at IS NULL`, [id, userId]);
  if (!rows[0]) throw notFound('Transacción');
  return rows[0];
}

// La cuenta y la categoría deben ser del usuario y la categoría del mismo tipo que la transacción.
async function assertRefs(userId, { account_id, category_id, type }) {
  const acc = await pool.query('SELECT 1 FROM accounts WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL', [account_id, userId]);
  if (!acc.rowCount) throw new AppError(400, 'Cuenta no encontrada', 'invalid_account');
  const cat = await pool.query('SELECT kind FROM categories WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL', [category_id, userId]);
  if (!cat.rowCount) throw new AppError(400, 'Categoría no encontrada', 'invalid_category');
  if (cat.rows[0].kind !== type) throw new AppError(400, 'La categoría no corresponde al tipo de transacción', 'category_kind_mismatch');
}

router.get('/', validate({ query: listQuery }), async (req, res) => {
  const f = req.valid.query;
  const where = ['t.user_id = $1', 't.deleted_at IS NULL'];
  const params = [req.userId];
  const add = (sql, value) => { params.push(value); where.push(sql.replace('?', `$${params.length}`)); };
  if (f.type) add('t.type = ?', f.type);
  if (f.category_id) add('t.category_id = ?', f.category_id);
  if (f.account_id) add('t.account_id = ?', f.account_id);
  if (f.bank_id) add('a.bank_id = ?', f.bank_id);
  if (f.from) add('t.occurred_on >= ?', f.from);
  if (f.to) add('t.occurred_on <= ?', f.to);
  if (f.q) add(`t.description ILIKE ? ESCAPE '\\'`, `%${f.q.replace(/[\\%_]/g, '\\$&')}%`);
  const whereSql = where.join(' AND ');

  const [list, totals] = await Promise.all([
    pool.query(`${SELECT} WHERE ${whereSql} ORDER BY t.occurred_on DESC, t.created_at DESC
                LIMIT ${f.limit} OFFSET ${f.offset}`, params),
    pool.query(`SELECT COALESCE(SUM(t.amount) FILTER (WHERE t.type = 'income'), 0) AS income,
                       COALESCE(SUM(t.amount) FILTER (WHERE t.type = 'expense'), 0) AS expense,
                       COUNT(*)::int AS count
                FROM transactions t JOIN accounts a ON a.id = t.account_id WHERE ${whereSql}`, params),
  ]);
  res.json({ data: list.rows, totals: totals.rows[0], limit: f.limit, offset: f.offset });
});

router.post('/', validate({ body: createBody }), async (req, res) => {
  const b = req.valid.body;
  await assertRefs(req.userId, b);
  const { rows } = await pool.query(
    `INSERT INTO transactions (id, user_id, account_id, category_id, type, amount, occurred_on, description, counterparty)
     VALUES (COALESCE($1, gen_random_uuid()), $2, $3, $4, $5, $6, $7, $8, $9) RETURNING id`,
    [b.id ?? null, req.userId, b.account_id, b.category_id, b.type, b.amount, b.occurred_on,
      b.description ?? null, b.counterparty ?? null]);
  res.status(201).json(await findOne(req.userId, rows[0].id));
});

router.get('/:id', validate({ params: idParams }), async (req, res) => {
  res.json(await findOne(req.userId, req.valid.params.id));
});

router.patch('/:id', validate({ params: idParams, body: updateBody }), async (req, res) => {
  const { id } = req.valid.params;
  const current = await findOne(req.userId, id);
  const merged = { ...current, ...req.valid.body };
  await assertRefs(req.userId, merged);
  if (changesLockedFields(current, merged) && (await transactionIsBacked(pool, req.userId, id))) {
    throw new AppError(409, 'La transacción pertenece a un abono o a un pago de tarjeta; no se puede cambiar su tipo, monto ni cuenta', 'in_use');
  }
  await pool.query(
    `UPDATE transactions SET type = $3, amount = $4, account_id = $5, category_id = $6,
            occurred_on = $7, description = $8, counterparty = $9
     WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL`,
    [id, req.userId, merged.type, merged.amount, merged.account_id, merged.category_id,
      merged.occurred_on, merged.description, merged.counterparty]);
  res.json(await findOne(req.userId, id));
});

router.delete('/:id', validate({ params: idParams }), async (req, res) => {
  if (await transactionIsBacked(pool, req.userId, req.valid.params.id)) {
    throw new AppError(409, 'La transacción pertenece a un abono o a un pago de tarjeta', 'in_use');
  }
  const { rowCount } = await pool.query(
    'UPDATE transactions SET deleted_at = now() WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL',
    [req.valid.params.id, req.userId]);
  if (!rowCount) throw notFound('Transacción');
  res.status(204).end();
});

module.exports = router;
