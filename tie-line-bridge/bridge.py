#!/usr/bin/env python3
"""Tie Line Bridge — Multi-channel audio bridge for intercom system.

Captures audio from a multi-channel device (Blackhole, Dante, MADI, etc.),
and bridges each channel to the intercom server via PlainTransport RTP.

Usage:
    python bridge.py                    # Run with config.json
    python bridge.py --config my.json   # Custom config file
    python bridge.py --list-devices     # Show available audio devices
"""

import argparse
import asyncio
import json
import os
import signal
import sys
import time

from audio_engine import AudioEngine, AudioDevicePool, list_devices, find_device
from channel import TieLineChannel


def load_config(path: str) -> dict:
    with open(path) as f:
        return json.load(f)


async def run_bridge(config: dict):
    """Main async entry point."""
    server = config["server"]
    # Global defaults (used as fallback when per-channel device is not set)
    global_input_name = config.get("input_device", "default")
    global_output_name = config.get("output_device", "default")
    sample_rate = config.get("sample_rate", 48000)
    channel_configs = config.get("channels", [])

    if not channel_configs:
        print("No channels configured in config.json")
        return

    # Resolve global device IDs
    global_input_dev = find_device(global_input_name, 'input')
    global_output_dev = find_device(global_output_name, 'output')

    # Create device pool
    pool = AudioDevicePool(sample_rate=sample_rate)

    # Create channels
    channels = []
    for ch_cfg in channel_configs:
        idx = ch_cfg["index"] - 1  # config is 1-based, internal is 0-based

        # Per-channel device (falls back to global)
        in_dev_name = ch_cfg.get("input_device", "")
        out_dev_name = ch_cfg.get("output_device", "")
        in_dev = find_device(in_dev_name, 'input') if in_dev_name else global_input_dev
        out_dev = find_device(out_dev_name, 'output') if out_dev_name else global_output_dev
        in_ch = ch_cfg.get("input_channel", ch_cfg["index"]) - 1  # 1-based → 0-based
        out_ch = ch_cfg.get("output_channel", ch_cfg["index"]) - 1

        # Open device streams via pool
        pool.open_input(in_dev)
        pool.open_output(out_dev)

        ch = TieLineChannel(
            index=idx,
            server_url=server,
            username=ch_cfg["username"],
            password=ch_cfg["password"],
            target_type=ch_cfg.get("target_type", "user"),
            target_id=ch_cfg.get("target_id", 0),
            audio_pool=pool,
            input_device=in_dev,
            input_channel=in_ch,
            output_device=out_dev,
            output_channel=out_ch,
            vox_send_enabled=ch_cfg.get("vox_send_enabled", False),
            vox_send_threshold_db=ch_cfg.get("vox_send_threshold_db",
                                              ch_cfg.get("vox_threshold_db", -40)),
            vox_send_hold_ms=ch_cfg.get("vox_send_hold_ms",
                                         ch_cfg.get("vox_hold_ms", 300)),
            vox_recv_enabled=ch_cfg.get("vox_recv_enabled", True),
            vox_recv_threshold_db=ch_cfg.get("vox_recv_threshold_db", -40),
            vox_recv_hold_ms=ch_cfg.get("vox_recv_hold_ms", 300),
        )
        channels.append(ch)

    if not channels:
        print("No valid channels to run")
        pool.stop_all()
        return

    print(f"\nStarting {len(channels)} tie line channel(s)...\n")

    # Setup graceful shutdown
    stop_event = asyncio.Event()

    def handle_signal():
        print("\nShutting down...")
        stop_event.set()
        for ch in channels:
            asyncio.ensure_future(ch.stop())

    loop = asyncio.get_event_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, handle_signal)

    # Run all channels + status display
    channel_tasks = [asyncio.create_task(ch.run()) for ch in channels]
    status_task = asyncio.create_task(status_display(channels, stop_event))

    try:
        await asyncio.gather(*channel_tasks, status_task, return_exceptions=True)
    finally:
        pool.stop_all()
        print("\nBridge stopped.")


async def status_display(channels: list, stop_event: asyncio.Event):
    """Periodically print channel status to terminal."""
    while not stop_event.is_set():
        lines = []
        for ch in channels:
            state = "OK" if ch.connected else ("ERR" if ch.error else "---")
            vox = "VOX" if ch.vox_active else "   "
            recv = "RCV" if ch.receiving else "   "
            level = f"{ch.level_db:6.1f}dB" if ch.connected else "      --"
            err = f" [{ch.error}]" if ch.error else ""
            lines.append(f"  CH{ch.index:<2} {state:>3}  {level}  {vox} {recv}{err}")

        status = "\r\033[K" + " | ".join(
            f"CH{ch.index}:{'OK' if ch.connected else '--'}"
            + (f"{'V' if ch.vox_active else ' '}")
            + (f"{'R' if ch.receiving else ' '}")
            for ch in channels
        )
        sys.stdout.write(status)
        sys.stdout.flush()

        await asyncio.sleep(0.5)


def main():
    parser = argparse.ArgumentParser(description="Tie Line Bridge")
    parser.add_argument("--config", default="config.json", help="Config file path")
    parser.add_argument("--list-devices", action="store_true", help="List audio devices and exit")
    args = parser.parse_args()

    if args.list_devices:
        list_devices()
        return

    # Resolve config path relative to script directory
    config_path = args.config
    if not os.path.isabs(config_path):
        script_dir = os.path.dirname(os.path.abspath(__file__))
        config_path = os.path.join(script_dir, config_path)

    if not os.path.exists(config_path):
        print(f"Config file not found: {config_path}")
        print("Create config.json or use --config <path>")
        print("Use --list-devices to see available audio devices")
        sys.exit(1)

    config = load_config(config_path)
    print(f"Tie Line Bridge — {len(config.get('channels', []))} channels configured")
    print(f"Server: {config['server']}")

    asyncio.run(run_bridge(config))


if __name__ == "__main__":
    main()
