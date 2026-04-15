const API = window.IntercomAPI;

// ======================== STATE ========================

let janus = null;
let listenHandle = null;           // Permanent: own room, receive audio
let talkHandles = new Map();       // roomId -> { handle, ready }
let activeTalkRoomIds = [];        // Currently unmuted room IDs

let targetPttModes = new Map();  // 'user-1' -> 'no-latch'|'latch'
let currentTarget = null;
let isTalking = false;
let onlineUsers = [];
let targets = { users: [], groups: [] };
let ws = null;

let selectedInputDeviceId = '';
let selectedOutputDeviceId = '';

let statsInterval = null;
let lastRxBytes = 0;
let lastTxBytes = 0;
let lastStatsTime = 0;

// ======================== INIT ========================

document.addEventListener('DOMContentLoaded', async () => {
  const user = API.getUser();
  if (!API.getToken() || !user) {
    window.location.href = 'index.html';
    return;
  }

  document.getElementById('userInfo').textContent = user.display_name;
  document.getElementById('logoutBtn').addEventListener('click', cleanup);
  document.getElementById('inputDevice').addEventListener('change', onInputDeviceChange);
  document.getElementById('outputDevice').addEventListener('change', onOutputDeviceChange);

  await loadAudioDevices();
  await loadTargets();
  connectWebSocket();
  initJanus();
});

function cleanup() {
  stopStats();
  if (ws) ws.close();
  if (janus) janus.destroy();
  API.logout();
  window.location.href = 'index.html';
}

// ======================== AUDIO DEVICES ========================

async function loadAudioDevices() {
  // Request mic permission to get labeled devices (may fail on non-HTTPS)
  try {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    stream.getTracks().forEach((t) => t.stop());
  } catch (err) {
    console.warn('Permiso de micrófono no disponible:', err.message);
    // Continue: enumerate devices anyway (labels may be empty)
  }

  try {
    const devices = await navigator.mediaDevices.enumerateDevices();
    const inputSelect = document.getElementById('inputDevice');
    const outputSelect = document.getElementById('outputDevice');
    inputSelect.innerHTML = '';
    outputSelect.innerHTML = '';

    const inputs = devices.filter((d) => d.kind === 'audioinput');
    const outputs = devices.filter((d) => d.kind === 'audiooutput');

    if (inputs.length === 0) {
      inputSelect.add(new Option('No disponible', ''));
      inputSelect.disabled = true;
    } else {
      inputs.forEach((d, i) => {
        inputSelect.add(new Option(d.label || `Micrófono ${i + 1}`, d.deviceId));
      });
    }

    if (outputs.length === 0) {
      outputSelect.add(new Option('No disponible', ''));
      outputSelect.disabled = true;
    } else {
      outputs.forEach((d, i) => {
        outputSelect.add(new Option(d.label || `Salida ${i + 1}`, d.deviceId));
      });
    }

    selectedInputDeviceId = inputSelect.value;
    selectedOutputDeviceId = outputSelect.value;
  } catch (err) {
    console.error('No se pueden enumerar dispositivos:', err);
  }
}

function onInputDeviceChange(e) {
  selectedInputDeviceId = e.target.value;
  // Device change requires reconnecting talk handles for new mic
  // For now, log a notice
  console.log('Input device changed to:', selectedInputDeviceId);
}

function onOutputDeviceChange(e) {
  selectedOutputDeviceId = e.target.value;
  const audio = document.getElementById('remoteAudio');
  if (audio.setSinkId) {
    audio.setSinkId(selectedOutputDeviceId).catch((err) =>
      console.error('setSinkId error:', err)
    );
  }
}

// ======================== PTT MODE ========================

function getTargetMode(targetKey) {
  return targetPttModes.get(targetKey) || 'no-latch';
}

// ======================== TARGETS ========================

async function loadTargets() {
  targets = await API.get('/api/rooms/my-targets');
  renderTargets();
}

