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
const perTable = z.object(Object.fromEntries(PULL_ORDER.map((t) => [t, position.optional()]))).strict();
// `_marks`: hasta qué punto de purga de tombstones ya está al día este cliente (docs/sync.md §7).
const cursorShape = perTable.extend({ _marks: perTable.optional() }).strict();

const zeros = () => Object.fromEntries(PULL_ORDER.map((t) => [t, ZERO]));

// Cursor opaco en base64url: posición (updated_at µs | id) por tabla + marcas de purga.
// Sin cursor = sincronización inicial (`initial`). Devuelve null si está mal formado.
function decode(cursor) {
  if (!cursor) return { positions: zeros(), marks: zeros(), initial: true };
  try {
    const { _marks, ...positions } = cursorShape.parse(JSON.parse(Buffer.from(cursor, 'base64url').toString('utf8')));
    return { positions: { ...zeros(), ...positions }, marks: { ...zeros(), ..._marks }, initial: false };
  } catch {
    return null;
  }
}

const encode = (positions, marks) => Buffer.from(JSON.stringify({ ...positions, _marks: marks }), 'utf8').toString('base64url');

// Las posiciones tienen formato fijo (µs, UTC) y los UUID se comparan en minúsculas: basta comparar texto.
const later = (a, b) => (a.toLowerCase() >= b.toLowerCase() ? a : b);

module.exports = { decode, encode, later, ZERO };
