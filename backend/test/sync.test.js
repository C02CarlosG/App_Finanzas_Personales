const { test, before, beforeEach, after } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const h = require('./helpers');
const config = require('../src/config');
const { pool } = require('../src/db/pool');

before(h.setup);
beforeEach(h.reset);
after(h.teardown);

const uid = () => crypto.randomUUID();
const at = (s) => `2026-01-15T${s}Z`; // at('10:00:00.000'): siempre en el pasado

const push = (u, changes) => u.post('/sync/push').send({ changes });
const pull = (u, query = '') => u.get(`/sync/pull${query}`);
const change = (table, id, data, ts, extra = {}) => ({ table, id, client_updated_at: ts, data, ...extra });
const remove = (table, id, ts = at('23:00:00.000')) => ({ table, id, client_updated_at: ts, deleted: true });

const acct = (over = {}) => ({ type: 'efectivo', name: 'Cartera', initial_balance: '100', ...over });
const txn = (accountId, categoryId, over = {}) => ({
  type: 'expense', amount: '50', account_id: accountId, category_id: categoryId, occurred_on: '2026-10-19', description: null, ...over,
});

// Usuario con una categoría de gasto propia, creada por sync.
async function setupDevice() {
  const u = await h.registerUser();
  const expenseCat = await h.categoryId(u, 'expense', 'Vivienda');
  const incomeCat = await h.categoryId(u, 'income', 'Freelance');
  return { u, expenseCat, incomeCat };
}

test('push crea cuenta y transacción en un lote (padres primero, sin importar el orden enviado)', async () => {
  const { u, expenseCat } = await setupDevice();
  const accId = uid(); const txId = uid();
  const res = await push(u, [
    change('transactions', txId, txn(accId, expenseCat), at('10:00:01.000')),
    change('accounts', accId, acct(), at('10:00:00.000')),
  ]).expect(200);
  assert.deepEqual(res.body.results.map((r) => [r.table, r.status]), [['transactions', 'applied'], ['accounts', 'applied']]);
  assert.equal(res.body.results[0].record.amount, '50.00');
  const balance = await u.get(`/accounts/${accId}`).expect(200);
  assert.equal(balance.body.balance, '50.00'); // 100 - 50
});

test('reintentar el mismo lote es idempotente: stale con el mismo registro, sin duplicados', async () => {
  const { u, expenseCat } = await setupDevice();
  const accId = uid(); const txId = uid();
  const batch = [
    change('accounts', accId, acct(), at('10:00:00.000')),
    change('transactions', txId, txn(accId, expenseCat), at('10:00:01.000')),
  ];
  const first = await push(u, batch).expect(200);
  const second = await push(u, batch).expect(200);
  assert.deepEqual(second.body.results.map((r) => r.status), ['stale', 'stale']);
  assert.deepEqual(second.body.results[1].record, first.body.results[1].record);
  assert.equal((await u.get('/transactions').expect(200)).body.data.length, 1);
});

test('last-write-wins por registro: gana el client_updated_at más reciente, llegue en el orden que llegue', async () => {
  const { u, expenseCat } = await setupDevice();
  const accId = uid(); const txId = uid();
  await push(u, [change('accounts', accId, acct(), at('09:00:00.000'))]).expect(200);
  await push(u, [change('transactions', txId, txn(accId, expenseCat, { amount: '10' }), at('10:00:00.000'))]).expect(200);

  // Dispositivo B (edición más nueva) llega primero; la de A (más vieja) llega después.
  const b = await push(u, [change('transactions', txId, txn(accId, expenseCat, { amount: '30' }), at('12:00:00.000'))]).expect(200);
  assert.equal(b.body.results[0].status, 'applied');
  const a = await push(u, [change('transactions', txId, txn(accId, expenseCat, { amount: '20' }), at('11:00:00.000'))]).expect(200);
  assert.equal(a.body.results[0].status, 'stale');
  assert.equal(a.body.results[0].record.amount, '30.00'); // A adopta la versión del servidor
  assert.equal((await u.get(`/transactions/${txId}`).expect(200)).body.amount, '30.00');
});

