const { test, before, beforeEach, after } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const h = require('./helpers');
const { pool } = require('../src/db/pool');
const cursor = require('../src/sync/cursor');
const { purgeTombstones, purgeWithLock, startPurgeScheduler, PURGE_PLAN } = require('../src/sync/purge');
const { PULL_ORDER } = require('../src/sync/entities');

before(h.setup);
beforeEach(h.reset);
after(h.teardown);

const uid = () => crypto.randomUUID();
const at = (s) => `2026-01-15T${s}Z`;
const push = (u, changes) => u.post('/sync/push').send({ changes });
const pull = (u, query = '') => u.get(`/sync/pull${query}`);
const change = (table, id, data, ts = at('10:00:00.000')) => ({ table, id, client_updated_at: ts, data });
const remove = (table, id, ts = at('23:00:00.000')) => ({ table, id, client_updated_at: ts, deleted: true });
const acct = (name = 'Cartera') => ({ type: 'efectivo', name, initial_balance: '0' });
const fresh = (ms) => new Date(Date.now() + ms).toISOString(); // sello más nuevo que el de la siembra

// Mueve updated_at al pasado (el trigger lo pisaría con now(), por eso se apaga un momento).
async function backdate(table, id, days) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query(`ALTER TABLE ${table} DISABLE TRIGGER USER`);
    await client.query(`UPDATE ${table} SET updated_at = now() - make_interval(days => $2) WHERE id = $1`, [id, days]);
    await client.query(`ALTER TABLE ${table} ENABLE TRIGGER USER`);
    await client.query('COMMIT');
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }
}

// Crea un registro y lo borra; devuelve su id (ya como tombstone en el servidor).
async function tombstone(u, table, data, { days } = {}) {
  const id = uid();
  await push(u, [change(table, id, data, fresh(1000))]).expect(200);
  const res = await push(u, [remove(table, id, fresh(2000))]).expect(200);
  assert.equal(res.body.results[0].status, 'applied');
  if (days) await backdate(table, id, days);
  return id;
}

const exists = async (table, id) => (await pool.query(`SELECT 1 FROM ${table} WHERE id = $1`, [id])).rowCount === 1;
const watermark = async (u, table) => (await pool.query(
  'SELECT id FROM sync_purge_watermarks WHERE user_id = $1 AND table_name = $2', [u.user.id, table])).rows[0];
const inDays = (days) => new Date(Date.now() + days * 24 * 60 * 60 * 1000);
// "Hoy + 200 días": con el límite de 180, todo lo borrado hasta ahora ya es purgable, conservando el orden real de updated_at.
const purgeAll = () => purgeTombstones({ now: inDays(200) });
const total = (purged) => Object.values(purged).reduce((a, b) => a + b, 0);

// Descarga todo y devuelve el cursor final (como haría un dispositivo al día).
async function fullSync(u, limit = 500) {
  let cur;
  for (;;) {
    const res = await pull(u, `?limit=${limit}${cur ? `&cursor=${cur}` : ''}`).expect(200);
    cur = res.body.next_cursor;
    if (!res.body.has_more) return cur;
  }
}

test('purga solo los tombstones viejos: ni los vivos ni los recientes se tocan', async () => {
  const u = await h.registerUser();
  const old = await tombstone(u, 'accounts', acct('vieja'), { days: 200 });
  const recent = await tombstone(u, 'accounts', acct('reciente'), { days: 100 });
  const live = uid();
  await push(u, [change('accounts', live, acct('viva'), fresh(1000))]).expect(200);
  await backdate('accounts', live, 400); // vieja pero viva: no es tombstone

  const purged = await purgeTombstones();
  assert.equal(purged.accounts, 1);
  assert.equal(total(purged), 1);
  assert.equal(await exists('accounts', old), false);
  assert.equal(await exists('accounts', recent), true);
  assert.equal(await exists('accounts', live), true);
  assert.equal(total(await purgeTombstones()), 0, 'idempotente');
});

test('el límite es configurable y retentionDays <= 0 desactiva la purga', async () => {
  const u = await h.registerUser();
  const id = await tombstone(u, 'accounts', acct(), { days: 50 });
  assert.equal(total(await purgeTombstones({ retentionDays: 0 })), 0);
  assert.equal(total(await purgeTombstones({ retentionDays: -5 })), 0);
  assert.equal(total(await purgeTombstones({ retentionDays: 60 })), 0);
  assert.equal(await exists('accounts', id), true);
  assert.equal(total(await purgeTombstones({ retentionDays: 30 })), 1);
  assert.equal(await exists('accounts', id), false);
});

