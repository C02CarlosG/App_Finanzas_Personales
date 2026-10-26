const { test, before, beforeEach, after } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const h = require('./helpers');
const { pool } = require('../src/db/pool');

before(h.setup);
beforeEach(h.reset);
after(h.teardown);

const uid = () => crypto.randomUUID();
const at = (s) => `2026-01-15T${s}Z`;
const push = (u, changes) => u.post('/sync/push').send({ changes });
const pull = (u, query = '') => u.get(`/sync/pull${query}`);
const change = (table, id, data, ts, extra = {}) => ({ table, id, client_updated_at: ts, data, ...extra });
const remove = (table, id, ts = at('23:00:00.000')) => ({ table, id, client_updated_at: ts, deleted: true });

const acct = (over = {}) => ({ type: 'efectivo', name: 'Cartera', initial_balance: '1000', ...over });
const loan = (over = {}) => ({ person_name: 'Luis Pérez', direction: 'owed_to_me', principal: '500', due_date: null, status: 'active', notes: null, ...over });
const move = (loanId, over = {}) => ({ loan_id: loanId, kind: 'payment', amount: '100', occurred_on: '2026-10-19', transaction_id: null, ...over });
const sub = (over = {}) => ({ name: 'Netflix', amount: '199', renewal_date: '2026-11-01', period: 'monthly', account_id: null, active: true, ...over });
const card = (over = {}) => ({ bank_id: null, name: 'BBVA Azul', pending_balance: '2500.50', due_date: '2026-11-10', ...over });
const cardPay = (cardId, over = {}) => ({ credit_card_id: cardId, account_id: null, transaction_id: null, amount: '500', paid_on: '2026-10-19', ...over });
const txn = (accountId, categoryId, type, over = {}) => ({
  type, amount: '100', account_id: accountId, category_id: categoryId, occurred_on: '2026-10-19', description: null, counterparty: null, ...over,
});

const soon = (ms) => new Date(Date.now() + ms).toISOString(); // más nuevo que el sello de la siembra, sin pasar el límite de adelanto
const statuses = (res) => res.body.results.map((r) => r.status);

async function setup() {
  const u = await h.registerUser();
  return {
    u,
    income: await h.categoryId(u, 'income', 'Préstamo cobrado'),
    loanPay: await h.categoryId(u, 'expense', 'Pago de préstamo'),
    cardPay: await h.categoryId(u, 'expense', 'Pago de tarjeta'),
  };
}

test('un usuario nuevo trae las categorías de sistema de Fase 2 y no se renombran ni se borran', async () => {
  const { u, loanPay, cardPay } = await setup();
  const cats = (await u.get('/categories?kind=expense').expect(200)).body.data;
  assert.equal(cats.find((c) => c.id === loanPay).is_system, true);
  assert.equal(cats.find((c) => c.id === cardPay).is_system, true);
  const del = await push(u, [remove('categories', cardPay)]).expect(200);
  assert.equal(del.body.results[0].code, 'system_category');
  const ren = await push(u, [change('categories', loanPay, { kind: 'expense', name: 'Otro nombre', icon: null, color: null }, soon(1000))]).expect(200);
  assert.equal(ren.body.results[0].code, 'system_category');
});

test('la migración 003 siembra las categorías a usuarios existentes y reutiliza una del mismo nombre', async () => {
  const { u, cardPay } = await setup();
  // Estado previo a la migración: sin 'Pago de préstamo' y con una 'pago de tarjeta' creada por el usuario.
  await pool.query(`DELETE FROM categories WHERE user_id = $1 AND name = 'Pago de préstamo'`, [u.user.id]);
  await pool.query(`UPDATE categories SET name = 'pago de tarjeta', is_system = false WHERE id = $1`, [cardPay]);
  const sql = fs.readFileSync(path.join(__dirname, '../src/db/migrations/003_fase2.sql'), 'utf8');
  const block = sql.slice(sql.indexOf('-- BACKFILL BEGIN'), sql.indexOf('-- BACKFILL END'));
  await pool.query(block);
  await pool.query(block); // idempotente
  const { rows } = await pool.query(
    `SELECT id, name, is_system FROM categories WHERE user_id = $1 AND kind = 'expense' AND name IN ('Pago de préstamo', 'Pago de tarjeta', 'pago de tarjeta')`, [u.user.id]);
  assert.equal(rows.length, 2);
  assert.ok(rows.every((r) => r.is_system));
  assert.equal(rows.find((r) => r.id === cardPay).name, 'Pago de tarjeta'); // se reutilizó, no se duplicó
});

