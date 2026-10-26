const { z } = require('zod');

// Dinero: se acepta string o número, pero siempre con máximo 2 decimales y se
// maneja como string decimal (NUMERIC en PostgreSQL). Nunca se opera con float.
const decimal = (re) =>
  z.union([z.string(), z.number()])
    .transform((v) => String(v).trim())
    .refine((v) => re.test(v), 'Monto inválido: máximo 12 enteros y 2 decimales');

const money = decimal(/^\d{1,12}(\.\d{1,2})?$/)
  .refine((v) => Number(v) > 0, 'El monto debe ser mayor a 0');

const signedMoney = decimal(/^-?\d{1,12}(\.\d{1,2})?$/);

// Cero permitido (p. ej. una tarjeta sin saldo pendiente); nunca negativo.
const nonNegativeMoney = decimal(/^\d{1,12}(\.\d{1,2})?$/);

const uuid = z.string().uuid();
const isoDate = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Fecha inválida (YYYY-MM-DD)')
  .refine((v) => !Number.isNaN(Date.parse(`${v}T00:00:00Z`)) &&
    new Date(`${v}T00:00:00Z`).toISOString().startsWith(v), 'Fecha inválida');
const month = z.string().regex(/^\d{4}-(0[1-9]|1[0-2])$/, 'Mes inválido (YYYY-MM)');

const idParams = z.object({ id: uuid });

module.exports = { z, money, nonNegativeMoney, signedMoney, uuid, isoDate, month, idParams };
