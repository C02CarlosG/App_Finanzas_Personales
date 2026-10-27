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
const { entitlementsFor } = require('../services/plans');
const { deleteUserData } = require('../services/deleteUserData');
const limiters = require('../services/attemptLimiter');

const router = express.Router();

const email = z.string().trim().toLowerCase().email().max(254);
const personName = z.string().trim().min(1).max(100);
const credentials = z.object({
  email,
  password: z.string().min(8, 'Mínimo 8 caracteres').max(128),
});
const registerBody = credentials.extend({ name: personName });

const newPassword = z.string().min(8, 'Mínimo 8 caracteres').max(128);
const confirmPassword = z.string().min(1).max(128);

const publicUser = (u) => ({
  id: u.id, email: u.email, name: u.name, currency: u.currency, plan: u.plan,
  entitlements: entitlementsFor(u.plan),
});
// "ver" liga el token a users.token_version: subirla revoca todos los tokens anteriores.
const sign = (user) => jwt.sign({ sub: user.id, ver: user.token_version }, config.jwtSecret,
  { algorithm: 'HS256', expiresIn: config.jwtExpiresIn });

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
  const emailKey = `${email}|${req.ip}`;
  const ipKey = req.ip;
  // Se revisan los límites antes de gastar bcrypt: un atacante bloqueado no cuesta CPU.
  limiters.loginByIp.check(ipKey);
  limiters.loginByEmail.check(emailKey);
  const { rows } = await pool.query('SELECT * FROM users WHERE lower(email) = $1 AND deleted_at IS NULL', [email]);
  const user = rows[0];
  const ok = await bcrypt.compare(password, user ? user.password_hash : DUMMY_HASH);
  if (!user || !ok) {
    limiters.loginByIp.fail(ipKey);
    limiters.loginByEmail.fail(emailKey);
    throw new AppError(401, 'Credenciales inválidas', 'invalid_credentials');
  }
  limiters.loginByEmail.clear(emailKey);
  res.json({ token: sign(user), user: publicUser(user) });
});

router.get('/me', auth, async (req, res) => {
  const { rows } = await pool.query('SELECT * FROM users WHERE id = $1 AND deleted_at IS NULL', [req.userId]);
  if (!rows[0]) throw notFound('Usuario');
  res.json({ user: publicUser(rows[0]) });
});

// Confirma la contraseña de la sesión actual (acciones sensibles). Un error de contraseña responde
// 403 y NO 401: el cliente interpreta 401 como "sesión vencida" y cerraría la sesión.
async function confirmPasswordOf(client, userId, password) {
  limiters.passwordByUser.check(userId);
  const { rows } = await client.query('SELECT * FROM users WHERE id = $1 AND deleted_at IS NULL FOR UPDATE', [userId]);
  const user = rows[0];
  if (!user) throw notFound('Usuario');
  if (!(await bcrypt.compare(password, user.password_hash))) {
    limiters.passwordByUser.fail(userId);
    throw new AppError(403, 'La contraseña no es correcta', 'invalid_password');
  }
  limiters.passwordByUser.clear(userId);
  return user;
}

router.patch('/me', auth, validate({ body: z.object({ name: personName }) }), async (req, res) => {
  const { rows } = await pool.query(
    'UPDATE users SET name = $2 WHERE id = $1 AND deleted_at IS NULL RETURNING *', [req.userId, req.valid.body.name]);
  if (!rows[0]) throw notFound('Usuario');
  res.json({ user: publicUser(rows[0]) });
});

router.post('/email', auth, validate({ body: z.object({ email, password: confirmPassword }) }), async (req, res) => {
  const { email: newEmail, password } = req.valid.body;
  const user = await withTransaction(async (client) => {
    const current = await confirmPasswordOf(client, req.userId, password);
    if (current.email.toLowerCase() === newEmail) return current;
    const taken = await client.query(
      'SELECT 1 FROM users WHERE lower(email) = $1 AND deleted_at IS NULL AND id <> $2', [newEmail, req.userId]);
    if (taken.rowCount) throw new AppError(409, 'El correo ya está registrado', 'email_taken');
    const { rows } = await client.query('UPDATE users SET email = $2 WHERE id = $1 RETURNING *', [req.userId, newEmail]);
    return rows[0];
  }).catch((err) => {
    // Dos cambios simultáneos al mismo correo: el índice único decide.
    if (err.code === '23505') throw new AppError(409, 'El correo ya está registrado', 'email_taken');
    throw err;
  });
  res.json({ user: publicUser(user) });
});

// Cambia la contraseña y revoca todas las sesiones; devuelve un token nuevo para este dispositivo.
router.post('/password', auth, validate({
  body: z.object({ current_password: confirmPassword, new_password: newPassword }),
}), async (req, res) => {
  const { current_password: current, new_password: next } = req.valid.body;
  if (current === next) throw new AppError(400, 'La nueva contraseña debe ser distinta', 'same_password');
  const hash = await bcrypt.hash(next, config.bcryptRounds);
  const user = await withTransaction(async (client) => {
    await confirmPasswordOf(client, req.userId, current);
    const { rows } = await client.query(
      'UPDATE users SET password_hash = $2, token_version = token_version + 1 WHERE id = $1 RETURNING *',
      [req.userId, hash]);
    return rows[0];
  });
  res.json({ token: sign(user), user: publicUser(user) });
});

// Revoca todos los tokens, incluido el de este dispositivo (el cliente cierra su sesión local).
router.post('/logout-all', auth, async (req, res) => {
  await pool.query('UPDATE users SET token_version = token_version + 1 WHERE id = $1', [req.userId]);
  res.status(204).end();
});

// Borra la cuenta y todos sus datos. POST y no DELETE: algunos proxies descartan el cuerpo de DELETE.
router.post('/delete-account', auth, validate({ body: z.object({ password: confirmPassword }) }), async (req, res) => {
  await withTransaction(async (client) => {
    await confirmPasswordOf(client, req.userId, req.valid.body.password);
    await deleteUserData(client, req.userId);
  });
  res.status(204).end();
});

module.exports = router;
