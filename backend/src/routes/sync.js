const express = require('express');
const config = require('../config');
const { pool, withTransaction } = require('../db/pool');
const validate = require('../middleware/validate');
const { AppError } = require('../utils/errors');
const { z, uuid } = require('../utils/schemas');
const { ENTITIES, READONLY_CATALOGS, PULL_ORDER } = require('../sync/entities');
const cursor = require('../sync/cursor');
const { applyChanges } = require('../sync/push');

const router = express.Router();

const MAX_CHANGES = 200;

const pushBody = z.object({
  changes: z.array(z.object({
    table: z.enum(Object.keys(ENTITIES)),
    id: uuid,
    client_updated_at: z.iso.datetime({ offset: true }),
    deleted: z.boolean().default(false),
    data: z.record(z.string(), z.unknown()).optional(),
  }).strict()).max(MAX_CHANGES),
}).strict().superRefine((body, ctx) => {
  const seen = new Set();
  body.changes.forEach((c, i) => {
    const key = `${c.table}:${c.id}`;
    if (seen.has(key)) ctx.addIssue({ code: 'custom', path: ['changes', i], message: 'Registro repetido en el lote: envía solo su estado final' });
    seen.add(key);
  });
});

const pullQuery = z.object({
  cursor: z.string().max(2048).optional(),
  limit: z.coerce.number().int().min(1).max(1000).default(500),
});

router.post('/push', validate({ body: pushBody }), async (req, res) => {
  const { results, serverNow } = await withTransaction((client) => applyChanges(client, req.userId, req.valid.body.changes));
  res.json({ results, server_time: serverNow.toISOString() });
});

router.get('/pull', validate({ query: pullQuery }), async (req, res) => {
  const positions = cursor.decode(req.valid.query.cursor);
  if (!positions) throw new AppError(400, 'Cursor inválido', 'invalid_cursor');
  const { limit } = req.valid.query;
  const lag = Math.max(0, config.syncSafetyLagMs);

  // Una sola foto de la BD para todas las tablas de esta página.
  const { changes, nextPositions, hasMore, serverNow } = await withTransaction(async (client) => {
    const serverNow = (await client.query('SELECT now() AS now')).rows[0].now;
    const changes = {};
    const nextPositions = { ...positions };
    let hasMore = false;
    for (const name of PULL_ORDER) {
      const def = ENTITIES[name] ?? READONLY_CATALOGS[name];
      const [after, afterId] = positions[name].split('|');
      const scope = ENTITIES[name] ? 't.user_id = $5 AND ' : '';
      const params = [after, afterId, lag, limit, ...(ENTITIES[name] ? [req.userId] : [])];
      const { rows } = await client.query(
        `SELECT ${def.select} FROM ${def.table} t
         WHERE ${scope}(t.updated_at, t.id) > ($1::timestamptz, $2::uuid)
           AND t.updated_at <= now() - ($3 * interval '1 millisecond')
         ORDER BY t.updated_at, t.id LIMIT $4`, params);
      changes[name] = rows;
      if (rows.length) nextPositions[name] = `${rows[rows.length - 1].updated_at}|${rows[rows.length - 1].id}`;
      if (rows.length === limit) hasMore = true;
    }
    return { changes, nextPositions, hasMore, serverNow };
  }, 'BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');

  res.json({ changes, next_cursor: cursor.encode(nextPositions), has_more: hasMore, server_time: serverNow.toISOString() });
});

module.exports = router;
