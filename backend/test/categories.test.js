const { test, before, beforeEach, after } = require('node:test');
const assert = require('node:assert/strict');
const h = require('./helpers');

before(h.setup);
beforeEach(h.reset);
after(h.teardown);

test('listar categorías filtra por tipo', async () => {
  const u = await h.registerUser();
  const res = await u.get('/categories?kind=expense').expect(200);
  assert.ok(res.body.data.length > 0);
  assert.ok(res.body.data.every((c) => c.kind === 'expense'));
});

test('crear, editar y eliminar categoría personalizada', async () => {
  const u = await h.registerUser();
  const created = await u.post('/categories').send({ kind: 'expense', name: 'Mascotas', color: '#00AA55' }).expect(201);
  const upd = await u.patch(`/categories/${created.body.id}`).send({ name: 'Mis mascotas' }).expect(200);
  assert.equal(upd.body.name, 'Mis mascotas');
  await u.del(`/categories/${created.body.id}`).expect(204);
  await u.get(`/categories/${created.body.id}`).expect(404);
});

test('nombre duplicado en el mismo tipo da 409', async () => {
  const u = await h.registerUser();
  await u.post('/categories').send({ kind: 'expense', name: 'vivienda' }).expect(409);
});

test('categoría del sistema no se renombra ni elimina', async () => {
  const u = await h.registerUser();
  const id = await h.categoryId(u, 'income', 'Préstamo cobrado');
  await u.patch(`/categories/${id}`).send({ name: 'Otro' }).expect(409);
  await u.del(`/categories/${id}`).expect(409);
  await u.patch(`/categories/${id}`).send({ color: '#112233' }).expect(200);
});

test('no se elimina una categoría con transacciones', async () => {
  const u = await h.registerUser();
  const acc = await u.post('/accounts').send({ type: 'efectivo' }).expect(201);
  const catId = await h.categoryId(u, 'expense', 'Salud');
  await u.post('/transactions').send({ type: 'expense', amount: 5, account_id: acc.body.id, category_id: catId, occurred_on: '2026-10-01' }).expect(201);
  await u.del(`/categories/${catId}`).expect(409);
});
