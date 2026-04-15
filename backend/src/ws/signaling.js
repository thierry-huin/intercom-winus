const jwt = require('jsonwebtoken');
const config = require('../config');
const { canUserTalkToUser, canUserTalkToGroup } = require('../services/permissions');
const { db } = require('../database');
const ms = require('../services/mediasoup-manager');
const { getConfig, resolveAnnouncedIps } = require('../services/config-service');
const { sendVoipPush } = require('../services/push-service');

const clients = new Map(); // userId -> ws

// Track active PTT sessions: sourceUserId -> Map<targetKey, { targetType, targetId, targetUserIds }>
const activePtt = new Map();

// Kicked users: userId -> expiry timestamp. Rejects auth during this window.
const kickedUsers = new Map();

function setupSignaling(wss) {
  // Notify clients when their transport dies so they can re-init media
  ms.setOnTransportClose((uid, direction) => {
    console.warn(`[Signaling] Transport closed for user=${uid} direction=${direction}, notifying client`);
    sendToUser(uid, { type: 'transportClosed', direction });
  });

  // WebSocket keepalive: ping all clients every 30s, close dead connections
  const pingInterval = setInterval(() => {
    for (const [uid, ws] of clients.entries()) {
      if (ws.readyState !== 1) { clients.delete(uid); continue; }
      if (ws._dead) {
        console.warn(`[Signaling] Closing dead connection for user=${uid}`);
        ws.close();
        continue;
      }
      ws._dead = true;
      ws.ping();
    }
    // Sweep stale PTT sessions: remove entries whose source is no longer connected
    for (const [sourceId, sessions] of activePtt.entries()) {
      if (!clients.has(sourceId)) {
        console.warn(`[Signaling] Sweeping orphan PTT for disconnected user=${sourceId} (${sessions.size} sessions)`);
        // Notify targets that audio stopped
        const allTargets = new Set();
        for (const session of sessions.values()) {
          for (const tid of session.targetUserIds) allTargets.add(tid);
        }
        for (const tid of allTargets) {
          sendToUser(tid, { type: 'incoming_audio', fromUserId: sourceId, talking: false });
        }
        // Clean up mediasoup state if peer still exists
        ms.cleanupPeer(sourceId);
        activePtt.delete(sourceId);
      }
    }
  }, 30000);
  wss.on('close', () => clearInterval(pingInterval));

  wss.on('connection', (ws) => {
    let userId = null;
    ws.on('pong', () => { ws._dead = false; });

    // Message queue to serialize async processing per connection.
    // Without this, rapid ptt_stop + ptt_start can interleave and
    // cause consumersClosed to arrive AFTER the new newConsumer.
    let messageQueue = Promise.resolve();

    ws.on('message', (data) => {
      let msg;
      try {
        msg = JSON.parse(data);
      } catch {
        return;
      }

      // All messages except 'auth' require authentication
      if (msg.type !== 'auth' && !userId) {
        return send(ws, { type: 'error', error: 'Not authenticated' });
      }

      // Chain onto the queue so messages are processed one at a time
      messageQueue = messageQueue.then(async () => {
        try {
          await handleMessage(ws, msg, () => userId, (id) => { userId = id; });
        } catch (err) {
          console.error(`WS error (user=${userId}, type=${msg.type}):`, err.message);
          send(ws, { type: 'error', requestId: msg.requestId, error: err.message });
        }
      });
    });

    ws.on('close', async () => {
      if (userId) {
        const currentWs = clients.get(userId);
        const isStale = currentWs !== ws;
        console.log(`[Signaling] WS close for user=${userId}: stale=${isStale}, hasCurrentWs=${!!currentWs}`);

        // Always clean up PTT sessions, even for stale connections.
        // A stale WS means the user reconnected, but if the old connection
        // had active PTT that wasn't cleaned up during re-auth, we must do it now.
        const userPtt = activePtt.get(userId);
        if (userPtt && userPtt.size > 0) {
          console.log(`[Signaling] Cleaning ${userPtt.size} PTT sessions for user=${userId} (stale=${isStale})`);
          const allTargetUserIds = new Set();
          for (const session of userPtt.values()) {
            for (const tid of session.targetUserIds) allTargetUserIds.add(tid);
          }
          // Only call pttStop on mediasoup if this is the current (non-stale) connection.
          // For stale connections, the new connection already has fresh transports.
          if (!isStale) {
            await ms.pttStop(userId, [...allTargetUserIds], true).catch((e) => {
              console.warn(`[Signaling] pttStop error for user=${userId}: ${e.message}`);
            });
          }
          for (const tid of allTargetUserIds) {
            sendToUser(tid, { type: 'consumersClosed', peerId: userId });
            sendToUser(tid, { type: 'incoming_audio', fromUserId: userId, talking: false });
          }
          activePtt.delete(userId);
        }

        if (isStale) {
          console.log(`[Signaling] Stale WS closed for user=${userId}, skipping peer cleanup (already reconnected)`);
          return;
        }

        ms.cleanupPeer(userId);
        clients.delete(userId);
        // Delayed broadcast so reconnecting users have time to re-auth before the
        // "offline" broadcast reaches other clients
        setTimeout(() => broadcastOnlineUsers(), 3000);
        // Send VoIP push to wake iOS app for reconnection
        setTimeout(() => sendVoipPush(userId), 2000);
      }
    });
  });
}