test('préstamo con abono y su ingreso: un lote en cualquier orden, dinero normalizado', async () => {
  const { u, income } = await setup();
  const accId = uid(); const loanId = uid(); const txId = uid(); const movId = uid();
  const res = await push(u, [
    change('loan_movements', movId, move(loanId, { amount: 100, transaction_id: txId }), at('10:00:04.000')),
    change('transactions', txId, txn(accId, income, 'income', { counterparty: 'Luis Pérez' }), at('10:00:03.000')),
    change('loans', loanId, loan({ principal: 500 }), at('10:00:02.000')),
    change('accounts', accId, acct(), at('10:00:01.000')),
  ]).expect(200);
  assert.deepEqual(statuses(res), ['applied', 'applied', 'applied', 'applied']);
  const mov = res.body.results[0].record;
  assert.deepEqual([mov.amount, mov.kind, mov.transaction_id, mov.occurred_on], ['100.00', 'payment', txId, '2026-10-19']);
  assert.equal(res.body.results[2].record.principal, '500.00');
  assert.equal(res.body.results[2].record.due_date, null);
});

test('validación de préstamos y movimientos', async () => {
  const { u } = await setup();
  const loanId = uid();
  const bad = await push(u, [
    change('loans', uid(), loan({ principal: '0' }), at('10:00:00.000')),
    change('loans', uid(), loan({ direction: 'otra' }), at('10:00:00.000')),
    change('loans', uid(), loan({ person_name: '  ' }), at('10:00:00.000')),
    change('loans', uid(), { ...loan(), extra: 1 }, at('10:00:00.000')),
    change('loans', uid(), loan({ principal: '10.123' }), at('10:00:00.000')),
    change('loans', loanId, loan(), at('10:00:00.000')),
    change('loan_movements', uid(), move(loanId, { amount: '-5' }), at('10:00:01.000')),
    change('loan_movements', uid(), move(loanId, { kind: 'regalo' }), at('10:00:01.000')),
    change('loan_movements', uid(), move(loanId, { occurred_on: '2026-02-30' }), at('10:00:01.000')),
  ]).expect(200);
  assert.deepEqual(statuses(bad), ['invalid', 'invalid', 'invalid', 'invalid', 'invalid', 'applied', 'invalid', 'invalid', 'invalid']);
  assert.ok(bad.body.results.slice(0, 5).every((r) => r.code === 'validation_error'));
});

test('el sentido del préstamo y las referencias de un movimiento son inmutables', async () => {
  const { u } = await setup();
  const loanId = uid(); const movId = uid(); const otherLoan = uid();
  await push(u, [
    change('loans', loanId, loan(), at('10:00:00.000')),
    change('loans', otherLoan, loan(), at('10:00:00.000')),
    change('loan_movements', movId, move(loanId), at('10:00:01.000')),
  ]).expect(200);
  const res = await push(u, [
    change('loans', loanId, loan({ direction: 'i_owe' }), at('11:00:00.000')),
    change('loan_movements', movId, move(otherLoan), at('11:00:01.000')),
    change('loan_movements', movId, move(loanId, { kind: 'increase' }), at('11:00:02.000')),
  ].slice(0, 2)).expect(200);
  assert.deepEqual(res.body.results.map((r) => r.code), ['immutable_field', 'immutable_field']);
  const kind = await push(u, [change('loan_movements', movId, move(loanId, { kind: 'increase' }), at('12:00:00.000'))]).expect(200);
  assert.equal(kind.body.results[0].code, 'immutable_field');
  // Sí se pueden editar los campos de datos: estado del préstamo y notas.
  const ok = await push(u, [change('loans', loanId, loan({ status: 'paid', notes: 'liquidado' }), at('13:00:00.000'))]).expect(200);
  assert.equal(ok.body.results[0].record.status, 'paid');
});

