// dbHelper.js -- a small, test-only Postgres pool (mirrors server.js /
// seed.js's own connection config from the same PG* env vars) used to seed
// and clean up rows directly, and to detect whether a database is even
// reachable so DB-dependent tests can no-op with a clear warning instead
// of crashing the whole suite when nothing is running locally.

const { Pool } = require('pg');

const pool = new Pool({
  host: process.env.PGHOST || 'localhost',
  port: Number(process.env.PGPORT || 5432),
  database: process.env.PGDATABASE || 'postgres',
  user: process.env.PGUSER || 'postgres',
  password: process.env.PGPASSWORD || 'cafetwin123',
  ssl: process.env.PGSSLMODE === 'require' ? { rejectUnauthorized: false } : false,
});

async function isDbReachable() {
  try {
    await pool.query('SELECT 1');
    return true;
  } catch (err) {
    return false;
  }
}

async function closeDb() {
  await pool.end();
}

module.exports = { pool, isDbReachable, closeDb };
