class AppError extends Error {
  constructor(status, message, code) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

const notFound = (what = 'Recurso') => new AppError(404, `${what} no encontrado`, 'not_found');

module.exports = { AppError, notFound };
