const { test, before, beforeEach, after } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const jwt = require('jsonwebtoken');
const h = require('./helpers');
const { pool } = require('../src/db/pool');
const { createAttemptLimiter } = require('../src/services/attemptLimiter');
const { entitlementsFor } = require('../src/services/plans');
const { TABLES_CHILDREN_FIRST } = require('../src/services/deleteUserData');

before(h.setup);
beforeEach(h.reset);
after(h.teardown);

const uid = () => crypto.randomUUID();
const at = (s) => `2026-01-15T${s}Z`;
const change = (table, id, data, ts = at('10:00:00.000')) => ({ table, id, client_updated_at: ts, data });
const login = (email, password) => h.api().post('/auth/login').send({ email, password });
const bearer = (token) => ({ Authorization: `Bearer ${token}` });
const tokenWorks = async (token) => (await h.api().get('/auth/me').set(bearer(token))).status === 200;

// Llena todas las tablas con datos del usuario (vía sync) para comprobar el borrado completo.
async function seedEverything(u) {
  const [income, expense, food] = await Promise.all([
    h.categoryId(u, 'income', 'Préstamo cobrado'), h.categoryId(u, 'expense', 'Pago de tarjeta'), h.categoryId(u, 'expense', 'Alimentación')]);
  const acc = uid(); const loan = uid(); const tx = uid(); const mov = uid(); const sub = uid(); const card = uid(); const pay = uid(); const budget = uid(); const cardTx = uid();
  const res = await u.post('/sync/push').send({ changes: [
    change('accounts', acc, { type: 'efectivo', name: 'Cartera', initial_balance: '1000' }),
    change('loans', loan, { person_name: 'Luis', direction: 'owed_to_me', principal: '500', due_date: null, status: 'active', notes: null }),
    change('transactions', tx, { type: 'income', amount: '100', account_id: acc, category_id: income, occurred_on: '2026-10-19', description: null, counterparty: 'Luis' }),
    change('loan_movements', mov, { loan_id: loan, kind: 'payment', amount: '100', occurred_on: '2026-10-19', transaction_id: tx }),
    change('subscriptions', sub, { name: 'Netflix', amount: '199', renewal_date: '2026-11-01', period: 'monthly', account_id: acc, active: true }),
    change('credit_cards', card, { bank_id: null, name: 'Azul', pending_balance: '2500', due_date: '2026-11-10' }),
    change('transactions', cardTx, { type: 'expense', amount: '500', account_id: acc, category_id: expense, occurred_on: '2026-10-19', description: null, counterparty: null }),
    change('credit_card_payments', pay, { credit_card_id: card, account_id: acc, transaction_id: cardTx, amount: '500', paid_on: '2026-10-19' }),
    change('budgets', budget, { category_id: food, monthly_limit: '1500', alert_percent: 80 }),
  ] }).expect(200);
  assert.deepEqual([...new Set(res.body.results.map((r) => r.status))], ['applied'], JSON.stringify(res.body.results));
}

const userTables = async () => (await pool.query(
  `SELECT c.table_name FROM information_schema.columns c
     JOIN information_schema.tables t USING (table_schema, table_name)
    WHERE c.table_schema = 'public' AND c.column_name = 'user_id' AND t.table_type = 'BASE TABLE' ORDER BY 1`)).rows.map((r) => r.table_name);
const rowsOf = async (table, userId) => Number((await pool.query(`SELECT count(*) FROM ${table} WHERE user_id = $1`, [userId])).rows[0].count);

// ---------- Perfil: nombre y plan ----------

test('PATCH /auth/me cambia el nombre (con recorte) y rechaza vacío o demasiado largo', async () => {
  const u = await h.registerUser();
  const res = await u.patch('/auth/me').send({ name: '  María López  ' }).expect(200);
  assert.equal(res.body.user.name, 'María López');
  assert.equal((await u.get('/auth/me').expect(200)).body.user.name, 'María López');
  await u.patch('/auth/me').send({ name: '   ' }).expect(400);
  await u.patch('/auth/me').send({ name: 'x'.repeat(101) }).expect(400);
  await u.patch('/auth/me').send({}).expect(400);
  await h.api().patch('/auth/me').send({ name: 'Sin token' }).expect(401);
});

