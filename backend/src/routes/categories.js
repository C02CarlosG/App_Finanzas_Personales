const express = require('express');
const { pool } = require('../db/pool');
const validate = require('../middleware/validate');
const { AppError, notFound } = require('../utils/errors');
const { z, uuid, idParams } = require('../utils/schemas');

const router = express.Router();

const color = z.string().regex(/^#[0-9a-fA-F]{6}$/, 'Color hex #RRGGBB');
const createBody = z.object({
  id: uuid.optional(),
  kind: z.enum(['income', 'expense']),
  name: z.string().trim().min(1).max(60),
  icon: z.string().trim().max(40).optional(),
  color: color.optional(),
});
const updateBody = z.object({
  name: z.string().trim().min(1).max(60),
  icon: z.string().trim().max(40).nullable(),
  color: color.nullable(),
}).partial().refine((v) => Object.keys(v).length > 0, 'Sin cambios');
const listQuery = z.object({ kind: z.enum(['income', 'expense']).optional() });

const COLS = 'id, kind, name, icon, color, is_system, created_at, updated_at';

async function findOne(userId, id) {
  const { rows } = await pool.query(
    `SELECT ${COLS} FROM categories WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL`, [id, userId]);
  if (!rows[0]) throw notFound('Categoría');
  return rows[0];
}

router.get('/', validate({ query: listQuery }), async (req, res) => {
  const { kind } = req.valid.query;
  const { rows } = await pool.query(
    `SELECT ${COLS} FROM categories WHERE user_id = $1 AND deleted_at IS NULL AND ($2::text IS NULL OR kind = $2)
     ORDER BY kind, created_at, name`, [req.userId, kind ?? null]);
  res.json({ data: rows });
});

router.post('/', validate({ body: createBody }), async (req, res) => {
  const b = req.valid.body;
  const { rows } = await pool.query(
    `INSERT INTO categories (id, user_id, kind, name, icon, color)
     VALUES (COALESCE($1, gen_random_uuid()), $2, $3, $4, $5, $6) RETURNING ${COLS}`,
    [b.id ?? null, req.userId, b.kind, b.name, b.icon ?? null, b.color ?? null]);
  res.status(201).json(rows[0]);
});

router.get('/:id', validate({ params: idParams }), async (req, res) => {
  res.json(await findOne(req.userId, req.valid.params.id));
});

router.patch('/:id', validate({ params: idParams, body: updateBody }), async (req, res) => {
  const { id } = req.valid.params;
  const b = req.valid.body;
  const current = await findOne(req.userId, id);
  if (current.is_system && b.name && b.name !== current.name) {
    throw new AppError(409, 'Las categorías del sistema no se pueden renombrar', 'system_category');
  }
  const { rows } = await pool.query(
    `UPDATE categories SET name = COALESCE($3, name),
                           icon = CASE WHEN $4 THEN $5 ELSE icon END,
                           color = CASE WHEN $6 THEN $7 ELSE color END
     WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL RETURNING ${COLS}`,
    [id, req.userId, b.name ?? null, 'icon' in b, b.icon ?? null, 'color' in b, b.color ?? null]);
  res.json(rows[0]);
});

router.delete('/:id', validate({ params: idParams }), async (req, res) => {
  const { id } = req.valid.params;
  const current = await findOne(req.userId, id);
  if (current.is_system) throw new AppError(409, 'Las categorías del sistema no se pueden eliminar', 'system_category');
  const used = await pool.query(
    'SELECT 1 FROM transactions WHERE category_id = $1 AND user_id = $2 AND deleted_at IS NULL LIMIT 1', [id, req.userId]);
  if (used.rowCount) throw new AppError(409, 'La categoría tiene transacciones; reasígnalas primero', 'in_use');
  await pool.query('UPDATE categories SET deleted_at = now() WHERE id = $1 AND user_id = $2', [id, req.userId]);
  res.status(204).end();
});

module.exports = router;