async function handleMessage(ws, msg, getUserId, setUserId) {
  const userId = getUserId();


  switch (msg.type) {
    // ---- Auth ----
    case 'auth': {
      const decoded = jwt.verify(msg.token, config.jwt.secret);

      // Block re-auth if user was recently kicked
      const kickExpiry = kickedUsers.get(decoded.id);
      if (kickExpiry && Date.now() < kickExpiry) {
        send(ws, { type: 'kicked', reason: 'Disconnected by admin' });
        setTimeout(() => { try { ws.close(); } catch (_) {} }, 200);
        return;
      }
      kickedUsers.delete(decoded.id);

      setUserId(decoded.id);

      // If there's an existing WS for this user, clean up old state first.
      // Without this, stale DTLS timeouts on old transports can disrupt
      // the new connection by triggering transportClosed events later.
      const oldWs = clients.get(decoded.id);
      if (oldWs && oldWs !== ws) {
        console.log(`[Signaling] User ${decoded.id} reconnected, cleaning up stale state`);

        // Stop active PTT sessions from this user and notify targets
        const userPtt = activePtt.get(decoded.id);
        if (userPtt) {
          const allTargetUserIds = new Set();
          for (const session of userPtt.values()) {
            for (const tid of session.targetUserIds) allTargetUserIds.add(tid);
          }
          await ms.pttStop(decoded.id, [...allTargetUserIds], false);
          for (const tid of allTargetUserIds) {
            sendToUser(tid, { type: 'consumersClosed', peerId: decoded.id });
            sendToUser(tid, { type: 'incoming_audio', fromUserId: decoded.id, talking: false });
          }
          activePtt.delete(decoded.id);
        }

        // Destroy old mediasoup state (transports, producer, consumers)
        ms.cleanupPeer(decoded.id);
        try { oldWs.close(); } catch (_) {}
      }

      clients.set(decoded.id, ws);
      send(ws, { type: 'auth_ok', userId: decoded.id });
      broadcastOnlineUsers();
      // Delayed re-broadcast to ensure it arrives after any stale WS cleanup
      setTimeout(() => broadcastOnlineUsers(), 2000);
      break;
    }

    // ---- mediasoup: Router capabilities ----
    case 'getRouterRtpCapabilities': {
      send(ws, {
        type: 'routerRtpCapabilities',
        requestId: msg.requestId,
        rtpCapabilities: ms.getRouterRtpCapabilities(),
      });
      break;
    }

    // ---- mediasoup: Store client RTP capabilities ----
    case 'setRtpCapabilities': {
      ms.setPeerRtpCapabilities(userId, msg.rtpCapabilities);
      send(ws, { type: 'ok', requestId: msg.requestId });
      // Restore any active consumers now that capabilities are known
      await restoreActiveConsumers(userId);
      // Re-broadcast if this user just became media-ready
      if (ms.isPeerReady(userId)) broadcastOnlineUsers();
      break;
    }

    // ---- mediasoup: Create transport ----
    case 'createWebRtcTransport': {
      const params = await ms.createWebRtcTransport(userId, msg.direction);
    // Build ICE servers from persisted config (updated live via admin panel)
      const iceServers = [];
      const turnPort = getConfig('turn_port', process.env.TURN_PORT || '3478');
      const turnHostRaw = getConfig('turn_host', '');
      const announcedIps = await resolveAnnouncedIps();
      // Resolve turn_host if it's a hostname
      let turnHosts;
      if (turnHostRaw) {
        const isIp = /^[\d.]+$/.test(turnHostRaw);
        if (isIp) {
          turnHosts = [turnHostRaw];
        } else {
          try {
            const { promises: dnsP } = require('dns');
            const addrs = await dnsP.resolve4(turnHostRaw);
            turnHosts = [addrs[0]];
          } catch { turnHosts = [turnHostRaw]; }
        }
      } else {
        turnHosts = announcedIps;
      }
      if (turnHosts.length > 0) {
        const stunUrls = turnHosts.map(ip => `stun:${ip}:${turnPort}`);
        const turnUrls = turnHosts.flatMap(ip => [
          `turn:${ip}:${turnPort}?transport=udp`,
          `turn:${ip}:${turnPort}?transport=tcp`,
        ]);
        iceServers.push({ urls: stunUrls });
        iceServers.push({
          urls: turnUrls,
          username: getConfig('turn_user', process.env.TURN_USER || 'intercom'),
          credential: getConfig('turn_password', process.env.TURN_PASSWORD || 'intercom2024'),
        });
      }
      send(ws, {
        type: 'transportCreated',
        requestId: msg.requestId,
        ...params,
        iceServers,
      });
      break;
    }

    // ---- mediasoup: Connect transport ----
    case 'connectTransport': {
      await ms.connectTransport(userId, msg.transportId, msg.dtlsParameters);
      send(ws, { type: 'ok', requestId: msg.requestId });
      break;
    }

    // ---- mediasoup: Produce ----
    case 'produce': {
      const result = await ms.produce(userId, msg.transportId, msg.kind, msg.rtpParameters);
      send(ws, {
        type: 'produced',
        requestId: msg.requestId,
        id: result.id,
      });
      // After producing, restore consumers for any active PTT sessions
      // targeting this user (e.g. user reconnected while bridge was talking)
      await restoreActiveConsumers(userId);
      // Re-broadcast if this user just became media-ready
      if (ms.isPeerReady(userId)) broadcastOnlineUsers();
      break;
    }

    // ---- mediasoup: PlainTransport (tie-line bridge) ----
    case 'createPlainTransport': {
      const ptParams = await ms.createPlainTransport(userId, msg.direction);
      send(ws, {
        type: 'plainTransportCreated',
        requestId: msg.requestId,
        ...ptParams,
      });
      break;
    }

    case 'connectPlainTransport': {
      await ms.connectPlainTransport(userId, msg.transportId, msg.ip, msg.port);
      send(ws, { type: 'ok', requestId: msg.requestId });
      // For PlainTransport (bridge): recv transport is created after produce,
      // so restore consumers here when it's the recv transport
      const ptPeer = ms.getPeer(userId);
      if (ptPeer?.recvTransport?.id === msg.transportId) {
        await restoreActiveConsumers(userId);
        // Bridge setup complete — broadcast so clients see bridge as online
        broadcastOnlineUsers();
      }
      break;
    }

    // ---- mediasoup: Resume consumer ----
    case 'resumeConsumer': {
      await ms.resumeConsumer(userId, msg.consumerId);
      send(ws, { type: 'ok', requestId: msg.requestId });
      break;
    }

    // ---- Ping (for latency measurement) ----
    case 'ping': {
      send(ws, { type: 'pong', requestId: msg.requestId });
      break;
    }

    // ---- PTT start ----
    case 'ptt_start': {
      const { targetType, targetId } = msg;
      const targetUserIds = resolveTargetUserIds(userId, targetType, targetId);

      if (targetUserIds.length === 0) {
        console.log(`ptt_start: user=${userId} -> ${targetType}:${targetId} DENIED (no targets/permission)`);
        send(ws, { type: 'ptt_denied', targetType, targetId });
        break;
      }

      // Get or create the active PTT map for this user
      if (!activePtt.has(userId)) activePtt.set(userId, new Map());
      const userPtt = activePtt.get(userId);
      const targetKey = `${targetType}:${targetId}`;

      // Store this PTT session
      userPtt.set(targetKey, { targetType, targetId, targetUserIds });

      // Create consumers on each target (producer resumes automatically)
      const results = await ms.pttStart(userId, targetUserIds);
      console.log(`ptt_start: user=${userId} -> ${targetType}:${targetId}, consumers created: ${results.length}/${targetUserIds.length}`);

      if (results.length === 0) {
        console.log(`ptt_start: user=${userId} -> ${targetType}:${targetId} DENIED (no_consumers)`);
        send(ws, { type: 'ptt_denied', targetType, targetId, reason: 'no_consumers' });
        break;
      }

      // Notify the talker
      send(ws, { type: 'ptt_allowed', targetType, targetId });

      const sourceUser = db.prepare('SELECT display_name FROM users WHERE id = ?').get(userId);
      const consumedTargets = new Set(results.map(r => r.targetUserId));

      for (const { targetUserId, consumerParams } of results) {
        if (consumerParams) {
          sendToUser(targetUserId, { type: 'newConsumer', ...consumerParams });
        }
        sendToUser(targetUserId, {
          type: 'incoming_audio',
          fromUserId: userId,
          fromDisplayName: sourceUser?.display_name || 'Unknown',
          talking: true,
        });
      }
      // For targets where consumer failed (no recv transport yet), retry with backoff
      const failedTargets = targetUserIds.filter(tid => !consumedTargets.has(tid));
      if (failedTargets.length > 0) {
        for (const tid of failedTargets) {
          console.warn(`ptt_start: FAILED to create consumer for user=${tid} (source=${userId}), will retry`);
        }
        const retryDelays = [1000, 2000, 3000];
        for (const delay of retryDelays) {
          setTimeout(async () => {
            const session = activePtt.get(userId)?.get(targetKey);
            if (!session) return; // PTT already stopped
            const sourceUser2 = db.prepare('SELECT display_name FROM users WHERE id = ?').get(userId);
            for (const tid of failedTargets) {
              // Skip if already has an active consumer
              const tPeer = ms.getPeer(tid);
              const sPeer = ms.getPeer(userId);
              if (tPeer && sPeer?.producer) {
                let hasConsumer = false;
                for (const c of tPeer.consumers.values()) {
                  if (c.producerId === sPeer.producer.id && !c.closed) { hasConsumer = true; break; }
                }
                if (hasConsumer) continue;
              }
              try {
                const consumerParams = await ms.consume(userId, tid);
                if (consumerParams) {
                  console.log(`ptt_start: retry@${delay}ms OK consumer for user=${tid} (source=${userId})`);
                  sendToUser(tid, { type: 'newConsumer', ...consumerParams });
                  sendToUser(tid, { type: 'incoming_audio', fromUserId: userId,
                    fromDisplayName: sourceUser2?.display_name || 'Unknown', talking: true });
                }
              } catch (e) {
                console.warn(`ptt_start: retry@${delay}ms failed for user=${tid}: ${e.message}`);
              }
            }
          }, delay);
        }
      }
      break;
    }

    // ---- PTT stop (now per-target) ----
    case 'ptt_stop': {
      const { targetType: stopType, targetId: stopId } = msg;
      const userPtt = activePtt.get(userId);
      if (!userPtt) break;

      const targetKey = `${stopType}:${stopId}`;
      const pttSession = userPtt.get(targetKey);
      if (!pttSession) break;

      // Remove this session
      userPtt.delete(targetKey);
      const stillActive = userPtt.size > 0;
      if (!stillActive) activePtt.delete(userId);

      // Collect targets that are STILL targeted by another active PTT from this user
      const stillTargeted = new Set();
      if (stillActive) {
        for (const otherSession of userPtt.values()) {
          for (const tid of otherSession.targetUserIds) stillTargeted.add(tid);
        }
      }

      // Only pause consumers for targets NOT covered by another active session
      const targetsToStop = pttSession.targetUserIds.filter(tid => !stillTargeted.has(tid));
      const closedByTarget = targetsToStop.length > 0
        ? await ms.pttStop(userId, targetsToStop, !stillActive)
        : new Map();

      // Notify only targets that actually stopped
      for (const tid of targetsToStop) {
        const closedIds = closedByTarget.get(tid) || [];
        if (closedIds.length > 0) {
          sendToUser(tid, { type: 'consumersClosed', peerId: userId, consumerIds: closedIds });
        }
        sendToUser(tid, {
          type: 'incoming_audio',
          fromUserId: userId,
          talking: false,
        });
      }
      break;
    }
  }
}