test('PATCH /auth/me ignora campos que no son del perfil (moneda y plan no se cambian desde el cliente)', async () => {
  const u = await h.registerUser();
  const res = await u.patch('/auth/me').send({ name: 'Ana', currency: 'USD', plan: 'premium' }).expect(200);
  assert.equal(res.body.user.currency, 'MXN');
  assert.equal(res.body.user.plan, 'free');
});

test('el usuario expone su plan y sus permisos en registro, login y /auth/me', async () => {
  const u = await h.registerUser({ email: 'plan@example.com' });
  const expected = { plan: 'free', features: { sync: true, export: true } };
  assert.deepEqual(u.user.entitlements, expected);
  assert.deepEqual((await u.get('/auth/me').expect(200)).body.user.entitlements, expected);
  assert.deepEqual((await login('plan@example.com', 'password123').expect(200)).body.user.entitlements, expected);
  await pool.query("UPDATE users SET plan = 'premium' WHERE id = $1", [u.user.id]);
  const me = (await u.get('/auth/me').expect(200)).body.user;
  assert.equal(me.plan, 'premium');
  assert.equal(me.entitlements.plan, 'premium');
});

test('entitlementsFor nunca da más que el plan gratuito a un plan desconocido y devuelve copias', () => {
  assert.equal(entitlementsFor('premium').plan, 'premium');
  assert.equal(entitlementsFor('platino').plan, 'free');
  assert.equal(entitlementsFor(undefined).plan, 'free');
  assert.equal(entitlementsFor('__proto__').plan, 'free');
  entitlementsFor('free').features.sync = false;
  assert.equal(entitlementsFor('free').features.sync, true);
});

// ---------- Contraseña ----------

test('cambiar contraseña: revoca los tokens anteriores, entrega uno nuevo y la clave vieja deja de servir', async () => {
  const u = await h.registerUser({ email: 'clave@example.com' });
  const second = (await login('clave@example.com', 'password123').expect(200)).body.token; // otro dispositivo
  assert.equal(await tokenWorks(second), true);

  const res = await u.post('/auth/password').send({ current_password: 'password123', new_password: 'nueva-clave-456' }).expect(200);
  assert.ok(res.body.token);
  assert.equal(res.body.user.email, 'clave@example.com');

  assert.equal(await tokenWorks(u.token), false, 'el token con el que se cambió la clave queda revocado');
  assert.equal(await tokenWorks(second), false, 'el de otro dispositivo también');
  assert.equal(await tokenWorks(res.body.token), true, 'el token nuevo sí funciona');
  await login('clave@example.com', 'password123').expect(401);
  await login('clave@example.com', 'nueva-clave-456').expect(200);
  // y el token revocado tampoco entra a las rutas de datos ni a sync
  await h.api().get('/sync/pull').set(bearer(u.token)).expect(401);
});

test('cambiar contraseña: contraseña actual incorrecta responde 403 (no 401) y no cambia nada', async () => {
  const u = await h.registerUser({ email: 'clave@example.com' });
  const res = await u.post('/auth/password').send({ current_password: 'incorrecta1', new_password: 'nueva-clave-456' }).expect(403);
  assert.equal(res.body.code, 'invalid_password');
  assert.equal(await tokenWorks(u.token), true);
  await login('clave@example.com', 'password123').expect(200);
});

test('cambiar contraseña valida: mínimo 8, distinta de la actual y campos obligatorios', async () => {
  const u = await h.registerUser();
  await u.post('/auth/password').send({ current_password: 'password123', new_password: 'corta' }).expect(400);
  const same = await u.post('/auth/password').send({ current_password: 'password123', new_password: 'password123' }).expect(400);
  assert.equal(same.body.code, 'same_password');
  await u.post('/auth/password').send({ new_password: 'nueva-clave-456' }).expect(400);
  await u.post('/auth/password').send({ current_password: 'password123' }).expect(400);
  assert.equal(await tokenWorks(u.token), true);
});

