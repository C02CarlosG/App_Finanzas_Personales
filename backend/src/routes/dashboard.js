const express = require('express');
const { pool } = require('../db/pool');
const validate = require('../middleware/validate');
const { z, month } = require('../utils/schemas');
const { currentMonth, monthRange } = require('../utils/dates');

const router = express.Router();

const query = z.object({
  month: month.optional(),
  recent: z.coerce.number().int().min(1).max(50).default(10),
});

// Resumen para el Inicio: saldo total, ingresos/gastos del mes y últimas transacciones.
router.get('/summary', validate({ query }), async (req, res) => {
  const m = req.valid.query.month ?? currentMonth();
  const { from, to } = monthRange(m);

  const [total, monthly, byCategory, recent] = await Promise.all([
    pool.query('SELECT COALESCE(SUM(balance), 0) AS total_balance FROM account_balances WHERE user_id = $1', [req.userId]),
    pool.query(
      `SELECT COALESCE(SUM(amount) FILTER (WHERE type = 'income'), 0) AS income,
              COALESCE(SUM(amount) FILTER (WHERE type = 'expense'), 0) AS expense
       FROM transactions WHERE user_id = $1 AND deleted_at IS NULL AND occurred_on >= $2 AND occurred_on < $3`,
      [req.userId, from, to]),
    pool.query(
      `SELECT c.id AS category_id, c.name, t.type, SUM(t.amount) AS total
       FROM transactions t JOIN categories c ON c.id = t.category_id
       WHERE t.user_id = $1 AND t.deleted_at IS NULL AND t.occurred_on >= $2 AND t.occurred_on < $3
       GROUP BY c.id, c.name, t.type ORDER BY total DESC`, [req.userId, from, to]),
    pool.query(
      `SELECT t.id, t.type, t.amount, t.occurred_on, t.description, t.counterparty,
              c.name AS category_name, a.name AS account_name
       FROM transactions t JOIN categories c ON c.id = t.category_id JOIN accounts a ON a.id = t.account_id
       WHERE t.user_id = $1 AND t.deleted_at IS NULL
       ORDER BY t.occurred_on DESC, t.created_at DESC LIMIT $2`, [req.userId, req.valid.query.recent]),
  ]);

  const { income, expense } = monthly.rows[0];
  // Resta en NUMERIC dentro de PostgreSQL para no usar float.
  const net = (await pool.query('SELECT ($1::numeric - $2::numeric) AS net', [income, expense])).rows[0].net;
  res.json({
    currency: 'MXN',
    total_balance: total.rows[0].total_balance,
    month: { month: m, income, expense, net },
    by_category: byCategory.rows,
    recent_transactions: recent.rows,
  });
});

module.exports = router;