// ======================== HELPERS ========================

/**
 * When a user reconnects, check if any other user has an active PTT session
 * targeting them and re-create the consumers on the new recv transport.
 */
async function restoreActiveConsumers(userId) {
  const peer = ms.getPeer(userId);
  if (!peer?.recvTransport || !peer?.rtpCapabilities) return;

  for (const [sourceId, sessions] of activePtt.entries()) {
    if (sourceId === userId) continue;
    // Skip if the source user is no longer connected (orphan PTT)
    if (!clients.has(sourceId)) {
      console.warn(`[Signaling] Skipping restore from disconnected source=${sourceId}, cleaning orphan PTT`);
      activePtt.delete(sourceId);
      ms.cleanupPeer(sourceId);
      continue;
    }
    let targets = false;
    for (const session of sessions.values()) {
      if (session.targetUserIds.includes(userId)) { targets = true; break; }
    }
    if (!targets) continue;

    // Close any stale consumers from this source before re-creating
    const sourcePeer = ms.getPeer(sourceId);
    if (sourcePeer?.producer) {
      for (const [cid, c] of peer.consumers) {
        if (c.producerId === sourcePeer.producer.id) {
          c.close();
          peer.consumers.delete(cid);
        }
      }
    }

    const consumerParams = await ms.consume(sourceId, userId);
    if (consumerParams) {
      sendToUser(userId, { type: 'newConsumer', ...consumerParams });
      const srcUser = db.prepare('SELECT display_name FROM users WHERE id = ?').get(sourceId);
      sendToUser(userId, {
        type: 'incoming_audio',
        fromUserId: sourceId,
        fromDisplayName: srcUser?.display_name || 'Unknown',
        talking: true,
      });
      console.log(`[Signaling] Restored consumer: source=${sourceId} -> target=${userId}`);
    }
  }
}