test('cambiar la contraseña de un usuario no afecta las sesiones de otro', async () => {
  const a = await h.registerUser();
  const b = await h.registerUser();
  await a.post('/auth/password').send({ current_password: 'password123', new_password: 'nueva-clave-456' }).expect(200);
  assert.equal(await tokenWorks(b.token), true);
});

// ---------- Cerrar sesión en todos los dispositivos ----------

test('logout-all revoca todos los tokens (también el actual) y un login nuevo vuelve a funcionar', async () => {
  const u = await h.registerUser({ email: 'todos@example.com' });
  const second = (await login('todos@example.com', 'password123').expect(200)).body.token;
  await u.post('/auth/logout-all').expect(204);
  assert.equal(await tokenWorks(u.token), false);
  assert.equal(await tokenWorks(second), false);
  const fresh = (await login('todos@example.com', 'password123').expect(200)).body.token;
  assert.equal(await tokenWorks(fresh), true);
  await h.api().post('/auth/logout-all').expect(401);
});

test('logout-all no toca las sesiones de otro usuario ni los datos', async () => {
  const a = await h.registerUser();
  const b = await h.registerUser();
  await seedEverything(a);
  await a.post('/auth/logout-all').expect(204);
  assert.equal(await tokenWorks(b.token), true);
  assert.equal(await rowsOf('accounts', a.user.id), 1);
});

test('un token anterior a la migración (sin "ver") sigue valiendo mientras la versión sea 0; uno con otra versión no', async () => {
  const u = await h.registerUser();
  const legacy = jwt.sign({ sub: u.user.id }, process.env.JWT_SECRET, { algorithm: 'HS256', expiresIn: '1h' });
  assert.equal(await tokenWorks(legacy), true);
  const wrong = jwt.sign({ sub: u.user.id, ver: 5 }, process.env.JWT_SECRET, { algorithm: 'HS256', expiresIn: '1h' });
  assert.equal(await tokenWorks(wrong), false);
  await u.post('/auth/logout-all').expect(204);
  assert.equal(await tokenWorks(legacy), false, 'tras revocar, el token sin "ver" ya no equivale a la versión vigente');
});

test('el middleware rechaza tokens con sub no UUID, de usuarios inexistentes o dados de baja', async () => {
  const u = await h.registerUser();
  const sign = (sub) => jwt.sign({ sub, ver: 0 }, process.env.JWT_SECRET, { algorithm: 'HS256', expiresIn: '1h' });
  assert.equal(await tokenWorks(sign('no-es-uuid')), false);
  assert.equal(await tokenWorks(sign(uid())), false);
  await pool.query('UPDATE users SET deleted_at = now() WHERE id = $1', [u.user.id]);
  assert.equal(await tokenWorks(u.token), false);
});

// ---------- Correo ----------

test('cambiar correo: pide la contraseña, normaliza, libera el anterior y el login usa el nuevo', async () => {
  const u = await h.registerUser({ email: 'viejo@example.com' });
  const wrong = await u.post('/auth/email').send({ email: 'nuevo@example.com', password: 'incorrecta1' }).expect(403);
  assert.equal(wrong.body.code, 'invalid_password');

  const res = await u.post('/auth/email').send({ email: '  Nuevo@Example.com ', password: 'password123' }).expect(200);
  assert.equal(res.body.user.email, 'nuevo@example.com');
  await login('viejo@example.com', 'password123').expect(401);
  await login('nuevo@example.com', 'password123').expect(200);
  assert.equal(await tokenWorks(u.token), true, 'cambiar el correo no cierra la sesión');
  // el correo anterior queda libre
  await h.registerUser({ email: 'viejo@example.com' });
});

