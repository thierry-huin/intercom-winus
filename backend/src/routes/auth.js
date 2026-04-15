const express = require('express');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const { db } = require('../database');
const config = require('../config');
const { getOnlineUserIds } = require('../ws/signaling');

const router = express.Router();

// ======================== RATE LIMITING ========================
const loginAttempts = new Map(); // ip -> { count, firstAttempt, blockedUntil }
const MAX_ATTEMPTS = 5;
const WINDOW_MS = 5 * 60 * 1000;    // 5 minutes
const BLOCK_MS = 15 * 60 * 1000;    // 15 minutes block

function getRealIp(req) {
  return req.headers['x-forwarded-for']?.split(',')[0]?.trim() || req.ip || 'unknown';
}

function checkRateLimit(ip) {
  const now = Date.now();
  const entry = loginAttempts.get(ip);
  if (!entry) return { allowed: true };

  // Currently blocked?
  if (entry.blockedUntil && now < entry.blockedUntil) {
    const remainMin = Math.ceil((entry.blockedUntil - now) / 60000);
    return { allowed: false, remainMin };
  }

  // Window expired? Reset
  if (now - entry.firstAttempt > WINDOW_MS) {
    loginAttempts.delete(ip);
    return { allowed: true };
  }

  return { allowed: true };
}

function recordFailedAttempt(ip) {
  const now = Date.now();
  const entry = loginAttempts.get(ip) || { count: 0, firstAttempt: now, blockedUntil: null };
  entry.count++;

  if (entry.count >= MAX_ATTEMPTS) {
    entry.blockedUntil = now + BLOCK_MS;
    console.warn(`[Auth] IP ${ip} blocked for ${BLOCK_MS / 60000} min after ${entry.count} failed attempts`);
  }

  loginAttempts.set(ip, entry);
}

function clearAttempts(ip) {
  loginAttempts.delete(ip);
}

// Cleanup expired entries every 10 min
setInterval(() => {
  const now = Date.now();
  for (const [ip, entry] of loginAttempts) {
    if (now - entry.firstAttempt > WINDOW_MS && (!entry.blockedUntil || now > entry.blockedUntil)) {
      loginAttempts.delete(ip);
    }
  }
}, 10 * 60 * 1000);

// POST /api/auth/login
router.post('/login', (req, res) => {
  const { username, password } = req.body;
  const ip = getRealIp(req);

  // Rate limit check
  const limit = checkRateLimit(ip);
  if (!limit.allowed) {
    return res.status(429).json({ error: `Too many attempts. Try again in ${limit.remainMin} min` });
  }

  if (!username || !password) {
    return res.status(400).json({ error: 'Usuario y contraseña requeridos' });
  }

  const user = db.prepare('SELECT * FROM users WHERE username = ?').get(username);
  if (!user || !bcrypt.compareSync(password, user.password_hash)) {
    recordFailedAttempt(ip);
    return res.status(401).json({ error: 'Credenciales inválidas' });
  }

  // Success: clear attempts
  clearAttempts(ip);

  // Bridge users can only authenticate from the bridge application
  if (user.role === 'bridge' && req.body.client_type !== 'bridge') {
    return res.status(403).json({ error: 'Este usuario es exclusivo para bridge' });
  }

  // Session lock: reject if user is already connected
  // Admins and bridges bypass — bridges need to reconnect after transient failures
  // and the WS auth handler already cleans up stale state on reconnect
  if (user.role !== 'admin' && user.role !== 'bridge' && getOnlineUserIds().includes(user.id)) {
    return res.status(409).json({ error: 'User already connected' });
  }

  const token = jwt.sign(
    { id: user.id, username: user.username, role: user.role, room_id: user.room_id },
    config.jwt.secret,
    { expiresIn: config.jwt.expiresIn }
  );

  res.json({
    token,
    user: {
      id: user.id,
      username: user.username,
      display_name: user.display_name,
      role: user.role,
      room_id: user.room_id,
      color: user.color,
    },
  });
});

// JWT authentication middleware
function authMiddleware(req, res, next) {
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Token requerido' });
  }

  try {
    const token = authHeader.split(' ')[1];
    req.user = jwt.verify(token, config.jwt.secret);
    next();
  } catch (err) {
    return res.status(401).json({ error: 'Token inválido' });
  }
}

// Admin-only middleware
function adminMiddleware(req, res, next) {
  if (req.user.role !== 'admin') {
    return res.status(403).json({ error: 'Acceso de administrador requerido' });
  }
  next();
}

module.exports = router;
module.exports.authMiddleware = authMiddleware;
module.exports.adminMiddleware = adminMiddleware;
