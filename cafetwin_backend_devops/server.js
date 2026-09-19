// CaféTwin backend API — full version covering all 6 tables.
// Hardened per cafetwin_backend_security guidance: helmet headers,
// rate limiting, request logging, env-driven DB config (so the same
// image runs in Docker Compose, Render/Railway, or bare metal),
// and an optional API-key gate on write endpoints.

require('dotenv').config();
const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const rateLimit = require('express-rate-limit');
const morgan = require('morgan');
const { Pool } = require('pg');
const squidController = require('./squid_controller');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const crypto = require('crypto');
const fs = require('fs');
// TOTP (RFC 6238) multi-factor auth -- see the "TOTP MULTI-FACTOR
// AUTHENTICATION" section below. Pinned to the otplib v12 line
// deliberately: v13 rewrote the API around async, plugin-supplied crypto
// backends, which buys nothing here and would only add moving parts;
// v12's synchronous `authenticator` helper is the same one nearly every
// "add 2FA" tutorial and Stack Overflow answer for Node uses, it has no
// known vulnerabilities (checked via `npm audit`), and it's a couple of
// hundred lines of well-understood code away from the standard it
// implements. Revisit only if a real vulnerability turns up in v12.
const { authenticator } = require('otplib');
const path = require('path');

const app = express();

// --- Auth (JWT) -----------------------------------------------------------
// JWT_SECRET should be a long random value set in the environment for
// production (Render's render.yaml already generates one). If unset, a
// random secret is generated for this process only -- tokens stop working
// across restarts, which is a safe (if inconvenient) default rather than a
// shared hardcoded fallback.
const JWT_SECRET = process.env.JWT_SECRET || crypto.randomBytes(32).toString('hex');
if (!process.env.JWT_SECRET) {
  console.warn('[auth] JWT_SECRET not set - using a random per-process secret. '
    + 'Set JWT_SECRET in the environment for production.');
}
const JWT_EXPIRES_IN = '8h';

// --- Security middleware -----------------------------------------------
app.use(helmet());
app.use(morgan(process.env.NODE_ENV === 'production' ? 'combined' : 'dev'));

// Restrict CORS to known origins in production; wide open in dev so
// `flutter run -d chrome` works without extra config.
const allowedOrigins = (process.env.CORS_ORIGINS || '*')
  .split(',')
  .map((o) => o.trim());
app.use(cors({
  origin: allowedOrigins.includes('*') ? true : allowedOrigins,
}));

app.use(express.json({ limit: '100kb' }));

// General rate limit for every route.
app.use(rateLimit({
  windowMs: 60 * 1000,
  max: Number(process.env.RATE_LIMIT_PER_MIN || 120),
  standardHeaders: true,
  legacyHeaders: false,
}));

// Verifies a Bearer JWT's signature/expiry AND -- when the token carries a
// session "jti" claim (every token issued by the current POST /auth/login;
// see AUTH SESSIONS below) -- that the session behind it hasn't been
// revoked via logout or DELETE /auth/sessions/:id. A token with no jti
// (issued before this feature existed, or found unrecognized in the
// table) is treated as always-valid until it expires naturally, so
// deploying this doesn't invalidate anyone already logged in.
//
// Returns { decoded } on success, or { error, message } to send straight
// back to the client -- callers below just relay whichever comes back.
async function authenticateBearer(req) {
  const authHeader = req.get('authorization') || '';
  if (!authHeader.startsWith('Bearer ')) {
    return { error: 401, message: 'This endpoint requires a Bearer token from a logged-in user.' };
  }
  let decoded;
  try {
    decoded = jwt.verify(authHeader.slice(7), JWT_SECRET);
  } catch (err) {
    return { error: 401, message: 'Invalid or expired token.' };
  }
  if (await isSessionRevoked(decoded.jti)) {
    return { error: 401, message: 'This session has been logged out. Please log in again.' };
  }
  return { decoded };
}

async function isSessionRevoked(jti) {
  if (!jti) return false;
  try {
    const result = await pool.query('SELECT revoked_at FROM auth_sessions WHERE jti = $1', [jti]);
    if (result.rows.length === 0) return false; // unrecognized jti -- fail open, don't break it
    return result.rows[0].revoked_at !== null;
  } catch (err) {
    console.error('[auth] failed checking session revocation:', err);
    return false; // a DB hiccup here should not lock everyone out
  }
}

// Fire-and-forget: bumps last_seen_at so GET /auth/sessions can show which
// session is actually still active, without adding latency to the request
// that triggered it.
function touchSession(jti) {
  if (!jti) return;
  pool
    .query('UPDATE auth_sessions SET last_seen_at = now() WHERE jti = $1 AND revoked_at IS NULL', [jti])
    .catch((err) => console.error('[auth] failed to update session last_seen_at:', err));
}

// Write routes accept EITHER a valid JWT (issued by POST /auth/login --
// the app's real authenticated path) OR the legacy x-api-key shared
// secret (for service-to-service callers such as simulate.js that never
// go through a human login). /auth/login itself is exempt (that's where
// a client gets a token in the first place).
async function requireAuth(req, res, next) {
  const authHeader = req.get('authorization') || '';
  if (authHeader.startsWith('Bearer ')) {
    const auth = await authenticateBearer(req);
    if (auth.error) return res.status(auth.error).json({ error: auth.message });
    req.user = auth.decoded;
    touchSession(auth.decoded.jti);
    return next();
  }
  if (!process.env.API_KEY) return next();
  if (req.get('x-api-key') === process.env.API_KEY) return next();
  return res.status(401).json({ error: 'Missing or invalid credentials (Bearer token or x-api-key).' });
}
app.use((req, res, next) => {
  if (['POST', 'PATCH', 'PUT', 'DELETE'].includes(req.method) && req.path !== '/auth/login') {
    return requireAuth(req, res, next);
  }
  next();
});

