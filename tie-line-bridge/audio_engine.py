from __future__ import annotations

"""Multi-channel audio I/O engine using sounddevice.

Works with any multi-channel device: Blackhole, Dante Virtual Soundcard, MADI, RME, etc.
On Windows, ASIO is enabled via SD_ENABLE_ASIO so DVS can expose up to 64 channels.

ASIO drivers (DVS included) are almost always exclusive and reject a second
half-duplex stream on the same device — that surfaces as PortAudio
paDeviceUnavailable (-9985). For ASIO we open a single full-duplex Stream.
"""

import os
import sys
import threading

# Must be set BEFORE importing sounddevice on Windows (loads ASIO PortAudio DLL).
if sys.platform.startswith("win"):
    os.environ.setdefault("SD_ENABLE_ASIO", "1")

import numpy as np
import sounddevice as sd

SAMPLE_RATE = 48000
FRAME_SIZE = 960  # 20ms at 48kHz (Opus frame)
BLOCK_SIZE = FRAME_SIZE
# Hard cap for DVS ASIO 64ch and similar devices (memory + UI slots).
MAX_DEVICE_CHANNELS = 64


def list_devices():
    """Print all audio devices with channel counts."""
    devices = sd.query_devices()
    print(f"\n{'ID':>4}  {'Inputs':>6}  {'Outputs':>7}  Name")
    print("-" * 60)
    for i, d in enumerate(devices):
        ins = d["max_input_channels"]
        outs = d["max_output_channels"]
        if ins > 0 or outs > 0:
            marker = ""
            if i == sd.default.device[0]:
                marker += " [default input]"
            if i == sd.default.device[1]:
                marker += " [default output]"
            print(f"{i:>4}  {ins:>6}  {outs:>7}  {d['name']}{marker}")
    print()


def find_device(name_or_id: str, kind: str = "input") -> int:
    """Find device by name (partial match) or numeric ID."""
    try:
        idx = int(name_or_id)
        info = sd.query_devices(idx)
        ch_key = "max_input_channels" if kind == "input" else "max_output_channels"
        if info[ch_key] > 0:
            return idx
        raise ValueError(f"Device {idx} has no {kind} channels")
    except (ValueError, sd.PortAudioError):
        pass

    devices = sd.query_devices()
    ch_key = "max_input_channels" if kind == "input" else "max_output_channels"
    search = name_or_id.lower()
    for i, d in enumerate(devices):
        if search in d["name"].lower() and d[ch_key] > 0:
            return i

    raise ValueError(
        f"No {kind} device matching '{name_or_id}' found. Use --list-devices."
    )


def _hostapi_name(device_id: int) -> str:
    try:
        info = sd.query_devices(device_id)
        ha = sd.query_hostapis(int(info.get("hostapi", 0)))
        return str(ha.get("name") or "")
    except Exception:
        return ""


def _is_asio_device(device_id: int) -> bool:
    return "asio" in _hostapi_name(device_id).lower()


def _pick_samplerate(info: dict, preferred: int = SAMPLE_RATE) -> int:
    try:
        dsr = int(float(info.get("default_samplerate") or preferred))
    except (TypeError, ValueError):
        dsr = preferred
    return preferred if preferred else dsr


