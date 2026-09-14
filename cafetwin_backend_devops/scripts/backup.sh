#!/usr/bin/env bash
# CaféTwin — database backup script.
#
# Dumps the whole Postgres database (organizations, stations, telemetry,
# alerts, sessions, report_entries, admins, auth_sessions -- every table in
# init.sql) to a single timestamped file in PostgreSQL's custom format
# (-Fc), which pg_restore can replay onto a fresh database regardless of
# row counts or ordering.
#
# Connection: uses $DATABASE_URL if set (Render's connection string format,
# e.g. postgres://user:pass@host:5432/dbname) -- otherwise falls back to
# the same PG* environment variables server.js and dbHelper.js already
# read (PGHOST/PGPORT/PGDATABASE/PGUSER/PGPASSWORD), so this script works
# unchanged against Render, docker-compose, or a bare local install.
#
# Usage:
#   ./backup.sh                          # writes to ../backups/
#   BACKUP_DIR=/some/path ./backup.sh
#   DATABASE_URL=postgres://... ./backup.sh
#
# See ../BACKUP_RESTORE.md for the scheduled GitHub Actions workflow that
# runs this automatically, and for how to restore a dump.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${BACKUP_DIR:-$SCRIPT_DIR/../backups}"
mkdir -p "$BACKUP_DIR"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_FILE="$BACKUP_DIR/cafetwin_${TIMESTAMP}.dump"

if [ -n "${DATABASE_URL:-}" ]; then
  echo "[backup] Dumping via DATABASE_URL -> $OUT_FILE"
  pg_dump "$DATABASE_URL" -Fc -f "$OUT_FILE"
else
  : "${PGDATABASE:=postgres}"
  : "${PGUSER:=postgres}"
  : "${PGHOST:=localhost}"
  : "${PGPORT:=5432}"
  echo "[backup] Dumping $PGUSER@$PGHOST:$PGPORT/$PGDATABASE -> $OUT_FILE"
  pg_dump -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -Fc -f "$OUT_FILE"
fi

SIZE="$(du -h "$OUT_FILE" | cut -f1)"
echo "[backup] Done: $OUT_FILE ($SIZE)"

# Keep only the most recent N local dumps so a machine that runs this on
# its own cron doesn't fill its disk. The GitHub Actions workflow relies on
# Actions' own artifact retention instead (see db-backup.yml) -- this only
# matters for a local/manual run.
KEEP="${BACKUP_KEEP:-14}"
COUNT=$(ls -1 "$BACKUP_DIR"/cafetwin_*.dump 2>/dev/null | wc -l)
if [ "$COUNT" -gt "$KEEP" ]; then
  ls -1t "$BACKUP_DIR"/cafetwin_*.dump | tail -n +"$((KEEP + 1))" | xargs -r rm --
  echo "[backup] Pruned local dumps beyond the most recent $KEEP."
fi
