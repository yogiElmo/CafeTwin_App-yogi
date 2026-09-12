# CaféTwin — Network & Infrastructure Hardening

This folder contains **infrastructure configuration only** — scripts and
config fragments that run on the café's real Linux gateway/router, not
inside a container or a PaaS:

| File | Purpose | Runs on |
|------|---------|---------|
| `firewall_rules.sh` | iptables hardening: default-drop policy, LAN/DB allow-lists, connection/hash rate limiting, dropped-packet logging | The gateway router |
| `guest_wifi_isolation.sh` | VLAN segmentation: isolates guest Wi-Fi (VLAN 20) from the gaming LAN (VLAN 10) and management (VLAN 1) | The gateway router |
| `fail2ban_cafetwin.conf` | fail2ban jail definitions for the API (port 3000) and SSH | The gateway/API host |

## What used to be here

An earlier copy of the Express + PostgreSQL API (`server.js`, `simulate.js`,
`package.json`) was duplicated into this folder. It hardcoded its database
password and connection host, had none of the security middleware
(Helmet, rate limiting, request logging) that the canonical backend has,
and queried a table name (`telemetry_snapshots`) that does not exist in
`cafetwin_backend_devops/init.sql` — it would have crashed on first write.

`DEPLOYMENT.md` already explains that this folder's *intent* (hardening)
was folded into the one real backend at `cafetwin_backend_devops/server.js`
instead of keeping two copies of the API in sync. The stale, insecure copy
has now been removed so there is exactly one backend in this repository —
see `cafetwin_backend_devops/` for the API, and `squid_proxy/` for
bandwidth-management config. This folder now holds only what its name
promises: infrastructure hardening artifacts.
