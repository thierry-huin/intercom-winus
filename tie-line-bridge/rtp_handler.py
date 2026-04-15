from __future__ import annotations

"""RTP packetization/depacketization and async UDP transport."""

import asyncio
import socket
import struct
import random

FRAME_SIZE = 960  # 20ms at 48kHz
TIMESTAMP_INCREMENT = FRAME_SIZE  # Opus at 48kHz


class RtpSender:
    """Sends RTP packets over UDP."""

    def __init__(self, dest_ip: str, dest_port: int, payload_type: int = 100, ssrc: int | None = None):
        self.dest = (dest_ip, dest_port)
        self.pt = payload_type
        self.ssrc = ssrc or random.randint(1, 0xFFFFFFFF)
        self.seq = random.randint(0, 0xFFFF)
        self.timestamp = random.randint(0, 0xFFFFFFFF)
        self._transport = None
        self._protocol = None

    async def start(self):
        loop = asyncio.get_event_loop()
        self._transport, self._protocol = await loop.create_datagram_endpoint(
            lambda: _UdpProtocol(),
            family=socket.AF_INET,
        )

    def send(self, opus_payload: bytes):
        if not self._transport:
            return
        header = self._build_header()
        self._transport.sendto(header + opus_payload, self.dest)
        self.seq = (self.seq + 1) & 0xFFFF
        self.timestamp = (self.timestamp + TIMESTAMP_INCREMENT) & 0xFFFFFFFF

    def _build_header(self) -> bytes:
        # V=2, P=0, X=0, CC=0 → first byte = 0x80
        # M=0, PT → second byte
        return struct.pack(
            '!BBHII',
            0x80,           # V=2, P=0, X=0, CC=0
            self.pt & 0x7F, # M=0, PT
            self.seq,
            self.timestamp,
            self.ssrc,
        )

    def stop(self):
        if self._transport:
            self._transport.close()
            self._transport = None


class RtpReceiver:
    """Receives RTP packets on a UDP port."""

    def __init__(self, bind_port: int = 0):
        self.bind_port = bind_port
        self.actual_port = 0
        self._transport = None
        self._protocol = None

    async def start(self) -> int:
        """Start listening. Returns the actual bound port."""
        loop = asyncio.get_event_loop()
        self._transport, self._protocol = await loop.create_datagram_endpoint(
            lambda: _UdpProtocol(),
            local_addr=('0.0.0.0', self.bind_port),
            family=socket.AF_INET,
        )
        sock = self._transport.get_extra_info('socket')
        self.actual_port = sock.getsockname()[1]
        return self.actual_port

    async def recv(self, timeout: float = 1.0) -> bytes | None:
        """Receive next RTP payload (strips header). Returns None on timeout."""
        try:
            data = await asyncio.wait_for(self._protocol.queue.get(), timeout=timeout)
        except asyncio.TimeoutError:
            return None
        if len(data) < 12:
            return None
        # Parse minimal header to get payload offset
        first_byte = data[0]
        cc = first_byte & 0x0F
        header_len = 12 + cc * 4
        # Check for extension
        if first_byte & 0x10:
            if len(data) < header_len + 4:
                return None
            ext_len = struct.unpack_from('!H', data, header_len + 2)[0]
            header_len += 4 + ext_len * 4
        if len(data) <= header_len:
            return None
        return data[header_len:]

    def stop(self):
        if self._transport:
            self._transport.close()
            self._transport = None


class _UdpProtocol(asyncio.DatagramProtocol):
    def __init__(self):
        self.queue = asyncio.Queue(maxsize=100)

    def datagram_received(self, data, addr):
        try:
            self.queue.put_nowait(data)
        except asyncio.QueueFull:
            pass  # Drop oldest-style: just skip

    def error_received(self, exc):
        pass

    def connection_lost(self, exc):
        pass
