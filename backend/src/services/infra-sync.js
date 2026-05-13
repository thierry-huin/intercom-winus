'use strict';
/**
 * Infra-sync — propagate admin-panel IP changes to .env, the self-signed
 * TLS cert and the actual coturn / nginx containers.
 *
 * The admin panel only persists `announced_ips`, `turn_host` and
 * `public_domain` to the `server_config` table. mediasoup picks them up
 * live from there (see ws/signaling.js), but coturn reads
 * `EXTERNAL_IP` / `LOCAL_IP` from the docker-compose `.env` at
 * container-create time and nginx serves a self-signed cert generated
 * during install. This module bridges those gaps:
 *
 *   - writeEnv()           → atomic rewrite of selected keys in /app/.env
 *   - regenerateCerts()    → openssl req -x509 with the new SAN list
 *   - recreateContainers() → `docker compose up -d <name...>` so the new
 *                            env / cert is picked up.
 *
 * All operations are best-effort: if `docker.sock` or `openssl` aren't
 * available (older install without the new mounts), the function logs
 * the issue and returns a structured `{ok:false, reason}` so callers
 * can surface it without aborting the whole request.
 */

const fs = require('fs');
const fsp = fs.promises;
const path = require('path');
const dns = require('dns').promises;
const { spawn } = require('child_process');

const ENV_PATH = process.env.INTERCOM_ENV_FILE || '/app/.env';
const COMPOSE_FILE =
  process.env.INTERCOM_COMPOSE_FILE || '/app/docker-compose.yml';
const CERTS_DIR =
  process.env.INTERCOM_CERTS_DIR || '/app/nginx/certs';

const IPV4_RE = /^\d{1,3}(\.\d{1,3}){3}$/;

function log(...args) {
  console.log('[infra-sync]', ...args);
}
function warn(...args) {
  console.warn('[infra-sync]', ...args);
}

/**
 * Resolve a hostname to its first A record. IPs are returned untouched.
 * Coturn refuses hostnames in --external-ip, so for the .env rewrite we
 * always want a literal IPv4 address.
 */
async function resolveHostToIp(hostOrIp) {
  if (!hostOrIp) return '';
  const trimmed = String(hostOrIp).trim();
  if (!trimmed) return '';
  if (IPV4_RE.test(trimmed)) return trimmed;
  try {
    const addrs = await dns.resolve4(trimmed);
    if (addrs && addrs.length > 0) {
      log(`resolved ${trimmed} → ${addrs[0]}`);
      return addrs[0];
    }
  } catch (e) {
    warn(`could not resolve ${trimmed}: ${e.message}`);
  }
  // Fall back to the original — coturn will fail loudly, which is the
  // correct behaviour: misconfigured DNS shouldn't be silently masked.
  return trimmed;
}

/**
 * Try to spot a private (RFC1918) IPv4 in a CSV announced_ips list.
 * Returns the LAST one seen (announce order is usually public-first,
 * private-last). Falls back to null when nothing matches.
 */
function pickPrivateIp(announcedCsv) {
  if (!announcedCsv) return null;
  const isPrivate = (ip) =>
    /^10\./.test(ip) ||
    /^192\.168\./.test(ip) ||
    /^172\.(1[6-9]|2\d|3[01])\./.test(ip);
  const parts = String(announcedCsv)
    .split(',')
    .map((s) => s.trim())
    .filter((s) => IPV4_RE.test(s));
  for (let i = parts.length - 1; i >= 0; i--) {
    if (isPrivate(parts[i])) return parts[i];
  }
  return null;
}

/**
 * Atomically rewrite the selected keys in /app/.env, preserving the
 * rest of the file. Missing keys are appended. Empty values are still
 * written (caller is responsible for not passing junk).
 */
async function writeEnv(updates) {
  let original = '';
  try {
    original = await fsp.readFile(ENV_PATH, 'utf8');
  } catch (e) {
    if (e.code !== 'ENOENT') throw e;
    warn(`${ENV_PATH} not found; creating it`);
  }

  const lines = original.length ? original.split('\n') : [];
  const seen = new Set();
  for (let i = 0; i < lines.length; i++) {
    for (const key of Object.keys(updates)) {
      const re = new RegExp(`^${key}=.*$`);
      if (re.test(lines[i])) {
        lines[i] = `${key}=${updates[key]}`;
        seen.add(key);
        break;
      }
    }
  }
  // Append any keys we never saw.
  for (const key of Object.keys(updates)) {
    if (!seen.has(key)) lines.push(`${key}=${updates[key]}`);
  }
  // Trim trailing empty lines and re-add exactly one.
  while (lines.length > 0 && lines[lines.length - 1] === '') lines.pop();
  const final = lines.join('\n') + '\n';

  const tmp = ENV_PATH + '.tmp';
  await fsp.writeFile(tmp, final, { mode: 0o644 });
  await fsp.rename(tmp, ENV_PATH);
  log(`updated ${Object.keys(updates).join(',')} in ${ENV_PATH}`);
  return { ok: true, path: ENV_PATH, keys: Object.keys(updates) };
}