function renderTargets() {
  const userGrid = document.getElementById('userTargets');
  const bridgeGrid = document.getElementById('bridgeTargets');
  const groupGrid = document.getElementById('groupTargets');

  // Separate users and bridges
  const regularUsers = targets.users.filter(u => u.role !== 'bridge');
  const bridgeUsers = targets.users.filter(u => u.role === 'bridge');

  const renderUserBtn = (u) => `
    <div class="ptt-btn${u.role === 'bridge' ? ' bridge-target' : ''}" data-type="user" data-id="${u.id}" data-room="${u.room_id}">
      <div class="ptt-mode-btns">
        <button class="mode-btn active" data-mode="no-latch" title="Mantener pulsado">M</button>
        <button class="mode-btn" data-mode="latch" title="Click para alternar">L</button>
      </div>
      <div class="name"><span class="online-indicator" id="online-${u.id}"></span>${u.display_name}</div>
      <div class="status">${u.username}</div>
    </div>`;

  userGrid.innerHTML =
    regularUsers.map(renderUserBtn).join('') ||
    '<p style="color:var(--text-light);font-size:0.875rem">Sin permisos asignados</p>';

  // Bridge section (hide header if no bridges)
  bridgeGrid.innerHTML = bridgeUsers.map(renderUserBtn).join('');
  bridgeGrid.closest('.targets-section').style.display = bridgeUsers.length ? '' : 'none';

  groupGrid.innerHTML =
    targets.groups
      .map(
        (g) => `
    <div class="ptt-btn" data-type="group" data-id="${g.id}" data-rooms="${(g.member_rooms || []).join(',')}">
      <div class="ptt-mode-btns">
        <button class="mode-btn active" data-mode="no-latch" title="Mantener pulsado">M</button>
        <button class="mode-btn" data-mode="latch" title="Click para alternar">L</button>
      </div>
      <div class="name">${g.name}</div>
      <div class="status">${(g.member_rooms || []).length} usuarios</div>
    </div>`
      )
      .join('') || '<p style="color:var(--text-light);font-size:0.875rem">Sin grupos asignados</p>';

  // Attach PTT + mode toggle event listeners
  document.querySelectorAll('.ptt-btn').forEach((btn) => {
    const targetType = btn.dataset.type;
    const targetId = parseInt(btn.dataset.id);
    const targetKey = `${targetType}-${targetId}`;

    // Per-target mode toggle
    btn.querySelectorAll('.mode-btn').forEach((modeBtn) => {
      modeBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        const mode = modeBtn.dataset.mode;
        targetPttModes.set(targetKey, mode);
        btn.querySelectorAll('.mode-btn').forEach((b) => {
          b.classList.toggle('active', b.dataset.mode === mode);
        });
        if (isTalking && currentTarget?.type === targetType && currentTarget?.id === targetId) {
          stopTalking(btn);
        }
      });
      modeBtn.addEventListener('mousedown', (e) => e.stopPropagation());
      modeBtn.addEventListener('touchstart', (e) => e.stopPropagation());
    });

    // PTT handlers
    btn.addEventListener('mousedown', (e) => {
      if (e.target.closest('.mode-btn')) return;
      if (getTargetMode(targetKey) === 'no-latch') startTalking(targetType, targetId, btn);
    });
    btn.addEventListener('mouseup', (e) => {
      if (e.target.closest('.mode-btn')) return;
      if (getTargetMode(targetKey) === 'no-latch') stopTalking(btn);
    });
    btn.addEventListener('mouseleave', () => {
      if (getTargetMode(targetKey) === 'no-latch' && isTalking && currentTarget?.id === targetId) {
        stopTalking(btn);
      }
    });
    btn.addEventListener('click', (e) => {
      if (e.target.closest('.mode-btn')) return;
      if (getTargetMode(targetKey) === 'latch') toggleTalking(targetType, targetId, btn);
    });
    btn.addEventListener('touchstart', (e) => {
      if (e.target.closest('.mode-btn')) return;
      e.preventDefault();
      if (getTargetMode(targetKey) === 'no-latch') startTalking(targetType, targetId, btn);
    }, { passive: false });
    btn.addEventListener('touchend', (e) => {
      if (e.target.closest('.mode-btn')) return;
      e.preventDefault();
      const mode = getTargetMode(targetKey);
      if (mode === 'no-latch') stopTalking(btn);
      else if (mode === 'latch') toggleTalking(targetType, targetId, btn);
    }, { passive: false });
  });

  updateOnlineIndicators();
}

