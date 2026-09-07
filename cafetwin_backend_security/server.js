// CaféTwin backend API — full version covering all 6 tables.

const express = require('express');
const cors = require('cors');
const { Pool } = require('pg');

const app = express();
app.use(cors());
app.use(express.json());

const pool = new Pool({
  host: 'localhost',
  port: 5432,
  database: 'postgres',
  user: 'postgres',
  password: 'cafetwin123',
});

app.get('/', (req, res) => {
  res.send('CaféTwin backend is running.');
});

// ============================================================
// ORGANIZATIONS + STATIONS
// ============================================================

app.post('/organizations', async (req, res) => {
  const { name, stations } = req.body;
  if (!name || !Array.isArray(stations) || stations.length === 0) {
    return res.status(400).json({ error: 'Request must include "name" and a non-empty "stations" array.' });
  }

  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const orgResult = await client.query(
      'INSERT INTO organizations (name) VALUES ($1) RETURNING id',
      [name]
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
      `INSERT INTO telemetry_snapshots
        (station_id, cpu_temp, gpu_temp, cpu_load, gpu_load, bandwidth_mbps, latency_ms, packet_loss, occupied, session_minutes, game)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
       RETURNING id, ts`,
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
      `SELECT * FROM telemetry_snapshots WHERE station_id = $1 ORDER BY ts DESC LIMIT $2`,
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
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Something went wrong saving the alert.' });
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

const PORT = 3000;
app.listen(PORT, () => {
  console.log(`CaféTwin backend listening on http://localhost:${PORT}`);
});
