const { test, before, beforeEach, after } = require('node:test');
const assert = require('node:assert/strict');
const h = require('./helpers');

before(h.setup);
beforeEach(h.reset);
after(h.teardown);

test('registro crea usuario, devuelve token y siembra categorías', async () => {
  const u = await h.registerUser({ email: 'Ana@Example.com' });
  assert.equal(u.user.email, 'ana@example.com');
  assert.equal(u.user.currency, 'MXN');
  const cats = await u.get('/categories').expect(200);
  const names = cats.body.data.map((c) => c.name);
  assert.ok(names.includes('Salario / quincena'));
  assert.ok(names.includes('Vivienda'));
  const loan = cats.body.data.find((c) => c.name === 'Préstamo cobrado');
  assert.equal(loan.is_system, true);
});

test('registro rechaza correo duplicado', async () => {
  await h.registerUser({ email: 'dup@example.com' });
  const res = await h.api().post('/auth/register')
    .send({ email: 'DUP@example.com', password: 'password123', name: 'Otro' }).expect(409);
  assert.equal(res.body.code, 'email_taken');
});

test('registro valida contraseña corta y correo inválido', async () => {
  const res = await h.api().post('/auth/register').send({ email: 'x', password: '123', name: 'A' }).expect(400);
  assert.equal(res.body.code, 'validation_error');
  assert.ok(res.body.details.length >= 2);
});

test('login correcto devuelve token', async () => {
  await h.registerUser({ email: 'login@example.com' });
  const res = await h.api().post('/auth/login').send({ email: 'login@example.com', password: 'password123' }).expect(200);
  assert.ok(res.body.token);
});

test('login con contraseña incorrecta o correo inexistente da 401', async () => {
  await h.registerUser({ email: 'login@example.com' });
  await h.api().post('/auth/login').send({ email: 'login@example.com', password: 'incorrecta1' }).expect(401);
  await h.api().post('/auth/login').send({ email: 'nadie@example.com', password: 'password123' }).expect(401);
});

test('rutas protegidas exigen token válido', async () => {
  await h.api().get('/accounts').expect(401);
  await h.api().get('/accounts').set('Authorization', 'Bearer basura').expect(401);
});

test('GET /auth/me devuelve el usuario autenticado', async () => {
  const u = await h.registerUser();
  const res = await u.get('/auth/me').expect(200);
  assert.equal(res.body.user.id, u.user.id);
});