// ======================== JANUS ========================

function initJanus() {
  if (typeof Janus === 'undefined') {
    console.error('Janus.js no cargado');
    return;
  }

  Janus.init({
    debug: false,
    callback: () => {
      const wsUrl = `${location.protocol === 'https:' ? 'wss:' : 'ws:'}//${location.host}/janus-ws`;

      janus = new Janus({
        server: wsUrl,
        apisecret: 'janussecret',
        success: () => {
          console.log('Janus conectado');
          setJanusStatus(true);
          setupListenHandle();
          setupTalkHandles();
          startStats();
        },
        error: (err) => {
          console.error('Janus error:', err);
          setJanusStatus(false);
          setTimeout(initJanus, 5000);
        },
        destroyed: () => {
          console.log('Janus destruido');
          setJanusStatus(false);
        },
      });
    },
  });
}

function setJanusStatus(connected) {
  const dot = document.getElementById('janusStatus');
  dot.classList.toggle('connected', connected);
  dot.title = connected ? 'Janus conectado' : 'Janus desconectado';
}

// ---- Listen Handle: own room, receive-only ----

function setupListenHandle() {
  const user = API.getUser();

  janus.attach({
    plugin: 'janus.plugin.audiobridge',
    success: (handle) => {
      listenHandle = handle;
      console.log('Listen handle creado');
      handle.send({
        message: {
          request: 'join',
          room: user.room_id,
          display: user.display_name,
          muted: true,
        },
      });
    },
    error: (err) => console.error('Listen handle error:', err),

    onmessage: (msg, jsep) => {
      // Joined own room - complete WebRTC handshake
      if (jsep) {
        listenHandle.createAnswer({
          jsep: jsep,
          media: { audio: true, video: false },
          success: (ourJsep) => {
            listenHandle.send({
              message: { request: 'configure', muted: true },
              jsep: ourJsep,
            });
          },
          error: (err) => console.error('Listen answer error:', err),
        });
      }

      // Detect talking events in our room
      if (msg.audiobridge === 'talking') {
        showIncomingAudio(msg.display || 'Alguien');
      }
      if (msg.audiobridge === 'stopped-talking') {
        hideIncomingAudio();
      }
    },

    onremotetrack: (track, mid, on) => {
      if (track.kind === 'audio' && on) {
        const audio = document.getElementById('remoteAudio');
        if (!audio.srcObject) {
          audio.srcObject = new MediaStream();
        }
        audio.srcObject.addTrack(track);
        audio.play().catch(() => {});

        if (selectedOutputDeviceId && audio.setSinkId) {
          audio.setSinkId(selectedOutputDeviceId).catch(() => {});
        }
      }
    },

    oncleanup: () => {
      console.log('Listen handle cleanup');
    },
  });
}

// ---- Talk Handles: one per target room, pre-joined muted ----

function setupTalkHandles() {
  const user = API.getUser();
  const allRoomIds = new Set();

  targets.users.forEach((u) => {
    if (u.room_id && u.room_id !== user.room_id) allRoomIds.add(u.room_id);
  });
  targets.groups.forEach((g) => {
    (g.member_rooms || []).forEach((r) => {
      if (r !== user.room_id) allRoomIds.add(r);
    });
  });

  console.log(`Creando ${allRoomIds.size} talk handles`);

  for (const roomId of allRoomIds) {
    createTalkHandle(roomId);
  }
}

