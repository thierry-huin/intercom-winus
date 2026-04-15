from __future__ import annotations

"""Per-channel tie line: login, WebSocket signaling, PlainTransport, produce/consume, VOX, PTT."""

import asyncio
import json
import math
import random
import ssl
import socket

import traceback

import aiohttp
import websockets
import numpy as np

from opus_codec import OpusEncoder, OpusDecoder, FRAME_SIZE, SAMPLE_RATE
from rtp_handler import RtpSender, RtpReceiver
from audio_engine import AudioEngine, AudioDevicePool

RECONNECT_DELAY = 3  # seconds between reconnect attempts


def _get_local_ip() -> str:
    """Get this machine's LAN IP address."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except Exception:
        return "127.0.0.1"
    finally:
        s.close()


def _get_local_ip_for(remote_ip: str) -> str:
    """Get the local IP used to reach a specific remote host."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((remote_ip, 80))
        return s.getsockname()[0]
    except Exception:
        return _get_local_ip()
    finally:
        s.close()


# Shared SSL context for self-signed certs
_ssl_ctx = ssl.create_default_context()
_ssl_ctx.check_hostname = False
_ssl_ctx.verify_mode = ssl.CERT_NONE


class TieLineChannel:
    """Manages a single bidirectional tie line channel (one intercom user)."""

    def __init__(
        self,
        index: int,
        server_url: str,
        username: str,
        password: str,
        target_type: str,
        target_id: int,
        audio_pool: AudioDevicePool,
        input_device: int,
        input_channel: int,
        output_device: int,
        output_channel: int,
        vox_send_enabled: bool = False,
        vox_send_threshold_db: float = -40.0,
        vox_send_hold_ms: int = 300,
        vox_recv_enabled: bool = True,
        vox_recv_threshold_db: float = -40.0,
        vox_recv_hold_ms: int = 300,
        bridge_ip: str = "",
    ):
        self.index = index
        self.server_url = server_url.rstrip('/')
        self.username = username
        self.password = password
        self.target_type = target_type
        self.target_id = target_id
        self.bridge_ip = bridge_ip  # Optional: explicit IP for recv (e.g. Zerotier/Wireguard IP)
        self.audio_pool = audio_pool
        self.input_device = input_device
        self.input_channel = input_channel
        self.output_device = output_device
        self.output_channel = output_channel

        # VOX send config (MTX → Winus)
        self.vox_send_enabled = vox_send_enabled
        self.vox_send_threshold_db = vox_send_threshold_db
        self.vox_send_hold_ms = vox_send_hold_ms

        # VOX recv config (Winus → MTX)
        self.vox_recv_enabled = vox_recv_enabled
        self.vox_recv_threshold_db = vox_recv_threshold_db
        self.vox_recv_hold_ms = vox_recv_hold_ms

        # State — send direction
        self.connected = False
        self.vox_send_active = False
        self.level_send_db = -100.0
        self._ptt_permanent = False  # True when VOX send disabled (open tie line)

        # State — recv direction
        self.vox_recv_active = False
        self.level_recv_db = -100.0
        self.receiving = False
        self._error = None

        # Internals
        self._token = None
        self._ws = None
        self._request_id = 0
        self._pending = {}  # requestId → Future
        self._send_transport_id = None
        self._recv_transport_id = None
        self._send_port = None  # server's PlainTransport port for sending
        self._send_ip = None
        self._rtp_sender = None
        self._rtp_receiver = None
        self._encoder = None
        self._decoder = None
        self._producer_id = None
        self._ssrc = random.randint(1, 0xFFFFFFFF)
        self._running = False
        self._vox_send_hold_task = None
        self._vox_recv_hold_task = None
        self._ws_reader_task = None
        self._ptt_retry_task = None
        self._ptt_active = False  # True when server accepted our PTT

    @property
    def label(self):
        return f"CH{self.index + 1}"

    @property
    def error(self):
        return self._error

    # Legacy aliases so existing GUI code keeps working
    @property
    def vox_active(self):
        return self.vox_send_active

    @property
    def level_db(self):
        return self.level_send_db

    async def run(self):
        """Main channel loop with auto-reconnect."""
        self._running = True
        while self._running:
            try:
                await self._connect()
                if not self.connected:
                    if not self._running:
                        break
                    print(f"[{self.label}] Connection failed, retrying in {RECONNECT_DELAY}s...")
                    await asyncio.sleep(RECONNECT_DELAY)
                    continue
                # _ws_reader_task already started in _connect, run send+recv alongside it
                await asyncio.gather(
                    self._send_loop(),
                    self._recv_loop(),
                    self._ws_reader_task,
                )
            except asyncio.CancelledError:
                print(f"[{self.label}] *** run() CancelledError ***")
                break
            except Exception as e:
                self._error = str(e)
                print(f"[{self.label}] *** run() Exception: {e} ***")
                traceback.print_exc()
            finally:
                print(f"[{self.label}] *** gather exited, running cleanup ***")
                await self._cleanup_resources()

            if self._running:
                print(f"[{self.label}] Reconnecting in {RECONNECT_DELAY}s...")
                await asyncio.sleep(RECONNECT_DELAY)

    async def stop(self):
        print(f"[{self.label}] *** stop() called ***")
        self._running = False
        self.connected = False

    # ======================== CONNECT ========================

    async def _connect(self):
        """Login, establish WebSocket, create transports, produce."""
        tag = self.label

        # 1. HTTP Login
        api_url = self.server_url
        async with aiohttp.ClientSession(connector=aiohttp.TCPConnector(ssl=False)) as session:
            async with session.post(
                f"{api_url}/api/auth/login",
                json={"username": self.username, "password": self.password, "client_type": "bridge"},
            ) as resp:
                data = await resp.json()
                if resp.status != 200:
                    self._error = data.get('error', f'HTTP {resp.status}')
                    print(f"[{tag}] Login failed: {self._error}")
                    return
                self._token = data['token']
        print(f"[{tag}] Logged in as {self.username}")

        # 2. WebSocket connect
        ws_url = self.server_url.replace('https://', 'wss://').replace('http://', 'ws://') + '/ws'
        self._ws = await websockets.connect(
            ws_url, ssl=_ssl_ctx,
            ping_interval=30, ping_timeout=60,
            close_timeout=5,
        )

        # Auth
        await self._ws_send({"type": "auth", "token": self._token})
        auth_msg = await self._ws_recv_type("auth_ok", timeout=5)
        if not auth_msg:
            self._error = "WS auth failed"
            print(f"[{tag}] WS auth failed")
            return
        print(f"[{tag}] WS authenticated")

        # Start background WS reader so _ws_request responses are dispatched
        self._ws_reader_task = asyncio.create_task(self._ws_reader())

        # 3. Get router RTP capabilities
        caps = await self._ws_request("getRouterRtpCapabilities")
        rtp_caps = caps.get("rtpCapabilities", {})

        # 4. Set our RTP capabilities (Opus only)
        opus_codec = None
        for codec in rtp_caps.get("codecs", []):
            if codec.get("mimeType", "").lower() == "audio/opus":
                opus_codec = codec
                break
        if not opus_codec:
            self._error = "No Opus codec in router"
            print(f"[{tag}] No Opus codec found in router capabilities")
            return

        # Build client RTP capabilities — mirror back the router's Opus codec
        client_caps = {
            "codecs": [opus_codec],
            "headerExtensions": rtp_caps.get("headerExtensions", []),
        }
        await self._ws_request("setRtpCapabilities", {"rtpCapabilities": client_caps})

        # Get payload type from router capabilities
        preferred_pt = opus_codec.get("preferredPayloadType", 100)

        # 5. Create send PlainTransport
        send_resp = await self._ws_request("createPlainTransport", {"direction": "send"})
        self._send_transport_id = send_resp["id"]
        self._send_ip = send_resp["ip"]
        self._send_port = send_resp["port"]
        print(f"[{tag}] Send transport: {self._send_ip}:{self._send_port}")

        # 6. Produce
        rtp_params = {
            "codecs": [{
                "mimeType": "audio/opus",
                "payloadType": preferred_pt,
                "clockRate": 48000,
                "channels": 2,
                "parameters": {
                    "useinbandfec": 1,
                    "sprop-stereo": 0,
                },
            }],
            "encodings": [{"ssrc": self._ssrc}],
        }
        produce_resp = await self._ws_request("produce", {
            "transportId": self._send_transport_id,
            "kind": "audio",
            "rtpParameters": rtp_params,
        })
        self._producer_id = produce_resp.get("id")
        print(f"[{tag}] Producer created: {self._producer_id}")

        # 7. Create recv PlainTransport (comedia mode — server detects our IP)
        recv_resp = await self._ws_request("createPlainTransport", {"direction": "recv"})
        self._recv_transport_id = recv_resp["id"]
        recv_server_ip = recv_resp["ip"]
        recv_server_port = recv_resp["port"]
        print(f"[{tag}] Recv transport: {recv_server_ip}:{recv_server_port}")

        # 8. Start RTP receiver
        self._rtp_receiver = RtpReceiver(bind_port=0)
        local_port = await self._rtp_receiver.start()
        from urllib.parse import urlparse
        _parsed = urlparse(self.server_url)

        # Determine the IP to announce for recv transport
        if self.bridge_ip:
            recv_ip = self.bridge_ip
        else:
            recv_ip = _get_local_ip_for(_parsed.hostname)

        await self._ws_request("connectPlainTransport", {
            "transportId": self._recv_transport_id,
            "ip": recv_ip,
            "port": local_port,
        })
        print(f"[{tag}] Recv connected: {recv_ip}:{local_port}")

        # 9. Start RTP sender
        # The server IP might be 0.0.0.0 — use the server's announced IP or hostname
        send_dest_ip = self._send_ip
        if send_dest_ip == "0.0.0.0":
            parsed = urlparse(self.server_url)
            send_dest_ip = parsed.hostname
        self._rtp_sender = RtpSender(
            dest_ip=send_dest_ip,
            dest_port=self._send_port,
            payload_type=preferred_pt,
            ssrc=self._ssrc,
        )
        await self._rtp_sender.start()

        # 10. Init codecs
        self._encoder = OpusEncoder(bitrate=32000)
        self._decoder = OpusDecoder()

        self.connected = True
        print(f"[{tag}] \u2713 Connected (send\u2192{send_dest_ip}:{self._send_port}, recv\u2190{recv_ip}:{local_port})")

        # If VOX send is disabled → open tie line (permanent PTT)
        if not self.vox_send_enabled:
            self._ptt_permanent = True
            await self._ptt_start_with_retry()
            print(f"[{tag}] VOX send OFF → PTT permanente")

    # ======================== AUDIO LOOPS ========================

    async def _send_loop(self):
        """Read audio from input channel → Opus encode → RTP send. Handles send VOX."""
        while self._running and self.connected:
            try:
                frame = self.audio_pool.read_input(self.input_device, self.input_channel)
                if frame is None:
                    await asyncio.sleep(0.005)  # ~5ms poll
                    continue

                # Update send level and VOX (only if VOX send is enabled)
                self._update_send_level(frame)
                if self.vox_send_enabled:
                    self._update_vox_send(frame)

                # Always encode and send (mediasoup producer is paused server-side until PTT)
                opus_data = self._encoder.encode(frame)
                self._rtp_sender.send(opus_data)

                # Yield to event loop so WS reader and pings can run
                await asyncio.sleep(0)
            except asyncio.CancelledError:
                raise
            except Exception as e:
                print(f"[{self.label}] send_loop error: {e}")
                await asyncio.sleep(0.02)

    async def _recv_loop(self):
        """Receive RTP → Opus decode → write to output channel. Handles recv VOX."""
        _rx_count = 0
        _last_rx_time = 0.0
        _fade_in_frames = 2  # Number of frames to fade in after a gap (anti-click)
        _fade_count = 0
        while self._running and self.connected:
            try:
                opus_data = await self._rtp_receiver.recv(timeout=0.5)
                if opus_data is None:
                    continue

                _rx_count += 1
                now = asyncio.get_event_loop().time()

                if _rx_count == 1:
                    print(f"[{self.label}] ★ First RTP packet received ({len(opus_data)} bytes)")
                elif _rx_count % 500 == 0:
                    print(f"[{self.label}] RTP rx: {_rx_count} packets, level={self.level_recv_db:.1f}dB")

                # Detect gap (>100ms since last packet) → apply fade-in to avoid click
                gap = now - _last_rx_time if _last_rx_time > 0 else 0
                if gap > 0.1:
                    _fade_count = _fade_in_frames
                    # Drain stale packets from queue to avoid buffer bloat
                    drained = 0
                    while not self._rtp_receiver._protocol.queue.empty() and drained < 20:
                        try:
                            self._rtp_receiver._protocol.queue.get_nowait()
                            drained += 1
                        except Exception:
                            break
                    if drained > 0:
                        print(f"[{self.label}] Drained {drained} stale RTP packets after {gap*1000:.0f}ms gap")
                _last_rx_time = now

                pcm = self._decoder.decode(opus_data)

                # Apply fade-in ramp to avoid click after PTT transition
                if _fade_count > 0:
                    ramp = np.linspace(0.0, 1.0, len(pcm), dtype=np.float32)
                    if _fade_count > 1:
                        ramp *= (_fade_in_frames - _fade_count + 1) / _fade_in_frames
                    pcm = pcm * ramp
                    _fade_count -= 1

                # Update recv level
                self._update_recv_level(pcm)

                if self.vox_recv_enabled:
                    # Only write to output when recv VOX is active
                    self._update_vox_recv(pcm)
                    if self.vox_recv_active:
                        self.audio_pool.write_output(self.output_device, self.output_channel, pcm)
                else:
                    # Pass-through: always write received audio to output
                    self.audio_pool.write_output(self.output_device, self.output_channel, pcm)
            except asyncio.CancelledError:
                raise
            except Exception as e:
                print(f"[{self.label}] recv_loop error: {e}")
                await asyncio.sleep(0.02)

    # ======================== VOX ========================

    def _update_send_level(self, frame: np.ndarray):
        """Update send audio level."""
        rms = np.sqrt(np.mean(frame ** 2))
        self.level_send_db = 20 * math.log10(max(rms, 1e-10))

    def _update_recv_level(self, frame: np.ndarray):
        """Update recv audio level."""
        rms = np.sqrt(np.mean(frame ** 2))
        self.level_recv_db = 20 * math.log10(max(rms, 1e-10))

    def _update_vox_send(self, frame: np.ndarray):
        """Update send VOX state and trigger PTT accordingly."""
        if self.level_send_db > self.vox_send_threshold_db:
            if not self.vox_send_active:
                self.vox_send_active = True
                asyncio.ensure_future(self._ptt_start())
            # Cancel any pending hold-off
            if self._vox_send_hold_task and not self._vox_send_hold_task.done():
                self._vox_send_hold_task.cancel()
                self._vox_send_hold_task = None
        else:
            if self.vox_send_active and (self._vox_send_hold_task is None or self._vox_send_hold_task.done()):
                self._vox_send_hold_task = asyncio.ensure_future(self._vox_send_hold_off())

    def _update_vox_recv(self, frame: np.ndarray):
        """Update recv VOX state (gates audio output to MTX)."""
        if self.level_recv_db > self.vox_recv_threshold_db:
            if not self.vox_recv_active:
                self.vox_recv_active = True
                print(f"[{self.label}] VOX recv → open")
            # Cancel any pending hold-off
            if self._vox_recv_hold_task and not self._vox_recv_hold_task.done():
                self._vox_recv_hold_task.cancel()
                self._vox_recv_hold_task = None
        else:
            if self.vox_recv_active and (self._vox_recv_hold_task is None or self._vox_recv_hold_task.done()):
                self._vox_recv_hold_task = asyncio.ensure_future(self._vox_recv_hold_off())

    async def _vox_send_hold_off(self):
        """Wait hold_ms then stop PTT if still below threshold."""
        await asyncio.sleep(self.vox_send_hold_ms / 1000.0)
        if self.vox_send_active:
            self.vox_send_active = False
            await self._ptt_stop()

    async def _vox_recv_hold_off(self):
        """Wait hold_ms then close recv VOX gate."""
        await asyncio.sleep(self.vox_recv_hold_ms / 1000.0)
        if self.vox_recv_active:
            self.vox_recv_active = False
            print(f"[{self.label}] VOX recv → closed")

    async def _ptt_start(self):
        try:
            await self._ws_send({
                "type": "ptt_start",
                "targetType": self.target_type,
                "targetId": self.target_id,
            })
            print(f"[{self.label}] VOX → PTT start → {self.target_type}:{self.target_id}")
        except Exception as e:
            print(f"[{self.label}] PTT start error: {e}")

    async def _ptt_start_with_retry(self):
        """Start PTT with automatic retry if target is not ready.

        Used for permanent-PTT channels (vox_send_enabled=False).
        Retries every 5s until the target has a recv transport.
        """
        await self._ptt_start()
        # _ptt_active is set to True/False by _ws_reader when ptt_allowed/ptt_denied arrives.
        # If denied, _ptt_retry_loop will keep trying.
        if not self._ptt_active:
            self._start_ptt_retry()

    def _start_ptt_retry(self):
        """Launch background task to retry PTT periodically."""
        if self._ptt_retry_task and not self._ptt_retry_task.done():
            return  # Already retrying
        self._ptt_retry_task = asyncio.ensure_future(self._ptt_retry_loop())

    async def _ptt_retry_loop(self):
        """Retry PTT with exponential backoff (5s, 10s, 20s, 40s, max 60s)."""
        delay = 5
        while self._running and self.connected and self._ptt_permanent and not self._ptt_active:
            await asyncio.sleep(delay)
            if not self._running or not self.connected or self._ptt_active:
                break
            print(f"[{self.label}] PTT retry (backoff={delay}s) → {self.target_type}:{self.target_id}")
            await self._ptt_start()
            # Give server time to respond
            await asyncio.sleep(0.5)
            # Exponential backoff, cap at 60s
            if not self._ptt_active:
                delay = min(delay * 2, 60)
            else:
                break
        if self._ptt_active:
            print(f"[{self.label}] ✓ PTT retry succeeded")

    async def _ptt_stop(self):
        # Cancel any pending PTT retry
        if self._ptt_retry_task and not self._ptt_retry_task.done():
            self._ptt_retry_task.cancel()
            self._ptt_retry_task = None
        self._ptt_active = False
        try:
            await self._ws_send({
                "type": "ptt_stop",
                "targetType": self.target_type,
                "targetId": self.target_id,
            })
            print(f"[{self.label}] VOX → PTT stop")
        except Exception as e:
            print(f"[{self.label}] PTT stop error: {e}")

    # ======================== WS MESSAGE HANDLING ========================

    async def _ws_reader(self):
        """Background task: read all WS messages, dispatch responses and handle pushed messages."""
        while self._running and self._ws:
            try:
                raw = await asyncio.wait_for(self._ws.recv(), timeout=1.0)
            except asyncio.TimeoutError:
                continue
            except websockets.ConnectionClosed:
                print(f"[{self.label}] WS disconnected")
                self.connected = False
                break
            except Exception:
                continue

            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                continue

            msg_type = msg.get("type")
            req_id = msg.get("requestId")

            # Response to a pending request
            if req_id and req_id in self._pending:
                fut = self._pending.get(req_id)
                if fut and not fut.done():
                    fut.set_result(msg)
                continue

            # Server-pushed messages
            try:
                if msg_type == "newConsumer":
                    await self._handle_new_consumer(msg)
                elif msg_type == "consumersClosed":
                    cids = msg.get("consumerIds", [])
                    print(f"[{self.label}] Consumers closed from peer {msg.get('peerId')}: {len(cids)} ids")
                    self.receiving = False
                elif msg_type == "incoming_audio":
                    talking = msg.get("talking", False)
                    who = msg.get("fromDisplayName", msg.get("fromUserId", "?"))
                    if talking != self.receiving:
                        print(f"[{self.label}] Incoming audio: {'start' if talking else 'stop'} from {who}")
                    self.receiving = talking
                elif msg_type == "ptt_allowed":
                    self._ptt_active = True
                    print(f"[{self.label}] PTT allowed")
                elif msg_type == "ptt_denied":
                    self._ptt_active = False
                    reason = msg.get('reason', 'no permission')
                    print(f"[{self.label}] PTT denied: {reason}")
                    # Auto-retry for permanent PTT channels
                    if self._ptt_permanent and not self._ptt_active:
                        self._start_ptt_retry()
                elif msg_type == "transportClosed":
                    print(f"[{self.label}] Transport closed: {msg.get('direction')}")
                    self.connected = False
                    break
                elif msg_type == "online_users":
                    # If our target just came online and we have pending PTT, retry immediately
                    if self._ptt_permanent and not self._ptt_active:
                        online_ids = msg.get('userIds', [])
                        if self.target_id in online_ids:
                            # Cancel backoff retry and try immediately
                            if self._ptt_retry_task and not self._ptt_retry_task.done():
                                self._ptt_retry_task.cancel()
                                self._ptt_retry_task = None
                            print(f"[{self.label}] Target {self.target_id} came online, retrying PTT now")
                            await self._ptt_start()
                            if not self._ptt_active:
                                self._start_ptt_retry()  # Restart with fresh backoff
            except asyncio.CancelledError:
                raise
            except Exception as e:
                print(f"[{self.label}] WS handler error ({msg_type}): {e}")
                traceback.print_exc()

    async def _handle_new_consumer(self, msg):
        """Handle incoming consumer — resume it so audio flows to our recv transport."""
        consumer_id = msg.get("id")
        producer_peer = msg.get("producerPeerId")
        kind = msg.get("kind", "?")
        print(f"[{self.label}] ★ New consumer: {consumer_id} kind={kind} from peer={producer_peer}")
        try:
            await self._ws_send({"type": "resumeConsumer", "consumerId": consumer_id})
            print(f"[{self.label}] Consumer resumed OK")
        except Exception as e:
            print(f"[{self.label}] resumeConsumer send error: {e}")

    # ======================== WS HELPERS ========================

    async def _ws_send(self, data: dict):
        if self._ws:
            await self._ws.send(json.dumps(data))

    async def _ws_request(self, msg_type: str, data: dict = None) -> dict:
        """Send a request and wait for the response (resolved by _ws_reader)."""
        self._request_id += 1
        req_id = self._request_id
        payload = {"type": msg_type, "requestId": req_id}
        if data:
            payload.update(data)

        loop = asyncio.get_event_loop()
        fut = loop.create_future()
        self._pending[req_id] = fut

        await self._ws_send(payload)

        try:
            result = await asyncio.wait_for(fut, timeout=10.0)
        except asyncio.TimeoutError:
            self._pending.pop(req_id, None)
            raise TimeoutError(f"WS request '{msg_type}' timed out")
        finally:
            self._pending.pop(req_id, None)

        if result.get("type") == "error":
            raise RuntimeError(f"Server error: {result.get('error')}")
        return result

    async def _ws_recv_type(self, expected_type: str, timeout: float = 5.0) -> dict | None:
        """Receive messages until we get one with the expected type."""
        deadline = asyncio.get_event_loop().time() + timeout
        while asyncio.get_event_loop().time() < deadline:
            remaining = deadline - asyncio.get_event_loop().time()
            try:
                raw = await asyncio.wait_for(self._ws.recv(), timeout=remaining)
                msg = json.loads(raw)
                if msg.get("type") == expected_type:
                    return msg
                # Dispatch request responses that may arrive during auth
                req_id = msg.get("requestId")
                if req_id and req_id in self._pending:
                    self._pending[req_id].set_result(msg)
            except (asyncio.TimeoutError, websockets.ConnectionClosed):
                return None
        return None

    # ======================== CLEANUP ========================

    async def _cleanup_resources(self):
        """Clean up connections and resources (does not stop the channel)."""
        self.connected = False

        # Stop PTT if active — either VOX-triggered or permanent (while WS is still open)
        if self.vox_send_active or self._ptt_permanent:
            try:
                await self._ptt_stop()
            except Exception:
                pass
            self.vox_send_active = False
            self._ptt_permanent = False

        if self._ws_reader_task and not self._ws_reader_task.done():
            self._ws_reader_task.cancel()
            try:
                await self._ws_reader_task
            except (asyncio.CancelledError, Exception):
                pass
            self._ws_reader_task = None

        if self._rtp_sender:
            self._rtp_sender.stop()
            self._rtp_sender = None
        if self._rtp_receiver:
            self._rtp_receiver.stop()
            self._rtp_receiver = None
        if self._ws:
            try:
                await self._ws.close()
            except Exception:
                pass
            self._ws = None

        # Cancel PTT retry task
        if self._ptt_retry_task and not self._ptt_retry_task.done():
            self._ptt_retry_task.cancel()
            try:
                await self._ptt_retry_task
            except (asyncio.CancelledError, Exception):
                pass
            self._ptt_retry_task = None
        self._ptt_active = False

        # Destroy codecs properly to free native memory
        if self._encoder:
            self._encoder.destroy()
            self._encoder = None
        if self._decoder:
            self._decoder.destroy()
            self._decoder = None
        self._producer_id = None
        self._send_transport_id = None
        self._recv_transport_id = None
        self._pending.clear()
        self._request_id = 0

        print(f"[{self.label}] Disconnected")
