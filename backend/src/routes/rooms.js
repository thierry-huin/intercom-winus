const express = require('express');
const { authMiddleware } = require('./auth');
const { getUserTargets } = require('../services/permissions');
const { db } = require('../database');

const router = express.Router();
router.use(authMiddleware);

// GET /api/rooms/my-targets - rooms the logged-in user can talk to
router.get('/my-targets', (req, res) => {
  const targets = getUserTargets(req.user.id, req.user.role);
  res.json(targets);
});

// GET /api/rooms/directory - list users and groups for the caller's company
// (tie line bridge). Superadmin sees all.
router.get('/directory', (req, res) => {
  const me = db.prepare('SELECT role, company_id FROM users WHERE id = ?').get(req.user.id);
  if (!me) return res.status(401).json({ error: 'Usuario no encontrado' });

  let users;
  let groups;
  if (me.role === 'superadmin') {
    users = db.prepare(
      'SELECT id, username, display_name, role, company_id FROM users ORDER BY id'
    ).all();
    groups = db.prepare(
      'SELECT id, name, company_id FROM groups ORDER BY id'
    ).all();
  } else {
    users = db.prepare(
      'SELECT id, username, display_name, role, company_id FROM users WHERE company_id = ? ORDER BY id'
    ).all(me.company_id);
    groups = db.prepare(
      'SELECT id, name, company_id FROM groups WHERE company_id = ? ORDER BY id'
    ).all(me.company_id);
  }
  res.json({ users, groups });
});

module.exports = router;
