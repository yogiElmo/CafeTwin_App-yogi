// Request-validation and auth-gate behaviour that fails BEFORE any
// database call is made -- these run with no Postgres required, in every
// environment, and would catch a regression in the checks themselves
// (e.g. someone loosening a required-field check by accident).

const request = require('supertest');
const app = require('../server');

describe('input validation (no database required)', () => {
  // These post with no credentials, so they only reach the validation
  // checks when the auth gate is in its zero-config local-dev mode (no
  // API_KEY set). That has always been true of the write gate; it matters
  // more now that API_KEY also gates the organization READ endpoints, so
  // pin it explicitly here rather than depending on the ambient
  // environment -- otherwise this suite passes or fails based on whether
  // whoever ran it happened to export API_KEY.
  const savedApiKey = process.env.API_KEY;

  beforeAll(() => {
    delete process.env.API_KEY;
  });

  afterAll(() => {
    if (savedApiKey === undefined) delete process.env.API_KEY;
    else process.env.API_KEY = savedApiKey;
  });

  it('POST /organizations rejects a missing name/stations', async () => {
    const res = await request(app).post('/organizations').send({});
    expect(res.status).toBe(400);
  });

  it('POST /auth/login rejects missing fields', async () => {
    const res = await request(app)
      .post('/auth/login')
      .send({ username: 'admin' });
    expect(res.status).toBe(400);
  });

  it('POST /stations/:id/telemetry rejects missing readings', async () => {
    const res = await request(app)
      .post('/stations/ST-01/telemetry')
      .send({ cpuTemp: 50 });
    expect(res.status).toBe(400);
  });

  it('POST /stations/:id/alerts rejects missing fields', async () => {
    const res = await request(app)
      .post('/stations/ST-01/alerts')
      .send({ ruleCode: 'HW-CRIT' });
    expect(res.status).toBe(400);
  });
});

describe('write-route auth gate', () => {
  it('rejects a garbage bearer token with 401 before touching the database', async () => {
    const res = await request(app)
      .post('/organizations')
      .set('Authorization', 'Bearer not-a-real-token')
      .send({ name: 'x', stations: [{ category: 'Gaming' }] });
    expect(res.status).toBe(401);
  });

  // Organization-scoped GETs used to be wide open: no guard at all, so
  // anyone holding a UUID could read a café's stations, alerts, telemetry
  // and report entries without logging in. They are now behind
  // requireAnyUserOrService + orgAccessError.
  //
  // Anonymous reads follow exactly the same rule the write gate has always
  // used: with no API_KEY configured (the zero-config local-dev default)
  // they are let through, and once API_KEY is set they are rejected. This
  // test asserts both halves rather than the old blanket "reads are open".
  //
  // Note this is only about ANONYMOUS callers. A logged-in staff member is
  // scoped to their own organization regardless of API_KEY, because the
  // Bearer branch runs first and orgAccessError then applies -- see
  // tests/staffScoping.test.js.
  it('gates GET routes the same way the write gate does', async () => {
    const hadApiKey = process.env.API_KEY;

    delete process.env.API_KEY;
    const open = await request(app).get('/stations/ST-01/telemetry');
    // 200 (empty list) or a DB-layer 500 with no Postgres -- never 401/403.
    expect([200, 500]).toContain(open.status);

    process.env.API_KEY = 'validation-test-key';
    const gated = await request(app).get('/stations/ST-01/telemetry');
    expect(gated.status).toBe(401);

    if (hadApiKey === undefined) delete process.env.API_KEY;
    else process.env.API_KEY = hadApiKey;
  });
});
