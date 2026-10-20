const jwt = require('jsonwebtoken');
const config = require('../config');
const { AppError } = require('../utils/errors');

module.exports = (req, _res, next) => {
  const header = req.headers.authorization || '';
  const [scheme, token] = header.split(' ');
  if (scheme !== 'Bearer' || !token) throw new AppError(401, 'Token requerido', 'unauthorized');
  try {
    const payload = jwt.verify(token, config.jwtSecret, { algorithms: ['HS256'] });
    req.userId = payload.sub;
    next();
  } catch {
    throw new AppError(401, 'Token inválido o expirado', 'unauthorized');
  }
};
