const express = require('express');
const bcrypt = require('bcryptjs');
const { db } = require('../database');
const config = require('../config');
const { authMiddleware, adminMiddleware } = require('./auth');
const { disconnectUser, getOnlineUserIds, getBridgeStatus } = require('../ws/signaling');
const { getConfig, setConfig } = require('../services/config-service');

const router = express.Router();
router.use(authMiddleware);
router.use(adminMiddleware);

// ======================== USERS ========================

// GET /api/admin/users
router.get('/users', (req, res) => {
  const users = db.prepare(
    'SELECT id, username, display_name, role, room_id, color, created_at FROM users ORDER BY id'
  ).all();
  res.json(users);
});

// POST /api/admin/users
router.post('/users', async (req, res) => {
  const { username, password, display_name, role, color } = req.body;

  if (!username || !password || !display_name) {
    return res.status(400).json({ error: 'username, password y display_name son requeridos' });
  }

  try {
    const hash = bcrypt.hashSync(password, 10);
    const result = db.prepare(
      'INSERT INTO users (username, password_hash, display_name, role, color) VALUES (?, ?, ?, ?, ?)'
    ).run(username, hash, display_name, role || 'user', color || null);

    const userId = result.lastInsertRowid;
    const roomId = config.roomIdOffset + userId;

    db.prepare('UPDATE users SET room_id = ? WHERE id = ?').run(roomId, userId);

    res.status(201).json({ id: userId, username, display_name, role: role || 'user', room_id: roomId, color: color || null });
  } catch (err) {
    if (err.message.includes('UNIQUE')) {
      return res.status(409).json({ error: 'El usuario ya existe' });
    }
    return res.status(500).json({ error: err.message });
  }
});

// PUT /api/admin/users/:id
router.put('/users/:id', (req, res) => {
  const { id } = req.params;
  const { display_name, role, password, color } = req.body;

  const user = db.prepare('SELECT id FROM users WHERE id = ?').get(id);
  if (!user) {
    return res.status(404).json({ error: 'Usuario no encontrado' });
  }

  if (display_name) {
    db.prepare('UPDATE users SET display_name = ? WHERE id = ?').run(display_name, id);
  }
  if (role) {
    db.prepare('UPDATE users SET role = ? WHERE id = ?').run(role, id);
  }
  if (password) {
    const hash = bcrypt.hashSync(password, 10);
    db.prepare('UPDATE users SET password_hash = ? WHERE id = ?').run(hash, id);
  }
  if (color !== undefined) {
    db.prepare('UPDATE users SET color = ? WHERE id = ?').run(color, id);
  }

  const updated = db.prepare(
    'SELECT id, username, display_name, role, room_id, color, created_at FROM users WHERE id = ?'
  ).get(id);
  res.json(updated);
});

// DELETE /api/admin/users/:id
router.delete('/users/:id', async (req, res) => {
  const { id } = req.params;

  const user = db.prepare('SELECT id, room_id FROM users WHERE id = ?').get(id);
  if (!user) {
    return res.status(404).json({ error: 'Usuario no encontrado' });
  }

  db.prepare('DELETE FROM users WHERE id = ?').run(id);
  res.json({ ok: true });
});

// POST /api/admin/users/:id/kick — force disconnect a user
router.post('/users/:id/kick', (req, res) => {
  const userId = parseInt(req.params.id);
  const ok = disconnectUser(userId);
  if (ok) {
    console.log(`[Admin] User ${userId} kicked by admin ${req.user.id}`);
    res.json({ ok: true });
  } else {
    res.status(404).json({ error: 'User not online' });
  }
});

// GET /api/admin/online — list of connected user IDs
router.get('/online', (req, res) => {
  res.json({ userIds: getOnlineUserIds() });
});

// GET /api/admin/bridge-status — detailed status of all bridge users
router.get('/bridge-status', (req, res) => {
  res.json(getBridgeStatus());
});

// ======================== PERMISSIONS ========================

// DELETE /api/admin/permissions/:fromId/:toId
router.delete('/permissions/:fromId/:toId', (req, res) => {
  db.prepare('DELETE FROM permissions WHERE from_user_id = ? AND to_user_id = ?')
    .run(req.params.fromId, req.params.toId);
  res.json({ ok: true });
});

// GET /api/admin/permissions
router.get('/permissions', (req, res) => {
  const permissions = db.prepare(
    'SELECT from_user_id, to_user_id, can_talk FROM permissions'
  ).all();
  res.json(permissions);
});

