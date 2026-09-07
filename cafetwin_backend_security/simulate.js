// CaféTwin data simulator — pushes realistic fake telemetry into your own API,
// the same way the real Flutter app eventually would. Run this after server.js
// is already running in another window.

const API_BASE = 'http://localhost:3000';

// Small helper: random number in a range.
function rand(min, max) {
  return +(Math.random() * (max - min) + min).toFixed(1);
}

async function setupOrganization() {
  const res = await fetch(`${API_BASE}/organizations`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      name: 'Diksha Demo Cafe',
      stations: [
        { category: 'Gaming' },
        { category: 'Gaming' },
        { category: 'Marketing' },
        { category: 'Design' },
      ],
    }),
  });
  const data = await res.json();
  console.log(`Created organization "${data.name}" with ${data.stations.length} stations.`);
  return data;
}

async function sendTelemetry(stationId) {
  const cpuTemp = rand(45, 90);
  const gpuTemp = rand(45, 95);

  await fetch(`${API_BASE}/stations/${stationId}/telemetry`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      cpuTemp,
      gpuTemp,
      cpuLoad: rand(10, 100),
      gpuLoad: rand(10, 100),
      bandwidthMbps: rand(200, 950),
      latencyMs: rand(5, 60),
      packetLoss: rand(0, 2),
      occupied: Math.random() > 0.3,
      sessionMinutes: Math.floor(rand(0, 180)),
      game: 'Valorant',
    }),
  });

  // Occasionally fire a real alert, same as the app's rules engine would.
  if (cpuTemp > 85) {
    await fetch(`${API_BASE}/stations/${stationId}/alerts`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        ruleCode: 'HW-CRIT',
        category: 'hardware',
        severity: 'critical',
        message: `${stationId} CPU temperature critical: ${cpuTemp}°C`,
        suggestion: 'Check cooling fan and airflow immediately.',
      }),
    });
    console.log(`  ⚠ Alert fired for ${stationId}: CPU ${cpuTemp}°C`);
  }
}

async function main() {
  const org = await setupOrganization();
  const stationIds = org.stations.map(s => s.id);

  console.log('Starting live simulation — press Ctrl+C to stop.\n');

  setInterval(async () => {
    for (const id of stationIds) {
      await sendTelemetry(id);
    }
    console.log(`[${new Date().toLocaleTimeString()}] Sent telemetry for ${stationIds.length} stations.`);
  }, 3000); // every 3 seconds
}

main();
