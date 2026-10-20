const { test, before, beforeEach, after } = require('node:test');
const assert = require('node:assert/strict');
const h = require('./helpers');

before(h.setup);
beforeEach(h.reset);
after(h.teardown);

test('resumen: saldo total, ingresos/gastos del mes y últimas transacciones', async () => {
  const u = await h.registerUser();
  const bank = await u.post('/accounts').send({ type: 'banco', bank_id: await h.bankId(), initial_balance: '1000' }).expect(201);
  const cash = await u.post('/accounts').send({ type: 'efectivo', initial_balance: '200.50' }).expect(201);
  const salary = await h.categoryId(u, 'income', 'Salario / quincena');
  const food = await h.categoryId(u, 'expense', 'Alimentación');
  const mk = (b) => u.post('/transactions').send(b).expect(201);
  await mk({ type: 'income', amount: 3000, account_id: bank.body.id, category_id: salary, occurred_on: '2026-10-01' });
  await mk({ type: 'expense', amount: '450.75', account_id: cash.body.id, category_id: food, occurred_on: '2026-10-10' });
  await mk({ type: 'expense', amount: 99, account_id: cash.body.id, category_id: food, occurred_on: '2026-09-30' });

  const res = await u.get('/dashboard/summary?month=2026-10').expect(200);
  assert.equal(res.body.total_balance, '3650.75'); // 1000+200.50+3000-450.75-99
  assert.equal(res.body.month.income, '3000.00');
  assert.equal(res.body.month.expense, '450.75');
  assert.equal(res.body.month.net, '2549.25');
  assert.equal(res.body.recent_transactions.length, 3);
  assert.equal(res.body.recent_transactions[0].occurred_on, '2026-10-10');
  assert.deepEqual(res.body.by_category.map((c) => [c.name, c.total]), [['Salario / quincena', '3000.00'], ['Alimentación', '450.75']]);
});

test('resumen sin datos devuelve ceros y valida el mes', async () => {
  const u = await h.registerUser();
  const res = await u.get('/dashboard/summary').expect(200);
  assert.equal(res.body.total_balance, '0');
  assert.deepEqual(res.body.recent_transactions, []);
  await u.get('/dashboard/summary?month=2026-13').expect(400);
});
