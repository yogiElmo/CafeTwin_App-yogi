// GET /organizations -- an admin's own organization list, scoped by the new
// organizations.created_by column. Like the other auth-dependent test
// files, everything here no-ops (with a console warning) when no Postgres
// is reachable.

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
      '\n[tests/organizations.test.js] No reachable Postgres (checked PG* env vars) ' +
        '-- skipping database-backed assertions in this file. Run ' +
        '`docker compose up -d postgres` locally, or rely on CI\'s Postgres ' +
        'service container, to exercise these for real.\n'
    );
  }
});

afterAll(async () => {
  await closeDb();
});

describe('GET /organizations (requires a live database)', () => {
  const ownerUsername = `test-org-owner-${Date.now()}`;
  const ownerPassword = 'Sup3rSecret!23';
  const ownerPin = '1122';

  const otherAdminUsername = `test-org-other-${Date.now()}`;
  const otherAdminPassword = 'AnotherSecret!45';
  const otherAdminPin = '3344';

  const usersToCleanUp = [ownerUsername, otherAdminUsername];
  const orgNamesToCleanUp = [
    `Owner Org A ${Date.now()}`,
    `Owner Org B ${Date.now()}`,
    `Other Admin Org ${Date.now()}`,
  ];

  let ownerToken = null;
  let otherAdminToken = null;

  beforeAll(async () => {
    if (!dbUp) return;
    await pool.query(
      `INSERT INTO admins (username, password_hash, pin_hash, role)
       VALUES ($1, $2, $3, 'admin')`,
      [ownerUsername, await bcrypt.hash(ownerPassword, 10), await bcrypt.hash(ownerPin, 10)]
    );
    await pool.query(
      `INSERT INTO admins (username, password_hash, pin_hash, role)
       VALUES ($1, $2, $3, 'admin')`,
      [otherAdminUsername, await bcrypt.hash(otherAdminPassword, 10), await bcrypt.hash(otherAdminPin, 10)]
    );

    const ownerLogin = await request(app)
      .post('/auth/login')
      .send({ username: ownerUsername, password: ownerPassword, pin: ownerPin });
    ownerToken = ownerLogin.body.token;

    const otherLogin = await request(app)
      .post('/auth/login')
      .send({ username: otherAdminUsername, password: otherAdminPassword, pin: otherAdminPin });
    otherAdminToken = otherLogin.body.token;

    // Owner creates two organizations; the other admin creates one. Each
    // POST /organizations call attaches created_by from the caller's JWT.
    await request(app)
      .post('/organizations')
      .set('Authorization', `Bearer ${ownerToken}`)
      .send({ name: orgNamesToCleanUp[0], stations: [{ category: 'Gaming' }, { category: 'Office' }] });
    await request(app)
      .post('/organizations')
      .set('Authorization', `Bearer ${ownerToken}`)
      .send({ name: orgNamesToCleanUp[1], stations: [{ category: 'Gaming' }] });
    await request(app)
      .post('/organizations')
      .set('Authorization', `Bearer ${otherAdminToken}`)
      .send({ name: orgNamesToCleanUp[2], stations: [{ category: 'Gaming' }] });
  });

  afterAll(async () => {
    if (!dbUp) return;
    await pool.query('DELETE FROM organizations WHERE name = ANY($1)', [orgNamesToCleanUp]);
    await pool.query('DELETE FROM admins WHERE username = ANY($1)', [usersToCleanUp]);
  });

  it('rejects listing organizations with no token', async () => {
    if (!dbUp) return;
    const res = await request(app).get('/organizations');
    expect(res.status).toBe(401);
  });

  it('rejects the legacy x-api-key for this admin-only route', async () => {
    if (!dbUp || !process.env.API_KEY) return;
    const res = await request(app).get('/organizations').set('x-api-key', process.env.API_KEY);
    expect(res.status).toBe(401);
  });

  it("returns only the calling admin's own organizations, with a station count", async () => {
    if (!dbUp) return;
    const res = await request(app)
      .get('/organizations')
      .set('Authorization', `Bearer ${ownerToken}`);
    expect(res.status).toBe(200);
    const names = res.body.map((o) => o.name);
    expect(names).toEqual(expect.arrayContaining([orgNamesToCleanUp[0], orgNamesToCleanUp[1]]));
    expect(names).not.toContain(orgNamesToCleanUp[2]);

    const orgA = res.body.find((o) => o.name === orgNamesToCleanUp[0]);
    expect(orgA.station_count).toBe(2);
    const orgB = res.body.find((o) => o.name === orgNamesToCleanUp[1]);
    expect(orgB.station_count).toBe(1);
  });

  it("does not leak one admin's organizations into another admin's list", async () => {
    if (!dbUp) return;
    const res = await request(app)
      .get('/organizations')
      .set('Authorization', `Bearer ${otherAdminToken}`);
    expect(res.status).toBe(200);
    const names = res.body.map((o) => o.name);
    expect(names).toEqual([orgNamesToCleanUp[2]]);
  });
});

