const { db } = require('../database');
const dns = require('dns').promises;

/**
 * Get a config value from DB, falling back to env var, then to defaultValue.
 */
function getConfig(key, defaultValue = '') {
  const row = db.prepare('SELECT value FROM server_config WHERE key = ?').get(key);
  if (row) return row.value;
  // Env var fallback: e.g. 'announced_ips' -> ANNOUNCED_IPS
  const envKey = key.toUpperCase();
  if (process.env[envKey]) return process.env[envKey];
  return defaultValue;
}

/**
 * Set a config value in DB.
 */
function setConfig(key, value) {
  db.prepare('INSERT OR REPLACE INTO server_config (key, value) VALUES (?, ?)').run(key, value);
}

/**
 * Get all config values as a plain object.
 */
function getAllConfig() {
  const rows = db.prepare('SELECT key, value FROM server_config').all();
  const result = {};
  for (const row of rows) result[row.key] = row.value;
  return result;
}

/**
 * Get announced IPs as an array (split by comma, trimmed, non-empty).
 */
function getAnnouncedIps() {
  const raw = getConfig('announced_ips', process.env.MEDIASOUP_ANNOUNCED_IPS || '');
  return raw.split(',').map(s => s.trim()).filter(Boolean);
}

/**
 * Resolve announced IPs/hostnames to IP addresses.
 * Hostnames (e.g. huin.tv) are resolved via DNS so the current IP is always used.
 */
async function resolveAnnouncedIps() {
  const entries = getAnnouncedIps();
  const resolved = [];
  for (const entry of entries) {
    if (/^[\d.]+$/.test(entry)) {
      resolved.push(entry); // Already an IP
    } else {
      try {
        const addrs = await dns.resolve4(entry);
        if (addrs.length > 0) {
          resolved.push(addrs[0]);
          console.log(`[config] Resolved ${entry} → ${addrs[0]}`);
        }
      } catch (e) {
        console.warn(`[config] Could not resolve ${entry}: ${e.message}`);
      }
    }
  }
  return resolved;
}

module.exports = { getConfig, setConfig, getAllConfig, getAnnouncedIps, resolveAnnouncedIps };