class AudioEngine:
    """Captures and plays multi-channel audio, providing per-channel ring buffers."""

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
        self.frame_size = FRAME_SIZE

        self._input_buffers = [[] for _ in range(num_channels)]
        self._input_locks = [threading.Lock() for _ in range(num_channels)]
        self._output_buffers = [[] for _ in range(num_channels)]
        self._output_locks = [threading.Lock() for _ in range(num_channels)]

        # Accumulators when host callback size != FRAME_SIZE (common with ASIO)
        self._in_accum = [np.zeros(0, dtype=np.float32) for _ in range(num_channels)]

        self._input_stream = None
        self._output_stream = None
        self._duplex_stream = None
        self._running = False

    def _ensure_channel_capacity(self, n: int):
        n = max(1, min(int(n), MAX_DEVICE_CHANNELS))
        while self.num_channels < n:
            self._input_buffers.append([])
            self._input_locks.append(threading.Lock())
            self._output_buffers.append([])
            self._output_locks.append(threading.Lock())
            self._in_accum.append(np.zeros(0, dtype=np.float32))
            self.num_channels += 1

    def stop(self):
        self._running = False
        for attr in ("_duplex_stream", "_input_stream", "_output_stream"):
            stream = getattr(self, attr, None)
            if stream is not None:
                try:
                    stream.stop()
                except Exception:
                    pass
                try:
                    stream.close()
                except Exception:
                    pass
                setattr(self, attr, None)
        print("[Audio] Streams stopped")

    def read_input(self, channel: int):
        if channel < 0 or channel >= self.num_channels:
            return None
        with self._input_locks[channel]:
            if self._input_buffers[channel]:
                return self._input_buffers[channel].pop(0)
        return None

    def write_output(self, channel: int, frame: np.ndarray):
        if channel < 0 or channel >= self.num_channels:
            return
        with self._output_locks[channel]:
            if len(self._output_buffers[channel]) < 10:
                self._output_buffers[channel].append(frame)

    def _push_input_frames(self, indata: np.ndarray):
        if indata is None or indata.size == 0:
            return
        num_ch = indata.shape[1] if indata.ndim > 1 else 1
        for ch in range(min(num_ch, self.num_channels)):
            mono = indata[:, ch] if indata.ndim > 1 else indata
            mono = np.asarray(mono, dtype=np.float32).reshape(-1)
            acc = self._in_accum[ch]
            if acc.size:
                mono = np.concatenate([acc, mono])
            while mono.size >= FRAME_SIZE:
                chunk = mono[:FRAME_SIZE].copy()
                mono = mono[FRAME_SIZE:]
                with self._input_locks[ch]:
                    if len(self._input_buffers[ch]) < 10:
                        self._input_buffers[ch].append(chunk)
            self._in_accum[ch] = mono

    def _fill_output(self, outdata: np.ndarray):
        outdata[:] = 0
        if outdata.ndim == 1:
            with self._output_locks[0]:
                if self._output_buffers[0]:
                    frame = self._output_buffers[0].pop(0)
                    n = min(len(frame), len(outdata))
                    outdata[:n] = frame[:n]
            return
        frames = outdata.shape[0]
        num_ch = outdata.shape[1]
        for ch in range(min(num_ch, self.num_channels)):
            with self._output_locks[ch]:
                filled = 0
                while filled < frames and self._output_buffers[ch]:
                    frame = self._output_buffers[ch][0]
                    need = frames - filled
                    take = min(len(frame), need)
                    outdata[filled : filled + take, ch] = frame[:take]
                    if take >= len(frame):
                        self._output_buffers[ch].pop(0)
                    else:
                        self._output_buffers[ch][0] = frame[take:]
                    filled += take

    def _input_callback(self, indata, frames, time_info, status):
        self._push_input_frames(indata)

    def _output_callback(self, outdata, frames, time_info, status):
        self._fill_output(outdata)

    def _duplex_callback(self, indata, outdata, frames, time_info, status):
        if indata is not None:
            self._push_input_frames(indata)
        if outdata is not None:
            self._fill_output(outdata)


