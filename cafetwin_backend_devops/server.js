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

// Write routes accept EITHER a valid JWT (issued by POST /auth/login --
// the app's real authenticated path) OR the legacy x-api-key shared
// secret (for service-to-service callers such as simulate.js that never
// go through a human login). /auth/login itself is exempt (that's where
// a client gets a token in the first place).
function requireAuth(req, res, next) {
  const authHeader = req.get('authorization') || '';
  if (authHeader.startsWith('Bearer ')) {
    try {
      req.user = jwt.verify(authHeader.slice(7), JWT_SECRET);
      return next();
    } catch (err) {
      return res.status(401).json({ error: 'Invalid or expired token.' });
    }
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
  return (req, res, next) => {
    const authHeader = req.get('authorization') || '';
    if (!authHeader.startsWith('Bearer ')) {
      return res.status(401).json({ error: 'This endpoint requires a Bearer token from a logged-in user.' });
    }
    let decoded;
    try {
      decoded = jwt.verify(authHeader.slice(7), JWT_SECRET);
    } catch (err) {
      return res.status(401).json({ error: 'Invalid or expired token.' });
    }
    if (decoded.role !== role) {
      return res.status(403).json({ error: `This action requires the "${role}" role.` });
    }
    req.user = decoded;
    next();
  };
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
  const { username, password, pin } = req.body;
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
    const token = jwt.sign(
      { sub: admin.id, username: admin.username, role: admin.role },
      JWT_SECRET,
      { expiresIn: JWT_EXPIRES_IN }
    );
    res.json({ token, expiresIn: JWT_EXPIRES_IN, role: admin.role, username: admin.username });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Something went wrong during login.' });
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
      'SELECT username, role, created_at FROM admins ORDER BY created_at ASC'
    );
    res.json(result.rows);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Something went wrong fetching users.' });
  }
});

app.post('/admin/users', requireRole('admin'), async (req, res) => {
  const { username, password, pin, role = 'staff' } = req.body;
  if (!username || !password || !pin) {
    return res.status(400).json({ error: 'Request must include "username", "password" and "pin".' });
  }
  if (!['admin', 'staff'].includes(role)) {
    return res.status(400).json({ error: '"role" must be "admin" or "staff".' });
  }
  try {
    const passwordHash = await bcrypt.hash(password, 12);
    const pinHash = await bcrypt.hash(pin, 12);
    const result = await pool.query(
      `INSERT INTO admins (username, password_hash, pin_hash, role)
       VALUES ($1, $2, $3, $4)
       RETURNING username, role, created_at`,
      [username, passwordHash, pinHash, role]
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

app.post('/organizations', async (req, res) => {
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

app.get('/organizations/:id', async (req, res) => {
  const { id } = req.params;
  try {
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

app.get('/stations/:stationId/telemetry', async (req, res) => {
  const { stationId } = req.params;
  const limit = Math.min(parseInt(req.query.limit) || 50, 500);
  try {
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

app.get('/organizations/:orgId/alerts', async (req, res) => {
  const { orgId } = req.params;
  const activeOnly = req.query.active === 'true';
  try {
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
// SESSIONS
// ============================================================

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

app.get('/organizations/:orgId/report-entries', async (req, res) => {
  const { orgId } = req.params;
  try {
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
