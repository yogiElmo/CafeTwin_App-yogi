// retention.js -- deletes old telemetry so the table doesn't grow forever.
//
// Every station uploads a reading every few seconds, so an unpruned
// telemetry table grows by hundreds of thousands of rows a week -- enough
// to fill a free-tier Postgres (Render's is 1 GB) and slow every query on
// it. Only recent readings are ever read back (GET /stations/:id/telemetry
// returns at most the latest 500), so anything older than the retention
// window is dead weight.
//
//   TELEMETRY_RETENTION_DAYS   days of telemetry to keep (default 30);
//                              "0" disables pruning entirely.

const HOUR_MS = 60 * 60 * 1000;

function retentionDaysFromEnv() {
  const raw = process.env.TELEMETRY_RETENTION_DAYS;
  if (raw === undefined || raw === '') return 30;
  const days = Number(raw);
  return Number.isInteger(days) && days >= 0 ? days : 30;
}

// Returns the number of rows deleted.
async function pruneTelemetry(pool, days) {
  const result = await pool.query(
    'DELETE FROM telemetry WHERE recorded_at < now() - make_interval(days => $1)',
    [days]
  );
  return result.rowCount;
}

// Prunes once now, then hourly. Errors are logged, never thrown -- a
// failed prune must not take the API down. The timer is unref'd so it
// never keeps the process alive on its own. Returns the timer (or null
// when disabled) so a caller can clearInterval it.
function startTelemetryRetention(pool, days = retentionDaysFromEnv()) {
  if (days === 0) return null;
  const run = () => pruneTelemetry(pool, days)
    .then((n) => { if (n > 0) console.log(`[retention] deleted ${n} telemetry rows older than ${days} days`); })
    .catch((err) => console.error('[retention] telemetry prune failed:', err));
  run();
  const timer = setInterval(run, HOUR_MS);
  timer.unref();
  return timer;
}

module.exports = { pruneTelemetry, startTelemetryRetention, retentionDaysFromEnv };