class AudioDevicePool:
    """Manages AudioEngine instances, one per unique device id.

    ASIO: always opens a full-duplex Stream when the device has both I/O
    (required by DVS — avoids paDeviceUnavailable -9985).
    """

    def __init__(self, sample_rate: int = SAMPLE_RATE):
        self.sample_rate = sample_rate
        self._engines: dict[int, AudioEngine] = {}
        self._input_refs: dict[int, int] = {}
        self._output_refs: dict[int, int] = {}

    def _ensure_engine(self, device_id: int) -> AudioEngine:
        if device_id not in self._engines:
            info = sd.query_devices(device_id)
            max_ch = max(info["max_input_channels"], info["max_output_channels"])
            max_ch = max(1, min(int(max_ch or 1), MAX_DEVICE_CHANNELS))
            engine = AudioEngine(
                input_device=device_id,
                output_device=device_id,
                num_channels=max_ch,
                sample_rate=self.sample_rate,
            )
            self._engines[device_id] = engine
        return self._engines[device_id]

    def open_input(self, device_id: int) -> AudioEngine:
        engine = self._ensure_engine(device_id)
        self._input_refs[device_id] = self._input_refs.get(device_id, 0) + 1
        self._ensure_device_streams(device_id)
        return engine

    def open_output(self, device_id: int) -> AudioEngine:
        engine = self._ensure_engine(device_id)
        self._output_refs[device_id] = self._output_refs.get(device_id, 0) + 1
        self._ensure_device_streams(device_id)
        return engine

    def _ensure_device_streams(self, device_id: int):
        engine = self._engines[device_id]
        want_in = self._input_refs.get(device_id, 0) > 0
        want_out = self._output_refs.get(device_id, 0) > 0
        if not want_in and not want_out:
            return

        info = sd.query_devices(device_id)
        in_ch = min(int(info["max_input_channels"] or 0), MAX_DEVICE_CHANNELS)
        out_ch = min(int(info["max_output_channels"] or 0), MAX_DEVICE_CHANNELS)
        engine._ensure_channel_capacity(max(in_ch, out_ch, 1))

        use_duplex = False
        if in_ch > 0 and out_ch > 0 and (want_in or want_out):
            if _is_asio_device(device_id):
                use_duplex = True
            elif want_in and want_out and sys.platform.startswith("win"):
                # Same physical device I/O on Windows: duplex avoids exclusive fights
                use_duplex = True

        if use_duplex:
            self._open_duplex(engine, device_id, info, in_ch, out_ch)
            return

        if want_in and engine._input_stream is None and engine._duplex_stream is None:
            self._open_input_half(engine, device_id, info, in_ch)
        if want_out and engine._output_stream is None and engine._duplex_stream is None:
            self._open_output_half(engine, device_id, info, out_ch)

    def _close_all_streams(self, engine: AudioEngine):
        for attr in ("_duplex_stream", "_input_stream", "_output_stream"):
            stream = getattr(engine, attr, None)
            if stream is not None:
                try:
                    stream.stop()
                except Exception:
                    pass
                try:
                    stream.close()
                except Exception:
                    pass
                setattr(engine, attr, None)

    def _open_duplex(self, engine, device_id, info, in_ch, out_ch):
        if engine._duplex_stream is not None:
            return
        self._close_all_streams(engine)

        sr = _pick_samplerate(info, self.sample_rate)
        engine.sample_rate = sr
        name = info.get("name", "?")
        print(
            f"[Pool] Opening duplex: device={device_id} ({name}) "
            f"in={in_ch} out={out_ch} @ {sr} Hz host={_hostapi_name(device_id)}"
        )

        last_err = None
        for blocksize in (0, 512, 256, 480, FRAME_SIZE):
            try:
                engine._duplex_stream = sd.Stream(
                    device=(device_id, device_id),
                    samplerate=sr,
                    blocksize=blocksize,
                    channels=(in_ch, out_ch),
                    dtype="float32",
                    latency="low",
                    callback=engine._duplex_callback,
                )
                engine._running = True
                engine._duplex_stream.start()
                engine._input_stream = engine._duplex_stream
                engine._output_stream = engine._duplex_stream
                print(
                    f"[Pool] Duplex OK: device={device_id} blocksize={blocksize} "
                    f"({name}, {in_ch}in/{out_ch}out)"
                )
                return
            except Exception as e:
                last_err = e
                print(f"[Pool] Duplex try blocksize={blocksize} failed: {e}")
                engine._duplex_stream = None
                engine._input_stream = None
                engine._output_stream = None

        try:
            dsr = int(float(info.get("default_samplerate") or sr))
        except (TypeError, ValueError):
            dsr = sr
        if dsr != sr:
            try:
                engine._duplex_stream = sd.Stream(
                    device=(device_id, device_id),
                    samplerate=dsr,
                    blocksize=0,
                    channels=(in_ch, out_ch),
                    dtype="float32",
                    callback=engine._duplex_callback,
                )
                engine.sample_rate = dsr
                engine._running = True
                engine._duplex_stream.start()
                engine._input_stream = engine._duplex_stream
                engine._output_stream = engine._duplex_stream
                print(f"[Pool] Duplex OK @ device default {dsr} Hz")
                return
            except Exception as e:
                last_err = e

        raise RuntimeError(
            f"Cannot open device {device_id} ({name}) full-duplex.\n"
            f"Last error: {last_err}\n\n"
            "Typical causes (ASIO / DVS):\n"
            "• Another app already holds the ASIO device (DAW, second bridge)\n"
            "• Close all other ASIO clients, then retry\n"
            "• Set DVS and Dante to 48 kHz\n"
            "• Use the same device for In and Out in the bridge"
        )

    def _open_input_half(self, engine, device_id, info, in_ch):
        if in_ch <= 0:
            return
        sr = _pick_samplerate(info, self.sample_rate)
        engine._input_stream = sd.InputStream(
            device=device_id,
            samplerate=sr,
            blocksize=engine.frame_size,
            channels=in_ch,
            dtype="float32",
            callback=engine._input_callback,
        )
        engine._running = True
        engine._input_stream.start()
        print(f"[Pool] Input opened: device={device_id} ({info['name']}, {in_ch}ch)")

    def _open_output_half(self, engine, device_id, info, out_ch):
        if out_ch <= 0:
            return
        sr = _pick_samplerate(info, self.sample_rate)
        engine._output_stream = sd.OutputStream(
            device=device_id,
            samplerate=sr,
            blocksize=engine.frame_size,
            channels=out_ch,
            dtype="float32",
            callback=engine._output_callback,
        )
        engine._running = True
        engine._output_stream.start()
        print(f"[Pool] Output opened: device={device_id} ({info['name']}, {out_ch}ch)")

    def read_input(self, device_id: int, channel: int):
        engine = self._engines.get(device_id)
        if engine is None:
            return None
        return engine.read_input(channel)

    def write_output(self, device_id: int, channel: int, frame: np.ndarray):
        engine = self._engines.get(device_id)
        if engine is not None:
            engine.write_output(channel, frame)

    def close_input(self, device_id: int):
        refs = self._input_refs.get(device_id, 0) - 1
        self._input_refs[device_id] = max(0, refs)
        if refs <= 0 and self._output_refs.get(device_id, 0) <= 0:
            engine = self._engines.get(device_id)
            if engine:
                self._close_all_streams(engine)
                print(f"[Pool] Closed device={device_id}")
            self._maybe_remove(device_id)
        elif refs <= 0:
            engine = self._engines.get(device_id)
            # ASIO duplex must stay open if output still needed
            if engine and engine._duplex_stream is None and engine._input_stream:
                try:
                    engine._input_stream.stop()
                    engine._input_stream.close()
                except Exception:
                    pass
                engine._input_stream = None

    def close_output(self, device_id: int):
        refs = self._output_refs.get(device_id, 0) - 1
        self._output_refs[device_id] = max(0, refs)
        if refs <= 0 and self._input_refs.get(device_id, 0) <= 0:
            engine = self._engines.get(device_id)
            if engine:
                self._close_all_streams(engine)
                print(f"[Pool] Closed device={device_id}")
            self._maybe_remove(device_id)
        elif refs <= 0:
            engine = self._engines.get(device_id)
            if engine and engine._duplex_stream is None and engine._output_stream:
                try:
                    engine._output_stream.stop()
                    engine._output_stream.close()
                except Exception:
                    pass
                engine._output_stream = None

    def _maybe_remove(self, device_id: int):
        if self._input_refs.get(device_id, 0) <= 0 and self._output_refs.get(device_id, 0) <= 0:
            engine = self._engines.pop(device_id, None)
            if engine:
                engine.stop()

    def stop_all(self):
        for engine in list(self._engines.values()):
            engine.stop()
        self._engines.clear()
        self._input_refs.clear()
        self._output_refs.clear()
        print("[Pool] All devices stopped")
