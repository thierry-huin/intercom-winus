#!/usr/bin/env node
/**
 * Winus Intercom — Full Stress Test
 * Creates temporary users, assigns full permissions, runs intensive PTT,
 * then cleans up.
 *
 * Usage: node stress-test-full.js [server_url] [extra_users] [duration_seconds]
 */

const WebSocket = require('ws');
const https = require('https');
const http = require('http');

const SERVER = process.argv[2] || 'https://localhost:8443';
const EXTRA_USERS = parseInt(process.argv[3] || '10');
const DURATION = parseInt(process.argv[4] || '60');
const ADMIN_USER = 'admin';
const TEST_PASS = '1234';

function askPassword(prompt) {
  return new Promise((resolve) => {
    process.stdout.write(prompt);
    process.stdin.setEncoding('utf8');
    process.stdin.once('data', (data) => {
      resolve(data.trim());
    });
  });
}

const stats = {
  connections: 0, disconnections: 0, reconnections: 0,
  pttStart: 0, pttStop: 0, pttAllowed: 0, pttDenied: 0,
  consumersCreated: 0, consumersClosed: 0,
  transportCreated: 0, errors: [],
};

// ======================== HTTP ========================

function httpReq(method, url, body, token) {
  return new Promise((resolve, reject) => {
    const parsed = new URL(url);
    const mod = parsed.protocol === 'https:' ? https : http;
    const headers = { 'Content-Type': 'application/json' };
    if (token) headers['Authorization'] = `Bearer ${token}`;
    const req = mod.request({
      hostname: parsed.hostname, port: parsed.port,
      path: parsed.pathname, method,
      headers, rejectUnauthorized: false,
    }, (res) => {
      let data = '';
      res.on('data', d => data += d);
      res.on('end', () => {
        try { resolve({ status: res.statusCode, data: JSON.parse(data) }); }
        catch { resolve({ status: res.statusCode, data }); }
      });
    });
    req.on('error', reject);
    if (body) req.write(JSON.stringify(body));
    req.end();
  });
}

const post = (url, body, token) => httpReq('POST', url, body, token);
const get = (url, token) => httpReq('GET', url, null, token);
const del = (url, token) => httpReq('DELETE', url, null, token);

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

// ======================== TEST USER ========================

class TestUser {
  constructor(username, password, userId) {
    this.username = username;
    this.password = password;
    this.userId = userId;
    this.token = null;
    this.ws = null;
    this.requestId = 0;
    this.pending = new Map();
    this.targets = [];
    this.running = false;
    this.connected = false;
    this.activePtt = null;
    this.mediaReady = false;
  }

  async login() {
    const resp = await post(`${SERVER}/api/auth/login`, {
      username: this.username, password: this.password, client_type: 'web',
    });
    if (!resp.data.token) throw new Error(`Login failed: ${JSON.stringify(resp.data)}`);
    this.token = resp.data.token;
    this.userId = resp.data.user.id;
  }

  async loadTargets() {
    const resp = await get(`${SERVER}/api/rooms/my-targets`, this.token);
    this.targets = (resp.data.users || []).map(u => ({ type: 'user', id: u.id, name: u.display_name }));
    for (const g of (resp.data.groups || [])) {
      this.targets.push({ type: 'group', id: g.id, name: g.name });
    }
  }

