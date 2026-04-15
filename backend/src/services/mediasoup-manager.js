const mediasoup = require('mediasoup');
const msConfig = require('../mediasoup-config');

/** @type {mediasoup.types.Worker} */
let worker = null;
/** @type {mediasoup.types.Router} */
let router = null;

// Per-user state: userId -> { sendTransport, recvTransport, producer, consumers: Map<consumerId, Consumer> }
const peers = new Map();

// Callback for transport close notifications: (userId, direction) => void
let _onTransportClose = null;
function setOnTransportClose(cb) { _onTransportClose = cb; }

// ======================== INIT ========================

async function init() {
  worker = await mediasoup.createWorker({
    logLevel: msConfig.worker.logLevel,
    logTags: msConfig.worker.logTags,
    rtcMinPort: msConfig.worker.rtcMinPort,
    rtcMaxPort: msConfig.worker.rtcMaxPort,
  });

  worker.on('died', () => {
    console.error('mediasoup Worker died, restarting in 2s...');
    setTimeout(() => init(), 2000);
  });

  router = await worker.createRouter({
    mediaCodecs: msConfig.router.mediaCodecs,
  });

  console.log(`mediasoup Worker pid=${worker.pid}, Router id=${router.id}`);
}

// ======================== ROUTER ========================

function getRouterRtpCapabilities() {
  return router.rtpCapabilities;
}

// ======================== PEERS ========================

function getPeer(userId) {
  if (!peers.has(userId)) {
    peers.set(userId, {
      sendTransport: null,
      recvTransport: null,
      producer: null,
      consumers: new Map(),
      rtpCapabilities: null,
    });
  }
  return peers.get(userId);
}

function setPeerRtpCapabilities(userId, rtpCapabilities) {
  const peer = getPeer(userId);
  peer.rtpCapabilities = rtpCapabilities;
}

// ======================== TRANSPORTS ========================

async function createWebRtcTransport(userId, direction) {
  const peer = getPeer(userId);

  // Close any existing transport for this direction
  if (direction === 'send' && peer.sendTransport) {
    try { peer.sendTransport.close(); } catch (_) {}
    peer.sendTransport = null;
    peer.producer = null;
  } else if (direction === 'recv' && peer.recvTransport) {
    // Close existing consumers
    for (const consumer of peer.consumers.values()) {
      try { consumer.close(); } catch (_) {}
    }
    peer.consumers.clear();
    try { peer.recvTransport.close(); } catch (_) {}
    peer.recvTransport = null;
  }

  const transportOptions = await msConfig.getWebRtcTransportOptions();
  console.log(`[mediasoup] WebRTC listenInfos: ${transportOptions.listenInfos.map(l => `${l.protocol}/${l.announcedAddress || '0.0.0.0'}`).join(', ')}`);
  const transport = await router.createWebRtcTransport(transportOptions);

  transport.on('dtlsstatechange', (dtlsState) => {
    if (dtlsState === 'closed' || dtlsState === 'failed') {
      console.warn(`Transport ${transport.id} DTLS ${dtlsState} for user ${userId} (${direction})`);
      // Only clean up and notify if this is still the active transport.
      // Stale transports (replaced on reconnect) should be silently closed.
      let isActive = false;
      if (peer.sendTransport?.id === transport.id) {
        peer.sendTransport = null;
        peer.producer = null;
        isActive = true;
      }
      if (peer.recvTransport?.id === transport.id) {
        for (const consumer of peer.consumers.values()) {
          try { consumer.close(); } catch (_) {}
        }
        peer.consumers.clear();
        peer.recvTransport = null;
        isActive = true;
      }
      try { transport.close(); } catch (_) {}
      if (isActive && _onTransportClose) _onTransportClose(userId, direction);
    }
  });

  if (direction === 'send') {
    peer.sendTransport = transport;
  } else {
    peer.recvTransport = transport;
  }

  return {
    id: transport.id,
    iceParameters: transport.iceParameters,
    iceCandidates: transport.iceCandidates,
    dtlsParameters: transport.dtlsParameters,
  };
}

async function connectTransport(userId, transportId, dtlsParameters) {
  const peer = getPeer(userId);
  const transport =
    peer.sendTransport?.id === transportId ? peer.sendTransport :
    peer.recvTransport?.id === transportId ? peer.recvTransport : null;

  if (!transport) throw new Error(`Transport ${transportId} not found for user ${userId}`);

  await transport.connect({ dtlsParameters });
}

// ======================== PRODUCER ========================

