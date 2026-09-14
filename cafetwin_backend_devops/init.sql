-- ============================================================
-- Caf�Twin � PostgreSQL Database Schema (Week 7)
-- Creates all 6 core tables for the digital twin backend
-- ============================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TABLE IF NOT EXISTS organizations (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name          TEXT NOT NULL,
  configured_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS stations (
  id              TEXT PRIMARY KEY,
  organization_id UUID REFERENCES organizations(id) ON DELETE CASCADE,
  name            TEXT NOT NULL,
  category        TEXT DEFAULT 'Gaming'
);

CREATE TABLE IF NOT EXISTS telemetry (
  id              SERIAL PRIMARY KEY,
  station_id      TEXT REFERENCES stations(id) ON DELETE CASCADE,
  cpu_temp        REAL,
  gpu_temp        REAL,
  cpu_load        REAL,
  gpu_load        REAL,
  bandwidth_mbps  REAL,
  latency_ms      REAL,
  packet_loss     REAL,
  occupied        BOOLEAN DEFAULT false,
  session_minutes INTEGER DEFAULT 0,
  game            TEXT DEFAULT '',
  recorded_at     TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS alerts (
  id           TEXT PRIMARY KEY DEFAULT 'ALT-' || substr(uuid_generate_v4()::text, 1, 8),
  station_id   TEXT REFERENCES stations(id) ON DELETE CASCADE,
  rule_code    TEXT NOT NULL,
  category     TEXT,
  severity     TEXT DEFAULT 'warning',
  message      TEXT,
  suggestion   TEXT,
  acknowledged BOOLEAN DEFAULT false,
  resolved     BOOLEAN DEFAULT false,
  fired_at     TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS sessions (
  id         SERIAL PRIMARY KEY,
  station_id TEXT REFERENCES stations(id) ON DELETE CASCADE,
  game       TEXT DEFAULT '',
  started_at TIMESTAMPTZ DEFAULT now(),
  ended_at   TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS report_entries (
  id              TEXT PRIMARY KEY,
  organization_id UUID REFERENCES organizations(id) ON DELETE CASCADE,
  station_id      TEXT,
  station_name    TEXT,
  category        TEXT,
  kind            TEXT NOT NULL,
  title           TEXT NOT NULL,
  detail          TEXT NOT NULL,
  impact          TEXT DEFAULT '',
  occurrences     INTEGER DEFAULT 1,
  first_seen      TIMESTAMPTZ DEFAULT now(),
  last_seen       TIMESTAMPTZ DEFAULT now()
);

-- Admin login accounts for the Flutter app's auth screen. Created/updated
-- by `npm run seed` (see seed.js) -- never insert plaintext credentials
-- here directly.
CREATE TABLE IF NOT EXISTS admins (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  username      TEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  pin_hash      TEXT NOT NULL,
  role          TEXT NOT NULL DEFAULT 'admin',
  created_at    TIMESTAMPTZ DEFAULT now()
);

-- Which admin account registered each organization, so an admin's "My
-- Organizations" list (GET /organizations) can be scoped to their own.
-- Added after both tables above already exist -- ADD COLUMN IF NOT EXISTS
-- keeps this file safe to re-run against a database that predates this
-- column (e.g. via /admin/bootstrap), same as every other statement here.
-- Nullable: existing organizations created before this column existed, or
-- ones created via the legacy x-api-key service path, simply have no owner.
-- ON DELETE SET NULL rather than the default NO ACTION -- removing an admin
-- account must never be blocked by (or cascade-delete) the organizations
-- they set up; those just become unowned, exactly like the x-api-key case.
ALTER TABLE organizations
  ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES admins(id) ON DELETE SET NULL;
