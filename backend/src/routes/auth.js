const express = require('express');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const config = require('../config');
const { pool, withTransaction } = require('../db/pool');
const validate = require('../middleware/validate');
const auth = require('../middleware/auth');
const { AppError, notFound } = require('../utils/errors');
const { z } = require('../utils/schemas');
const { seedCategories } = require('../services/seedCategories');

const router = express.Router();

const email = z.string().trim().toLowerCase().email().max(254);
const credentials = z.object({
  email,
  password: z.string().min(8, 'Mínimo 8 caracteres').max(128),
});
const registerBody = credentials.extend({ name: z.string().trim().min(1).max(100) });

const publicUser = (u) => ({ id: u.id, email: u.email, name: u.name, currency: u.currency, plan: u.plan });
const sign = (user) => jwt.sign({ sub: user.id }, config.jwtSecret, { algorithm: 'HS256', expiresIn: config.jwtExpiresIn });

// Hash válido para igualar tiempos cuando el correo no existe.
const DUMMY_HASH = bcrypt.hashSync('dummy-password', 10);

router.post('/register', validate({ body: registerBody }), async (req, res) => {
  const { email, password, name } = req.valid.body;
  const hash = await bcrypt.hash(password, config.bcryptRounds);
  const user = await withTransaction(async (client) => {
    const exists = await client.query('SELECT 1 FROM users WHERE lower(email) = $1 AND deleted_at IS NULL', [email]);
    if (exists.rowCount) throw new AppError(409, 'El correo ya está registrado', 'email_taken');
    const { rows } = await client.query(
      'INSERT INTO users (email, password_hash, name) VALUES ($1, $2, $3) RETURNING *',
      [email, hash, name],
    );
    await seedCategories(client, rows[0].id);
    return rows[0];
  });
  res.status(201).json({ token: sign(user), user: publicUser(user) });
});

router.post('/login', validate({ body: credentials }), async (req, res) => {
  const { email, password } = req.valid.body;
  const { rows } = await pool.query('SELECT * FROM users WHERE lower(email) = $1 AND deleted_at IS NULL', [email]);
  const user = rows[0];
  const ok = await bcrypt.compare(password, user ? user.password_hash : DUMMY_HASH);
  if (!user || !ok) throw new AppError(401, 'Credenciales inválidas', 'invalid_credentials');
  res.json({ token: sign(user), user: publicUser(user) });
});

router.get('/me', auth, async (req, res) => {
  const { rows } = await pool.query('SELECT * FROM users WHERE id = $1 AND deleted_at IS NULL', [req.userId]);
  if (!rows[0]) throw notFound('Usuario');
  res.json({ user: publicUser(rows[0]) });
});

module.exports = router;
