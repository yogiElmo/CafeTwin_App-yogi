// Concurrency and retention behaviour of the data layer: report-entry
// upserts, alert ids, and telemetry pruning. Like the other DB-backed
// suites, every test no-ops when no Postgres is reachable; CI's Postgres
// service container runs them for real.

const request = require('supertest');
const app = require('../server');
const { pruneTelemetry } = require('../retention');
const { pool, isDbReachable, closeDb } = require('./dbHelper');

let dbUp = false;
let orgId = null;
let stationId = null;
const savedEnv = { API_KEY: process.env.API_KEY, NODE_ENV: process.env.NODE_ENV };

beforeAll(async () => {
  dbUp = await isDbReachable();
  if (!dbUp) {
    // eslint-disable-next-line no-console
    console.warn('\n[tests/dataIntegrity.test.js] No reachable Postgres -- skipping.\n');
    return;
  }
  // Zero-config local-dev mode: anonymous service caller, no login needed.
  delete process.env.API_KEY;
  process.env.NODE_ENV = 'test';

  const res = await request(app)
    .post('/organizations')
    .send({ name: `Integrity ${Date.now()}`, stations: [{ category: 'Gaming' }] });
  orgId = res.body.organizationId;
  stationId = res.body.stations[0].id;
});

afterAll(async () => {
  for (const [key, value] of Object.entries(savedEnv)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
  if (dbUp && orgId) await pool.query('DELETE FROM organizations WHERE id = $1', [orgId]);
  await closeDb();
});

describe('report entries', () => {
  it('collapses concurrent posts of the same entry into one row', async () => {
    if (!dbUp) return;
    const entry = { stationId, kind: 'optimization', title: 'Same insight', detail: 'd' };
    const responses = await Promise.all(
      Array.from({ length: 8 }, () =>
        request(app).post(`/organizations/${orgId}/report-entries`).send(entry))
    );
    const statuses = responses.map((r) => r.status).sort();
    expect(statuses).toEqual([200, 200, 200, 200, 200, 200, 200, 201]);

    const rows = await pool.query(
      'SELECT occurrences FROM report_entries WHERE organization_id = $1 AND title = $2',
      [orgId, 'Same insight']
    );
    expect(rows.rows).toHaveLength(1);
    expect(rows.rows[0].occurrences).toBe(8);
  });

  it('gives distinct entries posted at the same moment distinct ids', async () => {
    if (!dbUp) return;
    const responses = await Promise.all(
      Array.from({ length: 5 }, (_, i) =>
        request(app)
          .post(`/organizations/${orgId}/report-entries`)
          .send({ kind: 'prediction', title: `Distinct ${i}`, detail: 'd' }))
    );
    expect(responses.map((r) => r.status)).toEqual([201, 201, 201, 201, 201]);
    expect(new Set(responses.map((r) => r.body.id)).size).toBe(5);
    expect(responses[0].body).not.toHaveProperty('inserted');
  });

  it('treats a missing station as its own identity, not a wildcard', async () => {
    if (!dbUp) return;
    const title = 'Org-wide vs station';
    const orgWide = await request(app)
      .post(`/organizations/${orgId}/report-entries`)
      .send({ kind: 'optimization', title, detail: 'd' });
    const perStation = await request(app)
      .post(`/organizations/${orgId}/report-entries`)
      .send({ stationId, kind: 'optimization', title, detail: 'd' });
    expect(orgWide.status).toBe(201);
    expect(perStation.status).toBe(201);
    expect(perStation.body.id).not.toBe(orgWide.body.id);
  });
});

describe('alerts', () => {
  it('does not collide when the same alert is raised twice at once', async () => {
    if (!dbUp) return;
    const alert = {
      ruleCode: 'HW-CRIT', category: 'hardware', severity: 'critical',
      message: 'hot', suggestion: 'cool it',
    };
    const responses = await Promise.all(
      Array.from({ length: 5 }, () => request(app).post(`/stations/${stationId}/alerts`).send(alert))
    );
    expect(responses.map((r) => r.status)).toEqual([201, 201, 201, 201, 201]);
  });
});

describe('telemetry retention', () => {
  it('deletes readings older than the window and keeps recent ones', async () => {
    if (!dbUp) return;
    await pool.query(
      `INSERT INTO telemetry (station_id, cpu_temp, gpu_temp, cpu_load, gpu_load,
         bandwidth_mbps, latency_ms, packet_loss, recorded_at)
       VALUES ($1, 1, 1, 1, 1, 1, 1, 0, now() - interval '31 days'),
              ($1, 2, 2, 2, 2, 2, 2, 0, now() - interval '29 days'),
              ($1, 3, 3, 3, 3, 3, 3, 0, now())`,
      [stationId]
    );
    const deleted = await pruneTelemetry(pool, 30);
    expect(deleted).toBeGreaterThanOrEqual(1);

    const left = await pool.query(
      'SELECT cpu_temp FROM telemetry WHERE station_id = $1 ORDER BY cpu_temp',
      [stationId]
    );
    expect(left.rows.map((r) => r.cpu_temp)).toEqual([2, 3]);
  });
});