describe('DELETE /organizations/:id (requires a live database)', () => {
  const ownerUsername = `test-org-del-owner-${Date.now()}`;
  const ownerPassword = 'Sup3rSecret!23';
  const ownerPin = '5566';

  const otherAdminUsername = `test-org-del-other-${Date.now()}`;
  const otherAdminPassword = 'AnotherSecret!45';
  const otherAdminPin = '7788';

  const usersToCleanUp = [ownerUsername, otherAdminUsername];
  const orgNameToKeep = `Owner Org To Keep ${Date.now()}`;
  const orgNameToDelete = `Owner Org To Delete ${Date.now()}`;

  let ownerToken = null;
  let otherAdminToken = null;
  let orgIdToDelete = null;
  let orgIdToKeep = null;

  beforeAll(async () => {
    if (!dbUp) return;
    await pool.query(
      `INSERT INTO admins (username, password_hash, pin_hash, role)
       VALUES ($1, $2, $3, 'admin')`,
      [ownerUsername, await bcrypt.hash(ownerPassword, 10), await bcrypt.hash(ownerPin, 10)]
    );
    await pool.query(
      `INSERT INTO admins (username, password_hash, pin_hash, role)
       VALUES ($1, $2, $3, 'admin')`,
      [otherAdminUsername, await bcrypt.hash(otherAdminPassword, 10), await bcrypt.hash(otherAdminPin, 10)]
    );

    const ownerLogin = await request(app)
      .post('/auth/login')
      .send({ username: ownerUsername, password: ownerPassword, pin: ownerPin });
    ownerToken = ownerLogin.body.token;

    const otherLogin = await request(app)
      .post('/auth/login')
      .send({ username: otherAdminUsername, password: otherAdminPassword, pin: otherAdminPin });
    otherAdminToken = otherLogin.body.token;

    const createToDelete = await request(app)
      .post('/organizations')
      .set('Authorization', `Bearer ${ownerToken}`)
      .send({ name: orgNameToDelete, stations: [{ category: 'Gaming' }] });
    orgIdToDelete = createToDelete.body.organizationId;

    const createToKeep = await request(app)
      .post('/organizations')
      .set('Authorization', `Bearer ${ownerToken}`)
      .send({ name: orgNameToKeep, stations: [{ category: 'Gaming' }] });
    orgIdToKeep = createToKeep.body.organizationId;
  });

  afterAll(async () => {
    if (!dbUp) return;
    await pool.query('DELETE FROM organizations WHERE name = ANY($1)', [
      [orgNameToDelete, orgNameToKeep],
    ]);
    await pool.query('DELETE FROM admins WHERE username = ANY($1)', [usersToCleanUp]);
  });

  it('rejects deleting with no token', async () => {
    if (!dbUp) return;
    const res = await request(app).delete(`/organizations/${orgIdToDelete}`);
    expect(res.status).toBe(401);
  });

  it("refuses to delete another admin's organization (404, not leaked as 403)", async () => {
    if (!dbUp) return;
    const res = await request(app)
      .delete(`/organizations/${orgIdToDelete}`)
      .set('Authorization', `Bearer ${otherAdminToken}`);
    expect(res.status).toBe(404);
  });

  it('lets the owning admin delete their own organization, cascading its stations', async () => {
    if (!dbUp) return;
    const res = await request(app)
      .delete(`/organizations/${orgIdToDelete}`)
      .set('Authorization', `Bearer ${ownerToken}`);
    expect(res.status).toBe(204);

    const stationsLeft = await pool.query(
      'SELECT COUNT(*)::int AS n FROM stations WHERE organization_id = $1',
      [orgIdToDelete]
    );
    expect(stationsLeft.rows[0].n).toBe(0);

    const listRes = await request(app)
      .get('/organizations')
      .set('Authorization', `Bearer ${ownerToken}`);
    const names = listRes.body.map((o) => o.name);
    expect(names).not.toContain(orgNameToDelete);
    expect(names).toContain(orgNameToKeep);
  });

  it('returns 404 for an id that no longer exists (already deleted)', async () => {
    if (!dbUp) return;
    const res = await request(app)
      .delete(`/organizations/${orgIdToDelete}`)
      .set('Authorization', `Bearer ${ownerToken}`);
    expect(res.status).toBe(404);
  });

  it('does not delete the other admin\'s organization it does not own', async () => {
    // Sanity check that orgIdToKeep is untouched (guards against a bug
    // that deletes by created_by alone, ignoring the id).
    if (!dbUp) return;
    const check = await pool.query('SELECT id FROM organizations WHERE id = $1', [orgIdToKeep]);
    expect(check.rows).toHaveLength(1);
  });
});