test('un movimiento exige préstamo y transacción propios y vivos; el tipo debe corresponder a la dirección', async () => {
  const { u, income, loanPay } = await setup();
  const other = await h.registerUser();
  const accId = uid(); const owedId = uid(); const oweId = uid(); const incomeTx = uid(); const expenseTx = uid();
  const foreignLoan = uid();
  await push(other, [change('loans', foreignLoan, loan(), at('09:00:00.000'))]).expect(200);
  await push(u, [
    change('accounts', accId, acct(), at('10:00:00.000')),
    change('loans', owedId, loan({ direction: 'owed_to_me' }), at('10:00:00.000')),
    change('loans', oweId, loan({ direction: 'i_owe' }), at('10:00:00.000')),
    change('transactions', incomeTx, txn(accId, income, 'income'), at('10:00:01.000')),
    change('transactions', expenseTx, txn(accId, loanPay, 'expense'), at('10:00:01.000')),
  ]).expect(200);

  const res = await push(u, [
    change('loan_movements', uid(), move(uid()), at('11:00:00.000')), // préstamo inexistente
    change('loan_movements', uid(), move(foreignLoan), at('11:00:00.000')), // préstamo ajeno
    change('loan_movements', uid(), move(owedId, { transaction_id: uid() }), at('11:00:00.000')), // tx inexistente
    change('loan_movements', uid(), move(owedId, { transaction_id: expenseTx }), at('11:00:00.000')), // cobro con un gasto
    change('loan_movements', uid(), move(oweId, { transaction_id: incomeTx }), at('11:00:00.000')), // pago con un ingreso
    change('loan_movements', uid(), move(owedId, { transaction_id: incomeTx }), at('11:00:00.000')), // ok
    change('loan_movements', uid(), move(oweId, { transaction_id: expenseTx }), at('11:00:00.000')), // ok
  ]).expect(200);
  assert.deepEqual(res.body.results.map((r) => r.code ?? r.status), [
    'invalid_reference', 'invalid_reference', 'invalid_reference', 'type_mismatch', 'type_mismatch', 'applied', 'applied']);
});

test('no se borra un préstamo con movimientos, ni una transacción que respalda un abono', async () => {
  const { u, income } = await setup();
  const accId = uid(); const loanId = uid(); const txId = uid(); const movId = uid();
  await push(u, [
    change('accounts', accId, acct(), at('10:00:00.000')),
    change('loans', loanId, loan(), at('10:00:00.000')),
    change('transactions', txId, txn(accId, income, 'income'), at('10:00:01.000')),
    change('loan_movements', movId, move(loanId, { transaction_id: txId }), at('10:00:02.000')),
  ]).expect(200);

  const blocked = await push(u, [remove('loans', loanId), remove('transactions', txId)]).expect(200);
  assert.deepEqual(blocked.body.results.map((r) => [r.status, r.code]), [['rejected', 'in_use'], ['rejected', 'in_use']]);
  assert.equal(blocked.body.results[0].record.deleted_at, null); // devuelve el registro vivo

  // Mismo lote: hijos primero (movimiento, luego transacción y préstamo).
  const ok = await push(u, [remove('loans', loanId), remove('transactions', txId), remove('loan_movements', movId)]).expect(200);
  assert.deepEqual(statuses(ok), ['applied', 'applied', 'applied']);
  assert.ok(ok.body.results.every((r) => r.record.deleted_at));

  // REST: la transacción de un abono tampoco se borra, mientras el abono esté vivo.
  const tx2 = uid(); const mov2 = uid(); const loan2 = uid();
  await push(u, [
    change('loans', loan2, loan(), at('12:00:00.000')),
    change('transactions', tx2, txn(accId, income, 'income'), at('12:00:01.000')),
    change('loan_movements', mov2, move(loan2, { transaction_id: tx2 }), at('12:00:02.000')),
  ]).expect(200);
  await u.del(`/transactions/${tx2}`).expect(409);
  await push(u, [remove('loan_movements', mov2, at('13:00:00.000'))]).expect(200);
  await u.del(`/transactions/${tx2}`).expect(204);
});

test('suscripciones: alta, edición por last-write-wins, referencias y borrado de la cuenta usada', async () => {
  const { u } = await setup();
  const accId = uid(); const subId = uid();
  const bad = await push(u, [
    change('subscriptions', uid(), sub({ period: 'daily' }), at('10:00:00.000')),
    change('subscriptions', uid(), sub({ amount: '0' }), at('10:00:00.000')),
    change('subscriptions', uid(), sub({ renewal_date: '31-12-2026' }), at('10:00:00.000')),
    change('subscriptions', uid(), sub({ active: 'si' }), at('10:00:00.000')),
    change('subscriptions', uid(), sub({ account_id: uid() }), at('10:00:00.000')),
  ]).expect(200);
  assert.deepEqual(bad.body.results.map((r) => r.code), ['validation_error', 'validation_error', 'validation_error', 'validation_error', 'invalid_reference']);

  await push(u, [change('accounts', accId, acct(), at('10:00:00.000')), change('subscriptions', subId, sub({ account_id: accId }), at('10:00:01.000'))]).expect(200);
  // La más reciente gana, llegue en el orden que llegue.
  await push(u, [change('subscriptions', subId, sub({ account_id: accId, amount: '219.50', active: false }), at('12:00:00.000'))]).expect(200);
  const stale = await push(u, [change('subscriptions', subId, sub({ account_id: accId, amount: '1' }), at('11:00:00.000'))]).expect(200);
  assert.equal(stale.body.results[0].status, 'stale');
  assert.deepEqual([stale.body.results[0].record.amount, stale.body.results[0].record.active], ['219.50', false]);

  const del = await push(u, [remove('accounts', accId)]).expect(200);
  assert.equal(del.body.results[0].code, 'in_use'); // la usa una suscripción
  await u.del(`/accounts/${accId}`).expect(409);
  // Quitarle la cuenta a la suscripción la libera.
  await push(u, [change('subscriptions', subId, sub({ account_id: null, amount: '219.50', active: false }), at('13:00:00.000'))]).expect(200);
  const ok = await push(u, [remove('accounts', accId, at('14:00:00.000'))]).expect(200);
  assert.equal(ok.body.results[0].status, 'applied');
});

