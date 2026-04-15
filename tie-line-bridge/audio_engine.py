from __future__ import annotations

"""Multi-channel audio I/O engine using sounddevice (CoreAudio on macOS).

Works with any multi-channel device: Blackhole, Dante Virtual Soundcard, MADI, RME, etc.
"""

import threading
import numpy as np
import sounddevice as sd

SAMPLE_RATE = 48000
FRAME_SIZE = 960  # 20ms at 48kHz
BLOCK_SIZE = FRAME_SIZE


def list_devices():
    """Print all audio devices with channel counts."""
    devices = sd.query_devices()
    print(f"\n{'ID':>4}  {'Inputs':>6}  {'Outputs':>7}  Name")
    print("-" * 60)
    for i, d in enumerate(devices):
        ins = d['max_input_channels']
        outs = d['max_output_channels']
        if ins > 0 or outs > 0:
            marker = ""
            if i == sd.default.device[0]:
                marker += " [default input]"
            if i == sd.default.device[1]:
                marker += " [default output]"
            print(f"{i:>4}  {ins:>6}  {outs:>7}  {d['name']}{marker}")
    print()


def find_device(name_or_id: str, kind: str = 'input') -> int:
    """Find device by name (partial match) or numeric ID.

    Args:
        name_or_id: Device name substring or numeric ID string.
        kind: 'input' or 'output'
    Returns:
        Device index for sounddevice.
    """
    # Try numeric ID first
    try:
        idx = int(name_or_id)
        info = sd.query_devices(idx)
        ch_key = 'max_input_channels' if kind == 'input' else 'max_output_channels'
        if info[ch_key] > 0:
            return idx
        raise ValueError(f"Device {idx} has no {kind} channels")
    except (ValueError, sd.PortAudioError):
        pass

    # Search by name (case-insensitive partial match)
    devices = sd.query_devices()
    ch_key = 'max_input_channels' if kind == 'input' else 'max_output_channels'
    search = name_or_id.lower()
    for i, d in enumerate(devices):
        if search in d['name'].lower() and d[ch_key] > 0:
            return i

    raise ValueError(f"No {kind} device matching '{name_or_id}' found. Use --list-devices to see available devices.")