function resolveTargetUserIds(fromUserId, targetType, targetId) {
  if (targetType === 'user') {
    if (canUserTalkToUser(fromUserId, targetId)) {
      return [targetId];
    }
    return [];
  }

  if (targetType === 'group') {
    if (!canUserTalkToGroup(fromUserId, targetId)) return [];
    const members = db.prepare(
      'SELECT user_id FROM group_members WHERE group_id = ?'
    ).all(targetId);

    // Check if source is a bridge
    const fromUser = db.prepare('SELECT role FROM users WHERE id = ?').get(fromUserId);
    const sourceIsBridge = fromUser?.role === 'bridge';

    return members
      .map((m) => m.user_id)
      .filter((uid) => {
        if (uid === fromUserId) return false; // Exclude self
        // Bridges don't send to other bridges (prevents cross-talk loops)
        if (sourceIsBridge) {
          const targetUser = db.prepare('SELECT role FROM users WHERE id = ?').get(uid);
          if (targetUser?.role === 'bridge') return false;
        }
        return true;
      });
  }

  return [];
}

function send(ws, data) {
  if (ws.readyState === 1) {
    ws.send(JSON.stringify(data));
  }
}

function sendToUser(userId, data) {
  const ws = clients.get(userId);
  if (ws) send(ws, data);
}

