const { Pool, types } = require('pg');
const config = require('../config');

// DATE como 'YYYY-MM-DD' (sin conversión a Date/zona horaria). NUMERIC se queda como string.
types.setTypeParser(1082, (v) => v);

const pool = new Pool({ connectionString: config.databaseUrl });

async function withTransaction(fn, beginSql = 'BEGIN') {
  const client = await pool.connect();
  try {
    await client.query(beginSql);
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }
}

module.exports = { pool, withTransaction };
