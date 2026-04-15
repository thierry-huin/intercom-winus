#!/usr/bin/env node
/**
 * Winus Intercom — Stress Test
 * Simulates multiple users doing rapid PTT, reconnections, and concurrent operations.
 *
 * Usage: node stress-test.js [server_url] [num_users] [duration_seconds]
 * Example: node stress-test.js https://10.147.19.1:8443 10 60
 */

const WebSocket = require('ws');
const https = require('https');
const http = require('http');

const SERVER = process.argv[2] || 'https://10.147.19.1:8443';
const NUM_USERS = parseInt(process.argv[3] || '8');
const DURATION = parseInt(process.argv[4] || '60');

// Stats
const stats = {
  connections: 0,
  disconnections: 0,
  reconnections: 0,
  pttStart: 0,
  pttStop: 0,
  pttAllowed: 0,
  pttDenied: 0,
  consumersCreated: 0,
  consumersClosed: 0,
  errors: [],
  transportCreated: 0,
  producerCreated: 0,
};

const agent = new https.Agent({ rejectUnauthorized: false });

// ======================== HTTP HELPERS ========================

function httpPost(url, body) {
  return new Promise((resolve, reject) => {
    const parsed = new URL(url);
    const mod = parsed.protocol === 'https:' ? https : http;
    const req = mod.request({
      hostname: parsed.hostname,
      port: parsed.port,
      path: parsed.pathname,
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      rejectUnauthorized: false,
    }, (res) => {
      let data = '';
      res.on('data', (d) => data += d);
      res.on('end', () => {
        try { resolve(JSON.parse(data)); }
        catch { resolve(data); }
      });
    });
    req.on('error', reject);
    req.write(JSON.stringify(body));
    req.end();
  });
}

function httpGet(url, token) {
  return new Promise((resolve, reject) => {
    const parsed = new URL(url);
    const mod = parsed.protocol === 'https:' ? https : http;
    const req = mod.request({
      hostname: parsed.hostname,
      port: parsed.port,
      path: parsed.pathname,
      method: 'GET',
      headers: { 'Authorization': `Bearer ${token}` },
      rejectUnauthorized: false,
    }, (res) => {
      let data = '';
      res.on('data', (d) => data += d);
      res.on('end', () => {
        try { resolve(JSON.parse(data)); }
        catch { resolve(data); }
      });
    });
    req.on('error', reject);
    req.end();
  });
}

// ======================== TEST USER ========================

class TestUser {
  constructor(username, password) {
    this.username = username;
    this.password = password;
    this.token = null;
    this.userId = null;
    this.ws = null;
    this.requestId = 0;
    this.pending = new Map();
    this.targets = [];
    this.running = false;
    this.connected = false;
    this.activePtt = null;
  }

  async login() {
    const resp = await httpPost(`${SERVER}/api/auth/login`, {
      username: this.username,
      password: this.password,
      client_type: 'web',
    });
    if (!resp.token) throw new Error(`Login failed for ${this.username}: ${JSON.stringify(resp)}`);
    this.token = resp.token;
    this.userId = resp.user.id;
  }

  async loadTargets() {
    const resp = await httpGet(`${SERVER}/api/rooms/my-targets`, this.token);
    this.targets = (resp.users || []).map(u => ({ type: 'user', id: u.id, name: u.display_name }));
    // Add groups
    for (const g of (resp.groups || [])) {
      this.targets.push({ type: 'group', id: g.id, name: g.name });
    }
  }

  async connectWs() {
    const wsUrl = SERVER.replace('https://', 'wss://').replace('http://', 'ws://') + '/ws';
    return new Promise((resolve, reject) => {
      this.ws = new WebSocket(wsUrl, { rejectUnauthorized: false });
      this.ws.on('open', () => {
        this.ws.send(JSON.stringify({ type: 'auth', token: this.token }));
      });
      this.ws.on('message', (data) => {
        let msg;
        try { msg = JSON.parse(data); } catch { return; }
        // Dispatch pending requests
        if (msg.requestId && this.pending.has(msg.requestId)) {
          const { resolve, reject, timer } = this.pending.get(msg.requestId);
          clearTimeout(timer);
          this.pending.delete(msg.requestId);
          if (msg.type === 'error') reject(new Error(msg.error));
          else resolve(msg);
          return;
        }
        // Handle pushed messages
        switch (msg.type) {
          case 'auth_ok':
            this.connected = true;
            stats.connections++;
            resolve();
            break;
          case 'ptt_allowed':
            stats.pttAllowed++;
            break;
          case 'ptt_denied':
            stats.pttDenied++;
            break;
          case 'newConsumer':
            stats.consumersCreated++;
            // Resume consumer
            this.wsSend({ type: 'resumeConsumer', consumerId: msg.id });
            break;
          case 'consumersClosed':
            stats.consumersClosed++;
            break;
          case 'transportClosed':
            // Simulate client re-init
            stats.reconnections++;
            this.initMedia().catch(() => {});
            break;
        }
      });
      this.ws.on('close', () => {
        this.connected = false;
        stats.disconnections++;
      });
      this.ws.on('error', (err) => {
        stats.errors.push(`${this.username}: WS error: ${err.message}`);
        reject(err);
      });
    });
  }