test('un empate exacto de client_updated_at lo gana quien llegó primero y el otro adopta el registro', async () => {
  const { u, expenseCat } = await setupDevice();
  const accId = uid(); const txId = uid();
  await push(u, [change('accounts', accId, acct(), at('09:00:00.000'))]).expect(200);
  await push(u, [change('transactions', txId, txn(accId, expenseCat, { amount: '10' }), at('10:00:00.000'))]).expect(200);
  const tie = await push(u, [change('transactions', txId, txn(accId, expenseCat, { amount: '99' }), at('10:00:00.000'))]).expect(200);
  assert.equal(tie.body.results[0].status, 'stale');
  assert.equal(tie.body.results[0].record.amount, '10.00');
});

test('tombstone gana a una edición posterior', async () => {
  const { u, expenseCat } = await setupDevice();
  const accId = uid(); const txId = uid();
  await push(u, [
    change('accounts', accId, acct(), at('09:00:00.000')),
    change('transactions', txId, txn(accId, expenseCat), at('10:00:00.000')),
  ]).expect(200);
  const del = await push(u, [remove('transactions', txId)]).expect(200);
  assert.equal(del.body.results[0].status, 'applied');
  assert.ok(del.body.results[0].record.deleted_at);
  const edit = await push(u, [change('transactions', txId, txn(accId, expenseCat, { amount: '77' }), at('23:59:00.000'))]).expect(200);
  assert.equal(edit.body.results[0].status, 'deleted');
  assert.ok(edit.body.results[0].record.deleted_at);
  await u.get(`/transactions/${txId}`).expect(404);
});

test('borrar un id desconocido o repetir un borrado es un no-op aplicado', async () => {
  const { u, expenseCat } = await setupDevice();
  const accId = uid(); const txId = uid();
  const unknown = await push(u, [remove('transactions', uid())]).expect(200);
  assert.deepEqual([unknown.body.results[0].status, unknown.body.results[0].record], ['applied', null]);
  await push(u, [change('accounts', accId, acct(), at('09:00:00.000')), change('transactions', txId, txn(accId, expenseCat), at('10:00:00.000'))]).expect(200);
  await push(u, [remove('transactions', txId)]).expect(200);
  const again = await push(u, [remove('transactions', txId)]).expect(200);
  assert.equal(again.body.results[0].status, 'applied');
});

test('borrar cuenta junto con sus transacciones en el mismo lote funciona (hijos primero)', async () => {
  const { u, expenseCat } = await setupDevice();
  const accId = uid(); const txId = uid();
  await push(u, [change('accounts', accId, acct(), at('09:00:00.000')), change('transactions', txId, txn(accId, expenseCat), at('10:00:00.000'))]).expect(200);
  const res = await push(u, [remove('accounts', accId), remove('transactions', txId)]).expect(200);
  assert.deepEqual(res.body.results.map((r) => r.status), ['applied', 'applied']);
  await u.get(`/accounts/${accId}`).expect(404);
});

test('borrar una cuenta que otro dispositivo ya usa se rechaza (in_use) y devuelve el registro vivo', async () => {
  const { u, expenseCat } = await setupDevice();
  const accId = uid(); const txId = uid();
  await push(u, [change('accounts', accId, acct(), at('09:00:00.000')), change('transactions', txId, txn(accId, expenseCat), at('10:00:00.000'))]).expect(200);
  const res = await push(u, [remove('accounts', accId)]).expect(200);
  assert.equal(res.body.results[0].status, 'rejected');
  assert.equal(res.body.results[0].code, 'in_use');
  assert.equal(res.body.results[0].record.deleted_at, null);
});