async function produce(userId, transportId, kind, rtpParameters) {
  const peer = getPeer(userId);
  if (!peer.sendTransport || peer.sendTransport.id !== transportId) {
    throw new Error('Send transport mismatch');
  }

  const producer = await peer.sendTransport.produce({ kind, rtpParameters });
  // Start paused — only unmute during PTT
  await producer.pause();
  peer.producer = producer;

  producer.on('transportclose', () => {
    peer.producer = null;
  });

  console.log(`Producer created: user=${userId} id=${producer.id} kind=${kind} (paused)`);
  return { id: producer.id };
}

// ======================== CONSUMER ========================

/**
 * Create a Consumer on targetUserId's recv transport for sourceUserId's Producer.
 * Returns consumer params to send to the target client, or null if not possible.
 */
async function consume(sourceUserId, targetUserId) {
  const sourcePeer = peers.get(sourceUserId);
  const targetPeer = peers.get(targetUserId);

  if (!sourcePeer?.producer) {
    console.warn(`consume: source user ${sourceUserId} has no producer`);
    return null;
  }
  if (!targetPeer?.recvTransport) {
    console.warn(`consume: target user ${targetUserId} has no recv transport`);
    return null;
  }
  if (!targetPeer.rtpCapabilities) {
    console.warn(`consume: target user ${targetUserId} has no rtpCapabilities`);
    return null;
  }
  if (!router.canConsume({ producerId: sourcePeer.producer.id, rtpCapabilities: targetPeer.rtpCapabilities })) {
    console.warn(`consume: router cannot consume producer ${sourcePeer.producer.id} for user ${targetUserId}`);
    return null;
  }

  try {
    const consumer = await targetPeer.recvTransport.consume({
      producerId: sourcePeer.producer.id,
      rtpCapabilities: targetPeer.rtpCapabilities,
      paused: false,
    });

    targetPeer.consumers.set(consumer.id, consumer);

    consumer.on('transportclose', () => {
      targetPeer.consumers.delete(consumer.id);
    });
    consumer.on('producerclose', () => {
      targetPeer.consumers.delete(consumer.id);
    });

    console.log(`Consumer created: source=${sourceUserId} -> target=${targetUserId} consumer=${consumer.id}`);

    return {
      id: consumer.id,
      producerId: sourcePeer.producer.id,
      kind: consumer.kind,
      rtpParameters: consumer.rtpParameters,
      producerPeerId: sourceUserId,
    };
  } catch (err) {
    console.error(`consume: FAILED source=${sourceUserId} -> target=${targetUserId}: ${err.message}`);
    return null;
  }
}

async function resumeConsumer(userId, consumerId) {
  const peer = peers.get(userId);
  const consumer = peer?.consumers.get(consumerId);
  if (consumer) {
    await consumer.resume();
  }
}

// ======================== PTT ========================

/**
 * Start PTT: resume source's producer and create consumers on all target users.
 * Returns array of { targetUserId, consumerParams } for each target.
 */
async function pttStart(sourceUserId, targetUserIds) {
  const sourcePeer = peers.get(sourceUserId);
  if (!sourcePeer?.producer) return [];

  // Resume source producer (only if paused)
  if (sourcePeer.producer.paused) {
    await sourcePeer.producer.resume();
  }

  const results = [];
  for (const targetUserId of targetUserIds) {
    const targetPeer = peers.get(targetUserId);
    if (!targetPeer) continue;

    // Reuse existing active consumer — avoids iOS/WebKit DTLS close on idle
    let existing = null;
    for (const [cid, c] of targetPeer.consumers) {
      if (c.producerId === sourcePeer.producer.id && !c.closed) {
        existing = c; break;
      }
    }

    if (existing) {
      // Resume existing paused consumer — no close/create, no gap, DTLS stays alive.
      // platformEnsureRemoteAudioPlaying() on the client restarts audio on resume.
      if (existing.paused) await existing.resume();
      results.push({ targetUserId, consumerParams: null, closedId: null });
    } else {
      const params = await consume(sourceUserId, targetUserId);
      if (params) results.push({ targetUserId, consumerParams: params, closedId: null });
    }
  }
  return results;
}

/**
 * Stop PTT: pause source's producer and close all consumers created for this PTT session.
 */
/**
 * Stop PTT: pause source's producer and close consumers.
 * Returns Map<targetUserId, [closedConsumerIds]> so signaling can notify specific IDs.
 */
