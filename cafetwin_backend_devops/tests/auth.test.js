// POST /auth/login round trip -- needs a live Postgres with the `admins`
// table from init.sql. When no database is reachable (checked once, up
// front) every test in this file no-ops with a console warning instead of
// failing the whole suite, so `npm test` stays green on a laptop with no
// Postgres running. CI provides a real Postgres service container (see
// .github/workflows/backend-tests.yml) so these assertions are actually
// exercised there, and locally via `docker compose up -d postgres`.

const request = require('supertest');
const bcrypt = require('bcryptjs');
const app = require('../server');
const { pool, isDbReachable, closeDb } = require('./dbHelper');

let dbUp = false;

beforeAll(async () => {
  dbUp = await isDbReachable();
  if (!dbUp) {
    // eslint-disable-next-line no-console
    console.warn(
      '\n[tests/auth.test.js] No reachable Postgres (checked PG* env vars) ' +
        '-- skipping database-backed assertions in this file. Run ' +
        '`docker compose up -d postgres` locally, or rely on CI\'s Postgres ' +
        'service container, to exercise these for real.\n'
    );
  }
});

afterAll(async () => {
  await closeDb();
});

describe('POST /auth/login (requires a live database)', () => {
  const username = `test-admin-${Date.now()}`;
  const password = 'Sup3rSecret!23';
  const pin = '4321';
  let createdOrgId = null;

  beforeAll(async () => {
    if (!dbUp) return;
    await pool.query(
      `INSERT INTO admins (username, password_hash, pin_hash, role)
       VALUES ($1, $2, $3, 'admin')`,
      [username, await bcrypt.hash(password, 10), await bcrypt.hash(pin, 10)]
    );
  });

  afterAll(async () => {
    if (!dbUp) return;
    await pool.query('DELETE FROM admins WHERE username = $1', [username]);
    if (createdOrgId) {
      await pool.query('DELETE FROM organizations WHERE id = $1', [createdOrgId]);
    }
  });

  it('issues a JWT for correct credentials', async () => {
    if (!dbUp) return;
    const res = await request(app).post('/auth/login').send({ username, password, pin });
    expect(res.status).toBe(200);
    expect(typeof res.body.token).toBe('string');
    expect(res.body.token.length).toBeGreaterThan(10);
  });

  it('rejects the wrong password', async () => {
    if (!dbUp) return;
    const res = await request(app)
      .post('/auth/login')
      .send({ username, password: 'wrong-password', pin });
    expect(res.status).toBe(401);
  });

  it('rejects the wrong PIN', async () => {
    if (!dbUp) return;
    const res = await request(app)
      .post('/auth/login')
      .send({ username, password, pin: '0000' });
    expect(res.status).toBe(401);
  });

  it('rejects an unknown username', async () => {
    if (!dbUp) return;
    const res = await request(app)
      .post('/auth/login')
      .send({ username: 'no-such-user', password, pin });
    expect(res.status).toBe(401);
  });

  it('lets a token from a successful login through the write-route auth gate', async () => {
    if (!dbUp) return;
    const login = await request(app).post('/auth/login').send({ username, password, pin });
    const token = login.body.token;

    const res = await request(app)
      .post('/organizations')
      .set('Authorization', `Bearer ${token}`)
      .send({ name: 'CaféTwin Test Org', stations: [{ category: 'Gaming' }] });

    expect(res.status).toBe(201);
    createdOrgId = res.body.organizationId;
  });
});
