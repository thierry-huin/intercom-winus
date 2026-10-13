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
const BLOCK_MS = 5 * 60 * 1000;     // 5 minutes block

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

// GET /api/auth/companies — public list for login company picker
router.get('/companies', (req, res) => {
  const rows = db.prepare(
    `SELECT id, name, slug, logo_url
       FROM companies
      WHERE active = 1
      ORDER BY name COLLATE NOCASE`
  ).all();
  res.json(rows);
});

function _resolveCompanyId(body) {
  if (!body) return null;
  if (body.company_id !== undefined && body.company_id !== null && body.company_id !== '') {
    const n = parseInt(body.company_id, 10);
    return Number.isFinite(n) ? n : null;
  }
  const key = (body.company || body.company_slug || body.company_name || '').toString().trim();
  if (!key) return null;
  const bySlug = db.prepare(
    'SELECT id FROM companies WHERE lower(slug) = lower(?) OR lower(name) = lower(?)'
  ).get(key, key);
  return bySlug ? bySlug.id : null;
}

// POST /api/auth/login
// Usernames are unique per company. Same login name may exist in several
// companies; pass company_id / company (slug or name) to disambiguate.
// If ambiguous and no company given → 409 with { companies: [...] }.
router.post('/login', (req, res) => {
  const { username, password } = req.body;
  const ip = getRealIp(req);

  if (!username || !password) {
    return res.status(400).json({ error: 'Usuario y contraseña requeridos' });
  }

  const uname = String(username).trim();
  const companyIdHint = _resolveCompanyId(req.body);

  // Superadmin always bypasses rate limiting so recovery access is never locked out.
  const anySuper = db.prepare(
    "SELECT id FROM users WHERE username = ? AND role = 'superadmin' LIMIT 1"
  ).get(uname);
  const isSuperadminLogin = !!anySuper;

  if (!isSuperadminLogin) {
    const limit = checkRateLimit(ip);
    if (!limit.allowed) {
      return res.status(429).json({ error: `Too many attempts. Try again in ${limit.remainMin} min` });
    }
  }

  let candidates;
  if (companyIdHint != null) {
    candidates = db.prepare(
      'SELECT * FROM users WHERE username = ? AND company_id = ?'
    ).all(uname, companyIdHint);
    // Superadmin has company_id NULL — also try global superadmin match.
    if (candidates.length === 0) {
      const sa = db.prepare(
        "SELECT * FROM users WHERE username = ? AND role = 'superadmin'"
      ).get(uname);
      if (sa) candidates = [sa];
    }
  } else {
    candidates = db.prepare('SELECT * FROM users WHERE username = ?').all(uname);
  }

  if (candidates.length === 0) {
    recordFailedAttempt(ip);
    return res.status(401).json({ error: 'Credenciales inválidas' });
  }

  // Password filter first (don't leak which companies share the username).
  const matched = candidates.filter((u) => bcrypt.compareSync(password, u.password_hash));
  if (matched.length === 0) {
    recordFailedAttempt(ip);
    return res.status(401).json({ error: 'Credenciales inválidas' });
  }

  if (matched.length > 1) {
    // Ambiguous username across companies — client must pick one.
    const cos = matched.map((u) => {
      const co = u.company_id
        ? db.prepare('SELECT id, name, slug, logo_url FROM companies WHERE id = ?').get(u.company_id)
        : null;
      return {
        company_id: u.company_id,
        company_name: co ? co.name : (u.role === 'superadmin' ? 'System' : null),
        company_slug: co ? co.slug : null,
        logo_url: co ? co.logo_url : null,
        display_name: u.display_name,
      };
    });
    return res.status(409).json({
      error: 'Usuario existe en varias empresas. Elige la empresa.',
      code: 'COMPANY_REQUIRED',
      companies: cos,
    });
  }

  const user = matched[0];

  // Success: clear attempts
  clearAttempts(ip);

  // Bridge users can only authenticate from the bridge application
  if (user.role === 'bridge' && req.body.client_type !== 'bridge') {
    return res.status(403).json({ error: 'Este usuario es exclusivo para bridge' });
  }

  // Session lock: reject if user is already connected
  if (user.role !== 'admin' && user.role !== 'superuser' && user.role !== 'superadmin' && user.role !== 'bridge' && user.role !== 'streamdeck' && getOnlineUserIds().includes(user.id)) {
    return res.status(409).json({ error: 'User already connected' });
  }

  let companyName = null;
  if (user.company_id) {
    const co = db.prepare('SELECT name FROM companies WHERE id = ?').get(user.company_id);
    companyName = co ? co.name : null;
  }

  const token = jwt.sign(
    {
      id: user.id,
      username: user.username,
      role: user.role,
      room_id: user.room_id,
      company_id: user.company_id ?? null,
    },
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
      company_id: user.company_id ?? null,
      company_name: companyName,
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

// Admin-only middleware (admin + superuser + superadmin)
function adminMiddleware(req, res, next) {
  const role = req.user.role;
  if (role !== 'admin' && role !== 'superuser' && role !== 'superadmin') {
    return res.status(403).json({ error: 'Acceso de administrador requerido' });
  }
  next();
}

// Superadmin-only middleware (only the hidden Winus backdoor passes).
// Used to gate username rename and numeric id change endpoints.
function superadminMiddleware(req, res, next) {
  if (req.user.role !== 'superadmin') {
    return res.status(403).json({ error: 'Acceso de superadmin requerido' });
  }
  next();
}

module.exports = router;
module.exports.authMiddleware = authMiddleware;
module.exports.adminMiddleware = adminMiddleware;
module.exports.superadminMiddleware = superadminMiddleware;