test('cambiar correo: rechaza uno ya registrado (sin distinguir mayúsculas), uno inválido y el propio es un no-op', async () => {
  const u = await h.registerUser({ email: 'yo@example.com' });
  await h.registerUser({ email: 'otro@example.com' });
  const taken = await u.post('/auth/email').send({ email: 'OTRO@example.com', password: 'password123' }).expect(409);
  assert.equal(taken.body.code, 'email_taken');
  await u.post('/auth/email').send({ email: 'no-es-correo', password: 'password123' }).expect(400);
  const same = await u.post('/auth/email').send({ email: 'YO@example.com', password: 'password123' }).expect(200);
  assert.equal(same.body.user.email, 'yo@example.com');
});

test('cambiar correo a uno que usó una cuenta ya borrada funciona', async () => {
  const gone = await h.registerUser({ email: 'libre@example.com' });
  await gone.post('/auth/delete-account').send({ password: 'password123' }).expect(204);
  const u = await h.registerUser({ email: 'yo@example.com' });
  await u.post('/auth/email').send({ email: 'libre@example.com', password: 'password123' }).expect(200);
});

// ---------- Borrar cuenta ----------

test('borrar cuenta: contraseña incorrecta responde 403 y no borra nada', async () => {
  const u = await h.registerUser();
  await seedEverything(u);
  const res = await u.post('/auth/delete-account').send({ password: 'incorrecta1' }).expect(403);
  assert.equal(res.body.code, 'invalid_password');
  await u.post('/auth/delete-account').send({}).expect(400);
  assert.equal(await tokenWorks(u.token), true);
  assert.equal(await rowsOf('transactions', u.user.id), 2);
});

test('borrar cuenta elimina de verdad al usuario y todas sus filas, y deja intactos a los demás', async () => {
  const tables = await userTables();
  assert.deepEqual([...tables].sort(), [...TABLES_CHILDREN_FIRST].sort(),
    'una tabla nueva con user_id debe agregarse a deleteUserData');
  const a = await h.registerUser({ email: 'adios@example.com' });
  const b = await h.registerUser();
  for (const u of [a, b]) {
    await seedEverything(u);
    await pool.query("INSERT INTO sync_purge_watermarks (user_id, table_name, updated_at, id) VALUES ($1, 'accounts', now(), $2)", [u.user.id, uid()]);
  }
  for (const t of tables) assert.ok(await rowsOf(t, a.user.id) > 0, `la prueba debe sembrar ${t}`);
  const banks = Number((await pool.query('SELECT count(*) FROM banks')).rows[0].count);

  await a.post('/auth/delete-account').send({ password: 'password123' }).expect(204);

  for (const t of tables) assert.equal(await rowsOf(t, a.user.id), 0, `${t} debe quedar vacía`);
  assert.equal((await pool.query('SELECT count(*) FROM users WHERE id = $1', [a.user.id])).rows[0].count, '0');
  for (const t of tables) assert.ok(await rowsOf(t, b.user.id) > 0, `${t} del otro usuario sigue intacta`);
  assert.equal(Number((await pool.query('SELECT count(*) FROM banks')).rows[0].count), banks, 'el catálogo de bancos no se toca');

  assert.equal(await tokenWorks(a.token), false);
  await login('adios@example.com', 'password123').expect(401);
  await h.api().get('/sync/pull').set(bearer(a.token)).expect(401);
  // el correo queda libre y la cuenta nueva empieza vacía
  const again = await h.registerUser({ email: 'adios@example.com' });
  assert.notEqual(again.user.id, a.user.id);
  assert.equal((await again.get('/accounts').expect(200)).body.data.length, 0);
});

test('borrar cuenta dos veces: el segundo intento (token ya inválido) da 401', async () => {
  const u = await h.registerUser();
  await u.post('/auth/delete-account').send({ password: 'password123' }).expect(204);
  await u.post('/auth/delete-account').send({ password: 'password123' }).expect(401);
});

// ---------- Límite de intentos ----------