/**
 * Read the current cert's SAN list (best-effort) so we can short-circuit
 * regen when nothing actually changed.
 */
async function readCurrentSan() {
  const certPath = path.join(CERTS_DIR, 'cert.pem');
  return new Promise((resolve) => {
    const p = spawn('openssl', [
      'x509',
      '-in', certPath,
      '-noout',
      '-ext', 'subjectAltName',
    ]);
    let out = '';
    p.stdout.on('data', (b) => (out += b.toString()));
    p.on('error', () => resolve(''));
    p.on('close', () => resolve(out.trim()));
  });
}

/**
 * Regenerate cert.pem + key.pem with the supplied SAN list. Skips the
 * call when the existing cert already covers the same names/IPs.
 */
async function regenerateCerts({ externalIp, localIp, publicDomain }) {
  if (!externalIp && !localIp && !publicDomain) {
    return { ok: false, reason: 'no inputs' };
  }
  const sanParts = [];
  if (localIp) sanParts.push(`IP:${localIp}`);
  sanParts.push('IP:127.0.0.1');
  if (externalIp && externalIp !== localIp) {
    sanParts.push(IPV4_RE.test(externalIp)
      ? `IP:${externalIp}`
      : `DNS:${externalIp}`);
  }
  if (publicDomain && publicDomain !== externalIp) {
    sanParts.push(`DNS:${publicDomain}`);
  }
  const wantedSan = sanParts.join(',');

  const currentSan = await readCurrentSan();
  // currentSan looks like: "X509v3 Subject Alternative Name:\n    IP Address:..., DNS:..."
  // We just check that every wanted entry shows up textually.
  const allCovered = wantedSan
    .split(',')
    .every((s) => currentSan.replace(/\s+/g, '').includes(s.replace(/\s+/g, '')));
  if (allCovered && currentSan) {
    log('cert SAN already covers requested names; skipping regen');
    return { ok: true, skipped: true };
  }

  await fsp.mkdir(CERTS_DIR, { recursive: true });
  const certPath = path.join(CERTS_DIR, 'cert.pem');
  const keyPath = path.join(CERTS_DIR, 'key.pem');

  const subjCN = publicDomain || externalIp || localIp || 'Winus Intercom';
  const args = [
    'req', '-x509',
    '-newkey', 'rsa:2048',
    '-keyout', keyPath,
    '-out', certPath,
    '-days', '3650',
    '-nodes',
    '-subj', `/CN=${subjCN}`,
    '-addext', `subjectAltName=${wantedSan}`,
  ];
  return new Promise((resolve) => {
    const p = spawn('openssl', args);
    let stderr = '';
    p.stderr.on('data', (b) => (stderr += b.toString()));
    p.on('error', (e) => {
      warn(`openssl spawn failed: ${e.message}`);
      resolve({ ok: false, reason: e.message });
    });
    p.on('close', (code) => {
      if (code === 0) {
        log(`regenerated certs (SAN=${wantedSan})`);
        resolve({ ok: true, san: wantedSan });
      } else {
        warn(`openssl exited ${code}: ${stderr.trim()}`);
        resolve({ ok: false, reason: `openssl rc=${code}` });
      }
    });
  });
}

/**
 * `docker compose -f /app/docker-compose.yml up -d <names...>` from
 * /app. Recreate (not just restart) so .env interpolation runs again.
 */
function recreateContainers(names) {
  if (!Array.isArray(names) || names.length === 0) {
    return Promise.resolve({ ok: true, skipped: true });
  }
  return new Promise((resolve) => {
    const args = ['compose', '-f', COMPOSE_FILE, 'up', '-d', ...names];
    log(`docker ${args.join(' ')}`);
    const p = spawn('docker', args, { cwd: '/app' });
    let stderr = '';
    let stdout = '';
    p.stdout.on('data', (b) => (stdout += b.toString()));
    p.stderr.on('data', (b) => (stderr += b.toString()));
    p.on('error', (e) => {
      // ENOENT from docker = old install without docker-cli; ENOENT
      // from /var/run/docker.sock = compose file present but socket
      // not mounted. Either way, surface a clean message.
      warn(`docker spawn failed: ${e.message}`);
      resolve({
        ok: false,
        reason:
          e.code === 'ENOENT'
            ? 'docker CLI not available in container (rebuild backend image and remount /var/run/docker.sock)'
            : e.message,
      });
    });
    p.on('close', (code) => {
      const tail = (stderr || stdout).trim().split('\n').slice(-3).join(' | ');
      if (code === 0) {
        log(`recreated ${names.join(',')} ok`);
        resolve({ ok: true, names, tail });
      } else {
        warn(`docker compose up rc=${code}: ${tail}`);
        resolve({ ok: false, reason: `docker rc=${code}: ${tail}` });
      }
    });
  });
}

module.exports = {
  resolveHostToIp,
  pickPrivateIp,
  writeEnv,
  regenerateCerts,
  recreateContainers,
};
