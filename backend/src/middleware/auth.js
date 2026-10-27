const jwt = require('jsonwebtoken');
const config = require('../config');
const { pool } = require('../db/pool');
const { AppError } = require('../utils/errors');
const { uuid } = require('../utils/schemas');

// Valida la firma y además que el usuario siga existiendo y que el token no haya sido revocado
// (cambio de contraseña / cerrar sesión en todos los dispositivos suben users.token_version).
// Cuesta una lectura por clave primaria por petición.
module.exports = async (req, _res, next) => {
  const header = req.headers.authorization || '';
  const [scheme, token] = header.split(' ');
  if (scheme !== 'Bearer' || !token) throw new AppError(401, 'Token requerido', 'unauthorized');
  let payload;
  try {
    payload = jwt.verify(token, config.jwtSecret, { algorithms: ['HS256'] });
  } catch {
    throw new AppError(401, 'Token inválido o expirado', 'unauthorized');
  }
  if (!uuid.safeParse(payload.sub).success) throw new AppError(401, 'Token inválido o expirado', 'unauthorized');
  const { rows } = await pool.query('SELECT token_version FROM users WHERE id = $1 AND deleted_at IS NULL', [payload.sub]);
  // Los tokens emitidos antes de la migración 005 no traen "ver": equivalen a la versión 0.
  if (!rows[0] || rows[0].token_version !== (payload.ver ?? 0)) {
    throw new AppError(401, 'Sesión cerrada o expirada', 'unauthorized');
  }
  req.userId = payload.sub;
  next();
};
