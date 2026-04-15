const express = require('express');
const { authMiddleware } = require('./auth');
const { registerToken, unregisterToken } = require('../services/push-service');

const router = express.Router();
router.use(authMiddleware);

// POST /api/push/register — register a device push token
router.post('/register', (req, res) => {
  const { token, platform } = req.body;
  if (!token) return res.status(400).json({ error: 'token required' });
  registerToken(req.user.id, token, platform || 'ios');
  res.json({ ok: true });
});

// POST /api/push/unregister — remove a device push token
router.post('/unregister', (req, res) => {
  const { token } = req.body;
  if (!token) return res.status(400).json({ error: 'token required' });
  unregisterToken(token);
  res.json({ ok: true });
});

module.exports = router;