function createTalkHandle(roomId) {
  const user = API.getUser();

  janus.attach({
    plugin: 'janus.plugin.audiobridge',
    success: (handle) => {
      talkHandles.set(roomId, { handle: handle, ready: false });
      handle.send({
        message: {
          request: 'join',
          room: roomId,
          display: user.display_name,
          muted: true,
        },
      });
    },
    error: (err) => console.error(`Talk handle error (room ${roomId}):`, err),

    onmessage: (msg, jsep) => {
      if (jsep) {
        const entry = talkHandles.get(roomId);
        if (!entry) return;

        const audioConstraints = selectedInputDeviceId
          ? { deviceId: { exact: selectedInputDeviceId } }
          : true;

        entry.handle.createAnswer({
          jsep: jsep,
          media: { audio: audioConstraints, video: false },
          success: (ourJsep) => {
            entry.handle.send({
              message: { request: 'configure', muted: true },
              jsep: ourJsep,
            });
            entry.ready = true;
            console.log(`Talk handle listo para sala ${roomId}`);
          },
          error: (err) => console.error(`Talk answer error (room ${roomId}):`, err),
        });
      }

      if (msg.audiobridge === 'event' && msg.error) {
        console.error(`AudioBridge error sala ${roomId}:`, msg.error);
      }
    },

    onremotetrack: () => {
      // Ignore: we don't play audio from rooms we're talking to
    },

    oncleanup: () => {
      const entry = talkHandles.get(roomId);
      if (entry) entry.ready = false;
    },
  });
}

// ======================== PTT ACTIONS ========================

function getRoomIdsForTarget(targetType, targetId) {
  const user = API.getUser();

  if (targetType === 'user') {
    const targetUser = targets.users.find((u) => u.id === targetId);
    return targetUser ? [targetUser.room_id] : [];
  }

  if (targetType === 'group') {
    const targetGroup = targets.groups.find((g) => g.id === targetId);
    if (!targetGroup) return [];
    // Filter out own room
    return (targetGroup.member_rooms || []).filter((r) => r !== user.room_id);
  }

  return [];
}

function startTalking(targetType, targetId, btn) {
  if (isTalking) return;
  isTalking = true;
  currentTarget = { type: targetType, id: targetId };
  btn.classList.add('talking');

  // Unmute in target rooms (WebRTC)
  const roomIds = getRoomIdsForTarget(targetType, targetId);
  activeTalkRoomIds = roomIds;

  for (const roomId of roomIds) {
    const entry = talkHandles.get(roomId);
    if (entry && entry.ready) {
      entry.handle.send({ message: { request: 'configure', muted: false } });
    }
  }

  // Notify via signaling WebSocket
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ type: 'ptt_start', targetType, targetId }));
  }
}

function stopTalking(btn) {
  if (!isTalking) return;
  isTalking = false;
  btn.classList.remove('talking');

  // Mute in all active rooms (WebRTC)
  for (const roomId of activeTalkRoomIds) {
    const entry = talkHandles.get(roomId);
    if (entry && entry.ready) {
      entry.handle.send({ message: { request: 'configure', muted: true } });
    }
  }

  // Notify via signaling WebSocket
  if (ws && ws.readyState === WebSocket.OPEN && currentTarget) {
    ws.send(
      JSON.stringify({ type: 'ptt_stop', targetType: currentTarget.type, targetId: currentTarget.id })
    );
  }

  activeTalkRoomIds = [];
  currentTarget = null;
}

function toggleTalking(targetType, targetId, btn) {
  if (isTalking && currentTarget?.type === targetType && currentTarget?.id === targetId) {
    stopTalking(btn);
  } else {
    stopAllTalking();
    startTalking(targetType, targetId, btn);
  }
}

function stopAllTalking() {
  if (!isTalking) return;

  document.querySelectorAll('.ptt-btn.talking').forEach((b) => b.classList.remove('talking'));

  for (const roomId of activeTalkRoomIds) {
    const entry = talkHandles.get(roomId);
    if (entry && entry.ready) {
      entry.handle.send({ message: { request: 'configure', muted: true } });
    }
  }

  if (ws && ws.readyState === WebSocket.OPEN && currentTarget) {
    ws.send(
      JSON.stringify({ type: 'ptt_stop', targetType: currentTarget.type, targetId: currentTarget.id })
    );
  }

  isTalking = false;
  activeTalkRoomIds = [];
  currentTarget = null;
}

// ======================== WEBSOCKET ========================

