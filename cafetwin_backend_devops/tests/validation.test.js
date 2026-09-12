// Request-validation and auth-gate behaviour that fails BEFORE any
// database call is made -- these run with no Postgres required, in every
// environment, and would catch a regression in the checks themselves
// (e.g. someone loosening a required-field check by accident).

const request = require('supertest');
const app = require('../server');

describe('input validation (no database required)', () => {
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

  it('leaves GET routes open (no auth required to read)', async () => {
    const res = await request(app).get('/stations/ST-01/telemetry');
    // No auth error either way -- 200 (empty list) or a DB-layer 500 in an
    // environment with no Postgres, but never 401/403.
    expect([200, 500]).toContain(res.status);
  });
});
