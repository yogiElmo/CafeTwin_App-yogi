// GET/POST /admin/users -- multi-user accounts with roles ("admin" vs
// "staff"). Like tests/auth.test.js, these need a live Postgres with the
// `admins` table from init.sql; every test no-ops (with a console warning)
// when no database is reachable, so `npm test` stays green with no
// Postgres running. CI's Postgres service container exercises these for
// real (see .github/workflows/backend-tests.yml).

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
      '\n[tests/adminUsers.test.js] No reachable Postgres (checked PG* env vars) ' +
        '-- skipping database-backed assertions in this file. Run ' +
        '`docker compose up -d postgres` locally, or rely on CI\'s Postgres ' +
        'service container, to exercise these for real.\n'
    );
  }
});

afterAll(async () => {
  await closeDb();
});

describe('GET/POST /admin/users (requires a live database)', () => {
  const adminUsername = `test-admin-${Date.now()}`;
  const adminPassword = 'Sup3rSecret!23';
  const adminPin = '1357';

  const staffUsername = `test-staff-${Date.now()}`;
  const staffPassword = 'AnotherSecret!45';
  const staffPin = '2468';

  const newUsername = `test-new-${Date.now()}`;
  const usersToCleanUp = [adminUsername, staffUsername, newUsername];

  let adminToken = null;
  let staffToken = null;
  let organizationId = null;

  beforeAll(async () => {
    if (!dbUp) return;
    await pool.query(
      `INSERT INTO admins (username, password_hash, pin_hash, role)
       VALUES ($1, $2, $3, 'admin')`,
      [adminUsername, await bcrypt.hash(adminPassword, 10), await bcrypt.hash(adminPin, 10)]
    );
    await pool.query(
      `INSERT INTO admins (username, password_hash, pin_hash, role)
       VALUES ($1, $2, $3, 'staff')`,
      [staffUsername, await bcrypt.hash(staffPassword, 10), await bcrypt.hash(staffPin, 10)]
    );

    const adminLogin = await request(app)
      .post('/auth/login')
      .send({ username: adminUsername, password: adminPassword, pin: adminPin });
    adminToken = adminLogin.body.token;

    const staffLogin = await request(app)
      .post('/auth/login')
      .send({ username: staffUsername, password: staffPassword, pin: staffPin });
    staffToken = staffLogin.body.token;

    // A staff account must now name the organization it belongs to, so
    // this suite needs one owned by adminUsername to create staff in.
    // tests/staffScoping.test.js covers the rules that enforcement adds.
    const orgRes = await request(app)
      .post('/organizations')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({
        name: `admin-users-org-${Date.now()}`,
        stations: [{ name: 'ST-01', category: 'gaming' }],
      });
    organizationId = orgRes.body.organizationId;
  });

  afterAll(async () => {
    if (!dbUp) return;
    await pool.query('DELETE FROM admins WHERE username = ANY($1)', [usersToCleanUp]);
    if (organizationId) {
      await pool.query('DELETE FROM organizations WHERE id = $1', [organizationId]);
    }
  });

  it('rejects listing users with no token', async () => {
    if (!dbUp) return;
    const res = await request(app).get('/admin/users');
    expect(res.status).toBe(401);
  });

  it('rejects listing users for a non-admin (staff) token', async () => {
    if (!dbUp) return;
    const res = await request(app)
      .get('/admin/users')
      .set('Authorization', `Bearer ${staffToken}`);
    expect(res.status).toBe(403);
  });

  it('rejects the legacy x-api-key for admin routes even if API_KEY is set', async () => {
    if (!dbUp || !process.env.API_KEY) return;
    const res = await request(app)
      .get('/admin/users')
      .set('x-api-key', process.env.API_KEY);
    expect(res.status).toBe(401);
  });

  it('lets an admin list users, without exposing password/pin hashes', async () => {
    if (!dbUp) return;
    const res = await request(app)
      .get('/admin/users')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body)).toBe(true);
    const row = res.body.find((u) => u.username === adminUsername);
    expect(row).toBeDefined();
    expect(row.role).toBe('admin');
    expect(row.password_hash).toBeUndefined();
    expect(row.pin_hash).toBeUndefined();
  });

  it('rejects a non-admin (staff) creating a new user', async () => {
    if (!dbUp) return;
    const res = await request(app)
      .post('/admin/users')
      .set('Authorization', `Bearer ${staffToken}`)
      .send({ username: newUsername, password: 'Whatever!23', pin: '9999' });
    expect(res.status).toBe(403);
  });

  it('lets an admin create a new user, defaulting role to "staff"', async () => {
    if (!dbUp) return;
    const res = await request(app)
      .post('/admin/users')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ username: newUsername, password: 'Whatever!23', pin: '9999', organizationId });
    expect(res.status).toBe(201);
    expect(res.body.username).toBe(newUsername);
    expect(res.body.role).toBe('staff');
  });

  it('rejects creating a user with a username that is already taken', async () => {
    if (!dbUp) return;
    const res = await request(app)
      .post('/admin/users')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ username: newUsername, password: 'Whatever!23', pin: '9999', organizationId });
    expect(res.status).toBe(409);
  });

  it('rejects creating a user with missing fields', async () => {
    if (!dbUp) return;
    const res = await request(app)
      .post('/admin/users')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ username: 'incomplete-user' });
    expect(res.status).toBe(400);
  });

  it('rejects creating a user with an invalid role', async () => {
    if (!dbUp) return;
    const res = await request(app)
      .post('/admin/users')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ username: 'bad-role-user', password: 'Whatever!23', pin: '9999', role: 'superuser' });
    expect(res.status).toBe(400);
  });
});

