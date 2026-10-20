// Las pruebas usan TEST_DATABASE_URL y la vacían entre pruebas: debe terminar en _test.
const url = process.env.TEST_DATABASE_URL;
if (!url || !/_test(\?|$)/.test(url)) {
  throw new Error('Define TEST_DATABASE_URL apuntando a una BD cuyo nombre termine en _test');
}
process.env.DATABASE_URL = url;
process.env.JWT_SECRET = 'secreto-solo-para-pruebas';
process.env.BCRYPT_ROUNDS = '4';
process.env.SYNC_SAFETY_LAG_MS = '0';

const request = require('supertest');
const app = require('../src/app');
const { pool } = require('../src/db/pool');
const { migrate } = require('../src/db/migrate');

const api = () => request(app);

async function setup() {
  await migrate();
}
async function reset() {
  await pool.query('TRUNCATE users CASCADE');
}
async function teardown() {
  await pool.end();
}

let counter = 0;
async function registerUser(overrides = {}) {
  counter += 1;
  const body = { email: `user${counter}@example.com`, password: 'password123', name: `Usuario ${counter}`, ...overrides };
  const res = await api().post('/auth/register').send(body).expect(201);
  const token = res.body.token;
  const as = (method, path) => api()[method](path).set('Authorization', `Bearer ${token}`);
  return { token, user: res.body.user, as, get: (p) => as('get', p), post: (p) => as('post', p),
    patch: (p) => as('patch', p), del: (p) => as('delete', p) };
}

async function categoryId(u, kind, name) {
  const res = await u.get(`/categories?kind=${kind}`).expect(200);
  return res.body.data.find((c) => c.name === name).id;
}

async function bankId(name = 'BBVA México') {
  const { rows } = await pool.query('SELECT id FROM banks WHERE name = $1', [name]);
  return rows[0].id;
}

module.exports = { api, setup, reset, teardown, registerUser, categoryId, bankId };
