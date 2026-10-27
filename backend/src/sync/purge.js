const config = require('../config');
const { pool } = require('../db/pool');

// Tablas de usuario en orden hijos → padres, con las filas que las referencian por FK. Un tombstone no se
// purga mientras algo (vivo o tombstone más nuevo) lo siga apuntando; se purgará en una corrida posterior.
const PURGE_PLAN = [
  { table: 'loan_movements', referencedBy: [] },
  { table: 'credit_card_payments', referencedBy: [] },
  { table: 'budgets', referencedBy: [] },
  { table: 'subscriptions', referencedBy: [] },
  { table: 'transactions', referencedBy: [['loan_movements', 'transaction_id'], ['credit_card_payments', 'transaction_id']] },
  { table: 'credit_cards', referencedBy: [['credit_card_payments', 'credit_card_id']] },
  { table: 'loans', referencedBy: [['loan_movements', 'loan_id'], ['transactions', 'loan_id']] },
  { table: 'accounts', referencedBy: [['transactions', 'account_id'], ['subscriptions', 'account_id'], ['credit_card_payments', 'account_id']] },
  { table: 'categories', referencedBy: [['transactions', 'category_id'], ['budgets', 'category_id']] },
];

const DAY_MS = 24 * 60 * 60 * 1000;
const LOCK_KEY = 70_001; // pg_advisory_lock: una sola instancia del API purga a la vez

// Borra un lote de tombstones y, en la MISMA sentencia (atómica), sube la marca de purga del usuario.
const purgeSql = ({ table, referencedBy }) => `
  WITH doomed AS (
    SELECT t.id FROM ${table} t
     WHERE t.deleted_at IS NOT NULL AND t.updated_at < $1
       ${referencedBy.map(([child, col]) => `AND NOT EXISTS (SELECT 1 FROM ${child} c WHERE c.${col} = t.id)`).join('\n       ')}
     ORDER BY t.updated_at, t.id LIMIT $3
       FOR UPDATE OF t SKIP LOCKED
  ), del AS (
    DELETE FROM ${table} t USING doomed WHERE t.id = doomed.id
    RETURNING t.user_id, t.updated_at, t.id
  ), mark AS (
    INSERT INTO sync_purge_watermarks (user_id, table_name, updated_at, id)
    SELECT DISTINCT ON (user_id) user_id, $2, updated_at, id FROM del ORDER BY user_id, updated_at DESC, id DESC
    ON CONFLICT (user_id, table_name) DO UPDATE SET updated_at = EXCLUDED.updated_at, id = EXCLUDED.id
      WHERE (EXCLUDED.updated_at, EXCLUDED.id) > (sync_purge_watermarks.updated_at, sync_purge_watermarks.id)
  )
  SELECT count(*)::int AS n FROM del`;

/** Purga los tombstones con más de `retentionDays` días sin cambios. `retentionDays` <= 0 desactiva la purga. */
async function purgeTombstones({ retentionDays = config.tombstoneRetentionDays, now = new Date(), batchSize = 1000 } = {}) {
  const purged = {};
  if (!(retentionDays > 0)) return purged;
  const cutoff = new Date(now.getTime() - retentionDays * DAY_MS);
  for (const step of PURGE_PLAN) {
    const sql = purgeSql(step);
    purged[step.table] = 0;
    for (;;) {
      const { rows } = await pool.query(sql, [cutoff, step.table, batchSize]);
      purged[step.table] += rows[0].n;
      if (rows[0].n < batchSize) break;
    }
  }
  return purged;
}

/** Igual, pero solo si ninguna otra instancia del API está purgando (candado de sesión en PostgreSQL). */
async function purgeWithLock(options) {
  const client = await pool.connect();
  try {
    const { rows } = await client.query('SELECT pg_try_advisory_lock($1) AS ok', [LOCK_KEY]);
    if (!rows[0].ok) return null;
    try {
      return await purgeTombstones(options);
    } finally {
      await client.query('SELECT pg_advisory_unlock($1)', [LOCK_KEY]);
    }
  } finally {
    client.release();
  }
}

/** Corre la purga poco después de arrancar y luego cada 24 h. Los errores se registran, no tumban el API. */
function startPurgeScheduler({ intervalMs = DAY_MS, initialDelayMs = 60_000, log = console } = {}) {
  if (!(config.tombstoneRetentionDays > 0)) return null;
  const run = () => purgeWithLock()
    .then((purged) => {
      const total = purged ? Object.values(purged).reduce((a, b) => a + b, 0) : 0;
      if (total) log.log(`Purga de tombstones: ${total} registros (${JSON.stringify(purged)})`);
    })
    .catch((err) => log.error('Purga de tombstones falló:', err));
  const first = setTimeout(() => { run(); }, initialDelayMs);
  const every = setInterval(run, intervalMs);
  first.unref();
  every.unref();
  return () => { clearTimeout(first); clearInterval(every); };
}

module.exports = { purgeTombstones, purgeWithLock, startPurgeScheduler, PURGE_PLAN };

if (require.main === module) {
  purgeWithLock()
    .then((purged) => console.log(purged ? `Purga terminada: ${JSON.stringify(purged)}` : 'Otra instancia está purgando'))
    .catch((err) => { console.error(err); process.exitCode = 1; })
    .finally(() => pool.end());
}