async function pttStop(sourceUserId, targetUserIds, pauseProducer = true) {
  const sourcePeer = peers.get(sourceUserId);
  if (pauseProducer && sourcePeer?.producer) {
    await sourcePeer.producer.pause();
  }
  // Pause consumers (not close) to prevent iOS/WebKit DTLS close on idle.
  // RTCP still flows on paused consumers, keeping the connection alive.
  // Paused consumers won't receive RTP when producer resumes for a different session.
  for (const targetUserId of targetUserIds) {
    const targetPeer = peers.get(targetUserId);
    if (!targetPeer) continue;
    for (const consumer of targetPeer.consumers.values()) {
      if (consumer.producerId === sourcePeer?.producer?.id && !consumer.paused) {
        await consumer.pause();
      }
    }
  }
  console.log(`ptt_stop: user=${sourceUserId}, targets=${targetUserIds}, consumers paused, pauseProducer: ${pauseProducer}`);
  return new Map(); // No consumersClosed events sent
}

// ======================== PLAIN TRANSPORT (tie-line bridge) ========================

async function createPlainTransport(userId, direction) {
  const peer = getPeer(userId);

  // Close any existing transport for this direction
  if (direction === 'send' && peer.sendTransport) {
    try { peer.sendTransport.close(); } catch (_) {}
    peer.sendTransport = null;
    peer.producer = null;
  } else if (direction === 'recv' && peer.recvTransport) {
    for (const consumer of peer.consumers.values()) {
      try { consumer.close(); } catch (_) {}
    }
    peer.consumers.clear();
    try { peer.recvTransport.close(); } catch (_) {}
    peer.recvTransport = null;
  }

  // Use first announced IP so bridge knows where to send RTP
  const announcedIp = (process.env.MEDIASOUP_ANNOUNCED_IPS || '').split(',')[0]?.trim() || undefined;
  const transport = await router.createPlainTransport({
    listenInfo: {
      protocol: 'udp',
      ip: '0.0.0.0',
      announcedAddress: announcedIp,
    },
    rtcpMux: true,
    comedia: direction === 'send',
  });

  transport.on('tuple', (tuple) => {
    console.log(`PlainTransport tuple for user=${userId} dir=${direction}: ${tuple.localAddress}:${tuple.localPort} -> ${tuple.remoteIp}:${tuple.remotePort}`);
  });

  if (direction === 'send') {
    peer.sendTransport = transport;
  } else {
    peer.recvTransport = transport;
  }

  console.log(`PlainTransport created: user=${userId} dir=${direction} id=${transport.id} port=${transport.tuple.localPort}`);

  return {
    id: transport.id,
    ip: transport.tuple.localAddress,
    port: transport.tuple.localPort,
  };
}

async function connectPlainTransport(userId, transportId, ip, port) {
  const peer = getPeer(userId);
  const transport =
    peer.sendTransport?.id === transportId ? peer.sendTransport :
    peer.recvTransport?.id === transportId ? peer.recvTransport : null;

  if (!transport) throw new Error(`PlainTransport ${transportId} not found for user ${userId}`);

  await transport.connect({ ip, port });
  console.log(`PlainTransport connected: user=${userId} id=${transportId} -> ${ip}:${port}`);
}

// ======================== CLEANUP ========================

function cleanupPeer(userId) {
  const peer = peers.get(userId);
  if (!peer) return;

  // Close all consumers
  for (const consumer of peer.consumers.values()) {
    consumer.close();
  }

  // Close producer
  if (peer.producer) {
    peer.producer.close();
  }

  // Close transports
  if (peer.sendTransport) peer.sendTransport.close();
  if (peer.recvTransport) peer.recvTransport.close();

  peers.delete(userId);
  console.log(`Peer cleaned up: user=${userId}`);
}

/**
 * A peer is "ready" when it can both send and receive audio:
 * - has a producer (send transport connected + producing)
 * - has a recv transport
 * - has rtpCapabilities
 */
function isPeerReady(userId) {
  const peer = peers.get(userId);
  if (!peer) return false;
  return !!(peer.producer && peer.recvTransport && peer.rtpCapabilities);
}

function getRouter() { return router; }

module.exports = {
  init,
  getRouter,
  getRouterRtpCapabilities,
  getPeer,
  setPeerRtpCapabilities,
  createWebRtcTransport,
  connectTransport,
  produce,
  consume,
  resumeConsumer,
  pttStart,
  pttStop,
  cleanupPeer,
  setOnTransportClose,
  createPlainTransport,
  connectPlainTransport,
  isPeerReady,
};
