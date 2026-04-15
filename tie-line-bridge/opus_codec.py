from __future__ import annotations

"""Opus encoder/decoder — direct ctypes wrapper (no opuslib dependency)."""

import ctypes
import ctypes.util
import os
import numpy as np

SAMPLE_RATE = 48000
CHANNELS = 1
FRAME_DURATION_MS = 20
FRAME_SIZE = SAMPLE_RATE * FRAME_DURATION_MS // 1000  # 960 samples

# Opus constants
OPUS_APPLICATION_VOIP = 2048
OPUS_OK = 0
OPUS_SET_BITRATE_REQUEST = 4002

# Load libopus
import sys
_script_dir = os.path.dirname(os.path.abspath(__file__))
_opus_path = None

if sys.platform == 'win32':
    # Windows: look in script dir FIRST (full path avoids DLL search issues)
    for path in [
        os.path.join(_script_dir, 'opus.dll'),
        os.path.join(_script_dir, 'libopus-0.dll'),
        os.path.join(_script_dir, 'libopus.dll'),
    ]:
        if os.path.exists(path):
            _opus_path = path
            break

if not _opus_path:
    _opus_path = ctypes.util.find_library('opus')

if not _opus_path:
    if sys.platform != 'win32':
        # macOS Homebrew / Linux paths
        for path in [
            '/opt/homebrew/lib/libopus.dylib',
            '/usr/local/lib/libopus.dylib',
            '/opt/homebrew/lib/libopus.0.dylib',
            '/usr/local/lib/libopus.0.dylib',
            '/usr/lib/x86_64-linux-gnu/libopus.so.0',
            '/usr/lib/aarch64-linux-gnu/libopus.so.0',
        ]:
            if os.path.exists(path):
                _opus_path = path
                break

if not _opus_path:
    if sys.platform == 'win32':
        raise RuntimeError(
            "opus.dll not found. Place opus.dll in the bridge directory.\n"
            "Run setup_windows.bat to install automatically.")
    else:
        raise RuntimeError("libopus not found. Install with: brew install opus (macOS) or apt install libopus0 (Linux)")

_lib = ctypes.cdll.LoadLibrary(_opus_path)
print(f"[Opus] Loaded: {_opus_path}")

# _create functions: only restype, NO argtypes (ARM64 ctypes bug workaround).
_lib.opus_encoder_create.restype = ctypes.c_void_p
_lib.opus_decoder_create.restype = ctypes.c_void_p
_lib.opus_strerror.restype = ctypes.c_char_p

# encode/decode/destroy: these are normal (non-problematic) functions,
# so we CAN set argtypes — and we MUST, to avoid pointer truncation.
_lib.opus_encode.argtypes = [
    ctypes.c_void_p, ctypes.POINTER(ctypes.c_int16), ctypes.c_int,
    ctypes.POINTER(ctypes.c_ubyte), ctypes.c_int32,
]
_lib.opus_encode.restype = ctypes.c_int32

_lib.opus_decode.argtypes = [
    ctypes.c_void_p, ctypes.POINTER(ctypes.c_ubyte), ctypes.c_int32,
    ctypes.POINTER(ctypes.c_int16), ctypes.c_int, ctypes.c_int,
]
_lib.opus_decode.restype = ctypes.c_int

_lib.opus_encoder_destroy.argtypes = [ctypes.c_void_p]
_lib.opus_encoder_destroy.restype = None
_lib.opus_decoder_destroy.argtypes = [ctypes.c_void_p]
_lib.opus_decoder_destroy.restype = None


def _check(err: int):
    if err < 0:
        msg = _lib.opus_strerror(ctypes.c_int(err))
        raise RuntimeError(f"Opus error {err}: {msg.decode()}")


class OpusEncoder:
    """Encodes float32 PCM -> Opus bytes."""

    def __init__(self, bitrate: int = 32000):
        err = ctypes.c_int(0)
        self._enc = _lib.opus_encoder_create(
            ctypes.c_int(SAMPLE_RATE),
            ctypes.c_int(CHANNELS),
            ctypes.c_int(OPUS_APPLICATION_VOIP),
            ctypes.byref(err),
        )
        if err.value != OPUS_OK or not self._enc:
            raise RuntimeError(f"opus_encoder_create failed: error {err.value}")
        print(f"[Opus] Encoder created OK")

        self._out_buf = (ctypes.c_ubyte * 1275)()

    def encode(self, pcm_float32: np.ndarray) -> bytes:
        """Encode 960 float32 samples -> Opus packet bytes."""
        pcm_int16 = np.clip(pcm_float32 * 32767, -32768, 32767).astype(np.int16)
        pcm_ptr = pcm_int16.ctypes.data_as(ctypes.POINTER(ctypes.c_int16))
        nbytes = _lib.opus_encode(
            self._enc, pcm_ptr, FRAME_SIZE,
            self._out_buf, 1275,
        )
        if nbytes < 0:
            _check(nbytes)
        return bytes(self._out_buf[:nbytes])

    def destroy(self):
        if self._enc:
            _lib.opus_encoder_destroy(self._enc)
            self._enc = None

    def __del__(self):
        self.destroy()


class OpusDecoder:
    """Decodes Opus bytes -> float32 PCM."""

    def __init__(self):
        self._create()
        self._out_buf = (ctypes.c_int16 * FRAME_SIZE)()
        self._error_count = 0

    def _create(self):
        err = ctypes.c_int(0)
        self._dec = _lib.opus_decoder_create(
            ctypes.c_int(SAMPLE_RATE),
            ctypes.c_int(CHANNELS),
            ctypes.byref(err),
        )
        if err.value != OPUS_OK or not self._dec:
            raise RuntimeError(f"opus_decoder_create failed: error {err.value}")
        print(f"[Opus] Decoder created OK")

    def decode(self, opus_data: bytes) -> np.ndarray:
        """Decode Opus packet -> 960 float32 samples."""
        in_buf = (ctypes.c_ubyte * len(opus_data))(*opus_data)
        samples = _lib.opus_decode(
            self._dec, in_buf, len(opus_data),
            self._out_buf, FRAME_SIZE, 0,
        )
        if samples < 0:
            self._error_count += 1
            if self._error_count >= 5:
                # Too many errors — reset decoder (likely corrupted after reconnect)
                print(f"[Opus] Decoder reset after {self._error_count} consecutive errors")
                self.destroy()
                self._create()
                self._error_count = 0
            # Return silence instead of crashing
            return np.zeros(FRAME_SIZE, dtype=np.float32)
        self._error_count = 0  # Reset on success
        pcm_int16 = np.ctypeslib.as_array(self._out_buf, shape=(samples,)).copy()
        return pcm_int16.astype(np.float32) / 32767.0

    def destroy(self):
        if self._dec:
            _lib.opus_decoder_destroy(self._dec)
            self._dec = None

    def __del__(self):
        self.destroy()