function broadcastOnlineUsers() {
  // Include all WS-connected users as online.
  // Bridges (PlainTransport) may not pass isPeerReady but are still functional.
  const onlineUserIds = Array.from(clients.keys());
  const msg = JSON.stringify({ type: 'online_users', userIds: onlineUserIds });
  for (const ws of clients.values()) {
    if (ws.readyState === 1) ws.send(msg);
  }
}

/**
 * Force-disconnect a user: close their WS, triggering full cleanup.
 */
function disconnectUser(userId) {
  const ws = clients.get(userId);
  if (!ws) return false;
  // Block re-auth for 30 seconds
  kickedUsers.set(userId, Date.now() + 30000);
  // Tell client they were kicked
  try { send(ws, { type: 'kicked', reason: 'Disconnected by admin' }); } catch (_) {}
  // Close after brief delay so the message arrives first
  setTimeout(() => { try { ws.close(); } catch (_) {} }, 200);
  return true;
}

/**
 * Get the list of currently connected user IDs.
 */
function getOnlineUserIds() {
  return Array.from(clients.keys());
}

/**
 * Get active PTT sessions for a specific user.
 * Returns array of { targetType, targetId, targetUserIds }.
 */
function getActivePttSessions(userId) {
  const sessions = activePtt.get(userId);
  if (!sessions) return [];
  return Array.from(sessions.values()).map(s => ({
    targetType: s.targetType,
    targetId: s.targetId,
    targetUserIds: s.targetUserIds,
  }));
}

