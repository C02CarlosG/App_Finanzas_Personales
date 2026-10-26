const { test, before, beforeEach, after } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const h = require('./helpers');
const { pool } = require('../src/db/pool');

before(h.setup);
beforeEach(h.reset);
after(h.teardown);

const uid = () => crypto.randomUUID();
const at = (s) => `2026-01-15T${s}Z`;
const soon = (ms) => new Date(Date.now() + ms).toISOString();
const push = (u, changes) => u.post('/sync/push').send({ changes });
const pull = (u, query = '') => u.get(`/sync/pull${query}`);
const change = (table, id, data, ts, extra = {}) => ({ table, id, client_updated_at: ts, data, ...extra });
const remove = (table, id, ts = at('23:00:00.000')) => ({ table, id, client_updated_at: ts, deleted: true });
const budget = (categoryId, over = {}) => ({ category_id: categoryId, monthly_limit: '1500', alert_percent: 80, ...over });

async function setup() {
  const u = await h.registerUser();
  return { u, food: await h.categoryId(u, 'expense', 'Alimentación'), rent: await h.categoryId(u, 'expense', 'Vivienda'), salary: await h.categoryId(u, 'income', 'Freelance') };
}

test('un presupuesto se crea, se edita por last-write-wins y llega en el pull', async () => {
  const { u, food } = await setup();
  const id = uid();
  const res = await push(u, [change('budgets', id, budget(food, { monthly_limit: 1500.5 }), at('10:00:00.000'))]).expect(200);
  assert.equal(res.body.results[0].status, 'applied');
  assert.deepEqual([res.body.results[0].record.monthly_limit, res.body.results[0].record.alert_percent, res.body.results[0].record.category_id], ['1500.50', 80, food]);

  await push(u, [change('budgets', id, budget(food, { monthly_limit: '2000', alert_percent: 90 }), at('12:00:00.000'))]).expect(200);
  const stale = await push(u, [change('budgets', id, budget(food, { monthly_limit: '1' }), at('11:00:00.000'))]).expect(200);
  assert.equal(stale.body.results[0].status, 'stale');
  assert.deepEqual([stale.body.results[0].record.monthly_limit, stale.body.results[0].record.alert_percent], ['2000.00', 90]);

  const pulled = (await pull(u).expect(200)).body.changes;
  assert.deepEqual(pulled.budgets.map((b) => b.id), [id]);
  assert.equal(Object.keys((await pull(u).expect(200)).body.changes).at(-1), 'budgets');
});

test('validación: límite > 0, umbral entero de 1 a 100, sin campos extra; la categoría debe ser de gastos, propia y viva', async () => {
  const { u, food, salary } = await setup();
  const other = await h.registerUser();
  const foreign = await h.categoryId(other, 'expense', 'Salud');
  const res = await push(u, [
    change('budgets', uid(), budget(food, { monthly_limit: '0' }), at('10:00:00.000')),
    change('budgets', uid(), budget(food, { monthly_limit: '10.123' }), at('10:00:00.000')),
    change('budgets', uid(), budget(food, { alert_percent: 0 }), at('10:00:00.000')),
    change('budgets', uid(), budget(food, { alert_percent: 101 }), at('10:00:00.000')),
    change('budgets', uid(), budget(food, { alert_percent: 50.5 }), at('10:00:00.000')),
    change('budgets', uid(), { ...budget(food), extra: 1 }, at('10:00:00.000')),
    change('budgets', uid(), budget(uid()), at('10:00:00.000')), // categoría inexistente
    change('budgets', uid(), budget(foreign), at('10:00:00.000')), // categoría ajena
    change('budgets', uid(), budget(salary), at('10:00:00.000')), // categoría de ingresos
  ]).expect(200);
  assert.deepEqual(res.body.results.map((r) => r.code), [
    'validation_error', 'validation_error', 'validation_error', 'validation_error', 'validation_error', 'validation_error',
    'invalid_reference', 'invalid_reference', 'category_kind_mismatch']);
});