test('la purga por lotes borra todo y deja como marca el tombstone más nuevo (por usuario y tabla)', async () => {
  const u = await h.registerUser();
  const ids = [];
  for (let i = 0; i < 5; i += 1) ids.push(await tombstone(u, 'accounts', acct(`c${i}`), { days: 300 - i * 10 }));
  const newest = ids[4]; // el que tiene menos días de antigüedad
  const purged = await purgeTombstones({ batchSize: 2 });
  assert.equal(purged.accounts, 5);
  for (const id of ids) assert.equal(await exists('accounts', id), false);
  assert.equal((await watermark(u, 'accounts')).id, newest);
  assert.equal(await watermark(u, 'categories'), undefined, 'solo se marca la tabla purgada');
});

test('una cuenta tombstone espera a que su transacción también envejezca; al purgarse caen juntas (hijos antes que padres)', async () => {
  const u = await h.registerUser();
  const acc = uid();
  const tx = uid();
  const cat = await h.categoryId(u, 'expense', 'Alimentación');
  await push(u, [
    change('accounts', acc, acct(), fresh(1000)),
    change('transactions', tx, { type: 'expense', amount: '10', account_id: acc, category_id: cat, occurred_on: '2026-10-19', description: null, counterparty: null }, fresh(1000)),
  ]).expect(200);
  await push(u, [remove('transactions', tx, fresh(2000))]).expect(200);
  await push(u, [remove('accounts', acc, fresh(2000))]).expect(200);
  await backdate('accounts', acc, 200);
  await backdate('transactions', tx, 10); // la transacción es reciente
  assert.equal(total(await purgeTombstones()), 0);
  assert.equal(await exists('accounts', acc), true, 'la cuenta sigue porque una transacción la referencia');
  await backdate('transactions', tx, 190);
  const purged = await purgeTombstones();
  assert.deepEqual([purged.transactions, purged.accounts], [1, 1]);
  assert.equal(await exists('accounts', acc), false);
});

test('la marca de purga nunca retrocede aunque después se purgue un tombstone más viejo que estaba bloqueado', async () => {
  const u = await h.registerUser();
  const cat = await h.categoryId(u, 'expense', 'Alimentación');
  const blocked = uid(); const other = uid(); const tx = uid();
  await push(u, [
    change('accounts', blocked, acct('bloqueada'), fresh(1000)),
    change('accounts', other, acct('otra'), fresh(1000)),
    change('transactions', tx, { type: 'expense', amount: '10', account_id: blocked, category_id: cat, occurred_on: '2026-10-19', description: null, counterparty: null }, fresh(1000)),
  ]).expect(200);
  await push(u, [remove('transactions', tx, fresh(2000)), remove('accounts', blocked, fresh(2000)), remove('accounts', other, fresh(2000))]).expect(200);
  await backdate('accounts', blocked, 300); // la más vieja, pero bloqueada por una transacción reciente
  await backdate('accounts', other, 200);
  await backdate('transactions', tx, 5);
  assert.equal((await purgeTombstones()).accounts, 1);
  assert.equal((await watermark(u, 'accounts')).id, other);
  await backdate('transactions', tx, 250);
  assert.equal((await purgeTombstones()).accounts, 1);
  assert.equal(await exists('accounts', blocked), false);
  assert.equal((await watermark(u, 'accounts')).id, other, 'la marca sigue en la más nueva ya purgada');
});

test('un tombstone referenciado por filas vivas o por tombstones más nuevos no se purga (FK)', async () => {
  const u = await h.registerUser();
  const income = await h.categoryId(u, 'income', 'Préstamo cobrado');
  const acc = uid(); const loan = uid(); const tx = uid(); const mov = uid();
  await push(u, [
    change('accounts', acc, acct(), fresh(1000)),
    change('loans', loan, { person_name: 'Luis', direction: 'owed_to_me', principal: '500', due_date: null, status: 'active', notes: null }, fresh(1000)),
    change('transactions', tx, { type: 'income', amount: '100', account_id: acc, category_id: income, occurred_on: '2026-10-19', description: null, counterparty: 'Luis' }, fresh(1000)),
    change('loan_movements', mov, { loan_id: loan, kind: 'payment', amount: '100', occurred_on: '2026-10-19', transaction_id: tx }, fresh(1000)),
  ]).expect(200);
  // Por SQL (el servidor no deja borrar esto vía sync): tombstones viejos con un movimiento vivo que los apunta.
  await pool.query('UPDATE transactions SET deleted_at = now() WHERE id = $1', [tx]);
  await pool.query('UPDATE loans SET deleted_at = now() WHERE id = $1', [loan]);
  await pool.query('UPDATE accounts SET deleted_at = now() WHERE id = $1', [acc]);
  for (const [t, id] of [['transactions', tx], ['loans', loan], ['accounts', acc]]) await backdate(t, id, 400);

  assert.equal(total(await purgeTombstones()), 0);
  for (const [t, id] of [['transactions', tx], ['loans', loan], ['accounts', acc], ['loan_movements', mov]]) assert.equal(await exists(t, id), true, t);

  // Cuando el movimiento también es un tombstone viejo, cae todo (hijo → padres) sin violar FKs.
  await pool.query('UPDATE loan_movements SET deleted_at = now() WHERE id = $1', [mov]);
  await backdate('loan_movements', mov, 400);
  const purged = await purgeTombstones();
  assert.deepEqual([purged.loan_movements, purged.transactions, purged.loans, purged.accounts], [1, 1, 1, 1]);
});