class AudioEngine:
    """Captures and plays multi-channel audio, providing per-channel ring buffers.

    Input: N-channel capture → per-channel callback with mono float32 frames.
    Output: Per-channel write() → merged N-channel playback.
    """

    def __init__(
        self,
        input_device: int,
        output_device: int,
        num_channels: int,
        sample_rate: int = SAMPLE_RATE,
    ):
        self.input_device = input_device
        self.output_device = output_device
        self.num_channels = num_channels
        self.sample_rate = sample_rate
        self.frame_size = sample_rate * 20 // 1000  # 20ms

        # Per-channel input buffers (filled by capture callback)
        # Each is a list used as a simple FIFO, protected by a lock
        self._input_buffers = [[] for _ in range(num_channels)]
        self._input_locks = [threading.Lock() for _ in range(num_channels)]

        # Per-channel output buffers (read by playback callback)
        self._output_buffers = [[] for _ in range(num_channels)]
        self._output_locks = [threading.Lock() for _ in range(num_channels)]

        self._input_stream = None
        self._output_stream = None
        self._running = False

    def start(self):
        """Open audio streams."""
        in_info = sd.query_devices(self.input_device)
        out_info = sd.query_devices(self.output_device)
        in_ch = min(self.num_channels, in_info['max_input_channels'])
        out_ch = min(self.num_channels, out_info['max_output_channels'])

        print(f"[Audio] Input:  {in_info['name']} ({in_ch} ch)")
        print(f"[Audio] Output: {out_info['name']} ({out_ch} ch)")

        self._input_stream = sd.InputStream(
            device=self.input_device,
            samplerate=self.sample_rate,
            blocksize=self.frame_size,
            channels=in_ch,
            dtype='float32',
            callback=self._input_callback,
        )
        self._output_stream = sd.OutputStream(
            device=self.output_device,
            samplerate=self.sample_rate,
            blocksize=self.frame_size,
            channels=out_ch,
            dtype='float32',
            callback=self._output_callback,
        )

        self._running = True
        self._input_stream.start()
        self._output_stream.start()
        print(f"[Audio] Streams started (frame={self.frame_size} samples, {self.sample_rate} Hz)")

    def stop(self):
        """Close audio streams."""
        self._running = False
        if self._input_stream:
            self._input_stream.stop()
            self._input_stream.close()
            self._input_stream = None
        if self._output_stream:
            self._output_stream.stop()
            self._output_stream.close()
            self._output_stream = None
        print("[Audio] Streams stopped")

    def read_input(self, channel: int) -> np.ndarray | None:
        """Read one frame (960 samples) from input channel. Non-blocking, returns None if empty."""
        with self._input_locks[channel]:
            if self._input_buffers[channel]:
                return self._input_buffers[channel].pop(0)
        return None

    def write_output(self, channel: int, frame: np.ndarray):
        """Write one frame (960 float32 samples) to output channel."""
        with self._output_locks[channel]:
            # Limit buffer to avoid unbounded growth (keep ~200ms = 10 frames)
            if len(self._output_buffers[channel]) < 10:
                self._output_buffers[channel].append(frame)

    def _input_callback(self, indata, frames, time_info, status):
        """Called by sounddevice for each captured block."""
        if status:
            pass  # Silently ignore xruns in callback context
        # indata shape: (frames, channels) — split into per-channel mono arrays
        num_ch = indata.shape[1]
        for ch in range(min(num_ch, self.num_channels)):
            mono = indata[:, ch].copy()
            with self._input_locks[ch]:
                # Keep max ~200ms buffered
                if len(self._input_buffers[ch]) < 10:
                    self._input_buffers[ch].append(mono)

    def _output_callback(self, outdata, frames, time_info, status):
        """Called by sounddevice for each playback block."""
        outdata[:] = 0  # Silence by default
        num_ch = outdata.shape[1]
        for ch in range(min(num_ch, self.num_channels)):
            with self._output_locks[ch]:
                if self._output_buffers[ch]:
                    frame = self._output_buffers[ch].pop(0)
                    outdata[:len(frame), ch] = frame


