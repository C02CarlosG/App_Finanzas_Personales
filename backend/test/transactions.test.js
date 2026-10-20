const { test, before, beforeEach, after } = require('node:test');
const assert = require('node:assert/strict');
const h = require('./helpers');

before(h.setup);
beforeEach(h.reset);
after(h.teardown);

async function scenario() {
  const u = await h.registerUser();
  const bank = await u.post('/accounts').send({ type: 'banco', bank_id: await h.bankId(), initial_balance: '1000.00' }).expect(201);
  const cash = await u.post('/accounts').send({ type: 'efectivo' }).expect(201);
  return {
    u, bank: bank.body, cash: cash.body,
    salary: await h.categoryId(u, 'income', 'Salario / quincena'),
    food: await h.categoryId(u, 'expense', 'Alimentación'),
    rent: await h.categoryId(u, 'expense', 'Vivienda'),
  };
}

const balanceOf = async (u, id) => (await u.get(`/accounts/${id}`).expect(200)).body.balance;

test('ingresos y gastos actualizan el saldo calculado', async () => {
  const s = await scenario();
  await s.u.post('/transactions').send({ type: 'income', amount: '500.25', account_id: s.bank.id, category_id: s.salary, occurred_on: '2026-10-01' }).expect(201);
  await s.u.post('/transactions').send({ type: 'expense', amount: 200, account_id: s.bank.id, category_id: s.food, occurred_on: '2026-10-02' }).expect(201);
  assert.equal(await balanceOf(s.u, s.bank.id), '1300.25');
});

test('precisión decimal: 0.1 + 0.2 = 0.30 exacto', async () => {
  const s = await scenario();
  for (const amount of ['0.10', '0.20']) {
    await s.u.post('/transactions').send({ type: 'income', amount, account_id: s.cash.id, category_id: s.salary, occurred_on: '2026-10-01' }).expect(201);
  }
  assert.equal(await balanceOf(s.u, s.cash.id), '0.30');
});

test('rechaza montos con más de 2 decimales, cero, negativos y no numéricos', async () => {
  const s = await scenario();
  for (const amount of ['10.999', 0, -5, 'abc', 0.1 + 0.2]) {
    await s.u.post('/transactions').send({ type: 'expense', amount, account_id: s.cash.id, category_id: s.food, occurred_on: '2026-10-01' }).expect(400);
  }
});

test('la categoría debe coincidir con el tipo de transacción', async () => {
  const s = await scenario();
  const res = await s.u.post('/transactions').send({ type: 'income', amount: 10, account_id: s.cash.id, category_id: s.food, occurred_on: '2026-10-01' }).expect(400);
  assert.equal(res.body.code, 'category_kind_mismatch');
});

test('no se puede usar cuenta ni categoría de otro usuario', async () => {
  const s = await scenario();
  const other = await h.registerUser();
  const otherAcc = await other.post('/accounts').send({ type: 'efectivo' }).expect(201);
  await s.u.post('/transactions').send({ type: 'expense', amount: 10, account_id: otherAcc.body.id, category_id: s.food, occurred_on: '2026-10-01' }).expect(400);
  const otherCat = await h.categoryId(other, 'expense', 'Salud');
  await s.u.post('/transactions').send({ type: 'expense', amount: 10, account_id: s.cash.id, category_id: otherCat, occurred_on: '2026-10-01' }).expect(400);
});

test('listado ordenado por fecha, con filtros por categoría, banco, búsqueda y fechas', async () => {
  const s = await scenario();
  const mk = (body) => s.u.post('/transactions').send({ type: 'expense', ...body }).expect(201);
  await mk({ amount: 100, account_id: s.bank.id, category_id: s.food, occurred_on: '2026-10-03', description: 'Tacos 100% buenos' });
  await mk({ amount: 50, account_id: s.cash.id, category_id: s.food, occurred_on: '2026-10-05', description: 'Café' });
  await mk({ amount: 900, account_id: s.bank.id, category_id: s.rent, occurred_on: '2026-09-01', description: 'Renta' });

  const all = await s.u.get('/transactions').expect(200);
  assert.deepEqual(all.body.data.map((t) => t.description), ['Café', 'Tacos 100% buenos', 'Renta']);
  assert.equal(all.body.totals.expense, '1050.00');

  const byCat = await s.u.get(`/transactions?category_id=${s.food}`).expect(200);
  assert.equal(byCat.body.data.length, 2);

  const byBank = await s.u.get(`/transactions?bank_id=${s.bank.bank_id}`).expect(200);
  assert.equal(byBank.body.data.length, 2);

  const search = await s.u.get('/transactions?q=' + encodeURIComponent('100%')).expect(200);
  assert.equal(search.body.data.length, 1);

  const range = await s.u.get('/transactions?from=2026-10-01&to=2026-10-31').expect(200);
  assert.equal(range.body.data.length, 2);
  assert.equal(range.body.totals.expense, '150.00');
});

test('editar transacción recalcula saldo; eliminar (soft delete) lo revierte', async () => {
  const s = await scenario();
  const t = await s.u.post('/transactions').send({ type: 'expense', amount: 100, account_id: s.bank.id, category_id: s.food, occurred_on: '2026-10-01' }).expect(201);
  assert.equal(await balanceOf(s.u, s.bank.id), '900.00');
  await s.u.patch(`/transactions/${t.body.id}`).send({ amount: '250.50', description: 'Súper' }).expect(200);
  assert.equal(await balanceOf(s.u, s.bank.id), '749.50');
  await s.u.del(`/transactions/${t.body.id}`).expect(204);
  assert.equal(await balanceOf(s.u, s.bank.id), '1000.00');
  await s.u.get(`/transactions/${t.body.id}`).expect(404);
});

test('cambiar el tipo exige una categoría compatible', async () => {
  const s = await scenario();
  const t = await s.u.post('/transactions').send({ type: 'expense', amount: 10, account_id: s.cash.id, category_id: s.food, occurred_on: '2026-10-01' }).expect(201);
  await s.u.patch(`/transactions/${t.body.id}`).send({ type: 'income' }).expect(400);
  await s.u.patch(`/transactions/${t.body.id}`).send({ type: 'income', category_id: s.salary }).expect(200);
});

test('las transacciones están aisladas por usuario', async () => {
  const s = await scenario();
  const t = await s.u.post('/transactions').send({ type: 'expense', amount: 10, account_id: s.cash.id, category_id: s.food, occurred_on: '2026-10-01' }).expect(201);
  const other = await h.registerUser();
  await other.get(`/transactions/${t.body.id}`).expect(404);
  await other.del(`/transactions/${t.body.id}`).expect(404);
  assert.equal((await other.get('/transactions').expect(200)).body.data.length, 0);
});

test('acepta id generado por el cliente (offline-first) y rechaza duplicado', async () => {
  const s = await scenario();
  const id = '7d0f5a0e-3f43-4a52-9a1c-0c1b8f6d2e11';
  const body = { id, type: 'expense', amount: 10, account_id: s.cash.id, category_id: s.food, occurred_on: '2026-10-01' };
  const res = await s.u.post('/transactions').send(body).expect(201);
  assert.equal(res.body.id, id);
  await s.u.post('/transactions').send(body).expect(409);
});