test('PURGE_PLAN cubre todas las entidades sincronizables de usuario, hijos antes que padres', () => {
  const { ENTITIES } = require('../src/sync/entities');
  assert.deepEqual(PURGE_PLAN.map((p) => p.table).sort(), Object.keys(ENTITIES).sort());
  const order = PURGE_PLAN.map((p) => p.table);
  for (const { table, referencedBy } of PURGE_PLAN) {
    for (const [child] of referencedBy) assert.ok(order.indexOf(child) < order.indexOf(table), `${child} debe purgarse antes que ${table}`);
  }
});

test('cursor anterior a una purga que no alcanzó a ver → 410 resync_required', async () => {
  const u = await h.registerUser();
  await tombstone(u, 'accounts', acct('a'));
  const before = await fullSync(u); // el cliente ya está al día y su cursor queda aquí
  await tombstone(u, 'accounts', acct('b')); // se crea y se borra después de ese cursor
  const purged = await purgeAll();
  assert.equal(purged.accounts, 2);

  const res = await pull(u, `?cursor=${before}`).expect(410);
  assert.equal(res.body.code, 'resync_required');
});

test('un cursor al día respecto a lo purgado no recibe 410 (el cliente ya había visto esos tombstones)', async () => {
  const u = await h.registerUser();
  await tombstone(u, 'accounts', acct('a'));
  const current = await fullSync(u); // ve el tombstone antes de la purga
  await purgeAll();
  const res = await pull(u, `?cursor=${current}`).expect(200);
  assert.equal(res.body.changes.accounts.length, 0);
  // y puede seguir sincronizando con el cursor que le devolvió
  const again = await pull(u, `?cursor=${res.body.next_cursor}`).expect(200);
  assert.equal(again.body.has_more, false);
});

test('sincronización inicial después de una purga: no trae lo purgado, y su cursor siguiente no da 410 aunque las filas sean más viejas que la marca', async () => {
  const u = await h.registerUser();
  const keep = uid();
  await push(u, [change('accounts', keep, acct('viva'), fresh(1000))]).expect(200); // viva y MÁS vieja que el tombstone
  await tombstone(u, 'accounts', acct('a'));
  await purgeAll();

  const first = await pull(u).expect(200);
  assert.deepEqual(first.body.changes.accounts.map((a) => a.id), [keep]);
  await pull(u, `?cursor=${first.body.next_cursor}`).expect(200);
});

test('sincronización inicial paginada con filas más viejas que la marca de purga nunca da 410', async () => {
  const u = await h.registerUser();
  const live = [];
  for (let i = 0; i < 5; i += 1) {
    const id = uid();
    await push(u, [change('accounts', id, acct(`viva${i}`), fresh(1000))]).expect(200);
    live.push(id);
  }
  await tombstone(u, 'accounts', acct('x'));
  await purgeAll();
  const seen = [];
  let cur;
  let pages = 0;
  for (; pages < 100; pages += 1) {
    const res = await pull(u, `?limit=2${cur ? `&cursor=${cur}` : ''}`).expect(200);
    seen.push(...res.body.changes.accounts.map((a) => a.id));
    cur = res.body.next_cursor;
    if (!res.body.has_more) break;
  }
  assert.ok(pages >= 2, 'la prueba debe paginar');
  assert.deepEqual(seen.sort(), live.sort());
});

