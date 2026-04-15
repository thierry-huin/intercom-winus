const { resolveAnnouncedIps } = require('./services/config-service');

/**
 * Build WebRTC transport options dynamically from persisted config.
 * Resolves hostnames (e.g. huin.tv) to IPs at call time.
 */
async function getWebRtcTransportOptions() {
  const ips = await resolveAnnouncedIps();

  const listenInfos = [];
  if (ips.length > 0) {
    for (const ip of ips) {
      listenInfos.push({ protocol: 'udp', ip: '0.0.0.0', announcedAddress: ip });
    }
    listenInfos.push({ protocol: 'tcp', ip: '0.0.0.0', announcedAddress: ips[0] });
  } else {
    listenInfos.push({ protocol: 'udp', ip: '0.0.0.0' });
    listenInfos.push({ protocol: 'tcp', ip: '0.0.0.0' });
  }

  return {
    listenInfos,
    enableUdp: true,
    enableTcp: true,
    preferUdp: true,
    initialAvailableOutgoingBitrate: 600000,
  };
}

module.exports = {
  // Worker settings
  worker: {
    rtcMinPort: 10000,
    rtcMaxPort: 10200,
    logLevel: 'warn',
    logTags: ['info', 'ice', 'dtls', 'rtp', 'srtp', 'rtcp'],
  },

  // Router: audio-only (opus)
  router: {
    mediaCodecs: [
      {
        kind: 'audio',
        mimeType: 'audio/opus',
        clockRate: 48000,
        channels: 2,
      },
    ],
  },

  // Number of workers (1 is enough for audio-only intercom)
  numWorkers: 1,

  // Dynamic transport options — call this function instead of using a static object
  getWebRtcTransportOptions,
};
