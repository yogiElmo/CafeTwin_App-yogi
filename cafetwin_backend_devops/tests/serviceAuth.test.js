// Service-caller (no Bearer token) gate and proxy trust. Everything here is
// decided before any database call, so this suite needs no Postgres.

const request = require('supertest');

describe('service caller gate (no database required)', () => {
  let app;
  const saved = { API_KEY: process.env.API_KEY, NODE_ENV: process.env.NODE_ENV };

  beforeAll(() => {
    app = require('../server');
  });

  afterEach(() => {
    for (const [key, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  });

  // An empty body fails validation with 400 -- so 400 means "got past the
  // auth gate", 401 means "stopped at it".
  const createOrg = () => request(app).post('/organizations').send({});

  it('lets anonymous callers through with no API_KEY outside production', async () => {
    delete process.env.API_KEY;
    process.env.NODE_ENV = 'development';
    expect((await createOrg()).status).toBe(400);
  });

  it('fails closed in production when API_KEY is not set', async () => {
    delete process.env.API_KEY;
    process.env.NODE_ENV = 'production';
    expect((await createOrg()).status).toBe(401);
    expect((await request(app).get('/stations/ST-01/telemetry')).status).toBe(401);
  });

  it('does not treat a missing x-api-key header as matching a missing API_KEY', async () => {
    delete process.env.API_KEY;
    process.env.NODE_ENV = 'production';
    const res = await request(app).post('/organizations').set('x-api-key', '').send({});
    expect(res.status).toBe(401);
  });

  it('accepts the correct x-api-key and rejects a wrong one', async () => {
    process.env.API_KEY = 'service-auth-test-key';
    process.env.NODE_ENV = 'production';
    const ok = await request(app).post('/organizations').set('x-api-key', 'service-auth-test-key').send({});
    expect(ok.status).toBe(400);

    const wrong = await request(app).post('/organizations').set('x-api-key', 'service-auth-test-kez').send({});
    expect(wrong.status).toBe(401);

    const short = await request(app).post('/organizations').set('x-api-key', 'nope').send({});
    expect(short.status).toBe(401);
  });
});

describe('trust proxy (TRUST_PROXY)', () => {
  const savedTrustProxy = process.env.TRUST_PROXY;

  afterEach(() => {
    if (savedTrustProxy === undefined) delete process.env.TRUST_PROXY;
    else process.env.TRUST_PROXY = savedTrustProxy;
  });

  function loadApp() {
    let app;
    jest.isolateModules(() => {
      app = require('../server');
    });
    return app;
  }

  it('does not trust X-Forwarded-For by default', () => {
    delete process.env.TRUST_PROXY;
    expect(loadApp().get('trust proxy')).toBe(false);
  });

  it('trusts the configured number of proxy hops', () => {
    process.env.TRUST_PROXY = '1';
    expect(loadApp().get('trust proxy')).toBe(1);
  });

  it('uses the forwarded client address for req.ip when enabled', async () => {
    process.env.TRUST_PROXY = '1';
    const app = loadApp();
    // The login limiter keys on req.ip, so with the proxy trusted two
    // different forwarded clients must get independent buckets.
    const attempt = (ip) => request(app)
      .post('/auth/login')
      .set('X-Forwarded-For', ip)
      .send({ username: 'nobody' });
    for (let i = 0; i < 10; i += 1) {
      // eslint-disable-next-line no-await-in-loop
      await attempt('203.0.113.1');
    }
    expect((await attempt('203.0.113.1')).status).toBe(429);
    expect((await attempt('203.0.113.2')).status).toBe(400);
  });
});