/**
 * Get detailed bridge status for all bridge users.
 */
function getBridgeStatus() {
  const bridges = db.prepare(
    "SELECT id, username, display_name FROM users WHERE role = 'bridge' ORDER BY id"
  ).all();

  return bridges.map(b => {
    const online = clients.has(b.id);
    const peer = ms.getPeer(b.id);
    const pttSessions = getActivePttSessions(b.id);

    // Resolve target names
    const pttTargets = pttSessions.map(s => {
      let targetName = '';
      if (s.targetType === 'user') {
        const u = db.prepare('SELECT display_name FROM users WHERE id = ?').get(s.targetId);
        targetName = u?.display_name || `User ${s.targetId}`;
      } else if (s.targetType === 'group') {
        const g = db.prepare('SELECT name FROM groups WHERE id = ?').get(s.targetId);
        targetName = g?.name || `Group ${s.targetId}`;
      }
      return { type: s.targetType, id: s.targetId, name: targetName, listeners: s.targetUserIds.length };
    });

    return {
      id: b.id,
      username: b.username,
      display_name: b.display_name,
      online,
      hasProducer: !!(peer?.producer && !peer.producer.closed),
      producerPaused: peer?.producer?.paused ?? true,
      consumerCount: peer?.consumers?.size ?? 0,
      hasSendTransport: !!peer?.sendTransport,
      hasRecvTransport: !!peer?.recvTransport,
      pttTargets,
    };
  });
}

module.exports = { setupSignaling, disconnectUser, getOnlineUserIds, getBridgeStatus };