test('tarjetas: saldo en cero permitido, negativo no; los pagos exigen tarjeta, cuenta y gasto propios', async () => {
  const { u, cardPay: cat, income } = await setup();
  const bank = await h.bankId();
  const accId = uid(); const cardId = uid(); const txId = uid(); const incomeTx = uid();
  const bad = await push(u, [
    change('credit_cards', uid(), card({ pending_balance: '-1' }), at('10:00:00.000')),
    change('credit_cards', uid(), card({ name: '' }), at('10:00:00.000')),
    change('credit_cards', uid(), card({ bank_id: uid() }), at('10:00:00.000')),
    change('credit_cards', cardId, card({ pending_balance: 0, bank_id: bank }), at('10:00:00.000')),
  ]).expect(200);
  assert.deepEqual(bad.body.results.map((r) => r.code ?? r.status), ['validation_error', 'validation_error', 'invalid_reference', 'applied']);
  assert.equal(bad.body.results[3].record.pending_balance, '0.00');

  await push(u, [
    change('accounts', accId, acct(), at('10:00:01.000')),
    change('transactions', txId, txn(accId, cat, 'expense', { amount: '500' }), at('10:00:02.000')),
    change('transactions', incomeTx, txn(accId, income, 'income'), at('10:00:02.000')),
  ]).expect(200);
  const res = await push(u, [
    change('credit_card_payments', uid(), cardPay(uid()), at('11:00:00.000')), // tarjeta inexistente
    change('credit_card_payments', uid(), cardPay(cardId, { account_id: uid() }), at('11:00:00.000')),
    change('credit_card_payments', uid(), cardPay(cardId, { transaction_id: incomeTx }), at('11:00:00.000')), // un ingreso no es pago
    change('credit_card_payments', uid(), cardPay(cardId, { amount: '0' }), at('11:00:00.000')),
    change('credit_card_payments', uid(), cardPay(cardId, { account_id: accId, transaction_id: txId }), at('11:00:00.000')),
  ]).expect(200);
  assert.deepEqual(res.body.results.map((r) => r.code ?? r.status), ['invalid_reference', 'invalid_reference', 'type_mismatch', 'validation_error', 'applied']);
});

test('no se borra una tarjeta con pagos ni la transacción de un pago; sí con el pago en el mismo lote', async () => {
  const { u, cardPay: cat } = await setup();
  const accId = uid(); const cardId = uid(); const txId = uid(); const payId = uid();
  await push(u, [
    change('accounts', accId, acct(), at('10:00:00.000')),
    change('credit_cards', cardId, card(), at('10:00:00.000')),
    change('transactions', txId, txn(accId, cat, 'expense'), at('10:00:01.000')),
    change('credit_card_payments', payId, cardPay(cardId, { account_id: accId, transaction_id: txId }), at('10:00:02.000')),
  ]).expect(200);
  const blocked = await push(u, [remove('credit_cards', cardId), remove('transactions', txId), remove('accounts', accId)]).expect(200);
  assert.deepEqual(blocked.body.results.map((r) => r.code), ['in_use', 'in_use', 'in_use']);
  await u.del(`/transactions/${txId}`).expect(409);
  const ok = await push(u, [remove('accounts', accId), remove('transactions', txId), remove('credit_cards', cardId), remove('credit_card_payments', payId)]).expect(200);
  assert.deepEqual(statuses(ok), ['applied', 'applied', 'applied', 'applied']);
});

