const apn = require('@parse/node-apn');
const path = require('path');
const { db } = require('../database');

let apnProvider = null;

function init() {
  const keyPath = process.env.APNS_KEY_PATH || path.join(__dirname, '..', '..', 'certs', 'AuthKey_86NJQR85N5.p8');
  const keyId = process.env.APNS_KEY_ID || '86NJQR85N5';
  const teamId = process.env.APNS_TEAM_ID || '4BT4GR6WJT';
  const production = process.env.APNS_PRODUCTION === 'true';

  try {
    const fs = require('fs');
    if (!fs.existsSync(keyPath)) {
      console.warn('[Push] APNs key not found at', keyPath, '— push notifications disabled');
      return;
    }

    apnProvider = new apn.Provider({
      token: {
        key: keyPath,
        keyId,
        teamId,
      },
      production,
    });
    console.log(`[Push] APNs initialized (${production ? 'production' : 'sandbox'}, keyId=${keyId})`);
  } catch (e) {
    console.warn('[Push] APNs init failed:', e.message);
  }
}

/**
 * Register a device token for a user.
 */
function registerToken(userId, token, platform = 'ios') {
  // Remove any existing registration for this token (could be from another user)
  db.prepare('DELETE FROM device_tokens WHERE token = ?').run(token);
  // Insert or replace for this user
  db.prepare(
    'INSERT OR REPLACE INTO device_tokens (user_id, token, platform) VALUES (?, ?, ?)'
  ).run(userId, token, platform);
  console.log(`[Push] Token registered for user=${userId} platform=${platform}`);
}

/**
 * Remove a device token.
 */
function unregisterToken(token) {
  db.prepare('DELETE FROM device_tokens WHERE token = ?').run(token);
}

/**
 * Send a VoIP push to wake up an iOS app.
 * Called when a user's WS disconnects to trigger reconnection.
 */
async function sendVoipPush(userId) {
  if (!apnProvider) return;

  const tokens = db.prepare(
    'SELECT token FROM device_tokens WHERE user_id = ? AND platform = ?'
  ).all(userId, 'ios');

  if (tokens.length === 0) return;

  const bundleId = process.env.APNS_BUNDLE_ID || 'tv.huin.intercom.intercomApp';

  for (const { token } of tokens) {
    try {
      const notification = new apn.Notification();
      notification.topic = `${bundleId}.voip`;
      notification.pushType = 'voip';
      notification.priority = 10; // Immediate
      notification.expiry = Math.floor(Date.now() / 1000) + 30; // 30s TTL
      notification.payload = {
        type: 'reconnect',
        userId,
        timestamp: Date.now(),
      };

      const result = await apnProvider.send(notification, token);
      if (result.failed.length > 0) {
        const failure = result.failed[0];
        console.warn(`[Push] VoIP push failed for user=${userId}: ${failure.response?.reason || 'unknown'}`);
        // Remove invalid tokens
        if (failure.response?.reason === 'BadDeviceToken' || failure.response?.reason === 'Unregistered') {
          db.prepare('DELETE FROM device_tokens WHERE token = ?').run(token);
          console.log(`[Push] Removed invalid token for user=${userId}`);
        }
      } else {
        console.log(`[Push] VoIP push sent to user=${userId}`);
      }
    } catch (e) {
      console.warn(`[Push] VoIP push error for user=${userId}:`, e.message);
    }
  }
}

module.exports = { init, registerToken, unregisterToken, sendVoipPush };