  connectWs() {
    const wsUrl = SERVER.replace('https://', 'wss://').replace('http://', 'ws://') + '/ws';
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error('WS connect timeout')), 10000);
      this.ws = new WebSocket(wsUrl, { rejectUnauthorized: false });
      this.ws.on('open', () => {
        this.ws.send(JSON.stringify({ type: 'auth', token: this.token }));
      });
      this.ws.on('message', (raw) => {
        let msg;
        try { msg = JSON.parse(raw); } catch { return; }
        if (msg.requestId && this.pending.has(msg.requestId)) {
          const p = this.pending.get(msg.requestId);
          clearTimeout(p.timer);
          this.pending.delete(msg.requestId);
          if (msg.type === 'error') p.reject(new Error(msg.error));
          else p.resolve(msg);
          return;
        }
        switch (msg.type) {
          case 'auth_ok':
            this.connected = true;
            stats.connections++;
            clearTimeout(timeout);
            resolve();
            break;
          case 'ptt_allowed': stats.pttAllowed++; break;
          case 'ptt_denied': stats.pttDenied++; break;
          case 'newConsumer':
            stats.consumersCreated++;
            this.wsSend({ type: 'resumeConsumer', consumerId: msg.id });
            break;
          case 'consumersClosed': stats.consumersClosed++; break;
          case 'transportClosed':
            stats.reconnections++;
            this.initMedia().catch(() => {});
            break;
        }
      });
      this.ws.on('close', () => { this.connected = false; stats.disconnections++; });
      this.ws.on('error', (e) => { stats.errors.push(`${this.username}: ${e.message}`); });
    });
  }

  wsSend(data) {
    if (this.ws?.readyState === WebSocket.OPEN) this.ws.send(JSON.stringify(data));
  }

  wsRequest(type, data = {}) {
    return new Promise((resolve, reject) => {
      const id = ++this.requestId;
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error(`Timeout: ${type}`)); }, 10000);
      this.pending.set(id, { resolve, reject, timer });
      this.wsSend({ type, requestId: id, ...data });
    });
  }

  async initMedia() {
    try {
      const caps = await this.wsRequest('getRouterRtpCapabilities');
      await this.wsRequest('setRtpCapabilities', { rtpCapabilities: caps.rtpCapabilities });
      await this.wsRequest('createWebRtcTransport', { direction: 'send' });
      stats.transportCreated++;
      await this.wsRequest('createWebRtcTransport', { direction: 'recv' });
      stats.transportCreated++;
      this.mediaReady = true;
    } catch (e) {
      stats.errors.push(`${this.username}: initMedia: ${e.message}`);
    }
  }

  async doPtt(holdMs) {
    if (!this.connected || this.targets.length === 0) return;
    const target = this.targets[Math.floor(Math.random() * this.targets.length)];
    this.wsSend({ type: 'ptt_start', targetType: target.type, targetId: target.id });
    stats.pttStart++;
    this.activePtt = target;
    await sleep(holdMs);
    this.wsSend({ type: 'ptt_stop', targetType: target.type, targetId: target.id });
    stats.pttStop++;
    this.activePtt = null;
  }

  async simulateReconnect() {
    if (!this.connected) return;
    this.ws.terminate();
    await sleep(300 + Math.random() * 1500);
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
    for (const { reject, timer } of this.pending.values()) { clearTimeout(timer); reject(new Error('closed')); }
    this.pending.clear();
    if (this.ws) this.ws.close();
  }
}

// ======================== MAIN ========================

