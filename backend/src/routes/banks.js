const express = require('express');
const { pool } = require('../db/pool');

const router = express.Router();

router.get('/', async (_req, res) => {
  const { rows } = await pool.query(
    'SELECT id, name, logo_key FROM banks WHERE deleted_at IS NULL ORDER BY sort_order',
  );
  res.json({ data: rows });
});

module.exports = router;
