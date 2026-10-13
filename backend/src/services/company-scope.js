const { db } = require('../database');

const WINUS_ID = 99999;

function isSuperadmin(user) {
  return user && user.role === 'superadmin';
}

/** Load company_id + role from DB (do not trust JWT alone). */
function loadUserRow(userId) {
  return db.prepare('SELECT id, role, company_id FROM users WHERE id = ?').get(userId);
}

/**
 * Resolve effective company scope for an admin request.
 * - Non-superadmin: always their own company_id (from DB).
 * - Superadmin: optional requested company_id (query/header/body); null = all companies.
 * Returns { companyId: number|null, isGlobal: boolean, caller }.
 */
function resolveCompanyScope(reqUser, requestedCompanyId) {
  const caller = loadUserRow(reqUser.id);
  if (!caller) {
    const err = new Error('Usuario no encontrado');
    err.status = 401;
    throw err;
  }

  if (isSuperadmin(caller)) {
    let companyId = null;
    if (requestedCompanyId !== undefined && requestedCompanyId !== null && requestedCompanyId !== '') {
      const n = parseInt(requestedCompanyId, 10);
      if (!Number.isFinite(n)) {
        const err = new Error('company_id inválido');
        err.status = 400;
        throw err;
      }
      const co = db.prepare('SELECT id FROM companies WHERE id = ?').get(n);
      if (!co) {
        const err = new Error('Empresa no encontrada');
        err.status = 404;
        throw err;
      }
      companyId = n;
    }
    return { companyId, isGlobal: companyId === null, caller };
  }

  if (caller.company_id == null) {
    const err = new Error('Usuario sin empresa asignada');
    err.status = 403;
    throw err;
  }
  return { companyId: caller.company_id, isGlobal: false, caller };
}

/** Read requested company id from query, header X-Company-Id, or body.company_id. */
function requestedCompanyFromReq(req) {
  if (req.query && req.query.company_id !== undefined) return req.query.company_id;
  if (req.headers && req.headers['x-company-id'] !== undefined) return req.headers['x-company-id'];
  if (req.body && req.body.company_id !== undefined) return req.body.company_id;
  return undefined;
}

/**
 * Express middleware: attaches req.companyScope = { companyId, isGlobal, caller }.
 * Superadmin without filter → companyId null (all).
 */
function companyScopeMiddleware(req, res, next) {
  try {
    req.companyScope = resolveCompanyScope(req.user, requestedCompanyFromReq(req));
    next();
  } catch (err) {
    res.status(err.status || 500).json({ error: err.message });
  }
}

/** Require a concrete company (superadmin must pass company_id on create ops). */
function requireConcreteCompany(scope, { allowBodyCompany = true } = {}) {
  if (scope.companyId != null) return scope.companyId;
  if (scope.isGlobal) {
    const err = new Error('company_id requerido');
    err.status = 400;
    throw err;
  }
  return scope.companyId;
}

function assertUserInScope(userId, scope) {
  const u = db.prepare('SELECT id, company_id, role FROM users WHERE id = ?').get(userId);
  if (!u) {
    const err = new Error('Usuario no encontrado');
    err.status = 404;
    throw err;
  }
  // Superadmin Winus is never "in" a company scope for mutations targeting others.
  if (u.id === WINUS_ID || u.role === 'superadmin') {
    if (!isSuperadmin(scope.caller)) {
      const err = new Error('No autorizado');
      err.status = 403;
      throw err;
    }
    return u;
  }
  if (!scope.isGlobal && u.company_id !== scope.companyId) {
    const err = new Error('Usuario fuera de la empresa');
    err.status = 403;
    throw err;
  }
  return u;
}

function assertGroupInScope(groupId, scope) {
  const g = db.prepare('SELECT id, company_id, name FROM groups WHERE id = ?').get(groupId);
  if (!g) {
    const err = new Error('Grupo no encontrado');
    err.status = 404;
    throw err;
  }
  if (!scope.isGlobal && g.company_id !== scope.companyId) {
    const err = new Error('Grupo fuera de la empresa');
    err.status = 403;
    throw err;
  }
  return g;
}

function sameCompany(userIdA, userIdB) {
  const a = db.prepare('SELECT company_id, role FROM users WHERE id = ?').get(userIdA);
  const b = db.prepare('SELECT company_id, role FROM users WHERE id = ?').get(userIdB);
  if (!a || !b) return false;
  // Superadmin is global — treat as same-company only for its own override paths.
  if (a.role === 'superadmin' || b.role === 'superadmin') return true;
  if (a.company_id == null || b.company_id == null) return false;
  return a.company_id === b.company_id;
}

function userCompanyId(userId) {
  const u = db.prepare('SELECT company_id FROM users WHERE id = ?').get(userId);
  return u ? u.company_id : null;
}

module.exports = {
  WINUS_ID,
  isSuperadmin,
  loadUserRow,
  resolveCompanyScope,
  requestedCompanyFromReq,
  companyScopeMiddleware,
  requireConcreteCompany,
  assertUserInScope,
  assertGroupInScope,
  sameCompany,
  userCompanyId,
};