function connectWebSocket() {
  const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
  ws = new WebSocket(`${protocol}//${location.host}/ws`);

  ws.onopen = () => {
    ws.send(JSON.stringify({ type: 'auth', token: API.getToken() }));
  };

  ws.onmessage = (event) => {
    const msg = JSON.parse(event.data);

    switch (msg.type) {
      case 'auth_ok':
        console.log('WebSocket autenticado');
        break;
      case 'online_users':
        onlineUsers = msg.userIds;
        updateOnlineIndicators();
        break;
      case 'incoming_audio':
        handleIncomingAudioWs(msg);
        break;
      case 'ptt_denied':
        console.log('PTT denegado');
        stopAllTalking();
        break;
    }
  };

  ws.onclose = () => {
    console.log('WebSocket desconectado, reconectando...');
    setTimeout(connectWebSocket, 3000);
  };
}

// ======================== UI UPDATES ========================

function updateOnlineIndicators() {
  targets.users.forEach((u) => {
    const el = document.getElementById(`online-${u.id}`);
    if (el) {
      el.classList.toggle('online', onlineUsers.includes(u.id));
    }
  });
}

function showIncomingAudio(displayName) {
  const indicator = document.getElementById('incomingAudio');
  const fromText = document.getElementById('incomingFrom');
  fromText.textContent = `Recibiendo audio de ${displayName}`;
  indicator.classList.add('active');
}

function hideIncomingAudio() {
  document.getElementById('incomingAudio').classList.remove('active');
}

function handleIncomingAudioWs(msg) {
  if (msg.talking) {
    const fromUser = targets.users.find((u) => u.id === msg.fromUserId);
    showIncomingAudio(fromUser ? fromUser.display_name : 'Usuario ' + msg.fromUserId);
  } else {
    hideIncomingAudio();
  }
}

// ======================== WEBRTC STATS ========================

function startStats() {
  stopStats();
  lastRxBytes = 0;
  lastTxBytes = 0;
  lastStatsTime = Date.now();
  statsInterval = setInterval(updateStats, 1000);
}

function stopStats() {
  if (statsInterval) {
    clearInterval(statsInterval);
    statsInterval = null;
  }
}

async function updateStats() {
  const now = Date.now();
  const elapsed = (now - lastStatsTime) / 1000;
  if (elapsed <= 0) return;

  let rxBytes = 0;
  let txBytes = 0;
  let listenPcState = 'none';
  let talkPcCount = 0;
  let talkPcReady = 0;

  try {
    // RX: listen handle (own room)
    const listenPc = listenHandle?.webrtcStuff?.pc;
    if (listenPc) {
      listenPcState = listenPc.connectionState || listenPc.iceConnectionState || '?';
      const stats = await listenPc.getStats();
      stats.forEach((report) => {
        if (report.type === 'inbound-rtp' && report.kind === 'audio') {
          rxBytes += report.bytesReceived || 0;
        }
      });
    }

    // TX: all talk handles
    for (const [, entry] of talkHandles) {
      talkPcCount++;
      const pc = entry.handle?.webrtcStuff?.pc;
      if (pc) {
        if (entry.ready) talkPcReady++;
        const stats = await pc.getStats();
        stats.forEach((report) => {
          if (report.type === 'outbound-rtp' && report.kind === 'audio') {
            txBytes += report.bytesSent || 0;
          }
        });
      }
    }
  } catch (err) {
    // Stats not available yet
    return;
  }

  const rxKbps = ((rxBytes - lastRxBytes) * 8 / 1000 / elapsed).toFixed(1);
  const txKbps = ((txBytes - lastTxBytes) * 8 / 1000 / elapsed).toFixed(1);

  const rxEl = document.getElementById('statsRx');
  const txEl = document.getElementById('statsTx');
  const detailEl = document.getElementById('statsDetail');
  if (rxEl) rxEl.textContent = rxKbps;
  if (txEl) txEl.textContent = txKbps;
  if (detailEl) detailEl.textContent = `Listen: ${listenPcState} | Talk: ${talkPcReady}/${talkPcCount} ready`;

  lastRxBytes = rxBytes;
  lastTxBytes = txBytes;
  lastStatsTime = now;
}
