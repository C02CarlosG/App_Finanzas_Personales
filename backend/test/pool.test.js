const { describe, it, before, after, mock } = require('node:test');
const assert = require('node:assert/strict');
const { setup, teardown } = require('./helpers');
const { pool } = require('../src/db/pool');

describe('pool de conexiones', () => {
  before(setup);
  after(teardown);

  it('una conexión ociosa que se cae no tumba el proceso', () => {
    // Sin escuchador de 'error', emit() lanza la excepción (en producción: proceso caído).
    const log = mock.method(console, 'error', () => {});
    try {
      assert.doesNotThrow(() => pool.emit('error', new Error('terminating connection due to administrator command')));
      assert.equal(log.mock.callCount(), 1);
    } finally {
      log.mock.restore();
    }
  });

  it('sigue atendiendo consultas después del aviso', async () => {
    const { rows } = await pool.query('SELECT 1 AS ok');
    assert.equal(rows[0].ok, 1);
  });
});