// POST /api/admin/permissions
router.post('/permissions', (req, res) => {
  const { from_user_id, to_user_id, can_talk } = req.body;

  if (from_user_id === to_user_id) {
    return res.status(400).json({ error: 'No se puede asignar permiso a sí mismo' });
  }

  db.prepare(`
    INSERT INTO permissions (from_user_id, to_user_id, can_talk)
    VALUES (?, ?, ?)
    ON CONFLICT(from_user_id, to_user_id) DO UPDATE SET can_talk = excluded.can_talk
  `).run(from_user_id, to_user_id, can_talk ? 1 : 0);

  res.json({ ok: true });
});

// POST /api/admin/permissions/bulk
router.post('/permissions/bulk', (req, res) => {
  const { permissions } = req.body;

  const stmt = db.prepare(`
    INSERT INTO permissions (from_user_id, to_user_id, can_talk)
    VALUES (?, ?, ?)
    ON CONFLICT(from_user_id, to_user_id) DO UPDATE SET can_talk = excluded.can_talk
  `);

  const transaction = db.transaction((perms) => {
    for (const p of perms) {
      if (p.from_user_id !== p.to_user_id) {
        stmt.run(p.from_user_id, p.to_user_id, p.can_talk ? 1 : 0);
      }
    }
  });

  transaction(permissions);
  res.json({ ok: true });
});

// DELETE /api/admin/group-permissions/:fromId/:toGroupId
router.delete('/group-permissions/:fromId/:toGroupId', (req, res) => {
  db.prepare('DELETE FROM group_permissions WHERE from_user_id = ? AND to_group_id = ?')
    .run(req.params.fromId, req.params.toGroupId);
  // Auto-remove from group when revoking permission
  db.prepare('DELETE FROM group_members WHERE group_id = ? AND user_id = ?')
    .run(req.params.toGroupId, req.params.fromId);
  res.json({ ok: true });
});

// ======================== GROUPS ========================

// GET /api/admin/groups
router.get('/groups', (req, res) => {
  const groups = db.prepare('SELECT * FROM groups ORDER BY id').all();

  const getMembers = db.prepare(
    'SELECT u.id, u.username, u.display_name FROM group_members gm JOIN users u ON gm.user_id = u.id WHERE gm.group_id = ?'
  );

  const result = groups.map((g) => ({
    ...g,
    members: getMembers.all(g.id),
  }));

  res.json(result);
});

// POST /api/admin/groups
router.post('/groups', async (req, res) => {
  const { name, member_ids } = req.body;

  if (!name) {
    return res.status(400).json({ error: 'Nombre del grupo requerido' });
  }

  try {
    const result = db.prepare('INSERT INTO groups (name) VALUES (?)').run(name);
    const groupId = result.lastInsertRowid;

    // Add members
    if (member_ids && member_ids.length > 0) {
      const stmt = db.prepare('INSERT OR IGNORE INTO group_members (group_id, user_id) VALUES (?, ?)');
      for (const uid of member_ids) {
        stmt.run(groupId, uid);
      }
    }

    res.status(201).json({ id: groupId, name });
  } catch (err) {
    if (err.message.includes('UNIQUE')) {
      return res.status(409).json({ error: 'El grupo ya existe' });
    }
    return res.status(500).json({ error: err.message });
  }
});

// POST /api/admin/groups/:id/members
router.post('/groups/:id/members', (req, res) => {
  const { id } = req.params;
  const { user_id } = req.body;
  db.prepare('INSERT OR IGNORE INTO group_members (group_id, user_id) VALUES (?, ?)').run(id, user_id);
  res.json({ ok: true });
});

// DELETE /api/admin/groups/:id/members/:userId
router.delete('/groups/:id/members/:userId', (req, res) => {
  db.prepare('DELETE FROM group_members WHERE group_id = ? AND user_id = ?')
    .run(req.params.id, req.params.userId);
  res.json({ ok: true });
});

// PUT /api/admin/groups/:id
router.put('/groups/:id', (req, res) => {
  const { id } = req.params;
  const { name, member_ids } = req.body;

  const group = db.prepare('SELECT id FROM groups WHERE id = ?').get(id);
  if (!group) {
    return res.status(404).json({ error: 'Grupo no encontrado' });
  }

  if (name) {
    db.prepare('UPDATE groups SET name = ? WHERE id = ?').run(name, id);
  }

  if (member_ids !== undefined) {
    db.prepare('DELETE FROM group_members WHERE group_id = ?').run(id);
    const stmt = db.prepare('INSERT INTO group_members (group_id, user_id) VALUES (?, ?)');
    for (const uid of member_ids) {
      stmt.run(id, uid);
    }
  }

  const updated = db.prepare('SELECT * FROM groups WHERE id = ?').get(id);
  const members = db.prepare(
    'SELECT u.id, u.username, u.display_name FROM group_members gm JOIN users u ON gm.user_id = u.id WHERE gm.group_id = ?'
  ).all(id);

  res.json({ ...updated, members });
});