test('login: tras 5 fallos el sexto intento da 429 con Retry-After, incluso con la clave correcta', async () => {
  await h.registerUser({ email: 'bloqueo@example.com' });
  for (let i = 0; i < 5; i += 1) await login('bloqueo@example.com', 'incorrecta1').expect(401);
  const res = await login('bloqueo@example.com', 'password123').expect(429);
  assert.equal(res.body.code, 'too_many_attempts');
  assert.ok(Number(res.headers['retry-after']) > 0);
});

test('login: un éxito reinicia el contador del correo', async () => {
  await h.registerUser({ email: 'reinicio@example.com' });
  for (let i = 0; i < 4; i += 1) await login('reinicio@example.com', 'incorrecta1').expect(401);
  await login('reinicio@example.com', 'password123').expect(200);
  for (let i = 0; i < 4; i += 1) await login('reinicio@example.com', 'incorrecta1').expect(401);
  await login('reinicio@example.com', 'password123').expect(200);
});

test('login: el bloqueo es por correo+IP, así que otro correo no queda bloqueado', async () => {
  await h.registerUser({ email: 'victima@example.com' });
  await h.registerUser({ email: 'otra@example.com' });
  for (let i = 0; i < 5; i += 1) await login('victima@example.com', 'incorrecta1').expect(401);
  await login('victima@example.com', 'password123').expect(429);
  await login('otra@example.com', 'password123').expect(200);
});

test('login: cuenta inexistente también se limita (no revela si el correo existe)', async () => {
  for (let i = 0; i < 5; i += 1) await login('fantasma@example.com', 'incorrecta1').expect(401);
  const res = await login('fantasma@example.com', 'incorrecta1').expect(429);
  assert.equal(res.body.code, 'too_many_attempts');
});

test('login: una IP que prueba muchos correos distintos también se frena', async () => {
  for (let i = 0; i < 50; i += 1) await login(`prueba${i}@example.com`, 'incorrecta1').expect(401);
  await login('prueba99@example.com', 'incorrecta1').expect(429);
});

test('las confirmaciones de contraseña (cambiar clave, correo, borrar cuenta) comparten un límite por usuario', async () => {
  const u = await h.registerUser({ email: 'sesion@example.com' });
  for (let i = 0; i < 5; i += 1) await u.post('/auth/delete-account').send({ password: 'incorrecta1' }).expect(403);
  const res = await u.post('/auth/delete-account').send({ password: 'password123' }).expect(429);
  assert.equal(res.body.code, 'too_many_attempts');
  await u.post('/auth/password').send({ current_password: 'password123', new_password: 'nueva-clave-456' }).expect(429);
  await u.post('/auth/email').send({ email: 'otro@example.com', password: 'password123' }).expect(429);
  assert.equal(await rowsOf('categories', u.user.id) > 0, true, 'nada se borró');
  // otro usuario no se ve afectado
  const b = await h.registerUser();
  await b.post('/auth/email').send({ email: 'b2@example.com', password: 'password123' }).expect(200);
});

test('el limitador libera la clave al terminar la ventana, acota su memoria y clear/reset funcionan', () => {
  let t = 1_000;
  const l = createAttemptLimiter({ max: 2, windowMs: 1_000, now: () => t });
  l.check('a');
  l.fail('a'); l.fail('a');
  assert.throws(() => l.check('a'), (e) => e.status === 429 && e.code === 'too_many_attempts' && e.retryAfter === 1);
  l.check('b'); // otra clave no se ve afectada
  t += 999;
  assert.throws(() => l.check('a'), { status: 429 });
  t += 1; // la ventana se cumple
  l.check('a');
  l.fail('a'); l.fail('a');
  l.clear('a');
  l.check('a');
  l.fail('a'); l.fail('a');
  l.reset();
  l.check('a');

  // memoria acotada: nunca guarda más de 10 000 claves aunque todas estén vigentes
  const small = createAttemptLimiter({ max: 1, windowMs: 60_000, now: () => t });
  small.fail('primera');
  for (let i = 0; i < 10_050; i += 1) small.fail(`k${i}`);
  small.check('primera'); // la más antigua fue sacrificada (ya no está bloqueada)
  assert.throws(() => small.check('k10049'), { status: 429 });
});