// Role-gated middleware for admin-only endpoints (e.g. user management).
// Unlike requireAuth above -- which accepts either a real login JWT or the
// legacy x-api-key shared secret for service callers -- this requires a
// genuine Bearer JWT specifically. A service-account x-api-key has no
// associated user or role, so it can never satisfy a role check.
function requireRole(role) {
  return async (req, res, next) => {
    const auth = await authenticateBearer(req);
    if (auth.error) return res.status(auth.error).json({ error: auth.message });
    if (auth.decoded.role !== role) {
      return res.status(403).json({ error: `This action requires the "${role}" role.` });
    }
    req.user = auth.decoded;
    touchSession(auth.decoded.jti);
    next();
  };
}

// Same as requireRole, but for endpoints any logged-in account (admin or
// staff) may use on their OWN behalf -- viewing/revoking their own auth
// sessions, managing their own MFA. A service-account x-api-key never
// satisfies this either, since there is no account behind it to scope
// "own sessions" to.
async function requireAnyUser(req, res, next) {
  const auth = await authenticateBearer(req);
  if (auth.error) return res.status(auth.error).json({ error: auth.message });
  req.user = auth.decoded;
  touchSession(auth.decoded.jti);
  next();
}

// For POST /organizations. Creating a café is an ADMIN action: staff are
// assigned to exactly one organization by an admin and must never be able
// to make their own. But this endpoint also has a legitimate non-human
// caller -- simulate.js seeds demo data through the legacy x-api-key path
// -- and requireRole('admin') would lock that out, since a service key has
// no role attached. So: a Bearer token must carry role 'admin', while a
// valid x-api-key is still accepted as a service caller.
//
// The `!API_KEY` escape hatch mirrors requireAuth's: with no API_KEY
// configured (the default for local development) an unauthenticated caller
// is let through, exactly as it was before this guard existed. A staff
// Bearer token is still rejected either way -- the token branch is checked
// first, so having a login never *lowers* what you are allowed to do.
async function requireAdminOrService(req, res, next) {
  const authHeader = req.get('authorization') || '';
  if (authHeader.startsWith('Bearer ')) {
    const auth = await authenticateBearer(req);
    if (auth.error) return res.status(auth.error).json({ error: auth.message });
    if (auth.decoded.role !== 'admin') {
      return res.status(403).json({
        error: 'Only an admin can create an organization. Staff accounts are '
          + 'assigned to one by an admin.',
      });
    }
    req.user = auth.decoded;
    touchSession(auth.decoded.jti);
    return next();
  }
  if (!process.env.API_KEY) return next();
  if (req.get('x-api-key') === process.env.API_KEY) return next();
  return res.status(401).json({ error: 'Missing or invalid credentials (Bearer token or x-api-key).' });
}

// Attaches req.user when a Bearer token is present, accepts a service
// x-api-key with no user attached, and rejects anything else. Used to put
// a door on the organization READ endpoints, which were plain GETs with no
// guard at all -- the global gate above only covers write methods, so
// anyone holding an organization's UUID could read its name, stations,
// alerts and report entries without logging in.
async function requireAnyUserOrService(req, res, next) {
  const authHeader = req.get('authorization') || '';
  if (authHeader.startsWith('Bearer ')) {
    const auth = await authenticateBearer(req);
    if (auth.error) return res.status(auth.error).json({ error: auth.message });
    req.user = auth.decoded;
    touchSession(auth.decoded.jti);
    return next();
  }
  if (!process.env.API_KEY) return next();
  if (req.get('x-api-key') === process.env.API_KEY) return next();
  return res.status(401).json({ error: 'Missing or invalid credentials (Bearer token or x-api-key).' });
}

// Single place that answers "may this caller touch this organization?".
// Returns null when allowed, or { status, error } to send back.
//
//   service caller (no req.user) -> everything; simulate.js and other
//       machine callers hold the shared secret and are trusted by it.
//   staff  -> only the organization on their own admins row. A staff
//       account whose organization was deleted (organization_id is now
//       NULL) can read nothing until an admin reassigns it.
//   admin  -> only organizations they created. Organizations with a NULL
//       created_by are also allowed: those predate the created_by column
//       or were seeded through the x-api-key path, and blocking them would
//       hide existing demo data from every admin.
//
// Deliberately re-reads role and organization_id from the database rather
// than trusting the JWT's copy, so revoking or reassigning a staff member
// takes effect on their next request instead of whenever their 8-hour
// token happens to expire.
async function orgAccessError(req, organizationId) {
  if (!req.user) return null;
  if (!organizationId) return { status: 404, error: 'Organization not found.' };

  const accountResult = await pool.query(
    'SELECT role, organization_id FROM admins WHERE id = $1',
    [req.user.sub]
  );
  const account = accountResult.rows[0];
  if (!account) return { status: 401, error: 'That account no longer exists.' };

  if (account.role === 'staff') {
    if (!account.organization_id || account.organization_id !== organizationId) {
      return { status: 403, error: 'Your account is not assigned to this organization.' };
    }
    return null;
  }

  const orgResult = await pool.query(
    'SELECT created_by FROM organizations WHERE id = $1',
    [organizationId]
  );
  if (orgResult.rows.length === 0) return { status: 404, error: 'Organization not found.' };
  const createdBy = orgResult.rows[0].created_by;
  if (createdBy && createdBy !== req.user.sub) {
    return { status: 403, error: 'That organization belongs to another admin.' };
  }
  return null;
}

// Same check, for the station-scoped routes: resolves the station to its
// organization first. A station id that does not exist is reported as 404
// rather than 403, since there is no organization to be denied access to.
async function stationOrgAccessError(req, stationId) {
  if (!req.user) return null;
  const result = await pool.query(
    'SELECT organization_id FROM stations WHERE id = $1',
    [stationId]
  );
  if (result.rows.length === 0) return { status: 404, error: 'Station not found.' };
  return orgAccessError(req, result.rows[0].organization_id);
}