test('categorías del sistema no se borran ni renombran por sync', async () => {
  const { u } = await setupDevice();
  const loanId = await h.categoryId(u, 'income', 'Préstamo cobrado');
  const del = await push(u, [remove('categories', loanId)]).expect(200);
  assert.deepEqual([del.body.results[0].status, del.body.results[0].code], ['rejected', 'system_category']);
  const soon = (ms) => new Date(Date.now() + ms).toISOString(); // más nuevo que el sello de la siembra, sin pasar el límite de adelanto
  const ren = await push(u, [change('categories', loanId, { kind: 'income', name: 'Otro' }, soon(1000))]).expect(200);
  assert.deepEqual([ren.body.results[0].status, ren.body.results[0].code], ['rejected', 'system_category']);
  const color = await push(u, [change('categories', loanId, { kind: 'income', name: 'Préstamo cobrado', color: '#112233' }, soon(2000))]).expect(200);
  assert.equal(color.body.results[0].status, 'applied');
});

test('categoría con nombre duplicado: rejected duplicate_name con el id que ya existe', async () => {
  const { u, expenseCat } = await setupDevice();
  const res = await push(u, [change('categories', uid(), { kind: 'expense', name: 'vivienda' }, at('10:00:00.000'))]).expect(200);
  assert.equal(res.body.results[0].status, 'rejected');
  assert.equal(res.body.results[0].code, 'duplicate_name');
  assert.equal(res.body.results[0].conflicting_id, expenseCat);
});

test('un cambio inválido no afecta a los demás del lote', async () => {
  const { u, expenseCat, incomeCat } = await setupDevice();
  const accId = uid();
  const res = await push(u, [
    change('accounts', accId, acct(), at('09:00:00.000')),
    change('transactions', uid(), txn(accId, expenseCat, { amount: '10.999' }), at('10:00:00.000')),
    change('transactions', uid(), txn(accId, incomeCat), at('10:00:00.000')), // categoría de otro tipo
    change('transactions', uid(), txn(uid(), expenseCat), at('10:00:00.000')), // cuenta inexistente
    change('transactions', uid(), { ...txn(accId, expenseCat), extra: 1 }, at('10:00:00.000')), // campo desconocido
    change('transactions', uid(), txn(accId, expenseCat, { amount: 5 }), at('10:00:00.000')),
  ]).expect(200);
  assert.deepEqual(res.body.results.map((r) => r.code ?? r.status), [
    'applied', 'validation_error', 'category_kind_mismatch', 'invalid_reference', 'validation_error', 'applied']);
  assert.equal((await u.get('/transactions').expect(200)).body.data.length, 1);
});

test('campos inmutables: tipo/banco de cuenta y tipo de categoría', async () => {
  const { u } = await setupDevice();
  const accId = uid(); const catId = uid();
  await push(u, [change('accounts', accId, acct(), at('09:00:00.000')), change('categories', catId, { kind: 'expense', name: 'Mascotas' }, at('09:00:00.000'))]).expect(200);
  const res = await push(u, [
    change('accounts', accId, acct({ type: 'banco', bank_id: await h.bankId() }), at('10:00:00.000')),
    change('categories', catId, { kind: 'income', name: 'Mascotas' }, at('10:00:00.000')),
  ]).expect(200);
  assert.deepEqual(res.body.results.map((r) => r.code), ['immutable_field', 'immutable_field']);
});

test('aislamiento: otro usuario no puede editar ni borrar ni ver registros ajenos', async () => {
  const a = await setupDevice();
  const b = await setupDevice();
  const accId = uid();
  await push(a.u, [change('accounts', accId, acct(), at('09:00:00.000'))]).expect(200);
  const edit = await push(b.u, [change('accounts', accId, acct({ name: 'Hack' }), at('23:00:00.000'))]).expect(200);
  assert.deepEqual([edit.body.results[0].status, edit.body.results[0].code], ['invalid', 'invalid_id']);
  const del = await push(b.u, [remove('accounts', accId)]).expect(200);
  assert.deepEqual([del.body.results[0].status, del.body.results[0].record], ['applied', null]);
  assert.equal((await a.u.get(`/accounts/${accId}`).expect(200)).body.name, 'Cartera');
  const seen = await pull(b.u).expect(200);
  assert.ok(!seen.body.changes.accounts.some((r) => r.id === accId));
  // ni usar la cuenta ajena en una transacción propia
  const tx = await push(b.u, [change('transactions', uid(), txn(accId, b.expenseCat), at('10:00:00.000'))]).expect(200);
  assert.equal(tx.body.results[0].code, 'invalid_reference');
});

