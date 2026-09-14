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
