# CaféTwin — Squid Proxy Setup Guide

> **How the Squid proxy fits the CaféTwin project.**
> The Flutter app *detects* bandwidth problems (NET-BW / NET-LAT alerts).
> Squid is the production tool that *enforces* the fix — per-station
> bandwidth limits at the café's gateway.

---

## 1. Where Squid sits in the production architecture

```
        ┌─────────────────── Gaming Café LAN ───────────────────┐
        │                                                       │
 ST-01 ─┐                                                       │
 ST-02 ─┤                                                       │
  ...   ├──► Switch ──► [ Squid Proxy / Gateway ] ──► Internet  │
 ST-10 ─┘                  ▲                                    │
                           │ applies throttle rules              │
        ┌──────────────────┴───────────────┐                    │
        │  CaféTwin Dashboard (Flutter)    │                    │
        │  • NET-BW alert on ST-07         │                    │
        │  • Suggestion: "Limit background │                    │
        │    downloads on this station"    │                    │
        └──────────────────────────────────┘                    │
```

**The feedback loop:**
1. CaféTwin twin notices ST-07 using > 80% of bandwidth → **NET-BW alert**
2. Dashboard suggestion tells staff to limit that station
3. Staff enables the matching `delay_access` rule in `squid.conf`
4. ST-07 is hard-capped at 10 Mbps; other stations stop lagging
5. Twin sees latency recover → alert auto-resolves ✅

---

## 2. Installation (Ubuntu/Debian gateway)

```bash
sudo apt update
sudo apt install squid

# Back up the default config, then install ours
sudo cp /etc/squid/squid.conf /etc/squid/squid.conf.bak
sudo cp squid.conf /etc/squid/squid.conf

# Check the config for errors (should print nothing / "Processing...")
sudo squid -k parse

# Start it
sudo systemctl restart squid
sudo systemctl enable squid
```

## 3. Point the gaming PCs at the proxy

On each station (Windows):

```
Settings → Network & Internet → Proxy
  Address : 192.168.10.1     (the gateway running Squid)
  Port    : 3128
```

Or use a **transparent proxy** on the gateway (iptables redirect) so no
per-PC setup is needed — see any "squid transparent proxy" guide.

## 4. Responding to a CaféTwin NET-BW alert

Example: dashboard flags **ST-07** for bandwidth hogging.

1. Edit `/etc/squid/squid.conf`, find Section 5, and uncomment just that
   station's line inside its `CAFETWIN:THROTTLE:ST-07` marker block:

   ```
   delay_access 1 allow st_07
   ```

   Pool **1** is the strict 10 Mbps per-station pool, and it has to stay
   ahead of the café-wide pool 2: Squid hands each request to the first
   pool whose `delay_access` matches and stops there, so a station listed
   only behind the café-wide pool would never actually be throttled.
   (`delay_access 1 deny all` and the pool 2 rules below it are already
   active — leave them alone.)

2. Reload without dropping connections:

   ```bash
   sudo squid -k reconfigure
   ```

3. ST-07 is now capped at **10 Mbps**. Watch the CaféTwin station detail
   chart — latency for the other stations should recover within a minute.

4. When the rush is over, comment that line out again and reconfigure.

## 5. Verifying it works

```bash
# Watch live traffic per station IP
sudo tail -f /var/log/squid/access.log

# Confirm delay pools are active
sudo squidclient mgr:delay
```

## 6. Mapping: CaféTwin alert → Squid action

| CaféTwin alert | Meaning | Squid response |
|---|---|---|
| **NET-BW** (warning) | Station > 80% of capacity | Move station to strict pool (10 Mbps cap) |
| **NET-LAT** (critical) | Latency > 150 ms sustained | Check access.log for the hogging station, throttle it |
| **UTIL-GHOST** | Occupied seat, no GPU load | Not network — check the seat, end session |
| **HW-CRIT / HW-RAMP** | Overheating | Not network — physical maintenance |

## 7. Automating steps 1–4 (backend → gateway, no staff step)

`squid.conf` above now ships with a `CAFETWIN:THROTTLE:ST-XX:START/END`
marker block per station (Section 5), and `toggle_throttle.sh` in this
folder flips one station's block on/off and reconfigures Squid safely.
`cafetwin_backend_devops/squid_controller.js` calls that script over SSH
whenever a NET-BW/NET-LAT alert fires or clears — see that file's header
comment for the environment variables it needs.

**One-time setup on the gateway:**
```bash
# Copy the script onto the gateway and make it runnable as root via sudo
sudo mkdir -p /opt/cafetwin
sudo cp toggle_throttle.sh /opt/cafetwin/toggle_throttle.sh
sudo chmod +x /opt/cafetwin/toggle_throttle.sh

# Create a dedicated user the backend will SSH in as, and let it run
# only this one script without a password prompt:
sudo useradd -m -s /bin/bash cafetwin
sudo mkdir -p /home/cafetwin/.ssh
# paste the backend's public key into /home/cafetwin/.ssh/authorized_keys
echo 'cafetwin ALL=(root) NOPASSWD: /opt/cafetwin/toggle_throttle.sh' | \
  sudo tee /etc/sudoers.d/cafetwin-throttle
```
Then on the backend, set `SQUID_HOST`, `SQUID_SSH_USER=cafetwin`, and
`SQUID_SSH_KEY_PATH` to the matching private key (see
`cafetwin_backend_devops/.env.example`).

**Without this setup** (no `SQUID_HOST` configured), the backend logs what
it *would* do and changes nothing — safe default for a demo/CI run with no
real gateway to reach.

**Reachability note:** the backend needs a network path to the gateway on
port 22. That's trivial if both run on the café's own LAN; if the backend
is hosted externally (e.g. Render) and the gateway sits behind home/café
NAT, you'll need port-forwarding or a reverse SSH tunnel first.

## 8. Notes for the capstone report

- The prototype simulates bandwidth telemetry in-app (no real traffic).
  Squid enforcement is exercised through the dry-run path above unless
  you have physical/lab access to a real gateway to point `SQUID_HOST` at.
- The loop is now: **twin detects (NET-BW/NET-LAT) → backend inserts the
  alert → backend SSHes the gateway → Squid throttles the station →
  when the twin's rule condition clears → backend releases the
  throttle** — no staff step required, matching the automation this
  section used to describe as future work.
