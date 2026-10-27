const { Pool, types } = require('pg');
const config = require('../config');

// DATE como 'YYYY-MM-DD' (sin conversión a Date/zona horaria). NUMERIC se queda como string.
types.setTypeParser(1082, (v) => v);

const pool = new Pool({ connectionString: config.databaseUrl });

// Una conexión ociosa puede caerse (reinicio o mantenimiento de la BD, o una BD gratuita que se suspende): el pool lo avisa
// con 'error' y, sin escuchador, Node lo trata como excepción no capturada y tumba el API. El pool descarta ese cliente y
// abre otro cuando haga falta.
pool.on('error', (err) => console.error('Se perdió una conexión ociosa a PostgreSQL (el pool abrirá otra):', err.message));

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
