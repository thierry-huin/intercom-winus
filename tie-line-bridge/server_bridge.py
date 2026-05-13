#!/usr/bin/env python3
"""Server-to-Server Bridge — Connect two Winus Intercom servers.

Each "link" creates a bridge user on Server A and another on Server B,
then pipes Opus RTP audio between them bidirectionally.  No audio
hardware is involved — it's a pure software relay.

Usage:
    python server_bridge.py                          # server_bridge.json
    python server_bridge.py --config my_bridge.json
"""

import argparse
import asyncio
import json
import os
import random
import signal
import socket
import ssl
import sys
import traceback

import aiohttp
import websockets

from rtp_handler import RtpSender, RtpReceiver

RECONNECT_DELAY = 5  # seconds between reconnect attempts

# Shared SSL context for self-signed certs
_ssl_ctx = ssl.create_default_context()
_ssl_ctx.check_hostname = False
_ssl_ctx.verify_mode = ssl.CERT_NONE


def _get_local_ip_for(remote_host: str) -> str:
    """Get the local IP used to reach a specific remote host."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((remote_host, 80))
        return s.getsockname()[0]
    except Exception:
        return "127.0.0.1"
    finally:
        s.close()


# ═══════════════════════════════════════════════════════════════
#  BridgeEndpoint — one side of a server-to-server link
# ═══════════════════════════════════════════════════════════════

class BridgeEndpoint:
    """Connects to a single Winus server as a bridge user and exposes
    raw RTP send/recv for forwarding."""

    def __init__(
        self,
        label: str,
        server_url: str,
        username: str,
        password: str,
        target_type: str,
        target_id: int,
        bridge_ip: str = "",
    ):
        self.label = label
        self.server_url = server_url.rstrip("/")
        self.username = username
        self.password = password
        self.target_type = target_type
        self.target_id = target_id
        self.bridge_ip = bridge_ip

        self.connected = False
        self.error = None
        self._token = None
        self._ws = None
        self._request_id = 0
        self._pending = {}
        self._send_transport_id = None
        self._recv_transport_id = None
        self._rtp_sender = None
        self._rtp_receiver = None
        self._producer_id = None
        self._ssrc = random.randint(1, 0xFFFFFFFF)
        self._running = False
        self._ws_reader_task = None
        self._rx_keepalive_task = None
        self._ptt_active = False
        self._ptt_retry_task = None

    async def connect(self):
        """Login, establish WebSocket, create transports, produce, start PTT."""
        tag = self.label

        # 1. HTTP Login
        async with aiohttp.ClientSession(
            connector=aiohttp.TCPConnector(ssl=False)
        ) as session:
            async with session.post(
                f"{self.server_url}/api/auth/login",
                json={
                    "username": self.username,
                    "password": self.password,
                    "client_type": "bridge",
                },
            ) as resp:
                data = await resp.json()
                if resp.status != 200:
                    self.error = data.get("error", f"HTTP {resp.status}")
                    print(f"[{tag}] Login failed: {self.error}")
                    return False
                self._token = data["token"]
        print(f"[{tag}] Logged in as {self.username}")

        # 2. WebSocket
        ws_url = (
            self.server_url.replace("https://", "wss://").replace(
                "http://", "ws://"
            )
            + "/ws"
        )
        self._ws = await websockets.connect(
            ws_url,
            ssl=_ssl_ctx,
            ping_interval=30,
            ping_timeout=60,
            close_timeout=5,
        )
        await self._ws_send({"type": "auth", "token": self._token})
        auth_msg = await self._ws_recv_type("auth_ok", timeout=5)
        if not auth_msg:
            self.error = "WS auth failed"
            print(f"[{tag}] WS auth failed")
            return False
        print(f"[{tag}] WS authenticated")

        self._ws_reader_task = asyncio.create_task(self._ws_reader())

        # 3. Router RTP capabilities
        caps = await self._ws_request("getRouterRtpCapabilities")
        rtp_caps = caps.get("rtpCapabilities", {})
        opus_codec = None
        for codec in rtp_caps.get("codecs", []):
            if codec.get("mimeType", "").lower() == "audio/opus":
                opus_codec = codec
                break
        if not opus_codec:
            self.error = "No Opus codec in router"
            return False

        client_caps = {
            "codecs": [opus_codec],
            "headerExtensions": rtp_caps.get("headerExtensions", []),
        }
        await self._ws_request(
            "setRtpCapabilities", {"rtpCapabilities": client_caps}
        )
        preferred_pt = opus_codec.get("preferredPayloadType", 100)

        # 4. Send PlainTransport + produce
        send_resp = await self._ws_request(
            "createPlainTransport", {"direction": "send"}
        )
        self._send_transport_id = send_resp["id"]
        send_ip = send_resp["ip"]
        send_port = send_resp["port"]

        rtp_params = {
            "codecs": [
                {
                    "mimeType": "audio/opus",
                    "payloadType": preferred_pt,
                    "clockRate": 48000,
                    "channels": 2,
                    "parameters": {"useinbandfec": 1, "sprop-stereo": 0},
                }
            ],
            "encodings": [{"ssrc": self._ssrc}],
        }
        produce_resp = await self._ws_request(
            "produce",
            {
                "transportId": self._send_transport_id,
                "kind": "audio",
                "rtpParameters": rtp_params,
            },
        )
        self._producer_id = produce_resp.get("id")

        # 5. Recv PlainTransport
        recv_resp = await self._ws_request(
            "createPlainTransport", {"direction": "recv"}
        )
        self._recv_transport_id = recv_resp["id"]
        recv_server_ip = recv_resp["ip"]
        recv_server_port = recv_resp["port"]

        # Start RTP receiver
        self._rtp_receiver = RtpReceiver(bind_port=0)
        local_port = await self._rtp_receiver.start()
        from urllib.parse import urlparse

        parsed = urlparse(self.server_url)
        recv_ip = self.bridge_ip or _get_local_ip_for(parsed.hostname)

        await self._ws_request(
            "connectPlainTransport",
            {
                "transportId": self._recv_transport_id,
                "ip": recv_ip,
                "port": local_port,
            },
        )

        # NAT keepalive
        keepalive_ip = (
            recv_server_ip
            if recv_server_ip != "0.0.0.0"
            else parsed.hostname
        )
        self._rtp_receiver.send_keepalive(keepalive_ip, recv_server_port)
        self._rx_keepalive_task = asyncio.create_task(
            self._rx_keepalive_loop(keepalive_ip, recv_server_port)
        )

        # 6. RTP sender
        send_dest_ip = send_ip if send_ip != "0.0.0.0" else parsed.hostname
        self._rtp_sender = RtpSender(
            dest_ip=send_dest_ip,
            dest_port=send_port,
            payload_type=preferred_pt,
            ssrc=self._ssrc,
        )
        await self._rtp_sender.start()

        self.connected = True
        print(
            f"[{tag}] ✓ Connected "
            f"(send→{send_dest_ip}:{send_port}, "
            f"recv←{recv_ip}:{local_port})"
        )

        # 7. Permanent PTT (open tie line)
        await self._ptt_start_with_retry()
        return True

    # ─── RTP forwarding helpers ───

    async def recv_opus(self, timeout: float = 0.5) -> bytes | None:
        """Receive one Opus payload from this server."""
        if not self._rtp_receiver:
            return None
        return await self._rtp_receiver.recv(timeout=timeout)

    def send_opus(self, opus_data: bytes):
        """Forward an Opus payload to this server."""
        if self._rtp_sender:
            self._rtp_sender.send(opus_data)

    # ─── PTT ───

    async def _ptt_start(self):
        try:
            await self._ws_send(
                {
                    "type": "ptt_start",
                    "targetType": self.target_type,
                    "targetId": self.target_id,
                }
            )
        except Exception as e:
            print(f"[{self.label}] PTT start error: {e}")

    async def _ptt_start_with_retry(self):
        await self._ptt_start()
        if not self._ptt_active:
            self._start_ptt_retry()

    def _start_ptt_retry(self):
        if self._ptt_retry_task and not self._ptt_retry_task.done():
            return
        self._ptt_retry_task = asyncio.ensure_future(self._ptt_retry_loop())

    async def _ptt_retry_loop(self):
        delay = 5
        while self._running and self.connected and not self._ptt_active:
            await asyncio.sleep(delay)
            if not self._running or not self.connected or self._ptt_active:
                break
            print(f"[{self.label}] PTT retry (backoff={delay}s)")
            await self._ptt_start()
            await asyncio.sleep(0.5)
            if not self._ptt_active:
                delay = min(delay * 2, 60)
            else:
                break

    async def _ptt_stop(self):
        if self._ptt_retry_task and not self._ptt_retry_task.done():
            self._ptt_retry_task.cancel()
            self._ptt_retry_task = None
        self._ptt_active = False
        try:
            await self._ws_send(
                {
                    "type": "ptt_stop",
                    "targetType": self.target_type,
                    "targetId": self.target_id,
                }
            )
        except Exception:
            pass

    # ─── WS helpers ───

    async def _ws_send(self, data: dict):
        if self._ws:
            await self._ws.send(json.dumps(data))

    async def _ws_request(self, msg_type: str, data: dict = None) -> dict:
        self._request_id += 1
        req_id = self._request_id
        payload = {"type": msg_type, "requestId": req_id}
        if data:
            payload.update(data)
        fut = asyncio.get_event_loop().create_future()
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

    async def _ws_recv_type(
        self, expected_type: str, timeout: float = 5.0
    ) -> dict | None:
        deadline = asyncio.get_event_loop().time() + timeout
        while asyncio.get_event_loop().time() < deadline:
            remaining = deadline - asyncio.get_event_loop().time()
            try:
                raw = await asyncio.wait_for(
                    self._ws.recv(), timeout=remaining
                )
                msg = json.loads(raw)
                if msg.get("type") == expected_type:
                    return msg
                req_id = msg.get("requestId")
                if req_id and req_id in self._pending:
                    self._pending[req_id].set_result(msg)
            except (asyncio.TimeoutError, websockets.ConnectionClosed):
                return None
        return None

    async def _ws_reader(self):
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
            if req_id and req_id in self._pending:
                fut = self._pending.get(req_id)
                if fut and not fut.done():
                    fut.set_result(msg)
                continue

            try:
                if msg_type == "newConsumer":
                    cid = msg.get("id")
                    await self._ws_send(
                        {"type": "resumeConsumer", "consumerId": cid}
                    )
                elif msg_type == "ptt_allowed":
                    self._ptt_active = True
                    print(f"[{self.label}] PTT allowed")
                elif msg_type == "ptt_denied":
                    self._ptt_active = False
                    reason = msg.get("reason", "?")
                    print(f"[{self.label}] PTT denied: {reason}")
                    if not self._ptt_active:
                        self._start_ptt_retry()
                elif msg_type == "transportClosed":
                    self.connected = False
                    break
                elif msg_type == "online_users":
                    online = msg.get("userIds", [])
                    if (
                        not self._ptt_active
                        and self.target_id in online
                    ):
                        if (
                            self._ptt_retry_task
                            and not self._ptt_retry_task.done()
                        ):
                            self._ptt_retry_task.cancel()
                            self._ptt_retry_task = None
                        await self._ptt_start()
                        if not self._ptt_active:
                            self._start_ptt_retry()
            except asyncio.CancelledError:
                raise
            except Exception as e:
                print(f"[{self.label}] WS handler error: {e}")

    async def _rx_keepalive_loop(
        self, dest_ip: str, dest_port: int, interval: float = 10.0
    ):
        try:
            while self._running and self._rtp_receiver:
                await asyncio.sleep(interval)
                if not self._running or not self._rtp_receiver:
                    return
                self._rtp_receiver.send_keepalive(dest_ip, dest_port)
        except asyncio.CancelledError:
            raise

    # ─── Lifecycle ───

    def start(self):
        self._running = True

    async def cleanup(self):
        self.connected = False
        try:
            await self._ptt_stop()
        except Exception:
            pass
        for task in (
            self._ws_reader_task,
            self._rx_keepalive_task,
            self._ptt_retry_task,
        ):
            if task and not task.done():
                task.cancel()
                try:
                    await task
                except (asyncio.CancelledError, Exception):
                    pass
        self._ws_reader_task = None
        self._rx_keepalive_task = None
        self._ptt_retry_task = None
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
        self._pending.clear()
        self._request_id = 0
        self._ptt_active = False
        print(f"[{self.label}] Disconnected")

    def stop(self):
        self._running = False


# ═══════════════════════════════════════════════════════════════
#  ServerBridgeLink — pairs two endpoints and pipes RTP
# ═══════════════════════════════════════════════════════════════

class ServerBridgeLink:
    """Bidirectional audio pipe between two BridgeEndpoints."""

    def __init__(self, label: str, endpoint_a: BridgeEndpoint, endpoint_b: BridgeEndpoint):
        self.label = label
        self.a = endpoint_a
        self.b = endpoint_b
        self._running = False

    async def run(self):
        """Connect both endpoints and pipe audio until stopped."""
        self._running = True
        self.a.start()
        self.b.start()

        while self._running:
            try:
                # Connect both sides
                print(f"\n[{self.label}] Connecting endpoints...")
                ok_a = await self.a.connect()
                if not ok_a:
                    print(f"[{self.label}] Endpoint A failed, retrying in {RECONNECT_DELAY}s")
                    await asyncio.sleep(RECONNECT_DELAY)
                    continue

                ok_b = await self.b.connect()
                if not ok_b:
                    print(f"[{self.label}] Endpoint B failed, retrying in {RECONNECT_DELAY}s")
                    await self.a.cleanup()
                    await asyncio.sleep(RECONNECT_DELAY)
                    continue

                print(f"[{self.label}] ✓ Both endpoints connected — forwarding audio")

                # Run bidirectional pipe
                await asyncio.gather(
                    self._forward(self.a, self.b, "A→B"),
                    self._forward(self.b, self.a, "B→A"),
                    self._watch_disconnect(),
                )
            except asyncio.CancelledError:
                break
            except Exception as e:
                print(f"[{self.label}] Error: {e}")
                traceback.print_exc()
            finally:
                await self.a.cleanup()
                await self.b.cleanup()

            if self._running:
                print(f"[{self.label}] Reconnecting in {RECONNECT_DELAY}s...")
                await asyncio.sleep(RECONNECT_DELAY)

    async def _forward(self, src: BridgeEndpoint, dst: BridgeEndpoint, direction: str):
        """Forward Opus RTP payloads from src to dst."""
        count = 0
        while self._running and src.connected and dst.connected:
            opus = await src.recv_opus(timeout=0.5)
            if opus is None:
                continue
            dst.send_opus(opus)
            count += 1
            if count == 1:
                print(f"[{self.label}] {direction} ★ First packet forwarded")
            elif count % 3000 == 0:
                print(f"[{self.label}] {direction} {count} packets forwarded")

    async def _watch_disconnect(self):
        """Exit when either endpoint disconnects."""
        while self._running and self.a.connected and self.b.connected:
            await asyncio.sleep(1)

    def stop(self):
        self._running = False
        self.a.stop()
        self.b.stop()


# ═══════════════════════════════════════════════════════════════
#  Main
# ═══════════════════════════════════════════════════════════════

def load_config(path: str) -> dict:
    with open(path) as f:
        return json.load(f)


async def run_server_bridge(config: dict):
    server_a = config["server_a"]
    server_b = config["server_b"]
    links_cfg = config.get("links", [])

    if not links_cfg:
        print("No links configured")
        return

    print(f"Server A: {server_a}")
    print(f"Server B: {server_b}")
    print(f"Links:    {len(links_cfg)}")
    print()

    links = []
    for i, lk in enumerate(links_cfg):
        label = lk.get("label", f"Link {i + 1}")
        ep_a = BridgeEndpoint(
            label=f"{label}/A",
            server_url=server_a,
            username=lk["a_username"],
            password=lk["a_password"],
            target_type=lk.get("a_target_type", "user"),
            target_id=lk.get("a_target_id", 0),
            bridge_ip=config.get("bridge_ip", ""),
        )
        ep_b = BridgeEndpoint(
            label=f"{label}/B",
            server_url=server_b,
            username=lk["b_username"],
            password=lk["b_password"],
            target_type=lk.get("b_target_type", "user"),
            target_id=lk.get("b_target_id", 0),
            bridge_ip=config.get("bridge_ip", ""),
        )
        links.append(ServerBridgeLink(label=label, endpoint_a=ep_a, endpoint_b=ep_b))

    # Graceful shutdown
    stop_event = asyncio.Event()

    def handle_signal():
        print("\nShutting down...")
        stop_event.set()
        for link in links:
            link.stop()

    loop = asyncio.get_event_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, handle_signal)

    # Run all links in parallel
    tasks = [asyncio.create_task(link.run()) for link in links]
    try:
        await asyncio.gather(*tasks, return_exceptions=True)
    finally:
        print("\nServer bridge stopped.")


def main():
    parser = argparse.ArgumentParser(
        description="Winus Intercom — Server-to-Server Bridge"
    )
    parser.add_argument(
        "--config",
        default="server_bridge.json",
        help="Config file (default: server_bridge.json)",
    )
    args = parser.parse_args()

    config_path = args.config
    if not os.path.isabs(config_path):
        script_dir = os.path.dirname(os.path.abspath(__file__))
        config_path = os.path.join(script_dir, config_path)

    if not os.path.exists(config_path):
        print(f"Config not found: {config_path}")
        print("Create server_bridge.json — example:")
        print(json.dumps(
            {
                "server_a": "https://server-a:8443",
                "server_b": "https://server-b:8443",
                "links": [
                    {
                        "label": "Studio A ↔ Studio B",
                        "a_username": "bridge_b_1",
                        "a_password": "changeme",
                        "a_target_type": "user",
                        "a_target_id": 5,
                        "b_username": "bridge_a_1",
                        "b_password": "changeme",
                        "b_target_type": "user",
                        "b_target_id": 3,
                    }
                ],
            },
            indent=2,
        ))
        sys.exit(1)

    config = load_config(config_path)
    print(f"Winus Server Bridge — {len(config.get('links', []))} link(s)")
    asyncio.run(run_server_bridge(config))


if __name__ == "__main__":
    main()
