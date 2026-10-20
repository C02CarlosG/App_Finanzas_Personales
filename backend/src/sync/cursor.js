const { z, uuid } = require('../utils/schemas');
const { PULL_ORDER } = require('./entities');

const ZERO = '1970-01-01T00:00:00.000000Z|00000000-0000-0000-0000-000000000000';
// Fecha real (ida y vuelta por Date descarta 2026-02-30, mes 13, etc.) y UUID válido.
const position = z.string().refine((s) => {
  const [t, id] = s.split('|');
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/.test(t ?? '')) return false;
  const ms = `${t.slice(0, 23)}Z`;
  const d = new Date(ms);
  return !Number.isNaN(d.getTime()) && d.toISOString() === ms && d.getUTCFullYear() >= 1970 && uuid.safeParse(id).success;
});
const cursorShape = z.object(Object.fromEntries(PULL_ORDER.map((t) => [t, position.optional()]))).strict();

// Cursor opaco: posición (updated_at µs | id) por tabla, en base64url.
function decode(cursor) {
  const positions = Object.fromEntries(PULL_ORDER.map((t) => [t, ZERO]));
  if (!cursor) return positions;
  try {
    const parsed = cursorShape.parse(JSON.parse(Buffer.from(cursor, 'base64url').toString('utf8')));
    return { ...positions, ...parsed };
  } catch {
    return null;
  }
}

const encode = (positions) => Buffer.from(JSON.stringify(positions), 'utf8').toString('base64url');

module.exports = { decode, encode };
