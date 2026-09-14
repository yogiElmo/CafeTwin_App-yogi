// GET/DELETE /auth/sessions + POST /auth/logout -- server-side auth
// session tracking. These are login/auth sessions (one row per device
// login), distinct from the gameplay `sessions` table covered by
// organizations.test.js's station-session endpoints. Needs a live
// Postgres with the `auth_sessions` table from init.sql; like the other
// auth-dependent test files, everything here no-ops (with a console
// warning) when no database is reachable.

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
      '\n[tests/authSessions.test.js] No reachable Postgres (checked PG* env vars) ' +
        '-- skipping database-backed assertions in this file. Run ' +
        '`docker compose up -d postgres` locally, or rely on CI\'s Postgres ' +
        'service container, to exercise these for real.\n'
    );
  }
});

afterAll(async () => {
  await closeDb();
});

describe('auth sessions (requires a live database)', () => {
  const username = `test-session-${Date.now()}`;
  const password = 'Sup3rSecret!23';
  const pin = '9876';

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
    // Cascades to auth_sessions via its admin_id -> admins(id) ON DELETE CASCADE.
    await pool.query('DELETE FROM admins WHERE username = $1', [username]);
  });

  it('rejects GET /auth/sessions with no token', async () => {
    if (!dbUp) return;
    const res = await request(app).get('/auth/sessions');
    expect(res.status).toBe(401);
  });

  it('lists the session just created by login, flagged as current', async () => {
    if (!dbUp) return;
    const login = await request(app).post('/auth/login').send({ username, password, pin });
    expect(login.status).toBe(200);
    const token = login.body.token;

    const res = await request(app).get('/auth/sessions').set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body)).toBe(true);
    expect(res.body.length).toBeGreaterThanOrEqual(1);
    expect(res.body.some((s) => s.current === true && s.revokedAt === null)).toBe(true);
  });

  it('a second login creates a second, separate session', async () => {
    if (!dbUp) return;
    const loginA = await request(app).post('/auth/login').send({ username, password, pin });
    const loginB = await request(app).post('/auth/login').send({ username, password, pin });
    const tokenB = loginB.body.token;

    const res = await request(app).get('/auth/sessions').set('Authorization', `Bearer ${tokenB}`);
    expect(res.status).toBe(200);
    // Both logins' sessions belong to the same account, so both show up.
    expect(res.body.length).toBeGreaterThanOrEqual(2);
    // Exactly one of them is "current" from tokenB's point of view.
    expect(res.body.filter((s) => s.current === true).length).toBe(1);
    void loginA;
  });

  it('POST /auth/logout revokes the current session; the token is then rejected', async () => {
    if (!dbUp) return;
    const login = await request(app).post('/auth/login').send({ username, password, pin });
    const token = login.body.token;

    const logoutRes = await request(app).post('/auth/logout').set('Authorization', `Bearer ${token}`);
    expect(logoutRes.status).toBe(204);

    const res = await request(app).get('/auth/sessions').set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(401);
    expect(res.body.error).toMatch(/logged out/i);
  });

  it('DELETE /auth/sessions/:id revokes a specific (non-current) session', async () => {
    if (!dbUp) return;
    const loginA = await request(app).post('/auth/login').send({ username, password, pin });
    const loginB = await request(app).post('/auth/login').send({ username, password, pin });
    const tokenA = loginA.body.token;
    const tokenB = loginB.body.token;

    // From B's perspective, find A's session (the one that isn't "current").
    const list = await request(app).get('/auth/sessions').set('Authorization', `Bearer ${tokenB}`);
    const otherSession = list.body.find((s) => s.current === false);
    expect(otherSession).toBeTruthy();

    const del = await request(app)
      .delete(`/auth/sessions/${otherSession.id}`)
      .set('Authorization', `Bearer ${tokenB}`);
    expect(del.status).toBe(204);

    // Token A should now be rejected -- its session was the one just revoked.
    const check = await request(app).get('/auth/sessions').set('Authorization', `Bearer ${tokenA}`);
    expect(check.status).toBe(401);
  });

  it('DELETE /auth/sessions/:id returns 404 for a session that is not yours', async () => {
    if (!dbUp) return;
    const otherUsername = `test-session-other-${Date.now()}`;
    await pool.query(
      `INSERT INTO admins (username, password_hash, pin_hash, role)
       VALUES ($1, $2, $3, 'admin')`,
      [otherUsername, await bcrypt.hash(password, 10), await bcrypt.hash(pin, 10)]
    );
    try {
      const mine = await request(app).post('/auth/login').send({ username, password, pin });
      const theirs = await request(app)
        .post('/auth/login')
        .send({ username: otherUsername, password, pin });

      const theirSessions = await request(app)
        .get('/auth/sessions')
        .set('Authorization', `Bearer ${theirs.body.token}`);
      const theirSessionId = theirSessions.body[0].id;

      const del = await request(app)
        .delete(`/auth/sessions/${theirSessionId}`)
        .set('Authorization', `Bearer ${mine.body.token}`);
      expect(del.status).toBe(404);
    } finally {
      await pool.query('DELETE FROM admins WHERE username = $1', [otherUsername]);
    }
  });
});