  wsSend(data) {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(data));
    }
  }

  wsRequest(type, data = {}) {
    return new Promise((resolve, reject) => {
      const id = ++this.requestId;
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Timeout: ${type}`));
      }, 10000);
      this.pending.set(id, { resolve, reject, timer });
      this.wsSend({ type, requestId: id, ...data });
    });
  }

  async initMedia() {
    try {
      // Get router capabilities
      await this.wsRequest('getRouterRtpCapabilities');
      // Set our capabilities (simplified — just echo back)
      const caps = await this.wsRequest('getRouterRtpCapabilities');
      await this.wsRequest('setRtpCapabilities', {
        rtpCapabilities: caps.rtpCapabilities,
      });
      // Create send transport
      const sendT = await this.wsRequest('createWebRtcTransport', { direction: 'send' });
      stats.transportCreated++;
      // Create recv transport
      const recvT = await this.wsRequest('createWebRtcTransport', { direction: 'recv' });
      stats.transportCreated++;
      // Note: we don't actually connect DTLS or produce (no real WebRTC)
      // This tests the signaling path only
    } catch (e) {
      stats.errors.push(`${this.username}: initMedia: ${e.message}`);
    }
  }

  async doPtt() {
    if (!this.connected || this.targets.length === 0) return;
    const target = this.targets[Math.floor(Math.random() * this.targets.length)];
    try {
      this.wsSend({ type: 'ptt_start', targetType: target.type, targetId: target.id });
      stats.pttStart++;
      this.activePtt = target;
      // Hold PTT for random duration (100ms - 3s)
      const holdMs = 100 + Math.random() * 2900;
      await sleep(holdMs);
      this.wsSend({ type: 'ptt_stop', targetType: target.type, targetId: target.id });
      stats.pttStop++;
      this.activePtt = null;
    } catch (e) {
      stats.errors.push(`${this.username}: PTT error: ${e.message}`);
    }
  }

  async simulateReconnect() {
    if (!this.connected) return;
    // Close WS abruptly (simulates network drop)
    this.ws.terminate();
    await sleep(500 + Math.random() * 2000);
    try {
      await this.connectWs();
      await this.initMedia();
    } catch (e) {
      stats.errors.push(`${this.username}: reconnect: ${e.message}`);
    }
  }

  close() {
    this.running = false;
    if (this.activePtt) {
      this.wsSend({ type: 'ptt_stop', targetType: this.activePtt.type, targetId: this.activePtt.id });
    }
    for (const { reject, timer } of this.pending.values()) {
      clearTimeout(timer);
      reject(new Error('closed'));
    }
    this.pending.clear();
    if (this.ws) this.ws.close();
  }
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

// ======================== MAIN ========================

async function main() {
  console.log(`\n🔥 Stress Test — ${SERVER}`);
  console.log(`   Users: ${NUM_USERS}, Duration: ${DURATION}s\n`);

  // 1. Get available test users
  console.log('[1/4] Logging in admin to get user list...');
  const adminResp = await httpPost(`${SERVER}/api/auth/login`, {
    username: 'admin', password: 'admin', client_type: 'web',
  });
  if (!adminResp.token) {
    console.error('Admin login failed:', adminResp);
    process.exit(1);
  }

  // Get all users
  const usersResp = await httpGet(`${SERVER}/api/admin/users`, adminResp.token);
  const testUsers = (usersResp || [])
    .filter(u => u.role !== 'admin' && u.role !== 'bridge')
    .slice(0, NUM_USERS);

  if (testUsers.length === 0) {
    console.error('No test users found. Create some users first.');
    process.exit(1);
  }
  console.log(`   Found ${testUsers.length} test users: ${testUsers.map(u => u.username).join(', ')}`);

  // 2. Create test user instances
  console.log('[2/4] Connecting users...');
  const users = [];
  for (const u of testUsers) {
    const tu = new TestUser(u.username, '1234');
    try {
      await tu.login();
      await tu.loadTargets();
      await tu.connectWs();
      await tu.initMedia();
      tu.running = true;
      users.push(tu);
      process.stdout.write(`   ✓ ${u.username} (${tu.targets.length} targets)\n`);
    } catch (e) {
      process.stdout.write(`   ✗ ${u.username}: ${e.message}\n`);
    }
  }

  if (users.length < 2) {
    console.error('\nNeed at least 2 connected users for stress test.');
    users.forEach(u => u.close());
    process.exit(1);
  }

  // 3. Run stress scenarios
  console.log(`\n[3/4] Running stress test for ${DURATION}s with ${users.length} users...`);
  const startTime = Date.now();
  const endTime = startTime + DURATION * 1000;

  // Status display interval
  const statusInterval = setInterval(() => {
    const elapsed = ((Date.now() - startTime) / 1000).toFixed(0);
    process.stdout.write(
      `\r  ⏱ ${elapsed}s | PTT: ${stats.pttStart}→/${stats.pttStop}■ | ` +
      `Allowed: ${stats.pttAllowed} Denied: ${stats.pttDenied} | ` +
      `Consumers: +${stats.consumersCreated}/-${stats.consumersClosed} | ` +
      `Reconn: ${stats.reconnections} | Errors: ${stats.errors.length}   `
    );
  }, 500);

  // User activity loops
  const tasks = users.map(async (user) => {
    while (Date.now() < endTime && user.running) {
      const action = Math.random();
      if (action < 0.6) {
        // 60%: PTT
        await user.doPtt();
      } else if (action < 0.7) {
        // 10%: Rapid PTT (quick press)
        if (user.connected && user.targets.length > 0) {
          const t = user.targets[Math.floor(Math.random() * user.targets.length)];
          user.wsSend({ type: 'ptt_start', targetType: t.type, targetId: t.id });
          stats.pttStart++;
          await sleep(50 + Math.random() * 150); // very short
          user.wsSend({ type: 'ptt_stop', targetType: t.type, targetId: t.id });
          stats.pttStop++;
        }
      } else if (action < 0.8) {
        // 10%: Reconnect
        await user.simulateReconnect();
      } else {
        // 20%: Idle
        await sleep(500 + Math.random() * 2000);
      }
      // Brief pause between actions
      await sleep(100 + Math.random() * 500);
    }
  });

  await Promise.all(tasks);
  clearInterval(statusInterval);

  // 4. Cleanup & report
  console.log('\n\n[4/4] Cleaning up...');
  users.forEach(u => u.close());
  await sleep(1000);

  console.log('\n' + '='.repeat(60));
  console.log('  STRESS TEST RESULTS');
  console.log('='.repeat(60));
  console.log(`  Duration:          ${DURATION}s`);
  console.log(`  Users:             ${users.length}`);
  console.log(`  Connections:       ${stats.connections}`);
  console.log(`  Disconnections:    ${stats.disconnections}`);
  console.log(`  Reconnections:     ${stats.reconnections}`);
  console.log(`  PTT Start:         ${stats.pttStart}`);
  console.log(`  PTT Stop:          ${stats.pttStop}`);
  console.log(`  PTT Allowed:       ${stats.pttAllowed}`);
  console.log(`  PTT Denied:        ${stats.pttDenied}`);
  console.log(`  Consumers Created: ${stats.consumersCreated}`);
  console.log(`  Consumers Closed:  ${stats.consumersClosed}`);
  console.log(`  Transports:        ${stats.transportCreated}`);
  console.log(`  Errors:            ${stats.errors.length}`);

  // Consumer leak check
  const consumerDelta = stats.consumersCreated - stats.consumersClosed;
  if (consumerDelta > users.length) {
    console.log(`\n  ⚠️  CONSUMER LEAK: ${consumerDelta} consumers not closed!`);
  } else {
    console.log(`\n  ✓ Consumer balance: ${consumerDelta} open (expected ≤ ${users.length})`);
  }

  // PTT balance check
  const pttDelta = stats.pttStart - stats.pttStop;
  if (pttDelta > 0) {
    console.log(`  ⚠️  PTT LEAK: ${pttDelta} PTT sessions not stopped!`);
  } else {
    console.log(`  ✓ PTT balance: all sessions stopped`);
  }

  if (stats.errors.length > 0) {
    console.log(`\n  Unique errors:`);
    const unique = [...new Set(stats.errors)];
    unique.slice(0, 10).forEach(e => console.log(`    - ${e}`));
    if (unique.length > 10) console.log(`    ... and ${unique.length - 10} more`);
  }

  console.log('='.repeat(60));

  // Check server health after test
  try {
    const health = await httpGet(`${SERVER}/api/health`, '');
    console.log(`\n  Server health: ${health.status || 'unknown'}`);
  } catch (e) {
    console.log(`\n  ⚠️  Server health check failed: ${e.message}`);
  }

  process.exit(stats.errors.length > 20 ? 1 : 0);
}

main().catch(e => {
  console.error('Fatal:', e);
  process.exit(1);
});