// DELETE /api/admin/groups/:id
router.delete('/groups/:id', (req, res) => {
  const { id } = req.params;

  const group = db.prepare('SELECT id FROM groups WHERE id = ?').get(id);
  if (!group) {
    return res.status(404).json({ error: 'Grupo no encontrado' });
  }

  db.prepare('DELETE FROM groups WHERE id = ?').run(id);
  res.json({ ok: true });
});

// ======================== GROUP PERMISSIONS ========================

// GET /api/admin/group-permissions
router.get('/group-permissions', (req, res) => {
  const perms = db.prepare(
    'SELECT from_user_id, to_group_id, can_talk FROM group_permissions'
  ).all();
  res.json(perms);
});

// POST /api/admin/group-permissions
router.post('/group-permissions', (req, res) => {
  const { from_user_id, to_group_id, can_talk } = req.body;

  db.prepare(`
    INSERT INTO group_permissions (from_user_id, to_group_id, can_talk)
    VALUES (?, ?, ?)
    ON CONFLICT(from_user_id, to_group_id) DO UPDATE SET can_talk = excluded.can_talk
  `).run(from_user_id, to_group_id, can_talk ? 1 : 0);

  // Auto-add as group member when granting permission
  if (can_talk) {
    db.prepare('INSERT OR IGNORE INTO group_members (group_id, user_id) VALUES (?, ?)')
      .run(to_group_id, from_user_id);
  }

  res.json({ ok: true });
});

// POST /api/admin/group-permissions/bulk
router.post('/group-permissions/bulk', (req, res) => {
  const { permissions } = req.body;

  const stmt = db.prepare(`
    INSERT INTO group_permissions (from_user_id, to_group_id, can_talk)
    VALUES (?, ?, ?)
    ON CONFLICT(from_user_id, to_group_id) DO UPDATE SET can_talk = excluded.can_talk
  `);

  const transaction = db.transaction((perms) => {
    for (const p of perms) {
      stmt.run(p.from_user_id, p.to_group_id, p.can_talk ? 1 : 0);
    }
  });

  transaction(permissions);
  res.json({ ok: true });
});

// ======================== SERVER CONFIG ========================

// GET /api/admin/server-config
router.get('/server-config', (req, res) => {
  res.json({
    announced_ips: getConfig('announced_ips', process.env.MEDIASOUP_ANNOUNCED_IPS || ''),
    turn_host:     getConfig('turn_host', ''),
    turn_port:     getConfig('turn_port', process.env.TURN_PORT || '3478'),
    turn_user:     getConfig('turn_user', process.env.TURN_USER || 'intercom'),
    turn_password: getConfig('turn_password', process.env.TURN_PASSWORD || 'intercom2024'),
  });
});

// PUT /api/admin/server-config
router.put('/server-config', (req, res) => {
  const fields = ['announced_ips', 'turn_host', 'turn_port', 'turn_user', 'turn_password'];
  for (const field of fields) {
    if (req.body[field] !== undefined) {
      setConfig(field, req.body[field]);
    }
  }
  res.json({ ok: true });
});

// ======================== EXPORT / IMPORT CONFIG ========================

// GET /api/admin/export-config — full backup
router.get('/export-config', (req, res) => {
  const users = db.prepare(
    'SELECT id, username, display_name, role, room_id, color FROM users ORDER BY id'
  ).all();
  const groups = db.prepare('SELECT id, name FROM groups ORDER BY id').all();
  const members = db.prepare('SELECT group_id, user_id FROM group_members').all();
  const permissions = db.prepare('SELECT from_user_id, to_user_id, can_talk FROM permissions').all();
  const groupPerms = db.prepare('SELECT from_user_id, to_group_id, can_talk FROM group_permissions').all();
  const serverConfig = {};
  for (const row of db.prepare('SELECT key, value FROM server_config').all()) {
    serverConfig[row.key] = row.value;
  }

  res.json({
    version: 1,
    exported_at: new Date().toISOString(),
    users,
    groups,
    group_members: members,
    permissions,
    group_permissions: groupPerms,
    server_config: serverConfig,
  });
});

