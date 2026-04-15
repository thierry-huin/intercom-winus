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
    CREATE TABLE IF NOT EXISTS users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      username TEXT UNIQUE NOT NULL,
      password_hash TEXT NOT NULL,
      display_name TEXT NOT NULL,
      role TEXT NOT NULL DEFAULT 'user' CHECK(role IN ('admin', 'user', 'bridge')),
      room_id INTEGER UNIQUE,
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
      name TEXT UNIQUE NOT NULL,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP
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

  // Migration: add color column if not exists
  try {
    db.exec('ALTER TABLE users ADD COLUMN color TEXT');
  } catch (e) {
    // Column already exists, ignore
  }

  // Migration: add 'bridge' and 'superuser' to role CHECK constraint
  try {
    const schema = db.prepare("SELECT sql FROM sqlite_master WHERE type='table' AND name='users'").get();
    if (schema && !schema.sql.includes("'superuser'")) {
      db.pragma('foreign_keys = OFF');
      db.exec(`
        CREATE TABLE users_new (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          username TEXT UNIQUE NOT NULL,
          password_hash TEXT NOT NULL,
          display_name TEXT NOT NULL,
          role TEXT NOT NULL DEFAULT 'user' CHECK(role IN ('admin', 'superuser', 'user', 'bridge')),
          room_id INTEGER UNIQUE,
          color TEXT,
          created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        INSERT INTO users_new SELECT id, username, password_hash, display_name, role, room_id, color, created_at FROM users;
        DROP TABLE users;
        ALTER TABLE users_new RENAME TO users;
      `);
      db.pragma('foreign_keys = ON');
      console.log('[DB] Migrated role CHECK to include superuser');
    }
  } catch (e) {
    console.warn('[DB] Role migration note:', e.message);
  }

  // Create default admin user if not exists
  const adminExists = db.prepare('SELECT id FROM users WHERE username = ?').get(config.admin.username);
  if (!adminExists) {
    const hash = bcrypt.hashSync(config.admin.password, 10);
    const result = db.prepare(
      'INSERT INTO users (username, password_hash, display_name, role) VALUES (?, ?, ?, ?)'
    ).run(config.admin.username, hash, 'Administrador', 'admin');

    const roomId = config.roomIdOffset + result.lastInsertRowid;
    db.prepare('UPDATE users SET room_id = ? WHERE id = ?').run(roomId, result.lastInsertRowid);

    console.log(`Admin user created: ${config.admin.username} (room_id: ${roomId})`);
  }
}

module.exports = { db, initialize };