// --- Database ------------------------------------------------------------
// Reads PG* env vars (set by docker-compose.yml / Render / Railway); falls
// back to local defaults so `node server.js` still works with zero setup.
const pool = new Pool({
  host: process.env.PGHOST || 'localhost',
  port: Number(process.env.PGPORT || 5432),
  database: process.env.PGDATABASE || 'postgres',
  user: process.env.PGUSER || 'postgres',
  password: process.env.PGPASSWORD || 'cafetwin123',
  ssl: process.env.PGSSLMODE === 'require' ? { rejectUnauthorized: false } : false,
});

app.get('/', (req, res) => {
  res.send('CaféTwin backend is running.');
});

app.get('/health', (req, res) => {
  res.json({ status: 'ok' });
});

// ============================================================
// AUTH
// ============================================================

const loginLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 10,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many login attempts - try again in a minute.' },
});

app.post('/auth/login', loginLimiter, async (req, res) => {
  const { username, password, pin, totpCode } = req.body;
  if (!username || !password || !pin) {
    return res.status(400).json({ error: 'Request must include "username", "password" and "pin".' });
  }
  try {
    const result = await pool.query('SELECT * FROM admins WHERE username = $1', [username]);
    if (result.rows.length === 0) {
      return res.status(401).json({ error: 'Invalid username, password or PIN.' });
    }
    const admin = result.rows[0];
    const [passwordOk, pinOk] = await Promise.all([
      bcrypt.compare(password, admin.password_hash),
      bcrypt.compare(pin, admin.pin_hash),
    ]);
    if (!passwordOk || !pinOk) {
      return res.status(401).json({ error: 'Invalid username, password or PIN.' });
    }

    // Second factor, admin accounts only (admins.totp_enabled -- see the
    // schema comment in init.sql). Checked only AFTER password+PIN both
    // already passed, so a wrong password never reveals whether MFA is
    // even turned on for this username. `requiresTotp: true` on the 401
    // body is what the Flutter login screen watches for to reveal the
    // code field instead of just showing a generic error -- the client
    // makes this same call twice (once without totpCode, once with it)
    // rather than the server holding any pending-login state in between.
    if (admin.totp_enabled) {
      if (!totpCode) {
        return res.status(401).json({ error: 'Authentication code required.', requiresTotp: true });
      }
      const totpOk =
        authenticator.check(totpCode, admin.totp_secret) ||
        (await tryConsumeRecoveryCode(admin.id, totpCode));
      if (!totpOk) {
        return res.status(401).json({ error: 'Invalid authentication code.', requiresTotp: true });
      }
    }

    // One auth_sessions row per login, keyed by a fresh jti embedded in the
    // token itself -- this is what GET /auth/sessions lists and what
    // POST /auth/logout / DELETE /auth/sessions/:id revoke later.
    const jti = crypto.randomUUID();
    await pool.query(
      `INSERT INTO auth_sessions (jti, admin_id, user_agent, ip) VALUES ($1, $2, $3, $4)`,
      [jti, admin.id, (req.get('user-agent') || '').slice(0, 255), req.ip]
    );
    const token = jwt.sign(
      { sub: admin.id, username: admin.username, role: admin.role, jti },
      JWT_SECRET,
      { expiresIn: JWT_EXPIRES_IN }
    );
    // organizationId is null for admins (they pick from their own list on
    // the next screen) and set for staff, who go straight into the one café
    // they are assigned to instead of being offered a chooser or a setup
    // form. The server still re-checks this on every request -- see
    // orgAccessError -- so the client is being told where to go, not being
    // trusted to decide what it may see.
    res.json({
      token,
      expiresIn: JWT_EXPIRES_IN,
      role: admin.role,
      username: admin.username,
      organizationId: admin.organization_id || null,
    });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Something went wrong during login.' });
  }
});

// ============================================================
// AUTH SESSIONS (server-side session tracking + real logout)
// ============================================================
// These are login/auth sessions -- distinct from the gameplay `sessions`
// table further down (station play-time tracking). Each row here is one
// device's login, created by POST /auth/login and looked up by jti in
// authenticateBearer above.

// Any logged-in account -- admin or staff -- can list their OWN sessions.
// "current" flags whichever row matches the token used to make this
// request, since the JWT doesn't otherwise identify itself to the caller.
app.get('/auth/sessions', requireAnyUser, async (req, res) => {
  try {
    const result = await pool.query(
      `SELECT id, jti, user_agent, ip, created_at, last_seen_at, revoked_at
       FROM auth_sessions WHERE admin_id = $1 ORDER BY created_at DESC`,
      [req.user.sub]
    );
    res.json(result.rows.map((row) => ({
      id: row.id,
      userAgent: row.user_agent,
      ip: row.ip,
      createdAt: row.created_at,
      lastSeenAt: row.last_seen_at,
      revokedAt: row.revoked_at,
      current: row.jti === req.user.jti,
    })));
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Something went wrong fetching sessions.' });
  }
});

// Revokes one of the caller's OWN sessions -- e.g. "sign out that other
// device" -- scoped by admin_id the same "not yours -> 404" way as
// DELETE /organizations/:id. There is no cross-account revoke; removing
// someone else's access entirely is DELETE /admin/users/:username.
app.delete('/auth/sessions/:id', requireAnyUser, async (req, res) => {
  const { id } = req.params;
  try {
    const result = await pool.query(
      `UPDATE auth_sessions SET revoked_at = now()
       WHERE id = $1 AND admin_id = $2 AND revoked_at IS NULL
       RETURNING id`,
      [id, req.user.sub]
    );
    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'Session not found.' });
    }
    res.status(204).end();
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Something went wrong revoking the session.' });
  }
});

