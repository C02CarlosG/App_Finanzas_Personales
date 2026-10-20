const { test, before, beforeEach, after } = require('node:test');
const assert = require('node:assert/strict');
const h = require('./helpers');

before(h.setup);
beforeEach(h.reset);
after(h.teardown);

test('el catálogo de bancos viene sembrado', async () => {
  const u = await h.registerUser();
  const res = await u.get('/banks').expect(200);
  const names = res.body.data.map((b) => b.name);
  assert.ok(names.includes('BBVA México') && names.includes('Santander') && names.includes('Banamex'));
});

test('crear cuenta de banco con saldo inicial; nombre por defecto = banco', async () => {
  const u = await h.registerUser();
  const res = await u.post('/accounts')
    .send({ type: 'banco', bank_id: await h.bankId('Santander'), initial_balance: '1500.50', card_type: 'debito' }).expect(201);
  assert.equal(res.body.name, 'Santander');
  assert.equal(res.body.logo_key, 'santander');
  assert.equal(res.body.balance, '1500.50');
});

test('crear cuenta de efectivo; banco es obligatorio solo para tipo banco', async () => {
  const u = await h.registerUser();
  const cash = await u.post('/accounts').send({ type: 'efectivo', initial_balance: 200 }).expect(201);
  assert.equal(cash.body.name, 'Efectivo');
  assert.equal(cash.body.bank_id, null);
  await u.post('/accounts').send({ type: 'banco' }).expect(400);
  await u.post('/accounts').send({ type: 'efectivo', bank_id: await h.bankId() }).expect(400);
});

test('los datos están aislados por usuario', async () => {
  const a = await h.registerUser();
  const b = await h.registerUser();
  const acc = await a.post('/accounts').send({ type: 'efectivo' }).expect(201);
  await b.get(`/accounts/${acc.body.id}`).expect(404);
  await b.patch(`/accounts/${acc.body.id}`).send({ name: 'hack' }).expect(404);
  await b.del(`/accounts/${acc.body.id}`).expect(404);
  const list = await b.get('/accounts').expect(200);
  assert.equal(list.body.data.length, 0);
});

test('editar y eliminar cuenta (soft delete)', async () => {
  const u = await h.registerUser();
  const acc = await u.post('/accounts').send({ type: 'efectivo' }).expect(201);
  const upd = await u.patch(`/accounts/${acc.body.id}`).send({ name: 'Cartera' }).expect(200);
  assert.equal(upd.body.name, 'Cartera');
  await u.del(`/accounts/${acc.body.id}`).expect(204);
  await u.get(`/accounts/${acc.body.id}`).expect(404);
});

test('no se elimina una cuenta con transacciones', async () => {
  const u = await h.registerUser();
  const acc = await u.post('/accounts').send({ type: 'efectivo' }).expect(201);
  await u.post('/transactions').send({
    type: 'expense', amount: '10', account_id: acc.body.id,
    category_id: await h.categoryId(u, 'expense', 'Vivienda'), occurred_on: '2026-10-01',
  }).expect(201);
  const res = await u.del(`/accounts/${acc.body.id}`).expect(409);
  assert.equal(res.body.code, 'in_use');
});
