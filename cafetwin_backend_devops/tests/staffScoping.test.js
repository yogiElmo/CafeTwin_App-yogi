// Staff role scoping: a staff account belongs to exactly ONE organization,
// cannot create organizations, and cannot read any organization other than
// its own. Also covers the read endpoints that used to be unauthenticated
// GETs, and admin-vs-admin isolation.
//
// Same pattern as the other DB-backed suites: every test no-ops (with a
// console warning) when no Postgres is reachable, so `npm test` stays green
// locally with nothing running. CI's Postgres service container exercises
// them for real.

const request = require('supertest');
const app = require('../server');
const { pool, isDbReachable, closeDb } = require('./dbHelper');

let dbUp = false;

beforeAll(async () => {
  dbUp = await isDbReachable();
  if (!dbUp) {
    // eslint-disable-next-line no-console
    console.warn(
      '\n[tests/staffScoping.test.js] No reachable Postgres (checked PG* env ' +
        'vars) -- skipping database-backed assertions in this file. Run ' +
        '`docker compose up -d postgres` locally, or rely on CI\'s Postgres ' +
        'service container, to exercise these for real.\n'
    );
  }
});

afterAll(async () => {
  await closeDb();
});

describe('staff organization scoping (requires a live database)', () => {
  const stamp = Date.now();
  const adminA = { username: `scope-admin-a-${stamp}`, password: 'AdminAPass!23', pin: '1111' };
  const adminB = { username: `scope-admin-b-${stamp}`, password: 'AdminBPass!23', pin: '2222' };
  const staffA = { username: `scope-staff-a-${stamp}`, password: 'StaffAPass!23', pin: '3333' };

  const usersToCleanUp = [adminA.username, adminB.username, staffA.username];
  const orgsToCleanUp = [];

  let adminAToken = null;
  let adminBToken = null;
  let staffAToken = null;
  let orgAId = null;
  let orgBId = null;
  let stationAId = null;

  // Creates an admin directly in the database (bypassing /admin/users, which
  // itself requires an admin) and logs it in.
  async function makeAdmin({ username, password, pin }) {
    const bcrypt = require('bcryptjs');
    await pool.query(
      `INSERT INTO admins (username, password_hash, pin_hash, role)
       VALUES ($1, $2, $3, 'admin')`,
      [username, await bcrypt.hash(password, 4), await bcrypt.hash(pin, 4)]
    );
    const res = await request(app).post('/auth/login').send({ username, password, pin });
    return res.body.token;
  }

  beforeAll(async () => {
    if (!dbUp) return;

    adminAToken = await makeAdmin(adminA);
    adminBToken = await makeAdmin(adminB);

    const orgARes = await request(app)
      .post('/organizations')
      .set('Authorization', `Bearer ${adminAToken}`)
      .send({ name: `Café A ${stamp}`, stations: [{ name: 'ST-01', category: 'gaming' }] });
    orgAId = orgARes.body.organizationId;
    if (orgAId) orgsToCleanUp.push(orgAId);

    const orgBRes = await request(app)
      .post('/organizations')
      .set('Authorization', `Bearer ${adminBToken}`)
      .send({ name: `Café B ${stamp}`, stations: [{ name: 'ST-01', category: 'gaming' }] });
    orgBId = orgBRes.body.organizationId;
    if (orgBId) orgsToCleanUp.push(orgBId);

    const stationRes = await pool.query(
      'SELECT id FROM stations WHERE organization_id = $1 LIMIT 1',
      [orgAId]
    );
    stationAId = stationRes.rows[0] && stationRes.rows[0].id;

    // Admin A creates a staff member inside Café A.
    await request(app)
      .post('/admin/users')
      .set('Authorization', `Bearer ${adminAToken}`)
      .send({ ...staffA, role: 'staff', organizationId: orgAId });

    const staffLogin = await request(app).post('/auth/login').send({
      username: staffA.username,
      password: staffA.password,
      pin: staffA.pin,
    });
    staffAToken = staffLogin.body.token;
  });

  afterAll(async () => {
    if (!dbUp) return;
    await pool.query('DELETE FROM admins WHERE username = ANY($1)', [usersToCleanUp]);
    for (const id of orgsToCleanUp) {
      await pool.query('DELETE FROM organizations WHERE id = $1', [id]);
    }
  });

  // --- account creation ---------------------------------------------------

  it('refuses to create a staff account without an organization', async () => {
    if (!dbUp) return;
    const res = await request(app)
      .post('/admin/users')
      .set('Authorization', `Bearer ${adminAToken}`)
      .send({ username: `no-org-${stamp}`, password: 'NoOrgPass!23', pin: '9999', role: 'staff' });
    expect(res.status).toBe(400);
    expect(res.body.error).toMatch(/organizationId/);
  });

  it("refuses to put staff in another admin's organization", async () => {
    if (!dbUp) return;
    const res = await request(app)
      .post('/admin/users')
      .set('Authorization', `Bearer ${adminAToken}`)
      .send({
        username: `wrong-org-${stamp}`,
        password: 'WrongOrgPass!23',
        pin: '9998',
        role: 'staff',
        organizationId: orgBId,
      });
    expect(res.status).toBe(403);
  });

  it('records the assigned organization on the staff account', async () => {
    if (!dbUp) return;
    const result = await pool.query(
      'SELECT organization_id FROM admins WHERE username = $1',
      [staffA.username]
    );
    expect(result.rows[0].organization_id).toBe(orgAId);
  });

  it('returns organizationId at login for staff, and null for an admin', async () => {
    if (!dbUp) return;
    const staffLogin = await request(app).post('/auth/login').send({
      username: staffA.username,
      password: staffA.password,
      pin: staffA.pin,
    });
    expect(staffLogin.body.organizationId).toBe(orgAId);

    const adminLogin = await request(app).post('/auth/login').send({
      username: adminA.username,
      password: adminA.password,
      pin: adminA.pin,
    });
    expect(adminLogin.body.organizationId).toBeNull();
  });

  // --- creating organizations --------------------------------------------

  it('does not let a staff account create an organization', async () => {
    if (!dbUp) return;
    const res = await request(app)
      .post('/organizations')
      .set('Authorization', `Bearer ${staffAToken}`)
      .send({ name: `Sneaky Café ${stamp}`, stations: [{ name: 'ST-01', category: 'gaming' }] });
    expect(res.status).toBe(403);
    expect(res.body.error).toMatch(/admin/i);
  });

  it('still lets an admin create an organization', async () => {
    if (!dbUp) return;
    const res = await request(app)
      .post('/organizations')
      .set('Authorization', `Bearer ${adminAToken}`)
      .send({ name: `Café A2 ${stamp}`, stations: [{ name: 'ST-01', category: 'gaming' }] });
    expect(res.status).toBe(201);
    if (res.body.organizationId) orgsToCleanUp.push(res.body.organizationId);
  });

  // --- reading organizations ---------------------------------------------

  it('lets staff read their own organization', async () => {
    if (!dbUp) return;
    const res = await request(app)
      .get(`/organizations/${orgAId}`)
      .set('Authorization', `Bearer ${staffAToken}`);
    expect(res.status).toBe(200);
    expect(res.body.id).toBe(orgAId);
  });

  it("does not let staff read another organization", async () => {
    if (!dbUp) return;
    const res = await request(app)
      .get(`/organizations/${orgBId}`)
      .set('Authorization', `Bearer ${staffAToken}`);
    expect(res.status).toBe(403);
  });

  it("does not let an admin read another admin's organization", async () => {
    if (!dbUp) return;
    const res = await request(app)
      .get(`/organizations/${orgBId}`)
      .set('Authorization', `Bearer ${adminAToken}`);
    expect(res.status).toBe(403);
  });

  it('rejects an unauthenticated read of an organization', async () => {
    if (!dbUp || !process.env.API_KEY) return;
    const res = await request(app).get(`/organizations/${orgAId}`);
    expect(res.status).toBe(401);
  });

  it("blocks staff from another organization's alerts and report entries", async () => {
    if (!dbUp) return;
    const alerts = await request(app)
      .get(`/organizations/${orgBId}/alerts`)
      .set('Authorization', `Bearer ${staffAToken}`);
    expect(alerts.status).toBe(403);

    const entries = await request(app)
      .get(`/organizations/${orgBId}/report-entries`)
      .set('Authorization', `Bearer ${staffAToken}`);
    expect(entries.status).toBe(403);
  });

  it("blocks staff from telemetry belonging to another organization's station", async () => {
    if (!dbUp) return;
    const stationB = await pool.query(
      'SELECT id FROM stations WHERE organization_id = $1 LIMIT 1',
      [orgBId]
    );
    if (!stationB.rows[0]) return;
    const res = await request(app)
      .get(`/stations/${stationB.rows[0].id}/telemetry`)
      .set('Authorization', `Bearer ${staffAToken}`);
    expect(res.status).toBe(403);
  });

  it('lets staff read telemetry for a station in their own organization', async () => {
    if (!dbUp || !stationAId) return;
    const res = await request(app)
      .get(`/stations/${stationAId}/telemetry`)
      .set('Authorization', `Bearer ${staffAToken}`);
    expect(res.status).toBe(200);
  });

  // --- MFA is open to staff ----------------------------------------------

  it('lets a staff account read and start its own MFA setup', async () => {
    if (!dbUp) return;
    const status = await request(app)
      .get('/auth/totp/status')
      .set('Authorization', `Bearer ${staffAToken}`);
    expect(status.status).toBe(200);
    expect(status.body.enabled).toBe(false);

    const setup = await request(app)
      .post('/auth/totp/setup')
      .set('Authorization', `Bearer ${staffAToken}`);
    expect(setup.status).toBe(200);
    expect(typeof setup.body.secret).toBe('string');
    expect(setup.body.otpauthUrl).toContain(staffA.username);
  });

  it('still keeps user management admin-only', async () => {
    if (!dbUp) return;
    const res = await request(app)
      .get('/admin/users')
      .set('Authorization', `Bearer ${staffAToken}`);
    expect(res.status).toBe(403);
  });
});