// Logs out the CURRENT session -- the one this very token belongs to.
// This is what makes the app's "Logout" a real server-side action: the
// token is rejected on its next authenticated request even though it
// hasn't expired yet, rather than the client just discarding its copy.
// A token with no jti (issued before this feature existed) has nothing to
// revoke server-side; it simply expires on its own, same as before.
app.post('/auth/logout', requireAnyUser, async (req, res) => {
  if (!req.user.jti) {
    return res.status(204).end();
  }
  try {
    await pool.query(
      `UPDATE auth_sessions SET revoked_at = now() WHERE jti = $1 AND revoked_at IS NULL`,
      [req.user.jti]
    );
    res.status(204).end();
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Something went wrong logging out.' });
  }
});

// ============================================================
// TOTP MULTI-FACTOR AUTHENTICATION (any account, opt-in)
// ============================================================
// Google Authenticator, Microsoft Authenticator, Authy, 1Password, etc.
// are all just client apps for the same open standard -- TOTP, RFC 6238
// -- so there is nothing Google- or Microsoft-specific to integrate here:
// one shared secret per admin, encoded once into a QR code (rendered
// client-side by the Flutter app from the otpauthUrl below -- this
// backend never generates an image), and any TOTP-compatible app can
// scan it and start producing the same rolling 6-digit code the server
// checks with `authenticator.check`. No external account, API key, or
// network call to either company is involved.
//
// Open to BOTH roles (requireAnyUser), and mandatory for neither. These
// routes were originally admin-only, on the reasoning that café-floor
// terminals are shared and a second factor there is friction with no real
// payoff. That reasoning holds against *forcing* MFA on staff -- it does
// not hold against letting them have it: a staff member with their own
// phone gains exactly as much from a second factor as an admin does, and
// a shared till account simply never turns it on.
//
// Every route below scopes to req.user.sub, so each account manages only
// its own MFA. An admin cannot enable, disable, or read the MFA state of
// anyone else's account through these -- turning MFA off still requires
// that account's own password and PIN.
//
// What remains admin-only is the damage a compromised account can do:
// creating, deleting and reassigning accounts. That is an argument for
// admins to switch MFA on, not for denying it to staff.

const TOTP_ISSUER = 'CaféTwin';

// 10 unambiguous characters (no 0/O/1/I/L) grouped as "XXXXX-XXXXX", using
// the same randomSecret() helper /admin/bootstrap uses for generated
// passwords/PINs below.
function randomRecoveryCode() {
  const raw = randomSecret(10, 'ABCDEFGHJKMNPQRSTUVWXYZ23456789');
  return `${raw.slice(0, 5)}-${raw.slice(5)}`;
}

// Generates a fresh batch of recovery codes for one admin, storing only
// their bcrypt hashes (exactly like password_hash/pin_hash) and returning
// the plaintext codes so the caller can hand them back to the admin
// ONCE. Replaces any previous batch outright -- there is only ever one
// live set of recovery codes per account.
async function issueRecoveryCodes(adminId) {
  const codes = Array.from({ length: 8 }, randomRecoveryCode);
  await pool.query('DELETE FROM totp_recovery_codes WHERE admin_id = $1', [adminId]);
  await Promise.all(
    codes.map(async (code) => {
      const hash = await bcrypt.hash(code, 10);
      await pool.query(
        'INSERT INTO totp_recovery_codes (admin_id, code_hash) VALUES ($1, $2)',
        [adminId, hash]
      );
    })
  );
  return codes;
}

// Checked at login as a fallback when the submitted code doesn't match
// the live TOTP secret -- covers an admin who has lost their
// authenticator device. Single-use: the matched row's used_at is set
// immediately, so the same recovery code can never be replayed. Looping
// over (at most 8) bcrypt comparisons rather than hashing the submitted
// code and doing an indexed lookup is deliberate -- bcrypt hashes are
// salted, so there is no shortcut lookup, and 8 comparisons is negligible
// next to the bcrypt work /auth/login already does for password+PIN.
async function tryConsumeRecoveryCode(adminId, code) {
  const result = await pool.query(
    'SELECT id, code_hash FROM totp_recovery_codes WHERE admin_id = $1 AND used_at IS NULL',
    [adminId]
  );
  for (const row of result.rows) {
    // eslint-disable-next-line no-await-in-loop
    if (await bcrypt.compare(code, row.code_hash)) {
      await pool.query('UPDATE totp_recovery_codes SET used_at = now() WHERE id = $1', [row.id]);
      return true;
    }
  }
  return false;
}

// Whether the calling admin currently has MFA enabled -- lets the
// Flutter security screen show the right state (and the right button:
// "Set up MFA" vs "Turn off MFA") without guessing.
app.get('/auth/totp/status', requireAnyUser, async (req, res) => {
  try {
    const result = await pool.query('SELECT totp_enabled FROM admins WHERE id = $1', [req.user.sub]);
    res.json({ enabled: result.rows[0] ? result.rows[0].totp_enabled : false });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Something went wrong checking MFA status.' });
  }
});

// Step 1 of turning MFA on: generates a fresh secret and returns it plus
// the otpauth:// URI the Flutter app renders as a QR code. Writing the
// secret here does NOT make login require a code yet -- that only
// happens once POST /auth/totp/enable confirms the admin actually
// scanned it. Safe to call again if setup is abandoned partway through;
// it simply overwrites the previous pending secret.
app.post('/auth/totp/setup', requireAnyUser, async (req, res) => {
  try {
    const secret = authenticator.generateSecret();
    await pool.query('UPDATE admins SET totp_secret = $1 WHERE id = $2', [secret, req.user.sub]);
    res.json({
      secret,
      otpauthUrl: authenticator.keyuri(req.user.username, TOTP_ISSUER, secret),
    });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Something went wrong starting MFA setup.' });
  }
});

