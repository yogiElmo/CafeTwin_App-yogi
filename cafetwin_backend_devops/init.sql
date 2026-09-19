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

-- TOTP (Google Authenticator / Microsoft Authenticator / Authy -- any
-- app that speaks the same RFC 6238 standard) multi-factor authentication.
-- totp_secret is written by POST /auth/totp/setup but does NOT make login
-- require a code by itself -- that only happens once totp_enabled is
-- flipped true by POST /auth/totp/enable, after the account holder proves
-- they actually scanned it.
--
-- Available to BOTH roles, but forced on neither. This was originally
-- admin-only, on the reasoning that café-floor terminals are shared and a
-- second factor there is friction with no real payoff. That still argues
-- against *mandating* MFA for staff -- it does not argue against offering
-- it. A staff member with their own device can opt in; a shared till
-- account simply leaves it off. ADD COLUMN IF NOT EXISTS keeps this safe
-- to re-run against a database that predates MFA, same as created_by.
ALTER TABLE admins
  ADD COLUMN IF NOT EXISTS totp_secret TEXT,
  ADD COLUMN IF NOT EXISTS totp_enabled BOOLEAN NOT NULL DEFAULT false;

-- Which café a STAFF account belongs to. Staff are scoped to exactly one
-- organization, chosen by the admin at the moment the account is created
-- (POST /admin/users). They can neither create organizations nor read any
-- other one -- enforced server-side by requireAdminOrService and
-- orgAccessError in server.js, not merely hidden in the UI.
--
-- NULL for admins, deliberately: an admin is not "in" one café, they own
-- the set of cafés they created, which organizations.created_by already
-- records. NULL is the normal state for an admin row, not a missing value.
--
-- ON DELETE SET NULL matches created_by above: deleting an organization
-- must not cascade into deleting the staff accounts attached to it. Such
-- an account survives with no organization, which orgAccessError treats as
-- "can read nothing" until an admin reassigns it.
ALTER TABLE admins
  ADD COLUMN IF NOT EXISTS organization_id UUID REFERENCES organizations(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_admins_organization_id ON admins(organization_id);

-- One-time recovery codes for an admin who enabled TOTP and then lost
-- their authenticator device. Generated once, when TOTP is enabled
-- (POST /auth/totp/enable) or explicitly regenerated
-- (POST /auth/totp/recovery-codes/regenerate); each row is single-use,
-- consumed by setting used_at the first time it's accepted at login.
-- Hashed with bcrypt exactly like password_hash/pin_hash below -- the
-- plaintext codes are returned to the admin ONCE in the API response and
-- never stored.
CREATE TABLE IF NOT EXISTS totp_recovery_codes (
  id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  admin_id   UUID REFERENCES admins(id) ON DELETE CASCADE,
  code_hash  TEXT NOT NULL,
  used_at    TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_totp_recovery_codes_admin_id ON totp_recovery_codes(admin_id);

-- Server-side session tracking for the JWT auth flow. One row per
-- successful login (created by POST /auth/login), keyed by the token's
-- own "jti" claim, so a specific device's session can be revoked without
-- touching any other session on the same account. This is what turns
-- "Logout" in the app into a real server-side action -- the token is
-- rejected on its very next authenticated request -- rather than just the
-- client discarding its local copy. See authenticateBearer/isSessionRevoked
-- in server.js, and GET/DELETE /auth/sessions + POST /auth/logout.
CREATE TABLE IF NOT EXISTS auth_sessions (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  admin_id     UUID REFERENCES admins(id) ON DELETE CASCADE,
  jti          UUID UNIQUE NOT NULL,
  user_agent   TEXT,
  ip           TEXT,
  created_at   TIMESTAMPTZ DEFAULT now(),
  last_seen_at TIMESTAMPTZ DEFAULT now(),
  revoked_at   TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_auth_sessions_admin_id ON auth_sessions(admin_id);
