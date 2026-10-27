class AppError extends Error {
  constructor(status, message, code, { retryAfter } = {}) {
    super(message);
    this.status = status;
    this.code = code;
    this.retryAfter = retryAfter; // segundos; se envía como encabezado Retry-After
  }
}

const notFound = (what = 'Recurso') => new AppError(404, `${what} no encontrado`, 'not_found');

module.exports = { AppError, notFound };