// Step 2: the admin submits the current 6-digit code from their
// authenticator app, proving they actually scanned the secret from step
// 1 rather than it just sitting unused in the database. Only on success
// does totp_enabled flip true (POST /auth/login starts requiring a code
// from this point on) and a fresh batch of recovery codes is issued --
// shown ONCE in this response, exactly like the generated admin
// password/PIN from GET /admin/bootstrap; only their bcrypt hashes are
// kept server-side.
app.post('/auth/totp/enable', requireAnyUser, async (req, res) => {
  const { totpCode } = req.body;
  if (!totpCode) {
    return res.status(400).json({ error: 'Request must include "totpCode".' });
  }
  try {
    const result = await pool.query('SELECT totp_secret FROM admins WHERE id = $1', [req.user.sub]);
    const secret = result.rows[0] && result.rows[0].totp_secret;
    if (!secret) {
      return res.status(400).json({ error: 'Call POST /auth/totp/setup first to generate a secret.' });
    }
    if (!authenticator.check(totpCode, secret)) {
      return res.status(401).json({ error: 'Invalid authentication code.' });
    }
    const recoveryCodes = await issueRecoveryCodes(req.user.sub);
    await pool.query('UPDATE admins SET totp_enabled = true WHERE id = $1', [req.user.sub]);
    res.json({
      enabled: true,
      recoveryCodes,
      note: 'Save these recovery codes now -- they will not be shown again. Each one works once, in place of a code from your authenticator app, if you lose access to it.',
    });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Something went wrong enabling MFA.' });
  }
});

// Turns MFA off. Requires the account's own current password + PIN
// rather than a totpCode, deliberately -- an admin who has already lost
// their authenticator device AND used up their recovery codes must still
// be able to turn MFA off using the same two factors that get them into
// the account in the first place, rather than being locked out entirely.
app.post('/auth/totp/disable', requireAnyUser, async (req, res) => {
  const { password, pin } = req.body;
  if (!password || !pin) {
    return res.status(400).json({ error: 'Request must include "password" and "pin".' });
  }
  try {
    const result = await pool.query('SELECT password_hash, pin_hash FROM admins WHERE id = $1', [req.user.sub]);
    const admin = result.rows[0];
    const [passwordOk, pinOk] = await Promise.all([
      bcrypt.compare(password, admin.password_hash),
      bcrypt.compare(pin, admin.pin_hash),
    ]);
    if (!passwordOk || !pinOk) {
      return res.status(401).json({ error: 'Invalid password or PIN.' });
    }
    await pool.query('UPDATE admins SET totp_enabled = false, totp_secret = NULL WHERE id = $1', [req.user.sub]);
    await pool.query('DELETE FROM totp_recovery_codes WHERE admin_id = $1', [req.user.sub]);
    res.status(204).end();
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Something went wrong disabling MFA.' });
  }
});

// Invalidates every existing recovery code and issues a fresh batch --
// for after one gets used, or just periodically. Same password+PIN
// re-authentication as disable, for the same reason.
app.post('/auth/totp/recovery-codes/regenerate', requireAnyUser, async (req, res) => {
  const { password, pin } = req.body;
  if (!password || !pin) {
    return res.status(400).json({ error: 'Request must include "password" and "pin".' });
  }
  try {
    const result = await pool.query(
      'SELECT password_hash, pin_hash, totp_enabled FROM admins WHERE id = $1',
      [req.user.sub]
    );
    const admin = result.rows[0];
    const [passwordOk, pinOk] = await Promise.all([
      bcrypt.compare(password, admin.password_hash),
      bcrypt.compare(pin, admin.pin_hash),
    ]);
    if (!passwordOk || !pinOk) {
      return res.status(401).json({ error: 'Invalid password or PIN.' });
    }
    if (!admin.totp_enabled) {
      return res.status(400).json({ error: 'MFA is not enabled on this account.' });
    }
    const recoveryCodes = await issueRecoveryCodes(req.user.sub);
    res.json({ recoveryCodes, note: 'Save these now -- the old codes no longer work.' });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Something went wrong regenerating recovery codes.' });
  }
});

// ============================================================
// ONE-TIME SETUP (schema + first admin account)
// ============================================================
// GET, not POST -- so this can be triggered with a single tap/link from
// a phone browser, no terminal needed. Gated by API_KEY (the same secret
// render.yaml already generates for this service), so only whoever holds
// that value can call it; disabled outright if API_KEY was never set.
// Safe to call more than once: every schema statement in init.sql is
// `CREATE ... IF NOT EXISTS` and the admin upsert below is
// `ON CONFLICT ... DO UPDATE`, so re-running this just rotates the admin
// password/PIN (exactly what `npm run seed` does locally) rather than
// duplicating anything or wiping existing telemetry/report data.
function randomSecret(bytes, alphabet) {
  return Array.from(crypto.randomBytes(bytes))
    .map((b) => alphabet[b % alphabet.length])
    .join('');
}

app.get('/admin/bootstrap', async (req, res) => {
  if (!process.env.API_KEY) {
    return res.status(404).end();
  }
  if (req.query.key !== process.env.API_KEY) {
    return res.status(401).json({ error: 'Missing or invalid "key" query parameter.' });
  }
  try {
    const schemaSql = fs.readFileSync(path.join(__dirname, 'init.sql'), 'utf8');
    await pool.query(schemaSql);

    const username = req.query.username || process.env.ADMIN_USERNAME || 'admin';
    let password = req.query.password || process.env.ADMIN_PASSWORD;
    let pin = req.query.pin || process.env.ADMIN_PIN;
    let generated = false;
    if (!password) {
      password = randomSecret(18, 'ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789');
      generated = true;
    }
    if (!pin) {
      pin = randomSecret(4, '0123456789');
      generated = true;
    }
    const passwordHash = await bcrypt.hash(password, 12);
    const pinHash = await bcrypt.hash(pin, 12);
    await pool.query(
      `INSERT INTO admins (username, password_hash, pin_hash, role)
       VALUES ($1, $2, $3, 'admin')
       ON CONFLICT (username) DO UPDATE
         SET password_hash = EXCLUDED.password_hash, pin_hash = EXCLUDED.pin_hash`,
      [username, passwordHash, pinHash]
    );

    res.json({
      schema: 'ok',
      admin: { username, ...(generated ? { password, pin } : {}) },
      note: generated
        ? 'Credentials generated just now -- save them, they are not shown again.'
        : 'Admin account created/updated with the username/password/pin you provided.',
    });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Bootstrap failed.', detail: err.message });
  }
});