describe('DELETE /admin/users/:username (requires a live database)', () => {
  const adminUsername = `test-del-admin-${Date.now()}`;
  const adminPassword = 'Sup3rSecret!23';
  const adminPin = '1357';

  const secondAdminUsername = `test-del-admin2-${Date.now()}`;

  const staffUsername = `test-del-staff-${Date.now()}`;
  const staffPassword = 'AnotherSecret!45';
  const staffPin = '2468';

  const usersToCleanUp = [adminUsername, secondAdminUsername, staffUsername];

  let adminToken = null;
  let staffToken = null;

  beforeAll(async () => {
    if (!dbUp) return;
    await pool.query(
      `INSERT INTO admins (username, password_hash, pin_hash, role)
       VALUES ($1, $2, $3, 'admin')`,
      [adminUsername, await bcrypt.hash(adminPassword, 10), await bcrypt.hash(adminPin, 10)]
    );
    await pool.query(
      `INSERT INTO admins (username, password_hash, pin_hash, role)
       VALUES ($1, $2, $3, 'admin')`,
      [secondAdminUsername, await bcrypt.hash('Whatever!99', 10), await bcrypt.hash('1111', 10)]
    );
    await pool.query(
      `INSERT INTO admins (username, password_hash, pin_hash, role)
       VALUES ($1, $2, $3, 'staff')`,
      [staffUsername, await bcrypt.hash(staffPassword, 10), await bcrypt.hash(staffPin, 10)]
    );

    const adminLogin = await request(app)
      .post('/auth/login')
      .send({ username: adminUsername, password: adminPassword, pin: adminPin });
    adminToken = adminLogin.body.token;

    const staffLogin = await request(app)
      .post('/auth/login')
      .send({ username: staffUsername, password: staffPassword, pin: staffPin });
    staffToken = staffLogin.body.token;
  });

  afterAll(async () => {
    if (!dbUp) return;
    await pool.query('DELETE FROM admins WHERE username = ANY($1)', [usersToCleanUp]);
  });

  it('rejects deleting with no token', async () => {
    if (!dbUp) return;
    const res = await request(app).delete(`/admin/users/${staffUsername}`);
    expect(res.status).toBe(401);
  });

  it('rejects a non-admin (staff) deleting anyone', async () => {
    if (!dbUp) return;
    const res = await request(app)
      .delete(`/admin/users/${adminUsername}`)
      .set('Authorization', `Bearer ${staffToken}`);
    expect(res.status).toBe(403);
  });

  it('refuses to let an admin delete the account they are logged in as', async () => {
    if (!dbUp) return;
    const res = await request(app)
      .delete(`/admin/users/${adminUsername}`)
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(400);
  });

  it('lets an admin delete a different, non-admin account', async () => {
    if (!dbUp) return;
    const res = await request(app)
      .delete(`/admin/users/${staffUsername}`)
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(204);
  });

  it('refuses to delete the last remaining admin account, even when the ' +
    'caller is not literally "deleting themselves"', async () => {
    if (!dbUp) return;
    // The self-delete guard only catches a token deleting its own username.
    // This test isolates the separate "last admin" count guard: adminToken
    // stays structurally valid even after its own row is gone (JWTs aren't
    // revoked server-side), which is exactly the scenario the count guard
    // exists for -- a stale-but-valid admin token must not be able to wipe
    // out the one admin account left standing.
    await pool.query('DELETE FROM admins WHERE username = $1', [adminUsername]);
    const res = await request(app)
      .delete(`/admin/users/${secondAdminUsername}`)
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(400);
  });

  it('returns 404 for a username that does not exist', async () => {
    if (!dbUp) return;
    const res = await request(app)
      .delete('/admin/users/no-such-user-at-all')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(404);
  });
});
