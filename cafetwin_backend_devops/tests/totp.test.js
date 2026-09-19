// TOTP multi-factor auth round trip -- setup -> enable -> gated login ->
// recovery codes -> disable. Needs a live Postgres with the MFA columns/
// table from init.sql (admins.totp_secret/totp_enabled,
// totp_recovery_codes). Same graceful skip as tests/auth.test.js when no
// database is reachable, so `npm test` stays green on a laptop with no
// Postgres running.

const request = require('supertest');
const bcrypt = require('bcryptjs');
const { authenticator } = require('otplib');
const app = require('../server');
const { pool, isDbReachable, closeDb } = require('./dbHelper');

let dbUp = false;

beforeAll(async () => {
  dbUp = await isDbReachable();
  if (!dbUp) {
    // eslint-disable-next-line no-console
    console.warn(
      '\n[tests/totp.test.js] No reachable Postgres (checked PG* env vars) ' +
        '-- skipping database-backed assertions in this file. Run ' +
        '`docker compose up -d postgres` locally, or rely on CI\'s Postgres ' +
        'service container, to exercise these for real.\n'
    );
  }
});

afterAll(async () => {
  await closeDb();
});

describe('TOTP multi-factor auth (requires a live database)', () => {
  const username = `test-mfa-admin-${Date.now()}`;
  const staffUsername = `test-mfa-staff-${Date.now()}`;
  const password = 'Sup3rSecret!23';
  const pin = '4321';
  let adminToken;

  beforeAll(async () => {
    if (!dbUp) return;
    await pool.query(
      `INSERT INTO admins (username, password_hash, pin_hash, role)
       VALUES ($1, $2, $3, 'admin')`,
      [username, await bcrypt.hash(password, 10), await bcrypt.hash(pin, 10)]
    );
    await pool.query(
      `INSERT INTO admins (username, password_hash, pin_hash, role)
       VALUES ($1, $2, $3, 'staff')`,
      [staffUsername, await bcrypt.hash(password, 10), await bcrypt.hash(pin, 10)]
    );
    const login = await request(app).post('/auth/login').send({ username, password, pin });
    adminToken = login.body.token;
  });

  afterAll(async () => {
    if (!dbUp) return;
    await pool.query('DELETE FROM admins WHERE username IN ($1, $2)', [username, staffUsername]);
  });

  it('reports MFA as not enabled before setup', async () => {
    if (!dbUp) return;
    const res = await request(app)
      .get('/auth/totp/status')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(res.body.enabled).toBe(false);
  });

  // MFA used to be admin-only; it is now open to staff as well --
  // available, never mandatory. The original reasoning (café-floor
  // terminals are shared, so a second factor there is friction with no
  // real payoff) argues against FORCING MFA on staff, not against offering
  // it to a staff member who has their own device. See the TOTP section
  // comment in server.js.
  it('is available to a staff account as well as an admin', async () => {
    if (!dbUp) return;
    const staffLogin = await request(app).post('/auth/login').send({
      username: staffUsername,
      password,
      pin,
    });
    const res = await request(app)
      .post('/auth/totp/setup')
      .set('Authorization', `Bearer ${staffLogin.body.token}`);
    expect(res.status).toBe(200);
    expect(typeof res.body.secret).toBe('string');
    // Scoped to the staff member's own account, not the admin's.
    expect(res.body.otpauthUrl).toContain(staffUsername);
  });

  let secret;

  it('generates a secret and an otpauth:// URI scoped to this admin', async () => {
    if (!dbUp) return;
    const res = await request(app)
      .post('/auth/totp/setup')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(res.status).toBe(200);
    expect(typeof res.body.secret).toBe('string');
    expect(res.body.otpauthUrl).toContain('otpauth://totp/');
    expect(res.body.otpauthUrl).toContain(encodeURIComponent(username));
    secret = res.body.secret;
  });

  it('refuses to enable with a wrong code', async () => {
    if (!dbUp) return;
    const res = await request(app)
      .post('/auth/totp/enable')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ totpCode: '000000' });
    expect(res.status).toBe(401);
  });

  let recoveryCodes;

  it('enables MFA with a valid code and returns 8 recovery codes', async () => {
    if (!dbUp) return;
    const res = await request(app)
      .post('/auth/totp/enable')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ totpCode: authenticator.generate(secret) });
    expect(res.status).toBe(200);
    expect(res.body.enabled).toBe(true);
    expect(res.body.recoveryCodes).toHaveLength(8);
    recoveryCodes = res.body.recoveryCodes;

    const status = await request(app)
      .get('/auth/totp/status')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(status.body.enabled).toBe(true);
  });

  it('rejects a login with only password+PIN once MFA is on', async () => {
    if (!dbUp) return;
    const res = await request(app).post('/auth/login').send({ username, password, pin });
    expect(res.status).toBe(401);
    expect(res.body.requiresTotp).toBe(true);
  });

  it('rejects a login with a wrong code', async () => {
    if (!dbUp) return;
    const res = await request(app)
      .post('/auth/login')
      .send({ username, password, pin, totpCode: '000000' });
    expect(res.status).toBe(401);
    expect(res.body.requiresTotp).toBe(true);
  });

  it('logs in with a valid TOTP code', async () => {
    if (!dbUp) return;
    const res = await request(app)
      .post('/auth/login')
      .send({ username, password, pin, totpCode: authenticator.generate(secret) });
    expect(res.status).toBe(200);
    expect(typeof res.body.token).toBe('string');
  });

  it('logs in with a recovery code in place of a TOTP code, then rejects it a second time', async () => {
    if (!dbUp) return;
    const code = recoveryCodes[0];
    const first = await request(app)
      .post('/auth/login')
      .send({ username, password, pin, totpCode: code });
    expect(first.status).toBe(200);

    const second = await request(app)
      .post('/auth/login')
      .send({ username, password, pin, totpCode: code });
    expect(second.status).toBe(401);
    expect(second.body.requiresTotp).toBe(true);
  });

  it('refuses to disable MFA with the wrong password', async () => {
    if (!dbUp) return;
    const res = await request(app)
      .post('/auth/totp/disable')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ password: 'wrong-password', pin });
    expect(res.status).toBe(401);
  });

  it('disables MFA with the correct password+PIN, after which login needs no code', async () => {
    if (!dbUp) return;
    const disable = await request(app)
      .post('/auth/totp/disable')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ password, pin });
    expect(disable.status).toBe(204);

    const status = await request(app)
      .get('/auth/totp/status')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(status.body.enabled).toBe(false);

    const login = await request(app).post('/auth/login').send({ username, password, pin });
    expect(login.status).toBe(200);
  });
});