// ============================================================
// ADMIN USER MANAGEMENT (multi-user accounts / roles)
// ============================================================
// Both routes require a real logged-in admin (a Bearer JWT with
// role === 'admin') -- the legacy x-api-key never satisfies this, by
// design, since granting user-management power to a shared service
// secret would defeat the point of having per-person accounts at all.

app.get('/admin/users', requireRole('admin'), async (req, res) => {
  try {
    const result = await pool.query(
      `SELECT a.username, a.role, a.created_at, a.organization_id, o.name AS organization_name
       FROM admins a
       LEFT JOIN organizations o ON o.id = a.organization_id
       ORDER BY a.created_at ASC`
    );
    res.json(result.rows);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Something went wrong fetching users.' });
  }
});

// A staff account MUST name the organization it belongs to, and that
// organization must be one this admin created -- otherwise an admin could
// park staff inside a café belonging to someone else. Admin accounts take
// no organization: they are scoped by what they create, not by membership
// (see the organization_id comment in init.sql).
app.post('/admin/users', requireRole('admin'), async (req, res) => {
  const { username, password, pin, role = 'staff', organizationId = null } = req.body;
  if (!username || !password || !pin) {
    return res.status(400).json({ error: 'Request must include "username", "password" and "pin".' });
  }
  if (!['admin', 'staff'].includes(role)) {
    return res.status(400).json({ error: '"role" must be "admin" or "staff".' });
  }
  if (role === 'staff' && !organizationId) {
    return res.status(400).json({
      error: 'A staff account must include "organizationId" -- the organization it is assigned to.',
    });
  }
  try {
    let assignedOrganizationId = null;
    if (role === 'staff') {
      const orgResult = await pool.query(
        'SELECT created_by FROM organizations WHERE id = $1',
        [organizationId]
      );
      if (orgResult.rows.length === 0) {
        return res.status(404).json({ error: 'That organization does not exist.' });
      }
      const createdBy = orgResult.rows[0].created_by;
      if (createdBy && createdBy !== req.user.sub) {
        return res.status(403).json({ error: 'That organization belongs to another admin.' });
      }
      assignedOrganizationId = organizationId;
    }

    const passwordHash = await bcrypt.hash(password, 12);
    const pinHash = await bcrypt.hash(pin, 12);
    const result = await pool.query(
      `INSERT INTO admins (username, password_hash, pin_hash, role, organization_id)
       VALUES ($1, $2, $3, $4, $5)
       RETURNING username, role, organization_id, created_at`,
      [username, passwordHash, pinHash, role, assignedOrganizationId]
    );
    res.status(201).json(result.rows[0]);
  } catch (err) {
    if (err.code === '23505') {
      return res.status(409).json({ error: 'That username is already taken.' });
    }
    console.error(err);
    res.status(500).json({ error: 'Something went wrong creating the user.' });
  }
});

// Admin-only: removes a login account. Two guards keep an admin from
// locking themselves (or everyone) out: you can't delete the account
// you're currently logged in as, and you can't delete the last remaining
// admin account, even a different one than your own.
app.delete('/admin/users/:username', requireRole('admin'), async (req, res) => {
  const { username } = req.params;
  if (username === req.user.username) {
    return res.status(400).json({ error: 'You cannot delete the account you are logged in as.' });
  }
  try {
    const target = await pool.query('SELECT role FROM admins WHERE username = $1', [username]);
    if (target.rows.length === 0) {
      return res.status(404).json({ error: 'No account found with that username.' });
    }
    if (target.rows[0].role === 'admin') {
      const adminCount = await pool.query("SELECT COUNT(*)::int AS n FROM admins WHERE role = 'admin'");
      if (adminCount.rows[0].n <= 1) {
        return res.status(400).json({ error: 'Cannot delete the last remaining admin account.' });
      }
    }
    await pool.query('DELETE FROM admins WHERE username = $1', [username]);
    res.status(204).end();
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Something went wrong deleting the user.' });
  }
});

// ============================================================
// ORGANIZATIONS + STATIONS
// ============================================================

// Admin-only: the organizations THIS admin has created, most recent first,
// with a station count so the list screen doesn't need a second round trip
// per organization. Scoped by created_by rather than shared globally --
// each admin sees their own cafés, not every organization in the database.
app.get('/organizations', requireRole('admin'), async (req, res) => {
  try {
    const result = await pool.query(
      `SELECT o.id, o.name, o.configured_at, COUNT(s.id)::int AS station_count
       FROM organizations o
       LEFT JOIN stations s ON s.organization_id = o.id
       WHERE o.created_by = $1
       GROUP BY o.id, o.name, o.configured_at
       ORDER BY o.configured_at DESC`,
      [req.user.sub]
    );
    res.json(result.rows);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Something went wrong fetching organizations.' });
  }
});