test('validación estructural del lote: repetidos, tabla desconocida, fecha mala, demasiados cambios', async () => {
  const { u } = await setupDevice();
  const id = uid();
  const ok = change('accounts', id, acct(), at('10:00:00.000'));
  await push(u, [ok, ok]).expect(400);
  await push(u, [{ ...ok, table: 'banks' }]).expect(400);
  await push(u, [{ ...ok, client_updated_at: 'ayer' }]).expect(400);
  await push(u, Array.from({ length: 201 }, () => change('accounts', uid(), acct(), at('10:00:00.000')))).expect(400);
  await u.post('/sync/push').send({}).expect(400);
  await h.api().post('/sync/push').send({ changes: [] }).expect(401);
});

test('un client_updated_at muy en el futuro se acota a la hora del servidor', async () => {
  const { u } = await setupDevice();
  const id = uid();
  const res = await push(u, [change('accounts', id, acct(), '2099-01-01T00:00:00.000Z')]).expect(200);
  const rec = res.body.results[0].record;
  assert.ok(Date.parse(rec.client_updated_at) <= Date.parse(res.body.server_time) + 1000);
  // y por tanto una edición legítima posterior (sin reloj adelantado) puede ganar tras unos instantes
  const later = new Date(Date.now() + 60_000).toISOString();
  const edit = await push(u, [change('accounts', id, acct({ name: 'Nueva' }), later)]).expect(200);
  assert.equal(edit.body.results[0].status, 'applied');
});

test('una edición hecha por REST posterior gana a un cambio de sync más viejo', async () => {
  const { u } = await setupDevice();
  const id = uid();
  await push(u, [change('accounts', id, acct(), at('10:00:00.000'))]).expect(200);
  await u.patch(`/accounts/${id}`).send({ name: 'Desde REST' }).expect(200);
  const res = await push(u, [change('accounts', id, acct({ name: 'Sync viejo' }), at('11:00:00.000'))]).expect(200);
  assert.equal(res.body.results[0].status, 'stale');
  assert.equal(res.body.results[0].record.name, 'Desde REST');
});

test('pull inicial entrega catálogo de bancos, categorías sembradas y datos propios; luego es incremental', async () => {
  const { u, expenseCat } = await setupDevice();
  const accId = uid(); const txId = uid();
  await push(u, [change('accounts', accId, acct(), at('09:00:00.000')), change('transactions', txId, txn(accId, expenseCat), at('10:00:00.000'))]).expect(200);

  const first = await pull(u).expect(200);
  assert.ok(first.body.changes.banks.length >= 16);
  assert.ok(first.body.changes.categories.length >= 15);
  assert.equal(first.body.changes.accounts.length, 1);
  assert.equal(first.body.changes.transactions[0].id, txId);
  assert.equal(first.body.has_more, false);
  assert.match(first.body.changes.accounts[0].updated_at, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/);

  const again = await pull(u, `?cursor=${first.body.next_cursor}`).expect(200);
  assert.deepEqual(Object.values(again.body.changes).map((r) => r.length), [0, 0, 0, 0]);

  // una edición REST y un borrado por sync aparecen en el siguiente pull
  await u.patch(`/transactions/${txId}`).send({ description: 'editada' }).expect(200);
  const third = await pull(u, `?cursor=${first.body.next_cursor}`).expect(200);
  assert.equal(third.body.changes.transactions[0].description, 'editada');
  await push(u, [remove('transactions', txId)]).expect(200);
  const fourth = await pull(u, `?cursor=${third.body.next_cursor}`).expect(200);
  assert.ok(fourth.body.changes.transactions[0].deleted_at);
  const last = await pull(u, `?cursor=${fourth.body.next_cursor}`).expect(200);
  assert.equal(last.body.changes.transactions.length, 0);
});