class AudioDevicePool:
    """Manages multiple AudioEngine instances, one per unique device.

    Allows different channels to use different audio devices while sharing
    streams when multiple channels use the same device.
    """

    def __init__(self, sample_rate: int = SAMPLE_RATE):
        self.sample_rate = sample_rate
        self._engines: dict[int, AudioEngine] = {}  # device_id → AudioEngine
        self._input_refs: dict[int, int] = {}   # device_id → ref count
        self._output_refs: dict[int, int] = {}  # device_id → ref count

    def _ensure_engine(self, device_id: int) -> AudioEngine:
        """Get or create an AudioEngine for the given device."""
        if device_id not in self._engines:
            info = sd.query_devices(device_id)
            max_ch = max(info['max_input_channels'], info['max_output_channels'])
            engine = AudioEngine(
                input_device=device_id,
                output_device=device_id,
                num_channels=max_ch,
                sample_rate=self.sample_rate,
            )
            self._engines[device_id] = engine
        return self._engines[device_id]

    def open_input(self, device_id: int) -> AudioEngine:
        """Open input stream on device (ref-counted)."""
        engine = self._ensure_engine(device_id)
        self._input_refs[device_id] = self._input_refs.get(device_id, 0) + 1
        if engine._input_stream is None:
            # If output is already open on this device, stop it and reopen both
            # together to avoid CoreAudio errors on macOS
            needs_reopen_output = engine._output_stream is not None
            if needs_reopen_output:
                engine._output_stream.stop()
                engine._output_stream.close()
                engine._output_stream = None

            info = sd.query_devices(device_id)
            in_ch = info['max_input_channels']
            if in_ch > 0:
                engine._input_stream = sd.InputStream(
                    device=device_id,
                    samplerate=self.sample_rate,
                    blocksize=engine.frame_size,
                    channels=in_ch,
                    dtype='float32',
                    callback=engine._input_callback,
                )
                engine._running = True
                engine._input_stream.start()
                print(f"[Pool] Input opened: device={device_id} ({info['name']}, {in_ch}ch)")

            if needs_reopen_output:
                self._start_output_stream(engine, device_id)
        return engine

    def open_output(self, device_id: int) -> AudioEngine:
        """Open output stream on device (ref-counted)."""
        engine = self._ensure_engine(device_id)
        self._output_refs[device_id] = self._output_refs.get(device_id, 0) + 1
        if engine._output_stream is None:
            # If input is already open on this device, stop it and reopen both
            # together to avoid CoreAudio errors on macOS
            needs_reopen_input = engine._input_stream is not None
            if needs_reopen_input:
                engine._input_stream.stop()
                engine._input_stream.close()
                engine._input_stream = None

            self._start_output_stream(engine, device_id)

            if needs_reopen_input:
                info = sd.query_devices(device_id)
                in_ch = info['max_input_channels']
                if in_ch > 0:
                    engine._input_stream = sd.InputStream(
                        device=device_id,
                        samplerate=self.sample_rate,
                        blocksize=engine.frame_size,
                        channels=in_ch,
                        dtype='float32',
                        callback=engine._input_callback,
                    )
                    engine._input_stream.start()
                    print(f"[Pool] Input reopened: device={device_id}")
        return engine

    def _start_output_stream(self, engine: AudioEngine, device_id: int):
        """Helper to create and start an output stream."""
        info = sd.query_devices(device_id)
        out_ch = info['max_output_channels']
        if out_ch > 0:
            engine._output_stream = sd.OutputStream(
                device=device_id,
                samplerate=self.sample_rate,
                blocksize=engine.frame_size,
                channels=out_ch,
                dtype='float32',
                callback=engine._output_callback,
            )
            engine._running = True
            engine._output_stream.start()
            print(f"[Pool] Output opened: device={device_id} ({info['name']}, {out_ch}ch)")

    def read_input(self, device_id: int, channel: int) -> np.ndarray | None:
        """Read one frame from a specific device + channel."""
        engine = self._engines.get(device_id)
        if engine is None:
            return None
        return engine.read_input(channel)

    def write_output(self, device_id: int, channel: int, frame: np.ndarray):
        """Write one frame to a specific device + channel."""
        engine = self._engines.get(device_id)
        if engine is not None:
            engine.write_output(channel, frame)

    def close_input(self, device_id: int):
        """Release input ref. Close stream when no more refs."""
        refs = self._input_refs.get(device_id, 0) - 1
        self._input_refs[device_id] = max(0, refs)
        if refs <= 0:
            engine = self._engines.get(device_id)
            if engine and engine._input_stream:
                engine._input_stream.stop()
                engine._input_stream.close()
                engine._input_stream = None
                print(f"[Pool] Input closed: device={device_id}")
            self._maybe_remove(device_id)

    def close_output(self, device_id: int):
        """Release output ref. Close stream when no more refs."""
        refs = self._output_refs.get(device_id, 0) - 1
        self._output_refs[device_id] = max(0, refs)
        if refs <= 0:
            engine = self._engines.get(device_id)
            if engine and engine._output_stream:
                engine._output_stream.stop()
                engine._output_stream.close()
                engine._output_stream = None
                print(f"[Pool] Output closed: device={device_id}")
            self._maybe_remove(device_id)

    def _maybe_remove(self, device_id: int):
        """Remove engine if no input or output refs remain."""
        if self._input_refs.get(device_id, 0) <= 0 and self._output_refs.get(device_id, 0) <= 0:
            engine = self._engines.pop(device_id, None)
            if engine:
                engine.stop()

    def stop_all(self):
        """Stop all engines."""
        for engine in self._engines.values():
            engine.stop()
        self._engines.clear()
        self._input_refs.clear()
        self._output_refs.clear()
        print("[Pool] All devices stopped")
