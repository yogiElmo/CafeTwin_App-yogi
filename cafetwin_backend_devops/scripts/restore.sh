#!/usr/bin/env bash
# CaféTwin — database restore script.
#
# Replays a dump produced by backup.sh (PostgreSQL custom format, -Fc)
# onto a target database. DESTRUCTIVE: --clean drops existing objects
# before recreating them, so this OVERWRITES whatever is currently in the
# target database with the dump's contents. Always restore into a scratch
# database first to verify a dump before pointing this at production.
#
# Usage:
#   ./restore.sh path/to/cafetwin_20260101T030000Z.dump
#   DATABASE_URL=postgres://... ./restore.sh backup.dump
#   PGHOST=localhost PGUSER=cafetwin PGDATABASE=cafetwin ./restore.sh backup.dump
#
# FORCE=1 skips the interactive confirmation prompt (for scripted/tested
# restores into a scratch database) -- never set this against production.

set -euo pipefail

DUMP_FILE="${1:-}"
if [ -z "$DUMP_FILE" ] || [ ! -f "$DUMP_FILE" ]; then
  echo "Usage: $0 <dump-file>" >&2
  exit 1
fi

TARGET_DESC="${DATABASE_URL:-${PGUSER:-postgres}@${PGHOST:-localhost}:${PGPORT:-5432}/${PGDATABASE:-postgres}}"

if [ "${FORCE:-}" != "1" ]; then
  read -r -p "This will OVERWRITE the database at '$TARGET_DESC' with the contents of $DUMP_FILE. Type 'yes' to continue: " CONFIRM
  if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 1
  fi
fi

if [ -n "${DATABASE_URL:-}" ]; then
  echo "[restore] Restoring into DATABASE_URL from $DUMP_FILE"
  pg_restore --clean --if-exists --no-owner --no-privileges -d "$DATABASE_URL" "$DUMP_FILE"
else
  : "${PGDATABASE:=postgres}"
  : "${PGUSER:=postgres}"
  : "${PGHOST:=localhost}"
  : "${PGPORT:=5432}"
  echo "[restore] Restoring into $PGUSER@$PGHOST:$PGPORT/$PGDATABASE from $DUMP_FILE"
  pg_restore --clean --if-exists --no-owner --no-privileges \
    -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" "$DUMP_FILE"
fi

echo "[restore] Done."
