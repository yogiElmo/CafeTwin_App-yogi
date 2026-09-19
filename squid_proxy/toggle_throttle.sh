#!/usr/bin/env bash
# toggle_throttle.sh — flips one station's delay_access block in
# /etc/squid/squid.conf between commented (normal) and active (throttled),
# then reconfigures Squid without dropping connections.
#
# Runs ON the Squid gateway itself (not on the backend). The backend
# reaches this via SSH — see cafetwin_backend_devops/squid_controller.js.
#
# Usage:
#   sudo ./toggle_throttle.sh ST-07 on     # cap ST-07 at 10 Mbps
#   sudo ./toggle_throttle.sh ST-07 off    # release ST-07 back to normal
#
# Requires: the CAFETWIN:THROTTLE:<station>:START/END markers already
# present in /etc/squid/squid.conf (installed from squid_proxy/squid.conf).

set -euo pipefail

CONF="${SQUID_CONF_PATH:-/etc/squid/squid.conf}"
STATION="${1:-}"
ACTION="${2:-}"

usage() {
  echo "Usage: $0 <STATION-ID e.g. ST-07> <on|off>" >&2
  exit 1
}

[[ -z "$STATION" || -z "$ACTION" ]] && usage
[[ "$ACTION" != "on" && "$ACTION" != "off" ]] && usage

START="# CAFETWIN:THROTTLE:${STATION}:START"
END="# CAFETWIN:THROTTLE:${STATION}:END"

if ! grep -qF "$START" "$CONF"; then
  echo "No throttle block found for $STATION in $CONF" >&2
  echo "(check the station id matches squid.conf's ST-01..ST-10 markers)" >&2
  exit 2
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

if [[ "$ACTION" == "on" ]]; then
  # Uncomment the single "delay_access 1 allow st_XX" line between markers.
  # (Pool 1 is the strict per-station pool; it is matched ahead of the
  # café-wide pool 2. The pattern below is pool-number-agnostic anyway.)
  awk -v start="$START" -v end="$END" '
    $0 == start { inblock=1; print; next }
    $0 == end   { inblock=0; print; next }
    inblock && /^# delay_access/ { sub(/^# /, ""); print; next }
    { print }
  ' "$CONF" > "$TMP"
  echo "Throttling $STATION to 10 Mbps..."
else
  # Re-comment it if it's currently active.
  awk -v start="$START" -v end="$END" '
    $0 == start { inblock=1; print; next }
    $0 == end   { inblock=0; print; next }
    inblock && /^delay_access/ { print "# " $0; next }
    { print }
  ' "$CONF" > "$TMP"
  echo "Releasing $STATION back to normal..."
fi

cp "$CONF" "${CONF}.bak"
mv "$TMP" "$CONF"

squid -k parse   # fail fast if the edit produced invalid config
squid -k reconfigure

echo "Done. $STATION throttle is now: $ACTION"