// Admin-or-service only. Staff are assigned to an organization by an
// admin; they must not be able to create their own -- see
// requireAdminOrService for why this is not just requireRole('admin').
app.post('/organizations', requireAdminOrService, async (req, res) => {
  const { name, stations } = req.body;
  if (!name || !Array.isArray(stations) || stations.length === 0) {
    return res.status(400).json({ error: 'Request must include "name" and a non-empty "stations" array.' });
  }

  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const orgResult = await client.query(
      'INSERT INTO organizations (name, created_by) VALUES ($1, $2) RETURNING id',
      // req.user is only set when the caller authenticated with a real
      // login JWT (see requireAuth) -- the legacy x-api-key path has no
      // associated user, so those organizations are simply unowned.
      [name, req.user ? req.user.sub : null]
    );
    const organizationId = orgResult.rows[0].id;

    const createdStations = [];
    for (let i = 0; i < stations.length; i++) {
      const number = String(i + 1).padStart(2, '0');
      const orgShort = organizationId.slice(0, 8);
      const stationId = `ST-${orgShort}-${number}`;
      const stationName = `Station ${i + 1}`;
      const category = stations[i].category || 'Gaming';
      await client.query(
        `INSERT INTO stations (id, organization_id, name, category) VALUES ($1, $2, $3, $4)`,
        [stationId, organizationId, stationName, category]
      );
      createdStations.push({ id: stationId, name: stationName, category });
    }

    await client.query('COMMIT');
    res.status(201).json({ organizationId, name, stations: createdStations });
  } catch (err) {
    await client.query('ROLLBACK');
    console.error(err);
    res.status(500).json({ error: 'Something went wrong saving the organization.' });
  } finally {
    client.release();
  }
});

// Reading one organization is now gated: previously this was an
// unauthenticated GET, so anyone holding the UUID could pull its name and
// station list. Staff get only their assigned café, admins only their own.
app.get('/organizations/:id', requireAnyUserOrService, async (req, res) => {
  const { id } = req.params;
  try {
    const denied = await orgAccessError(req, id);
    if (denied) return res.status(denied.status).json({ error: denied.error });

    const orgResult = await pool.query(
      'SELECT id, name, configured_at FROM organizations WHERE id = $1',
      [id]
    );
    if (orgResult.rows.length === 0) {
      return res.status(404).json({ error: 'Organization not found.' });
    }
    const stationsResult = await pool.query(
      'SELECT id, name, category FROM stations WHERE organization_id = $1 ORDER BY id',
      [id]
    );
    res.json({ ...orgResult.rows[0], stations: stationsResult.rows });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Something went wrong fetching the organization.' });
  }
});

// Admin-only, and further scoped to the organization's own creator: an
// admin can delete organizations they created, but not another admin's.
// 404 (not 403) for "exists but isn't yours" -- same "as far as you're
// concerned it doesn't exist" reasoning as everywhere else here that
// scopes by created_by. Cascades to that organization's stations,
// telemetry, alerts, sessions and report_entries via each table's
// existing ON DELETE CASCADE -- no separate cleanup needed here.
app.delete('/organizations/:id', requireRole('admin'), async (req, res) => {
  const { id } = req.params;
  try {
    const result = await pool.query(
      'DELETE FROM organizations WHERE id = $1 AND created_by = $2 RETURNING id',
      [id, req.user.sub]
    );
    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'Organization not found.' });
    }
    res.status(204).end();
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Something went wrong deleting the organization.' });
  }
});

// ============================================================
// TELEMETRY
// ============================================================

app.post('/stations/:stationId/telemetry', async (req, res) => {
  const { stationId } = req.params;
  const {
    cpuTemp, gpuTemp, cpuLoad, gpuLoad,
    bandwidthMbps, latencyMs, packetLoss,
    occupied = false, sessionMinutes = 0, game = '',
  } = req.body;

  if ([cpuTemp, gpuTemp, cpuLoad, gpuLoad, bandwidthMbps, latencyMs, packetLoss].some(v => v === undefined)) {
    return res.status(400).json({ error: 'Missing one or more required telemetry fields.' });
  }

  try {
    const result = await pool.query(
      `INSERT INTO telemetry
        (station_id, cpu_temp, gpu_temp, cpu_load, gpu_load, bandwidth_mbps, latency_ms, packet_loss, occupied, session_minutes, game)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
       RETURNING id, recorded_at`,
      [stationId, cpuTemp, gpuTemp, cpuLoad, gpuLoad, bandwidthMbps, latencyMs, packetLoss, occupied, sessionMinutes, game]
    );
    res.status(201).json(result.rows[0]);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Something went wrong saving telemetry.' });
  }
});

app.get('/stations/:stationId/telemetry', requireAnyUserOrService, async (req, res) => {
  const { stationId } = req.params;
  const limit = Math.min(parseInt(req.query.limit) || 50, 500);
  try {
    const denied = await stationOrgAccessError(req, stationId);
    if (denied) return res.status(denied.status).json({ error: denied.error });

    const result = await pool.query(
      `SELECT * FROM telemetry WHERE station_id = $1 ORDER BY recorded_at DESC LIMIT $2`,
      [stationId, limit]
    );
    res.json(result.rows);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Something went wrong fetching telemetry.' });
  }
});

// ============================================================
// ALERTS
// ============================================================

app.post('/stations/:stationId/alerts', async (req, res) => {
  const { stationId } = req.params;
  const { ruleCode, category, severity, message, suggestion } = req.body;

  if (!ruleCode || !category || !severity || !message || !suggestion) {
    return res.status(400).json({ error: 'Missing one or more required alert fields.' });
  }

  const alertId = `${stationId}-${ruleCode}-${Date.now()}`;
  try {
    const result = await pool.query(
      `INSERT INTO alerts (id, station_id, rule_code, category, severity, message, suggestion)
       VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING *`,
      [alertId, stationId, ruleCode, category, severity, message, suggestion]
    );
    res.status(201).json(result.rows[0]);

    // Close the loop: a bandwidth-related alert automatically asks the
    // Squid gateway to throttle the offending station. Fire-and-forget —
    // the alert is already saved and returned above regardless of outcome.
    if (squidController.THROTTLE_RULE_CODES.has(ruleCode)) {
      squidController.throttle(stationId);
    }
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Something went wrong saving the alert.' });
  }
});

