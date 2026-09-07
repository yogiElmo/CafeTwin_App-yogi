// squid_controller.js — closes the loop from "twin detects a bandwidth
// problem" to "gateway enforces the fix", per squid_proxy/SQUID_SETUP.md
// section 7 ("could call the Squid reconfigure step automatically").
//
// Talks to the café's Squid gateway over SSH and runs
// squid_proxy/toggle_throttle.sh there. Configure via environment
// variables; with none set, every call is a safe, logged no-op (dry run) —
// so this never breaks a demo/CI run that has no real gateway to reach.
//
//   SQUID_HOST            gateway hostname/IP, e.g. 192.168.10.1
//   SQUID_SSH_USER         default: cafetwin
//   SQUID_SSH_PORT         default: 22
//   SQUID_SSH_KEY_PATH     path to a private key readable by the backend
//   SQUID_SCRIPT_PATH      default: /opt/cafetwin/toggle_throttle.sh
//   SQUID_SSH_STRICT_HOST_CHECK  "true" to enable host-key checking
//                                 (default "false" for first-run convenience;
//                                  set "true" once you've pinned known_hosts)

const { spawn } = require('child_process');

const HOST = process.env.SQUID_HOST || '';
const USER = process.env.SQUID_SSH_USER || 'cafetwin';
const PORT = process.env.SQUID_SSH_PORT || '22';
const KEY_PATH = process.env.SQUID_SSH_KEY_PATH || '';
const SCRIPT_PATH =
  process.env.SQUID_SCRIPT_PATH || '/opt/cafetwin/toggle_throttle.sh';
const STRICT_HOST_CHECK = process.env.SQUID_SSH_STRICT_HOST_CHECK === 'true';

const isConfigured = Boolean(HOST);

function runSsh(stationId, action) {
  return new Promise((resolve) => {
    const sshArgs = [
      '-p', PORT,
      '-o', 'BatchMode=yes',
      '-o', 'ConnectTimeout=6',
      '-o', `StrictHostKeyChecking=${STRICT_HOST_CHECK ? 'yes' : 'no'}`,
    ];
    if (KEY_PATH) sshArgs.push('-i', KEY_PATH);
    sshArgs.push(
      `${USER}@${HOST}`,
      `sudo ${SCRIPT_PATH} ${stationId} ${action}`
    );

    const child = spawn('ssh', sshArgs);
    let stderr = '';
    child.stderr.on('data', (d) => { stderr += d.toString(); });
    child.on('error', (err) => {
      resolve({ ok: false, error: `ssh spawn failed: ${err.message}` });
    });
    child.on('close', (code) => {
      if (code === 0) {
        resolve({ ok: true });
      } else {
        resolve({ ok: false, error: stderr.trim() || `ssh exited ${code}` });
      }
    });
  });
}

/**
 * Requests the gateway throttle (or release) one station.
 * Always resolves (never throws) so callers can fire-and-forget.
 * @param {string} stationId e.g. "ST-07"
 * @param {"on"|"off"} action
 */
async function setThrottle(stationId, action) {
  if (!isConfigured) {
    console.log(
      `[squid_controller] DRY RUN (SQUID_HOST not set): would set ${stationId} throttle=${action}`
    );
    return { ok: true, dryRun: true };
  }
  const result = await runSsh(stationId, action);
  if (result.ok) {
    console.log(`[squid_controller] ${stationId} throttle=${action} applied on ${HOST}`);
  } else {
    console.error(`[squid_controller] ${stationId} throttle=${action} FAILED: ${result.error}`);
  }
  return result;
}

const throttle = (stationId) => setThrottle(stationId, 'on');
const release = (stationId) => setThrottle(stationId, 'off');

// Alerts that represent a bandwidth problem Squid can actually fix.
// Matches SQUID_SETUP.md's mapping table.
const THROTTLE_RULE_CODES = new Set(['NET-BW', 'NET-LAT']);

module.exports = { throttle, release, isConfigured, THROTTLE_RULE_CODES };