// POST /api/admin/import-config — restore from backup
router.post('/import-config', (req, res) => {
  const data = req.body;
  if (!data || !data.users || !data.groups) {
    return res.status(400).json({ error: 'Invalid config format' });
  }

  try {
    const bcrypt = require('bcryptjs');
    const defaultHash = bcrypt.hashSync('1234', 10);

    db.transaction(() => {
      // Clear existing data (order matters for FK constraints)
      db.exec('DELETE FROM group_permissions');
      db.exec('DELETE FROM permissions');
      db.exec('DELETE FROM group_members');
      db.exec('DELETE FROM groups');
      db.exec('DELETE FROM users');

      // Import users (with default password since we don't export hashes)
      const insertUser = db.prepare(
        'INSERT INTO users (id, username, password_hash, display_name, role, room_id, color) VALUES (?, ?, ?, ?, ?, ?, ?)'
      );
      for (const u of data.users) {
        insertUser.run(u.id, u.username, defaultHash, u.display_name, u.role || 'user', u.room_id, u.color || null);
      }

      // Import groups
      const insertGroup = db.prepare('INSERT INTO groups (id, name) VALUES (?, ?)');
      for (const g of data.groups) {
        insertGroup.run(g.id, g.name);
      }

      // Import group members
      if (data.group_members) {
        const insertMember = db.prepare('INSERT OR IGNORE INTO group_members (group_id, user_id) VALUES (?, ?)');
        for (const m of data.group_members) {
          insertMember.run(m.group_id, m.user_id);
        }
      }

      // Import permissions
      if (data.permissions) {
        const insertPerm = db.prepare(
          'INSERT OR IGNORE INTO permissions (from_user_id, to_user_id, can_talk) VALUES (?, ?, ?)'
        );
        for (const p of data.permissions) {
          insertPerm.run(p.from_user_id, p.to_user_id, p.can_talk ? 1 : 0);
        }
      }

      // Import group permissions
      if (data.group_permissions) {
        const insertGP = db.prepare(
          'INSERT OR IGNORE INTO group_permissions (from_user_id, to_group_id, can_talk) VALUES (?, ?, ?)'
        );
        for (const p of data.group_permissions) {
          insertGP.run(p.from_user_id, p.to_group_id, p.can_talk ? 1 : 0);
        }
      }

      // Import server config
      if (data.server_config) {
        const upsertConfig = db.prepare(
          'INSERT INTO server_config (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value'
        );
        for (const [key, value] of Object.entries(data.server_config)) {
          upsertConfig.run(key, value);
        }
      }
    })();

    console.log(`[Admin] Config imported: ${data.users.length} users, ${data.groups.length} groups`);
    res.json({ ok: true, users: data.users.length, groups: data.groups.length });
  } catch (err) {
    console.error('[Admin] Import error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ======================== BRIDGE CONFIG ========================

// GET /api/admin/bridge-config — generate TieLine bridge config.json
router.get('/bridge-config', (req, res) => {
  const bridgeUsers = db.prepare(
    "SELECT id, username, display_name FROM users WHERE role = 'bridge' ORDER BY id"
  ).all();

  // Get saved channel mappings (target per bridge user)
  const savedRaw = getConfig('bridge_channels', '{}');
  let saved = {};
  try { saved = JSON.parse(savedRaw); } catch (_) {}

  const channels = bridgeUsers.map((u, idx) => {
    const ch = saved[String(u.id)] || {};
    return {
      index: idx + 1,
      user_id: u.id,
      username: u.username,
      display_name: u.display_name,
      password: ch.password || '1234',
      target_type: ch.target_type || 'user',
      target_id: ch.target_id || 0,
      input_device: ch.input_device || '',
      input_channel: ch.input_channel || idx + 1,
      output_device: ch.output_device || '',
      output_channel: ch.output_channel || idx + 1,
      vox_send_enabled: ch.vox_send_enabled ?? false,
      vox_send_threshold_db: ch.vox_send_threshold_db ?? -40,
      vox_send_hold_ms: ch.vox_send_hold_ms ?? 300,
      vox_recv_enabled: ch.vox_recv_enabled ?? true,
      vox_recv_threshold_db: ch.vox_recv_threshold_db ?? -40,
      vox_recv_hold_ms: ch.vox_recv_hold_ms ?? 300,
    };
  });

  res.json({
    server: `https://${req.headers.host || 'localhost:8443'}`,
    channels,
  });
});

// PUT /api/admin/bridge-config — save bridge channel mappings
router.put('/bridge-config', (req, res) => {
  const { channels } = req.body;
  if (!channels || !Array.isArray(channels)) {
    return res.status(400).json({ error: 'channels array required' });
  }

  // Store as { "userId": { password, target_type, target_id, ... } }
  const saved = {};
  for (const ch of channels) {
    saved[String(ch.user_id)] = {
      password: ch.password,
      target_type: ch.target_type,
      target_id: ch.target_id,
      input_device: ch.input_device,
      input_channel: ch.input_channel,
      output_device: ch.output_device,
      output_channel: ch.output_channel,
      vox_send_enabled: ch.vox_send_enabled,
      vox_send_threshold_db: ch.vox_send_threshold_db,
      vox_send_hold_ms: ch.vox_send_hold_ms,
      vox_recv_enabled: ch.vox_recv_enabled,
      vox_recv_threshold_db: ch.vox_recv_threshold_db,
      vox_recv_hold_ms: ch.vox_recv_hold_ms,
    };
  }
  setConfig('bridge_channels', JSON.stringify(saved));
  res.json({ ok: true });
});

module.exports = router;
