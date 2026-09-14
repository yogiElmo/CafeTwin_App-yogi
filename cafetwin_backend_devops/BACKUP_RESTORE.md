# CaféTwin — Database Backup & Restore

> **Status before this document existed:** no backup script, no scheduled
> dump, and no documented recovery procedure existed anywhere in this
> repository — the production database (organizations, stations, alerts,
> telemetry history, admin accounts, everything) had a single copy, on
> Render, with nothing behind it if that copy was ever lost or corrupted.
> This closes that gap.

## 1. What gets backed up

Everything: a single `pg_dump` of the whole database — every table in
`init.sql` (`organizations`, `stations`, `telemetry`, `alerts`, `sessions`,
`report_entries`, `admins`, `auth_sessions`) — in PostgreSQL's custom
format (`-Fc`), which `pg_restore` can replay onto any Postgres instance
regardless of row counts.

## 2. The scheduled backup (GitHub Actions)

`.github/workflows/db-backup.yml` runs automatically **once a day at
03:00 UTC**, and can also be triggered manually. It:

1. Runs `cafetwin_backend_devops/scripts/backup.sh` against the database
   at the `DATABASE_URL` repository secret.
2. Uploads the resulting `.dump` file as a **workflow artifact**, kept for
   **30 days**.

### One-time setup

The workflow needs a single secret — it is **not** configured yet, so the
schedule will fail (with a clear error, not silently) until this is done:

1. Render dashboard → your Postgres instance (`cafetwin-db`) →
   **Connections** → copy the **External Database URL**.
2. GitHub repo → **Settings → Secrets and variables → Actions → New
   repository secret** → name it `DATABASE_URL`, paste the value, save.

That's it — the next scheduled run (or a manual one, see below) will pick
it up.

### Running it manually

GitHub repo → **Actions** tab → **Database backup** (left sidebar) →
**Run workflow**. Useful right before a risky change (e.g. re-running
`/admin/bootstrap`), or just to confirm the setup above worked.

### Downloading a backup

Actions tab → **Database backup** → click a completed run → scroll to
**Artifacts** → download `cafetwin-db-backup-<run-id>` (a zip containing
the `.dump` file). Artifacts older than 30 days are deleted automatically
by GitHub — download anything you want to keep longer.

### If Render blocks the connection

Some Postgres providers restrict external connections to an IP allowlist.
If the workflow's dump step fails with a connection/timeout error rather
than an auth error, check Render's Postgres **Access Control** settings
for your plan — GitHub Actions runners use rotating IPs, so this may mean
allowing all IPs for external connections (Render's default on most
plans) rather than a fixed list, or backing up from a self-hosted runner
on a network Render already trusts.

## 3. Running a backup manually (local machine)

```bash
cd cafetwin_backend_devops

# Against Render (or any Postgres reachable by connection string):
DATABASE_URL="postgres://user:pass@host:5432/dbname" ./scripts/backup.sh

# Against a local/docker-compose Postgres (reads the same PG* vars as
# server.js — see .env.example):
PGHOST=localhost PGUSER=postgres PGPASSWORD=cafetwin123 PGDATABASE=cafetwin \
  ./scripts/backup.sh
```

Dumps land in `cafetwin_backend_devops/backups/` (git-ignored — never
commit real data), named `cafetwin_<UTC timestamp>.dump`. Local backups
older than the most recent 14 are pruned automatically each run
(`BACKUP_KEEP` overrides this).

## 4. Restoring a backup

**This is destructive** — restoring overwrites whatever is currently in
the target database. Always restore into a **scratch database first** to
confirm the dump is good before touching production:

```bash
# 1. Create a throwaway database and restore into IT first:
createdb cafetwin_restore_test
PGDATABASE=cafetwin_restore_test ./scripts/restore.sh backups/cafetwin_20260101T030000Z.dump

# 2. Spot-check it (row counts, a login account, etc.), then, only once
#    you're satisfied, restore into the real target:
DATABASE_URL="postgres://user:pass@host:5432/dbname" \
  ./scripts/restore.sh backups/cafetwin_20260101T030000Z.dump
```

The script asks for a typed `yes` confirmation before touching anything
(bypass with `FORCE=1` only for scripted restores into a scratch
database — never against production).

### Full disaster-recovery sequence (e.g. the Render database is gone)

1. Provision a fresh Render Postgres instance (or reuse an existing empty
   one).
2. Download the most recent good dump (Actions artifact, or a local
   `backups/*.dump`).
3. `DATABASE_URL="<new instance's External Database URL>" ./scripts/restore.sh <dump file>`
4. Point the backend's `PG*`/`DATABASE_URL` environment variables at the
   new instance (Render service → Environment) and redeploy.
5. Confirm with `GET /health` and a real login before announcing it's
   back up.

## 5. Notes for the capstone report

- This closes the "backup management" responsibility that a codebase
  review previously found no evidence for at all (see the team's
  role-coverage gap analysis).
- The design choice — GitHub Actions artifacts rather than a third-party
  storage bucket — needs no new paid service or credentials beyond the
  one `DATABASE_URL` secret, which fits a capstone project's budget and
  scope while still being a genuine, scheduled, off-site copy.
- 30-day artifact retention is a deliberate trade-off, not an oversight:
  it's GitHub's default artifact lifetime and is more than enough to
  recover from an operational mistake, though it is not a long-term
  compliance-grade archive.
