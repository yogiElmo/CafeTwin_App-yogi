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
//   SQUID_SSH_STRICT_HOST_CHECK  unset (default): trust-on-first-use --
//                                 the gateway's key is recorded on the first
//                                 connection and a CHANGED key is refused.
//                                 "true": only keys already in known_hosts.
//                                 "false": no checking at all (not
//                                 recommended -- anyone who can intercept
//                                 the connection could run commands as root
//                                 on the gateway).

const { spawn } = require('child_process');

const HOST = process.env.SQUID_HOST || '';
const USER = process.env.SQUID_SSH_USER || 'cafetwin';
const PORT = process.env.SQUID_SSH_PORT || '22';
const KEY_PATH = process.env.SQUID_SSH_KEY_PATH || '';
const SCRIPT_PATH =
  process.env.SQUID_SCRIPT_PATH || '/opt/cafetwin/toggle_throttle.sh';
const STRICT_HOST_CHECK = {
  true: 'yes',
  false: 'no',
}[process.env.SQUID_SSH_STRICT_HOST_CHECK] || 'accept-new';

// The remote command below is a single string that ssh hands to the
// gateway's shell and runs under sudo, so anything interpolated into it
// must be incapable of carrying shell syntax. Station ids are generated
// server-side (ST-<org>-NN, or ST-NN in older data) and the database's
// foreign keys already stop unknown ids before this is reached -- this is
// the check that keeps it safe if either of those ever changes.
const STATION_ID_PATTERN = /^[A-Za-z0-9-]{1,64}$/;
const ACTIONS = new Set(['on', 'off']);

const isConfigured = Boolean(HOST);

function runSsh(stationId, action) {
  return new Promise((resolve) => {
    const sshArgs = [
      '-p', PORT,
      '-o', 'BatchMode=yes',
      '-o', 'ConnectTimeout=6',
      '-o', `StrictHostKeyChecking=${STRICT_HOST_CHECK}`,
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
  if (typeof stationId !== 'string' || !STATION_ID_PATTERN.test(stationId) || !ACTIONS.has(action)) {
    console.error(
      `[squid_controller] refusing throttle request with unsafe arguments: ${JSON.stringify({ stationId, action })}`
    );
    return { ok: false, error: 'invalid stationId or action' };
  }
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

module.exports = { throttle, release, setThrottle, isConfigured, THROTTLE_RULE_CODES };
