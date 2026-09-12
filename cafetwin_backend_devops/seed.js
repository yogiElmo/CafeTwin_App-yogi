// seed.js -- creates or updates the single admin account CaféTwin's login
// screen authenticates against. Run once (and again whenever you want to
// rotate the password):
//
//   npm run seed
//
// Reads credentials from the environment so nothing sensitive is ever
// committed to source. If ADMIN_PASSWORD/ADMIN_PIN are left unset, a
// random password and PIN are generated and printed ONCE -- copy them
// somewhere safe; they cannot be recovered afterwards (only reset by
// running this script again).

require('dotenv').config();
const crypto = require('crypto');
const bcrypt = require('bcryptjs');
const { Pool } = require('pg');

const pool = new Pool({
  host: process.env.PGHOST || 'localhost',
  port: Number(process.env.PGPORT || 5432),
  database: process.env.PGDATABASE || 'postgres',
  user: process.env.PGUSER || 'postgres',
  password: process.env.PGPASSWORD || 'cafetwin123',
  ssl: process.env.PGSSLMODE === 'require' ? { rejectUnauthorized: false } : false,
});

function randomSecret(bytes, alphabet) {
  return Array.from(crypto.randomBytes(bytes))
    .map((b) => alphabet[b % alphabet.length])
    .join('');
}

async function main() {
  const username = process.env.ADMIN_USERNAME || 'admin';
  let password = process.env.ADMIN_PASSWORD;
  let pin = process.env.ADMIN_PIN;
  let generated = false;

  if (!password) {
    password = randomSecret(18, 'ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789');
    generated = true;
  }
  if (!pin) {
    pin = randomSecret(4, '0123456789');
    generated = true;
  }

  const passwordHash = await bcrypt.hash(password, 12);
  const pinHash = await bcrypt.hash(pin, 12);

  await pool.query(
    `INSERT INTO admins (username, password_hash, pin_hash, role)
     VALUES ($1, $2, $3, 'admin')
     ON CONFLICT (username) DO UPDATE
       SET password_hash = EXCLUDED.password_hash, pin_hash = EXCLUDED.pin_hash`,
    [username, passwordHash, pinHash]
  );

  console.log(`Admin account "${username}" is ready.`);
  if (generated) {
    console.log('');
    console.log('Generated credentials (shown once -- store them now):');
    console.log(`  username : ${username}`);
    console.log(`  password : ${password}`);
    console.log(`  pin      : ${pin}`);
    console.log('');
  }
  await pool.end();
}

main().catch((err) => {
  console.error('Seeding failed:', err);
  process.exit(1);
});
