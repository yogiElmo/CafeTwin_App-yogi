# CaféTwin — Connecting the pieces & getting off `flutter run`

This documents what changed to connect `lib/` (the Flutter app) to
`cafetwin_backend_devops/` (the API + Postgres), where
`cafetwin_backend_security/` and `squid_proxy/` fit in, and how to host the
app somewhere other than your laptop.

## What was actually disconnected before

- `lib/` had **zero networking code** — no `http` package, nothing calling
  the backend. All data came from the in-app simulation timer.
- `cafetwin_backend_devops/server.js` queried a table (`telemetry_snapshots`)
  that didn't exist in `init.sql` (the real table is `telemetry`) — telemetry
  writes would have crashed even if the app had called them.
- `cafetwin_backend_devops/server.js` ignored the `PGHOST`/`PGUSER`/etc
  environment variables that `docker-compose.yml` was already setting,
  hardcoding `localhost` instead — so it only ever worked inside a very
  specific local Docker setup.
- `cafetwin_backend_security/` and `squid_proxy/` are **infrastructure**,
  not application code: fail2ban, firewall rules, guest-wifi VLAN
  isolation, and Squid bandwidth throttling all run on a real Linux
  gateway/router, not inside GitHub or a PaaS. They stay as configs you
  apply on real hardware; nothing to "connect" in code for those.

## What changed

1. **`lib/services/api_service.dart`** (new) — a thin client that posts
   telemetry, alerts, session-end events, and report entries to the
   backend, and registers the organization on setup. Every call is
   best-effort: wrapped in try/catch with a timeout, logged to stdout on
   failure, never thrown. If the backend is unreachable or not configured,
   **the app still runs exactly as before, on pure simulation.**
2. **`lib/state/cafe_state.dart`** — now calls `ApiService` at the right
   points (`configure`, each tick, `endSession`, new insights).
