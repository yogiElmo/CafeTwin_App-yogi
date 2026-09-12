// Routes that need no database connection at all -- always run, in every
// environment, since they only exercise Express itself.

const request = require('supertest');
const app = require('../server');

describe('GET /health', () => {
  it('returns ok', async () => {
    const res = await request(app).get('/health');
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: 'ok' });
  });
});

describe('GET /', () => {
  it('returns the running message', async () => {
    const res = await request(app).get('/');
    expect(res.status).toBe(200);
    expect(res.text).toMatch(/CaféTwin backend is running/);
  });
});
