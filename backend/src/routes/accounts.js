const express = require('express');
const { pool } = require('../db/pool');
const validate = require('../middleware/validate');
const { AppError, notFound } = require('../utils/errors');
const { z, signedMoney, uuid, idParams } = require('../utils/schemas');

const router = express.Router();

const createBody = z.object({
  id: uuid.optional(), // el cliente offline puede generar el UUID
  type: z.enum(['banco', 'efectivo']),
  bank_id: uuid.optional(),
  name: z.string().trim().min(1).max(100).optional(),
  card_type: z.enum(['debito', 'credito']).optional(),
  initial_balance: signedMoney.default('0'),
}).superRefine((v, ctx) => {
  if (v.type === 'banco' && !v.bank_id) ctx.addIssue({ code: 'custom', path: ['bank_id'], message: 'bank_id es requerido para cuentas de banco' });
  if (v.type === 'efectivo' && (v.bank_id || v.card_type)) ctx.addIssue({ code: 'custom', path: ['type'], message: 'Una cuenta de efectivo no lleva banco ni tipo de tarjeta' });
});

const updateBody = z.object({
  name: z.string().trim().min(1).max(100),
  card_type: z.enum(['debito', 'credito']).nullable(),
  initial_balance: signedMoney,
}).partial().refine((v) => Object.keys(v).length > 0, 'Sin cambios');

const SELECT = `
  SELECT a.id, a.type, a.bank_id, b.name AS bank_name, b.logo_key, a.name, a.card_type,
         a.initial_balance, ab.balance, a.created_at, a.updated_at
  FROM accounts a
  JOIN account_balances ab ON ab.account_id = a.id
  LEFT JOIN banks b ON b.id = a.bank_id`;

async function findOne(userId, id) {
  const { rows } = await pool.query(`${SELECT} WHERE a.user_id = $1 AND a.id = $2 AND a.deleted_at IS NULL`, [userId, id]);
  if (!rows[0]) throw notFound('Cuenta');
  return rows[0];
}

router.get('/', async (req, res) => {
  const { rows } = await pool.query(`${SELECT} WHERE a.user_id = $1 AND a.deleted_at IS NULL ORDER BY a.created_at`, [req.userId]);
  res.json({ data: rows });
});

router.post('/', validate({ body: createBody }), async (req, res) => {
  const b = req.valid.body;
  let name = b.name;
  if (b.type === 'banco') {
    const bank = await pool.query('SELECT name FROM banks WHERE id = $1 AND deleted_at IS NULL', [b.bank_id]);
    if (!bank.rowCount) throw new AppError(400, 'Banco no existe en el catálogo', 'invalid_bank');
    name ??= bank.rows[0].name;
  } else {
    name ??= 'Efectivo';
  }
  const { rows } = await pool.query(
    `INSERT INTO accounts (id, user_id, type, bank_id, name, card_type, initial_balance)
     VALUES (COALESCE($1, gen_random_uuid()), $2, $3, $4, $5, $6, $7) RETURNING id`,
    [b.id ?? null, req.userId, b.type, b.bank_id ?? null, name, b.card_type ?? null, b.initial_balance],
  );
  res.status(201).json(await findOne(req.userId, rows[0].id));
});

router.get('/:id', validate({ params: idParams }), async (req, res) => {
  res.json(await findOne(req.userId, req.valid.params.id));
});

router.patch('/:id', validate({ params: idParams, body: updateBody }), async (req, res) => {
  const { id } = req.valid.params;
  const b = req.valid.body;
  const { rowCount } = await pool.query(
    `UPDATE accounts SET name = COALESCE($3, name),
                         card_type = CASE WHEN $4 THEN $5 ELSE card_type END,
                         initial_balance = COALESCE($6, initial_balance)
     WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL`,
    [id, req.userId, b.name ?? null, 'card_type' in b, b.card_type ?? null, b.initial_balance ?? null],
  );
  if (!rowCount) throw notFound('Cuenta');
  res.json(await findOne(req.userId, id));
});

router.delete('/:id', validate({ params: idParams }), async (req, res) => {
  const { id } = req.valid.params;
  const used = await pool.query(
    'SELECT 1 FROM transactions WHERE account_id = $1 AND user_id = $2 AND deleted_at IS NULL LIMIT 1', [id, req.userId]);
  if (used.rowCount) throw new AppError(409, 'La cuenta tiene transacciones; elimínalas o muévelas primero', 'in_use');
  const { rowCount } = await pool.query(
    'UPDATE accounts SET deleted_at = now() WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL', [id, req.userId]);
  if (!rowCount) throw notFound('Cuenta');
  res.status(204).end();
});

module.exports = router;
