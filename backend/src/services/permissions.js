const { db } = require('../database');
const { sameCompany } = require('./company-scope');

function _userRow(userId) {
  return db.prepare('SELECT id, role, company_id FROM users WHERE id = ?').get(userId);
}

function _isAdmin(userId) {
  const user = _userRow(userId);
  return user && ['admin', 'superadmin', 'superuser', 'streamdeck'].includes(user.role);
}

function canUserTalkToUser(fromUserId, toUserId) {
  // Hard isolation: never allow cross-company talk (except superadmin override).
  const from = _userRow(fromUserId);
  const to = _userRow(toUserId);
  if (!from || !to) return false;
  if (from.role !== 'superadmin' && to.role !== 'superadmin') {
    if (from.company_id == null || to.company_id == null || from.company_id !== to.company_id) {
      return false;
    }
  }

  if (_isAdmin(fromUserId)) {
    // Company admins only override inside their company.
    if (from.role === 'superadmin') return true;
    return from.company_id != null && from.company_id === to.company_id;
  }

  const perm = db.prepare(
    'SELECT can_talk FROM permissions WHERE from_user_id = ? AND to_user_id = ?'
  ).get(fromUserId, toUserId);
  return perm && perm.can_talk === 1;
}

function canUserTalkToGroup(fromUserId, toGroupId) {
  const from = _userRow(fromUserId);
  if (!from) return false;
  const group = db.prepare('SELECT id, company_id FROM groups WHERE id = ?').get(toGroupId);
  if (!group) return false;

  if (from.role !== 'superadmin') {
    if (from.company_id == null || group.company_id == null || from.company_id !== group.company_id) {
      return false;
    }
  }

  if (_isAdmin(fromUserId)) {
    if (from.role === 'superadmin') return true;
    return from.company_id === group.company_id;
  }
  const perm = db.prepare(
    'SELECT can_talk FROM group_permissions WHERE from_user_id = ? AND to_group_id = ?'
  ).get(fromUserId, toGroupId);
  return perm && perm.can_talk === 1;
}

function getUserTargets(userId) {
  const me = _userRow(userId);
  if (!me) return { users: [], groups: [] };
  const isAdmin = _isAdmin(userId);
  const isSuper = me.role === 'superadmin';
  const companyId = me.company_id;

  let users;
  if (isSuper) {
    // Superadmin maintenance: see everyone except self (rarely used in PTT UI).
    users = db.prepare(`
      SELECT id, username, display_name, room_id, color, role, company_id
      FROM users WHERE id != ?
    `).all(userId);
  } else if (isAdmin) {
    users = db.prepare(`
      SELECT id, username, display_name, room_id, color, role, company_id
      FROM users
      WHERE id != ?
        AND company_id = ?
        AND role != 'superadmin'
    `).all(userId, companyId);
  } else {
    users = db.prepare(`
      SELECT u.id, u.username, u.display_name, u.room_id, u.color, u.role, u.company_id
      FROM permissions p
      JOIN users u ON p.to_user_id = u.id
      WHERE p.from_user_id = ? AND p.can_talk = 1
        AND u.role NOT IN ('admin','superadmin')
        AND u.company_id = ?
    `).all(userId, companyId);
  }

  let groups;
  if (isSuper) {
    groups = db.prepare('SELECT id, name, company_id FROM groups').all();
  } else if (isAdmin) {
    groups = db.prepare('SELECT id, name, company_id FROM groups WHERE company_id = ?').all(companyId);
  } else {
    groups = db.prepare(`
      SELECT g.id, g.name, g.company_id
      FROM group_permissions gp
      JOIN groups g ON gp.to_group_id = g.id
      WHERE gp.from_user_id = ? AND gp.can_talk = 1
        AND g.company_id = ?
    `).all(userId, companyId);
  }

  // For each group, include the member room_ids (the actual rooms to talk to)
  const getMembers = db.prepare(`
    SELECT u.id, u.room_id FROM group_members gm
    JOIN users u ON gm.user_id = u.id
    WHERE gm.group_id = ?
      AND (u.company_id = (SELECT company_id FROM groups WHERE id = ?) OR ? = 1)
  `);
  for (const g of groups) {
    const members = getMembers.all(g.id, g.id, isSuper ? 1 : 0);
    g.member_rooms = members.map(m => m.room_id);
    g.member_ids = members.map(m => m.id);
  }

  return { users, groups };
}

/**
 * Get all userIds that have permission to talk TO this user.
 * Includes: direct permissions + group members where user is a member.
 * Admins can talk to anyone, so all admins are included.
 */
function getWhoCanTalkTo(userId) {
  const me = _userRow(userId);
  if (!me) return [];
  const sourceIds = new Set();

  // Direct permissions: who has can_talk=1 TO this userId (same company only)
  const direct = db.prepare(`
    SELECT p.from_user_id
      FROM permissions p
      JOIN users u ON u.id = p.from_user_id
     WHERE p.to_user_id = ? AND p.can_talk = 1
       AND (u.company_id = ? OR u.role = 'superadmin')
  `).all(userId, me.company_id);
  for (const p of direct) sourceIds.add(p.from_user_id);

  // Group permissions: find groups this user is a member of,
  // then find who has permission to talk to those groups
  const userGroups = db.prepare(
    'SELECT group_id FROM group_members WHERE user_id = ?'
  ).all(userId);
  for (const { group_id } of userGroups) {
    const groupSources = db.prepare(`
      SELECT gp.from_user_id
        FROM group_permissions gp
        JOIN users u ON u.id = gp.from_user_id
       WHERE gp.to_group_id = ? AND gp.can_talk = 1
         AND (u.company_id = ? OR u.role = 'superadmin')
    `).all(group_id, me.company_id);
    for (const p of groupSources) {
      if (p.from_user_id !== userId) sourceIds.add(p.from_user_id);
    }
  }

  // Privileged roles can talk to anyone *in the same company* (superadmin global).
  const admins = db.prepare(`
    SELECT id, role, company_id FROM users
     WHERE role IN ('admin','superadmin','superuser','streamdeck')
  `).all();
  for (const a of admins) {
    if (a.id === userId) continue;
    if (a.role === 'superadmin' || (me.company_id != null && a.company_id === me.company_id)) {
      sourceIds.add(a.id);
    }
  }

  // Drop any residual cross-company ids (defensive).
  return [...sourceIds].filter((id) => sameCompany(id, userId) || _userRow(id)?.role === 'superadmin');
}

module.exports = { canUserTalkToUser, canUserTalkToGroup, getUserTargets, getWhoCanTalkTo };
