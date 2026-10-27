const { ZodError } = require('zod');
const { AppError } = require('../utils/errors');

// eslint-disable-next-line no-unused-vars
module.exports = (err, _req, res, _next) => {
  if (err instanceof ZodError) {
    return res.status(400).json({
      error: 'Datos inválidos',
      code: 'validation_error',
      details: err.issues.map((i) => ({ path: i.path.join('.'), message: i.message })),
    });
  }
  if (err instanceof AppError) {
    if (err.retryAfter) res.set('Retry-After', String(err.retryAfter));
    return res.status(err.status).json({ error: err.message, code: err.code });
  }
  if (err.type === 'entity.parse.failed') {
    return res.status(400).json({ error: 'JSON inválido', code: 'bad_json' });
  }
  if (err.code === '40P01' || err.code === '55P03') {
    return res.status(503).json({ error: 'Servidor ocupado; reintenta', code: 'retry_later' });
  }
  if (err.code === '23505') return res.status(409).json({ error: 'Registro duplicado', code: 'conflict' });
  if (err.code === '23503') return res.status(409).json({ error: 'Referencia inválida', code: 'conflict' });
  console.error(err);
  res.status(500).json({ error: 'Error interno', code: 'internal' });
};