// Resolves the most recent active alert for a (station, ruleCode) pair.
// Exists alongside PATCH /alerts/:alertId because the Flutter app tracks
// alerts by its own local id, not the backend's — this lets it report a
// resolution without needing to know the backend's id. Automatically
// releases the Squid throttle for NET-BW/NET-LAT alerts.
app.post('/stations/:stationId/alerts/:ruleCode/resolve', async (req, res) => {
  const { stationId, ruleCode } = req.params;
  try {
    const result = await pool.query(
      `UPDATE alerts SET resolved = true
       WHERE id = (
         SELECT id FROM alerts
         WHERE station_id = $1 AND rule_code = $2 AND resolved = false
         ORDER BY fired_at DESC LIMIT 1
       )
       RETURNING *`,
      [stationId, ruleCode]
    );
    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'No active alert found for that station/rule.' });
    }
    res.json(result.rows[0]);

    if (squidController.THROTTLE_RULE_CODES.has(ruleCode)) {
      squidController.release(stationId);
    }
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Something went wrong resolving the alert.' });
  }
});

app.get('/organizations/:orgId/alerts', requireAnyUserOrService, async (req, res) => {
  const { orgId } = req.params;
  const activeOnly = req.query.active === 'true';
  try {
    const denied = await orgAccessError(req, orgId);
    if (denied) return res.status(denied.status).json({ error: denied.error });

    const result = await pool.query(
      `SELECT a.* FROM alerts a
       JOIN stations s ON a.station_id = s.id
       WHERE s.organization_id = $1
       ${activeOnly ? 'AND a.resolved = false' : ''}
       ORDER BY a.fired_at DESC`,
      [orgId]
    );
    res.json(result.rows);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Something went wrong fetching alerts.' });
  }
});

app.patch('/alerts/:alertId', async (req, res) => {
  const { alertId } = req.params;
  const { acknowledged, resolved } = req.body;
  try {
    const result = await pool.query(
      `UPDATE alerts SET
         acknowledged = COALESCE($2, acknowledged),
         resolved = COALESCE($3, resolved)
       WHERE id = $1 RETURNING *`,
      [alertId, acknowledged, resolved]
    );
    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'Alert not found.' });
    }
    res.json(result.rows[0]);

    const alert = result.rows[0];
    if (resolved === true && squidController.THROTTLE_RULE_CODES.has(alert.rule_code)) {
      squidController.release(alert.station_id);
    }
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Something went wrong updating the alert.' });
  }
});

// ============================================================
// SESSIONS (gameplay/play-time -- NOT auth sessions)
// ============================================================
// These track how long a station was occupied and playing what, for
// utilization/report purposes. For login/auth session tracking (a device
// signing in, and being signed out server-side), see AUTH SESSIONS above.

app.post('/stations/:stationId/sessions/start', async (req, res) => {
  const { stationId } = req.params;
  const { game = '' } = req.body;
  try {
    const result = await pool.query(
      `INSERT INTO sessions (station_id, game) VALUES ($1, $2) RETURNING *`,
      [stationId, game]
    );
    res.status(201).json(result.rows[0]);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Something went wrong starting the session.' });
  }
});

app.post('/stations/:stationId/sessions/end', async (req, res) => {
  const { stationId } = req.params;
  try {
    const result = await pool.query(
      `UPDATE sessions SET ended_at = now()
       WHERE id = (
         SELECT id FROM sessions
         WHERE station_id = $1 AND ended_at IS NULL
         ORDER BY started_at DESC LIMIT 1
       )
       RETURNING *`,
      [stationId]
    );
    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'No open session found for this station.' });
    }
    res.json(result.rows[0]);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Something went wrong ending the session.' });
  }
});

// ============================================================
// REPORT ENTRIES (optimization / prediction insights)
// ============================================================

app.post('/organizations/:orgId/report-entries', async (req, res) => {
  const { orgId } = req.params;
  const { stationId = null, stationName = null, category = null, kind, title, detail, impact = '' } = req.body;

  if (!kind || !title || !detail) {
    return res.status(400).json({ error: 'Missing one or more required report entry fields.' });
  }

  try {
    const existing = await pool.query(
      `SELECT id, occurrences FROM report_entries
       WHERE organization_id = $1 AND kind = $2 AND COALESCE(station_id, '') = COALESCE($3, '') AND title = $4`,
      [orgId, kind, stationId, title]
    );

    if (existing.rows.length > 0) {
      const result = await pool.query(
        `UPDATE report_entries SET detail = $2, impact = $3, last_seen = now(), occurrences = occurrences + 1
         WHERE id = $1 RETURNING *`,
        [existing.rows[0].id, detail, impact]
      );
      return res.json(result.rows[0]);
    }

    const newId = `REC-${Date.now()}`;
    const result = await pool.query(
      `INSERT INTO report_entries
        (id, organization_id, station_id, station_name, category, kind, title, detail, impact, first_seen, last_seen)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,now(),now()) RETURNING *`,
      [newId, orgId, stationId, stationName, category, kind, title, detail, impact]
    );
    res.status(201).json(result.rows[0]);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Something went wrong saving the report entry.' });
  }
});

app.get('/organizations/:orgId/report-entries', requireAnyUserOrService, async (req, res) => {
  const { orgId } = req.params;
  try {
    const denied = await orgAccessError(req, orgId);
    if (denied) return res.status(denied.status).json({ error: denied.error });

    const result = await pool.query(
      `SELECT * FROM report_entries WHERE organization_id = $1 ORDER BY last_seen DESC`,
      [orgId]
    );
    res.json(result.rows);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Something went wrong fetching report entries.' });
  }
});

// Fallback error handler -- catches anything that reaches here
// (e.g. an awaited DB call that rejected outside a route's own
// try/catch) and returns plain JSON instead of Express's default
// HTML page, which otherwise leaks a full stack trace to the client.
// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  console.error(err);
  res.status(500).json({ error: 'Something went wrong.' });
});

const PORT = process.env.PORT || 3000;

// Only start listening when run directly (`node server.js` / `npm start`).
// When required from a test file (`require('../server')`), the caller
// gets the Express app to drive with supertest instead of a live socket.
if (require.main === module) {
  app.listen(PORT, () => {
    console.log(`CaféTwin backend listening on http://localhost:${PORT}`);
  });
}

module.exports = app;
