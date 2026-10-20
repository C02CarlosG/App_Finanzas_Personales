const { z, uuid } = require('../utils/schemas');
const { PULL_ORDER } = require('./entities');

const ZERO = '1970-01-01T00:00:00.000000Z|00000000-0000-0000-0000-000000000000';
const position = z.string().refine((s) => {
  const [t, id] = s.split('|');
  return /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/.test(t ?? '') && uuid.safeParse(id).success;
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