async function main() {
  console.log(`\n🔥 FULL Stress Test — ${SERVER}`);
  console.log(`   Extra users: ${EXTRA_USERS}, Duration: ${DURATION}s\n`);

  // 1. Admin login
  const ADMIN_PASS = await askPassword('  Admin password: ');
  console.log('[1/7] Admin login...');  
  const adminLogin = await post(`${SERVER}/api/auth/login`, {
    username: ADMIN_USER, password: ADMIN_PASS, client_type: 'web',
  });
  if (!adminLogin.data.token) {
    console.error('Admin login failed:', adminLogin.data);
    process.exit(1);
  }
  const adminToken = adminLogin.data.token;
  console.log('  ✓ Admin authenticated');

  // 2. Get existing users
  console.log('[2/7] Loading existing users...');
  const existingResp = await get(`${SERVER}/api/admin/users`, adminToken);
  const existingUsers = (existingResp.data || []).filter(u => u.role !== 'admin' && u.role !== 'bridge');
  console.log(`  ✓ ${existingUsers.length} existing users`);

  // 3. Create temporary test users
  console.log(`[3/7] Creating ${EXTRA_USERS} temporary users...`);
  const tempUserIds = [];
  for (let i = 0; i < EXTRA_USERS; i++) {
    const name = `StressBot_${i + 1}`;
    const resp = await post(`${SERVER}/api/admin/users`, {
      display_name: name, username: name.toLowerCase(), password: TEST_PASS, role: 'user',
    }, adminToken);
    if (resp.data.id) {
      tempUserIds.push(resp.data.id);
    } else if (resp.data.error?.includes('already exists')) {
      // Try to find existing
      const all = await get(`${SERVER}/api/admin/users`, adminToken);
      const found = (all.data || []).find(u => u.username === name.toLowerCase());
      if (found) tempUserIds.push(found.id);
    }
  }
  console.log(`  ✓ ${tempUserIds.length} temp users created`);

  // 4. Assign permissions (all can talk to all)
  console.log('[4/7] Assigning permissions...');
  const allUserIds = [...existingUsers.map(u => u.id), ...tempUserIds];
  let permCount = 0;
  for (const from of allUserIds) {
    for (const to of allUserIds) {
      if (from !== to) {
        await post(`${SERVER}/api/admin/permissions`, {
          from_user_id: from, to_user_id: to, can_talk: true,
        }, adminToken);
        permCount++;
      }
    }
  }
  console.log(`  ✓ ${permCount} permissions set`);

  // 5. Connect all users
  console.log('[5/7] Connecting users...');
  const users = [];

  // Existing users
  for (const u of existingUsers) {
    const tu = new TestUser(u.username, TEST_PASS, u.id);
    try {
      await tu.login();
      await tu.loadTargets();
      await tu.connectWs();
      await tu.initMedia();
      tu.running = true;
      users.push(tu);
      process.stdout.write(`  ✓ ${u.display_name} (${tu.targets.length} targets)\n`);
    } catch (e) {
      process.stdout.write(`  ✗ ${u.display_name}: ${e.message}\n`);
    }
  }

  // Temp users
  for (let i = 0; i < tempUserIds.length; i++) {
    const name = `stressbot_${i + 1}`;
    const tu = new TestUser(name, TEST_PASS, tempUserIds[i]);
    try {
      await tu.login();
      await tu.loadTargets();
      await tu.connectWs();
      await tu.initMedia();
      tu.running = true;
      users.push(tu);
      process.stdout.write(`  ✓ ${name} (${tu.targets.length} targets)\n`);
    } catch (e) {
      process.stdout.write(`  ✗ ${name}: ${e.message}\n`);
    }
  }

  console.log(`\n  Total connected: ${users.length}`);

  if (users.length < 2) {
    console.error('Need at least 2 users');
    await cleanup(adminToken, tempUserIds);
    process.exit(1);
  }

  // 6. Run stress test
  console.log(`\n[6/7] Running stress test (${DURATION}s, ${users.length} users)...`);
  const startTime = Date.now();
  const endTime = startTime + DURATION * 1000;

  const statusInterval = setInterval(() => {
    const elapsed = ((Date.now() - startTime) / 1000).toFixed(0);
    const rate = (stats.pttStart / Math.max(1, elapsed)).toFixed(1);
    process.stdout.write(
      `\r  ⏱ ${elapsed}s | PTT: ${stats.pttStart}→/${stats.pttStop}■ (${rate}/s) | ` +
      `OK:${stats.pttAllowed} NO:${stats.pttDenied} | ` +
      `C:+${stats.consumersCreated}/-${stats.consumersClosed} | ` +
      `Reconn:${stats.reconnections} Err:${stats.errors.length}   `
    );
  }, 500);

  const tasks = users.map(async (user) => {
    while (Date.now() < endTime && user.running) {
      const r = Math.random();
      if (r < 0.50) {
        // 50%: Normal PTT (0.5-3s hold)
        await user.doPtt(500 + Math.random() * 2500);
      } else if (r < 0.65) {
        // 15%: Rapid PTT (<200ms)
        await user.doPtt(30 + Math.random() * 170);
      } else if (r < 0.75) {
        // 10%: Double-tap (PTT twice quickly to same target)
        await user.doPtt(100 + Math.random() * 300);
        await sleep(50);
        await user.doPtt(100 + Math.random() * 300);
      } else if (r < 0.85) {
        // 10%: Reconnect
        await user.simulateReconnect();
      } else {
        // 15%: Idle
        await sleep(500 + Math.random() * 2000);
      }
      await sleep(50 + Math.random() * 300);
    }
  });

  await Promise.all(tasks);
  clearInterval(statusInterval);
  console.log('\n');

  // 7. Cleanup & report
  console.log('[7/7] Cleaning up...');
  users.forEach(u => u.close());
  await sleep(1000);
  await cleanup(adminToken, tempUserIds);

  // Report
  const elapsed = (DURATION).toFixed(0);
  console.log('\n' + '═'.repeat(60));
  console.log('  STRESS TEST RESULTS');
  console.log('═'.repeat(60));
  console.log(`  Duration:          ${elapsed}s`);
  console.log(`  Users:             ${users.length} (${existingUsers.length} real + ${tempUserIds.length} bots)`);
  console.log(`  Connections:       ${stats.connections}`);
  console.log(`  Disconnections:    ${stats.disconnections}`);
  console.log(`  Reconnections:     ${stats.reconnections}`);
  console.log(`  PTT Start:         ${stats.pttStart}`);
  console.log(`  PTT Stop:          ${stats.pttStop}`);
  console.log(`  PTT Rate:          ${(stats.pttStart / DURATION).toFixed(1)}/s`);
  console.log(`  PTT Allowed:       ${stats.pttAllowed}`);
  console.log(`  PTT Denied:        ${stats.pttDenied}`);
  console.log(`  Consumers Created: ${stats.consumersCreated}`);
  console.log(`  Consumers Closed:  ${stats.consumersClosed}`);
  console.log(`  Transports:        ${stats.transportCreated}`);
  console.log(`  Errors:            ${stats.errors.length}`);

  // Checks
  console.log('\n  ── Checks ──');
  const pttDelta = stats.pttStart - stats.pttStop;
  console.log(pttDelta <= 0 ? '  ✓ PTT balanced' : `  ⚠️  PTT LEAK: ${pttDelta} not stopped`);

  const cDelta = stats.consumersCreated - stats.consumersClosed;
  console.log(cDelta <= users.length
    ? `  ✓ Consumer balance: ${cDelta} open (≤ ${users.length})`
    : `  ⚠️  CONSUMER LEAK: ${cDelta} not closed`);

  const deniedPct = stats.pttStart > 0 ? (stats.pttDenied / stats.pttStart * 100).toFixed(1) : 0;
  console.log(`  ${deniedPct > 50 ? '⚠️' : '✓'} PTT denied rate: ${deniedPct}%`);

  if (stats.errors.length > 0) {
    console.log(`\n  ── Errors (top 10) ──`);
    [...new Set(stats.errors)].slice(0, 10).forEach(e => console.log(`    - ${e}`));
  }

  console.log('═'.repeat(60));

  try {
    const h = await get(`${SERVER}/api/health`, '');
    console.log(`\n  Server health: ${h.data.status || 'unknown'}`);
  } catch (e) {
    console.log(`\n  ⚠️  Health check failed: ${e.message}`);
  }

  process.exit(stats.errors.length > 50 ? 1 : 0);
}

async function cleanup(adminToken, tempUserIds) {
  console.log(`  Deleting ${tempUserIds.length} temporary users...`);
  for (const id of tempUserIds) {
    await del(`${SERVER}/api/admin/users/${id}`, adminToken).catch(() => {});
  }
  console.log('  ✓ Cleanup done');
}

main().catch(e => { console.error('Fatal:', e); process.exit(1); });