3. **`pubspec.yaml`** — added `http`.
4. **`cafetwin_backend_devops/server.js`** — fixed the table-name bug,
   switched to environment-driven DB config, and added `helmet`,
   `express-rate-limit`, `morgan` request logging, and an optional
   `x-api-key` gate on writes (this is where the
   `cafetwin_backend_security` intent — hardening — actually lands, so
   there's one API to run instead of two identical copies).
5. **`.gitignore`** (new) — the zip included a full `.dart_tool/` with a
   cached Chrome profile (hundreds of files); that's now excluded, along
   with `node_modules/`, `.env`, and generated platform folders.
6. **`.github/workflows/deploy-web.yml`** (new) — builds the Flutter **web**
   app and publishes it to GitHub Pages on every push to `main`.
7. **`cafetwin_backend_devops/render.yaml`** (new) — a Render Blueprint so
   the API + Postgres can go live with no server to manage.
8. **`cafetwin_backend_devops/.github/workflows/deploy-backend.yml`** —
   fixed a path filter that referenced a folder name that doesn't exist
   (`cafetwin-backend` vs the real `cafetwin_backend_devops`), fixed
   corrupted characters, and gated it behind a repo variable so it won't
   run half-configured. This one's for deploying to a VM/VPS you already
   own; skip it if you're using Render.

## Squid + security: what actually connects and what doesn't

- Squid (bandwidth throttling) and the firewall/fail2ban/guest-wifi
  scripts run on the café's **physical gateway router**, not on GitHub or
  a PaaS. There is no "host Squid on GitHub" — it has to sit between the
  gaming PCs and the internet.
- The link between the app and Squid stays what `SQUID_SETUP.md` already
  says: the dashboard's NET-BW/NET-LAT alerts tell staff *which* station
  to throttle; a human edits `squid.conf` and reconfigures. Automating
  that last step (the twin calling Squid directly) would mean the backend
  SSHing into the gateway to run `squid -k reconfigure` — a real feature,
  but a separate piece of work, and one that needs a specific, reachable
  gateway box to target. Say the word if you want that wired up next.

## Step-by-step: get a live link instead of re-running Flutter

### 1. Push this project to GitHub
```bash
cd cafetwin_app
git init
git add .
git commit -m "Connect app to backend; add hosting"
git branch -M main
git remote add origin https://github.com/<you>/<repo>.git
git push -u origin main
```

### 2. Turn on GitHub Pages (one click)
Repo → **Settings → Pages → Source: "GitHub Actions"**. That's it — the
`deploy-web.yml` workflow you just pushed will build and publish
automatically. After the first run finishes (check the **Actions** tab),
your app is live at:
```
https://<you>.github.io/<repo>/
```
Every future `git push` to `main` updates it — no more `flutter run`.

> This deploys the UI in **offline-simulation mode** by default (no
> backend configured yet), which is a fully working demo on its own.

### 3. (Optional) Put the backend online too
Easiest path, no server to manage:
1. Go to [render.com](https://render.com) → **New → Blueprint** → pick
   your repo. Render reads `cafetwin_backend_devops/render.yaml` and
   creates the API + a free Postgres database.
2. Once it's deployed, open the Render Postgres instance's **Shell** (or
   connect with `psql` using the external connection string Render
   shows you) and run the contents of `cafetwin_backend_devops/init.sql`
   once, to create the tables.
3. Copy the API's URL, e.g. `https://cafetwin-api.onrender.com`.

### 4. Point the deployed app at the live backend
Repo → **Settings → Secrets and variables → Actions → Variables tab** →
add `API_BASE_URL` = `https://cafetwin-api.onrender.com`. Push anything
(or re-run the workflow from the Actions tab) — the next Pages build will
include it, and the app will start syncing telemetry/alerts to the
database.

### 5. Local dev, if you still want it sometimes
```bash
cd cafetwin_backend_devops && cp .env.example .env && npm install && npm start
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:3000
```

### 6. Real authentication (replaces the hardcoded demo login)

The login screen used to accept a single hardcoded username/password/PIN
baked into the app and printed on screen. It now authenticates against
the backend: `POST /auth/login` checks bcrypt-hashed credentials in the
new `admins` table and returns a JWT, which the app stores with
`flutter_secure_storage` and sends as `Authorization: Bearer <token>` on
every write. The old `x-api-key` gate still works too, for service
callers (like `simulate.js`) that never go through a human login.

One-time setup after `init.sql` has run:
```bash
cd cafetwin_backend_devops
ADMIN_USERNAME=youradminname ADMIN_PASSWORD=... ADMIN_PIN=1234 npm run seed
# or just `npm run seed` with nothing set -- it generates and prints a
# password + PIN once.
```
Run it again any time to rotate the password. Set `JWT_SECRET` to a
long random value in production (see `.env.example`); if left unset the
backend generates one per process, which is safe but means everyone is
logged out on every restart/redeploy.

The app itself now needs `API_BASE_URL` configured to log in at all --
see `lib/services/auth_service.dart`. Pure offline-simulation mode
(no backend) intentionally has no login bypass any more; if you need a
backend-free demo, pass `--dart-define=DEMO_USERNAME=...
--dart-define=DEMO_PASSWORD=... --dart-define=DEMO_PIN=...` at build/run
time instead of hardcoding anything in source.

### 7. Multi-factor authentication (admin accounts only)

Any admin can turn on TOTP -- the same open standard (RFC 6238) Google
Authenticator, Microsoft Authenticator, Authy, and 1Password all speak,
so there's nothing vendor-specific to configure. From the app: log in,
then the shield icon in the top app bar (admin-only, next to "Manage
Users") opens setup -- it shows a QR code and a manual-entry secret,
confirms with one code from the app, then shows 8 one-time recovery
codes (save these; they're not shown again). From then on,
`POST /auth/login` requires a `totpCode` in the request body for that
account, on top of the existing password + PIN.

Deliberately scoped to admins, not staff: staff accounts share terminals
on the café floor, where a second factor is friction with no real
security payoff, while an admin account can create, delete, and manage
every other account -- see `cafetwin_backend_devops/server.js`'s "TOTP
MULTI-FACTOR AUTHENTICATION" section and the schema comment on
`admins.totp_enabled` in `init.sql` for the full reasoning. No new
environment variables or secrets are needed; `init.sql` adds the
required columns/table automatically (same `ADD COLUMN IF NOT EXISTS`
pattern the rest of the schema uses), so this works on a fresh database
and picks up automatically the next time `GET /admin/bootstrap` runs
against an existing one.

## Notes / things left as-is on purpose

- `ApiService` doesn't sync acknowledge/resolve state *back* from the app
  to the backend's own alert ids (the backend mints its own id on
  insert; the app doesn't currently store the mapping). Fine for a
  telemetry/insight record trail; say so if you want two-way sync.
- Render's free Postgres expires after 90 days and the free web service
  cold-starts after idling — good for a demo/report, not for a café
  running this 24/7.