test('si se purga algo que una sincronización inicial a medias aún no vio, la siguiente página pide reiniciar', async () => {
  const u = await h.registerUser();
  for (let i = 0; i < 3; i += 1) await push(u, [change('accounts', uid(), acct(`v${i}`), fresh(1000))]).expect(200);
  const first = await pull(u, '?limit=1').expect(200);
  assert.equal(first.body.has_more, true);
  await tombstone(u, 'accounts', acct('nueva')); // aparece (y se purga) después de la primera página
  await purgeAll();
  const res = await pull(u, `?limit=1&cursor=${first.body.next_cursor}`).expect(410);
  assert.equal(res.body.code, 'resync_required');
  // reiniciar desde cero siempre funciona
  const restart = await pull(u).expect(200);
  assert.ok(restart.body.next_cursor);
});

test('la purga de un usuario no afecta los cursores de otro ni los propios en otras tablas', async () => {
  const a = await h.registerUser();
  const b = await h.registerUser();
  await push(a, [change('accounts', uid(), acct(), fresh(1000))]).expect(200);
  const cursorA = await fullSync(a);
  await tombstone(b, 'accounts', acct('b'));
  await purgeAll();
  await pull(a, `?cursor=${cursorA}`).expect(200);

  // y las tablas inactivas de A no provocan 410 cuando se purga otra tabla de A que A sí había visto
  await tombstone(a, 'categories', { kind: 'expense', name: 'Temporal', icon: null, color: null });
  const cursorA2 = await fullSync(a);
  await purgeAll();
  await pull(a, `?cursor=${cursorA2}`).expect(200);
});

test('un cursor viejo sin marcas (formato anterior) funciona mientras no haya purgas, y se rechaza _marks mal formado', async () => {
  const u = await h.registerUser();
  const flat = Buffer.from(JSON.stringify({ accounts: `2026-01-01T00:00:00.000000Z|${uid()}` })).toString('base64url');
  await pull(u, `?cursor=${flat}`).expect(200);
  const bad = Buffer.from(JSON.stringify({ _marks: { accounts: 'x' } })).toString('base64url');
  assert.equal((await pull(u, `?cursor=${bad}`).expect(400)).body.code, 'invalid_cursor');
  const unknown = Buffer.from(JSON.stringify({ _marks: { otra: `2026-01-01T00:00:00.000000Z|${uid()}` } })).toString('base64url');
  await pull(u, `?cursor=${unknown}`).expect(400);
});

test('con un cursor de formato anterior (sin marcas) y una purga posterior, pide reiniciar', async () => {
  const u = await h.registerUser();
  await tombstone(u, 'accounts', acct('a'));
  await purgeAll();
  const flat = Buffer.from(JSON.stringify({ accounts: `2026-01-01T00:00:00.000000Z|${uid()}` })).toString('base64url');
  await pull(u, `?cursor=${flat}`).expect(410);
});

test('el peor cursor posible (todas las tablas con posición y marca) cabe en el límite de 4096', () => {
  const pos = `2026-12-31T23:59:59.999999Z|${uid()}`;
  const all = Object.fromEntries(PULL_ORDER.map((t) => [t, pos]));
  const encoded = cursor.encode(all, all);
  assert.ok(encoded.length < 4096, `mide ${encoded.length}`);
  const back = cursor.decode(encoded);
  assert.deepEqual(back.positions, all);
  assert.deepEqual(back.marks, all);
});

test('purgeWithLock no corre si otra instancia tiene el candado', async () => {
  const u = await h.registerUser();
  const id = await tombstone(u, 'accounts', acct(), { days: 200 });
  const other = await pool.connect();
  try {
    await other.query('SELECT pg_advisory_lock(70001)');
    assert.equal(await purgeWithLock(), null);
    assert.equal(await exists('accounts', id), true);
  } finally {
    await other.query('SELECT pg_advisory_unlock(70001)');
    other.release();
  }
  assert.equal(total(await purgeWithLock()), 1);
});

test('el programador purga por su cuenta y se detiene', async () => {
  const u = await h.registerUser();
  const id = await tombstone(u, 'accounts', acct(), { days: 200 });
  const logs = [];
  const stop = startPurgeScheduler({ initialDelayMs: 10, intervalMs: 60_000, log: { log: (m) => logs.push(m), error: (...m) => logs.push(m) } });
  assert.equal(typeof stop, 'function');
  for (let i = 0; i < 50 && await exists('accounts', id); i += 1) await new Promise((r) => setTimeout(r, 20));
  stop();
  assert.equal(await exists('accounts', id), false);
  assert.ok(logs.some((l) => String(l).includes('Purga de tombstones')), JSON.stringify(logs));
});