test('la categoría de un presupuesto es inmutable', async () => {
  const { u, food, rent } = await setup();
  const id = uid();
  await push(u, [change('budgets', id, budget(food), at('10:00:00.000'))]).expect(200);
  const res = await push(u, [change('budgets', id, budget(rent), at('11:00:00.000'))]).expect(200);
  assert.equal(res.body.results[0].code, 'immutable_field');
});

test('dos dispositivos crean el presupuesto de la misma categoría: el segundo recibe duplicate_budget con el id vigente', async () => {
  const { u, food } = await setup();
  const first = uid(); const second = uid();
  await push(u, [change('budgets', first, budget(food), at('10:00:00.000'))]).expect(200);
  const res = await push(u, [change('budgets', second, budget(food, { monthly_limit: '99' }), at('11:00:00.000'))]).expect(200);
  assert.deepEqual([res.body.results[0].status, res.body.results[0].code, res.body.results[0].conflicting_id, res.body.results[0].record], ['rejected', 'duplicate_budget', first, null]);
  const { rows } = await pool.query('SELECT count(*)::int AS n FROM budgets WHERE category_id = $1 AND deleted_at IS NULL', [food]);
  assert.equal(rows[0].n, 1);
});

test('borrar un presupuesto y crear otro de la misma categoría en un lote funciona (segundo pase)', async () => {
  const { u, food } = await setup();
  const old = uid(); const fresh = uid();
  await push(u, [change('budgets', old, budget(food), at('10:00:00.000'))]).expect(200);
  const res = await push(u, [change('budgets', fresh, budget(food, { monthly_limit: '700' }), at('11:00:00.000')), remove('budgets', old, at('11:00:00.000'))]).expect(200);
  assert.deepEqual(res.body.results.map((r) => r.status), ['applied', 'applied']);
  assert.equal(res.body.results[0].record.monthly_limit, '700.00');
});

test('una categoría con presupuesto no se borra (sync ni REST) hasta quitar el presupuesto', async () => {
  const { u, food } = await setup();
  const id = uid();
  // la categoría nueva del usuario, sin transacciones
  const custom = uid();
  await push(u, [change('categories', custom, { kind: 'expense', name: 'Mascotas' }, at('10:00:00.000')), change('budgets', id, budget(custom), at('10:00:01.000'))]).expect(200);
  const blocked = await push(u, [remove('categories', custom)]).expect(200);
  assert.deepEqual([blocked.body.results[0].status, blocked.body.results[0].code], ['rejected', 'in_use']);
  await u.del(`/categories/${custom}`).expect(409);
  // mismo lote: el presupuesto se borra primero (hijos primero)
  const ok = await push(u, [remove('categories', custom), remove('budgets', id)]).expect(200);
  assert.deepEqual(ok.body.results.map((r) => r.status), ['applied', 'applied']);
  void food;
});

test('aislamiento: otro usuario no toca ni ve presupuestos ajenos', async () => {
  const { u, food } = await setup();
  const other = await h.registerUser();
  const id = uid();
  await push(u, [change('budgets', id, budget(food), at('10:00:00.000'))]).expect(200);
  const res = await push(other, [change('budgets', id, budget(food, { monthly_limit: '1' }), at('11:00:00.000'))]).expect(200);
  assert.equal(res.body.results[0].code, 'invalid_id');
  const del = await push(other, [remove('budgets', id, at('11:00:00.000'))]).expect(200);
  assert.deepEqual([del.body.results[0].status, del.body.results[0].record], ['applied', null]);
  assert.equal((await pull(other).expect(200)).body.changes.budgets.length, 0);
  const { rows } = await pool.query('SELECT monthly_limit, deleted_at FROM budgets WHERE id = $1', [id]);
  assert.deepEqual([rows[0].monthly_limit, rows[0].deleted_at], ['1500.00', null]);
});

test('el tombstone de un presupuesto gana a una edición posterior', async () => {
  const { u, food } = await setup();
  const id = uid();
  await push(u, [change('budgets', id, budget(food), at('10:00:00.000'))]).expect(200);
  await push(u, [remove('budgets', id, at('11:00:00.000'))]).expect(200);
  const res = await push(u, [change('budgets', id, budget(food, { monthly_limit: '5' }), soon(1000))]).expect(200);
  assert.equal(res.body.results[0].status, 'deleted');
});
