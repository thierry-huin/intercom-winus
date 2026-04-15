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

// GET /api/rooms/directory - list all users and groups (for tie line bridge)
router.get('/directory', (req, res) => {
  const users = db.prepare(
    'SELECT id, username, display_name, role FROM users ORDER BY id'
  ).all();
  const groups = db.prepare(
    'SELECT id, name FROM groups ORDER BY id'
  ).all();
  res.json({ users, groups });
});

module.exports = router;