test('aislamiento: otro usuario no puede tocar ni ver préstamos, suscripciones ni tarjetas ajenos', async () => {
  const { u } = await setup();
  const other = await h.registerUser();
  const loanId = uid(); const subId = uid(); const cardId = uid();
  await push(u, [
    change('loans', loanId, loan(), at('10:00:00.000')),
    change('subscriptions', subId, sub(), at('10:00:00.000')),
    change('credit_cards', cardId, card(), at('10:00:00.000')),
  ]).expect(200);
  const res = await push(other, [
    change('loans', loanId, loan({ person_name: 'Robo' }), at('11:00:00.000')),
    change('subscriptions', subId, sub({ name: 'Robo' }), at('11:00:00.000')),
    change('credit_cards', cardId, card({ name: 'Robo' }), at('11:00:00.000')),
  ]).expect(200);
  assert.deepEqual(res.body.results.map((r) => r.code ?? r.status), ['invalid_id', 'invalid_id', 'invalid_id']);
  // Borrar un id ajeno es un no-op: el registro del dueño sigue vivo.
  const del = await push(other, [remove('loans', loanId, at('11:00:00.000'))]).expect(200);
  assert.deepEqual([del.body.results[0].status, del.body.results[0].record], ['applied', null]);
  const rows = await pool.query('SELECT person_name, deleted_at FROM loans WHERE id = $1', [loanId]);
  assert.deepEqual([rows.rows[0].person_name, rows.rows[0].deleted_at], ['Luis Pérez', null]);
  const theirs = (await pull(other).expect(200)).body.changes;
  assert.deepEqual([theirs.loans.length, theirs.subscriptions.length, theirs.credit_cards.length], [0, 0, 0]);
});

test('pull entrega las tablas de Fase 2, es incremental y recorre todo con paginación', async () => {
  const { u, income } = await setup();
  const accId = uid(); const loanId = uid(); const txId = uid(); const movId = uid(); const cardId = uid(); const subId = uid();
  await push(u, [
    change('accounts', accId, acct(), at('10:00:00.000')),
    change('loans', loanId, loan(), at('10:00:00.000')),
    change('credit_cards', cardId, card(), at('10:00:00.000')),
    change('subscriptions', subId, sub({ account_id: accId }), at('10:00:00.000')),
    change('transactions', txId, txn(accId, income, 'income'), at('10:00:01.000')),
    change('loan_movements', movId, move(loanId, { transaction_id: txId }), at('10:00:02.000')),
  ]).expect(200);
  const first = (await pull(u).expect(200)).body;
  assert.deepEqual(
    [first.changes.loans.length, first.changes.credit_cards.length, first.changes.subscriptions.length, first.changes.loan_movements.length, first.changes.credit_card_payments.length],
    [1, 1, 1, 1, 0]);
  assert.equal(first.changes.loan_movements[0].transaction_id, txId);
  assert.equal(first.changes.credit_cards[0].pending_balance, '2500.50');

  const again = (await pull(u, `?cursor=${first.next_cursor}`).expect(200)).body;
  assert.equal(Object.values(again.changes).flat().length, 0);

  await push(u, [change('loans', loanId, loan({ status: 'paid' }), at('12:00:00.000'))]).expect(200);
  const inc = (await pull(u, `?cursor=${first.next_cursor}`).expect(200)).body;
  assert.deepEqual([inc.changes.loans.length, inc.changes.loans[0].status, Object.values(inc.changes).flat().length], [1, 'paid', 1]);

  // Paginando de a 1 se ve cada registro exactamente una vez.
  const seen = []; let cursor;
  for (let i = 0; i < 50; i += 1) {
    const page = (await pull(u, `?limit=1${cursor ? `&cursor=${cursor}` : ''}`).expect(200)).body;
    for (const [table, rows] of Object.entries(page.changes)) for (const r of rows) seen.push(`${table}:${r.id}`);
    cursor = page.next_cursor;
    if (!page.has_more) break;
  }
  assert.equal(new Set(seen).size, seen.length);
  for (const id of [loanId, cardId, subId, movId]) assert.ok(seen.some((s) => s.endsWith(id)));
});

test('dos dispositivos convergen en préstamos aunque lleguen en distinto orden', async () => {
  const { u } = await setup();
  const loanId = uid();
  await push(u, [change('loans', loanId, loan(), at('10:00:00.000'))]).expect(200);
  await push(u, [change('loans', loanId, loan({ notes: 'B' }), at('12:00:00.000'))]).expect(200);
  const r = await push(u, [change('loans', loanId, loan({ notes: 'A' }), at('11:00:00.000'))]).expect(200);
  assert.equal(r.body.results[0].status, 'stale');
  assert.equal(r.body.results[0].record.notes, 'B');
});