test('pull con paginación recorre todo exactamente una vez', async () => {
  const { u, expenseCat } = await setupDevice();
  const accId = uid();
  const txIds = Array.from({ length: 7 }, uid);
  await push(u, [change('accounts', accId, acct(), at('09:00:00.000'))]).expect(200);
  await push(u, txIds.map((id) => change('transactions', id, txn(accId, expenseCat), at('10:00:00.000')))).expect(200);

  const seen = { banks: [], categories: [], accounts: [], transactions: [] };
  let cursor; let pages = 0; let more = true;
  while (more) {
    const res = await pull(u, `?limit=3${cursor ? `&cursor=${cursor}` : ''}`).expect(200);
    for (const [t, rows] of Object.entries(res.body.changes)) seen[t].push(...rows.map((r) => r.id));
    cursor = res.body.next_cursor; more = res.body.has_more; pages += 1;
    assert.ok(pages < 20, 'no debe ciclar');
  }
  for (const [t, ids] of Object.entries(seen)) assert.equal(new Set(ids).size, ids.length, `${t} sin duplicados`);
  assert.deepEqual(seen.transactions.sort(), [...txIds].sort());
  assert.ok(seen.banks.length >= 16 && seen.categories.length >= 15);
});

test('el margen de seguridad oculta cambios demasiado recientes hasta que maduran', async () => {
  const { u, expenseCat } = await setupDevice();
  const accId = uid();
  await push(u, [change('accounts', accId, acct(), at('09:00:00.000'))]).expect(200);
  const original = config.syncSafetyLagMs;
  config.syncSafetyLagMs = 60_000;
  try {
    const hidden = await pull(u).expect(200);
    assert.equal(hidden.body.changes.accounts.length, 0);
  } finally { config.syncSafetyLagMs = original; }
  const visible = await pull(u).expect(200);
  assert.equal(visible.body.changes.accounts.length, 1);
  assert.ok(expenseCat);
});

test('cursor inválido da 400 y pull exige autenticación', async () => {
  const { u } = await setupDevice();
  await pull(u, '?cursor=basura').expect(400);
  await pull(u, `?cursor=${Buffer.from('{"accounts":"x"}').toString('base64url')}`).expect(400);
  await pull(u, '?limit=0').expect(400);
  await h.api().get('/sync/pull').expect(401);
});

test('dos dispositivos convergen: ambos terminan con la misma versión sin importar el orden de llegada', async () => {
  const finals = [];
  for (const arrival of ['AB', 'BA']) {
    const { u, expenseCat } = await setupDevice();
    const accId = uid(); const txId = uid();
    await push(u, [change('accounts', accId, acct(), at('09:00:00.000')), change('transactions', txId, txn(accId, expenseCat), at('10:00:00.000'))]).expect(200);
    const edits = {
      A: change('transactions', txId, txn(accId, expenseCat, { amount: '11', description: 'A' }), at('11:00:00.000')),
      B: change('transactions', txId, txn(accId, expenseCat, { amount: '22', description: 'B' }), at('11:00:00.500')),
    };
    for (const who of arrival) await push(u, [edits[who]]).expect(200);
    const rec = (await u.get(`/transactions/${txId}`).expect(200)).body;
    finals.push([rec.description, rec.amount]);
  }
  assert.deepEqual(finals, [['B', '22.00'], ['B', '22.00']]);
});

test('dinero: se normaliza a 2 decimales y nunca pasa por float', async () => {
  const { u, expenseCat } = await setupDevice();
  const accId = uid();
  await push(u, [change('accounts', accId, acct({ initial_balance: '0' }), at('09:00:00.000'))]).expect(200);
  const ids = [uid(), uid()];
  await push(u, [
    change('transactions', ids[0], txn(accId, expenseCat, { type: 'expense', amount: '0.1' }), at('10:00:00.000')),
    change('transactions', ids[1], txn(accId, expenseCat, { type: 'expense', amount: 0.2 }), at('10:00:00.000')),
  ]).expect(200);
  assert.equal((await u.get(`/accounts/${accId}`).expect(200)).body.balance, '-0.30');
  const { rows } = await pool.query('SELECT sum(amount)::text AS s FROM transactions');
  assert.equal(rows[0].s, '0.30');
});
