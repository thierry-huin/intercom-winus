const { db } = require('../database');

function _isAdmin(userId) {
  const user = db.prepare('SELECT role FROM users WHERE id = ?').get(userId);
  return user && user.role === 'admin';
}

function canUserTalkToUser(fromUserId, toUserId) {
  if (_isAdmin(fromUserId)) return true;

  const perm = db.prepare(
    'SELECT can_talk FROM permissions WHERE from_user_id = ? AND to_user_id = ?'
  ).get(fromUserId, toUserId);
  return perm && perm.can_talk === 1;
}

function canUserTalkToGroup(fromUserId, toGroupId) {
  if (_isAdmin(fromUserId)) return true;
  const perm = db.prepare(
    'SELECT can_talk FROM group_permissions WHERE from_user_id = ? AND to_group_id = ?'
  ).get(fromUserId, toGroupId);
  return perm && perm.can_talk === 1;
}

function getUserTargets(userId) {
  const isAdmin = _isAdmin(userId);

  const users = isAdmin
    ? db.prepare(`
        SELECT id, username, display_name, room_id, color, role
        FROM users WHERE id != ?
      `).all(userId)
    : db.prepare(`
        SELECT u.id, u.username, u.display_name, u.room_id, u.color, u.role
        FROM permissions p
        JOIN users u ON p.to_user_id = u.id
        WHERE p.from_user_id = ? AND p.can_talk = 1
      `).all(userId);

  const groups = isAdmin
    ? db.prepare('SELECT id, name FROM groups').all()
    : db.prepare(`
        SELECT g.id, g.name
        FROM group_permissions gp
        JOIN groups g ON gp.to_group_id = g.id
        WHERE gp.from_user_id = ? AND gp.can_talk = 1
      `).all(userId);

  // For each group, include the member room_ids (the actual rooms to talk to)
  const getMembers = db.prepare(`
    SELECT u.id, u.room_id FROM group_members gm
    JOIN users u ON gm.user_id = u.id
    WHERE gm.group_id = ?
  `);
  for (const g of groups) {
    const members = getMembers.all(g.id);
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
  const sourceIds = new Set();

  // Direct permissions: who has can_talk=1 TO this userId
  const direct = db.prepare(
    'SELECT from_user_id FROM permissions WHERE to_user_id = ? AND can_talk = 1'
  ).all(userId);
  for (const p of direct) sourceIds.add(p.from_user_id);

  // Group permissions: find groups this user is a member of,
  // then find who has permission to talk to those groups
  const userGroups = db.prepare(
    'SELECT group_id FROM group_members WHERE user_id = ?'
  ).all(userId);
  for (const { group_id } of userGroups) {
    const groupSources = db.prepare(
      'SELECT from_user_id FROM group_permissions WHERE to_group_id = ? AND can_talk = 1'
    ).all(group_id);
    for (const p of groupSources) {
      if (p.from_user_id !== userId) sourceIds.add(p.from_user_id);
    }
  }

  // Admins can talk to anyone
  const admins = db.prepare("SELECT id FROM users WHERE role = 'admin'").all();
  for (const a of admins) {
    if (a.id !== userId) sourceIds.add(a.id);
  }

  return [...sourceIds];
}

module.exports = { canUserTalkToUser, canUserTalkToGroup, getUserTargets, getWhoCanTalkTo };
