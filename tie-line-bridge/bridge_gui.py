#!/usr/bin/env python3
from __future__ import annotations

"""Tie Line Bridge — macOS GUI Application (Modern UI with customtkinter).

Visual interface for configuring and running multi-channel tie lines.
Works with Blackhole, Dante Virtual Soundcard, MADI, etc.
"""

import asyncio
import json
import os
import ssl
import sys
import threading
import tkinter as tk
from tkinter import messagebox

import aiohttp
import customtkinter as ctk
import sounddevice as sd

# Add script dir to path for local imports
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from audio_engine import AudioEngine, AudioDevicePool, find_device
from channel import TieLineChannel

CONFIG_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.json")

# Theme colors
COLOR_BG = "#1a1a2e"       # Dark navy background
COLOR_CARD = "#16213e"     # Card background
COLOR_ACCENT = "#7b2ff7"   # Purple (from logo)
COLOR_ACCENT2 = "#00c9db"  # Cyan (from logo)
COLOR_GREEN = "#00e676"    # Connected
COLOR_RED = "#ff5252"      # Error / VOX
COLOR_ORANGE = "#ffab40"   # Warning
COLOR_TEXT = "#e0e0e0"     # Light text
COLOR_DIM = "#666680"      # Dimmed text
COLOR_ROW_EVEN = "#1a1a2e"
COLOR_ROW_ODD = "#0f3460"
COLOR_BLUE = "#2196f3"      # Active toggle (VOX enabled)


class ChannelRow:
    """UI row for one tie line channel."""

    def __init__(self, parent: ctk.CTkFrame, index: int, row: int, on_connect=None):
        self.index = index
        self.channel: TieLineChannel | None = None
        self._directory: dict = {"user": [], "group": []}
        self._pending_target_id: int = 0
        self._on_connect_cb = on_connect
        self._vox_send_enabled = True
        self._vox_recv_enabled = True

        bg = COLOR_ROW_ODD if index % 2 else COLOR_ROW_EVEN

        # Row frame
        self.frame = ctk.CTkFrame(parent, fg_color=bg, corner_radius=6, height=40)
        self.frame.grid(row=row, column=0, sticky="ew", padx=4, pady=2)
        self.frame.grid_columnconfigure(5, weight=1)  # Target column expands

        col = 0

        # Channel number
        self.lbl = ctk.CTkLabel(self.frame, text=f"CH {index + 1}",
                                font=("SF Pro Display", 14, "bold"),
                                text_color=COLOR_ACCENT2, width=50)
        self.lbl.grid(row=0, column=col, padx=(8, 4), pady=6); col += 1

        # Status dot (big LED)
        self.status_dot = ctk.CTkLabel(self.frame, text="●", font=("Arial", 22),
                                       text_color=COLOR_DIM, width=26)
        self.status_dot.grid(row=0, column=col, padx=2); col += 1

        # Username
        self.user_var = tk.StringVar()
        self.user_entry = ctk.CTkEntry(self.frame, textvariable=self.user_var, width=110,
                                        placeholder_text="usuario", height=30)
        self.user_entry.grid(row=0, column=col, padx=4, pady=4); col += 1

        # Password
        self.pass_var = tk.StringVar()
        self.pass_entry = ctk.CTkEntry(self.frame, textvariable=self.pass_var, width=90,
                                        placeholder_text="password", show="•", height=30)
        self.pass_entry.grid(row=0, column=col, padx=4, pady=4); col += 1

        # Target type
        self.ttype_var = tk.StringVar(value="user")
        self.ttype_combo = ctk.CTkComboBox(self.frame, variable=self.ttype_var,
                                            values=["user", "group"], width=80,
                                            height=30, state="readonly",
                                            command=lambda _: self._update_target_dropdown())
        self.ttype_combo.grid(row=0, column=col, padx=4, pady=4); col += 1

        # Target dropdown
        self.tid_var = tk.StringVar(value="")
        self.tid_combo = ctk.CTkComboBox(self.frame, variable=self.tid_var,
                                          values=[], width=120, height=30, state="readonly")
        self.tid_combo.grid(row=0, column=col, padx=4, pady=4, sticky="ew"); col += 1

        # --- Per-channel audio device selection ---
        self.in_dev_var = tk.StringVar(value="")
        self.in_dev_combo = ctk.CTkComboBox(self.frame, variable=self.in_dev_var,
                                             values=[], width=130, height=26, state="readonly")
        self.in_dev_combo.grid(row=0, column=col, padx=2, pady=4); col += 1

        self.in_ch_var = tk.StringVar(value="1")
        self.in_ch_spin = ctk.CTkEntry(self.frame, textvariable=self.in_ch_var, width=30,
                                        height=26, placeholder_text="ch")
        self.in_ch_spin.grid(row=0, column=col, padx=1, pady=4); col += 1

        self.out_dev_var = tk.StringVar(value="")
        self.out_dev_combo = ctk.CTkComboBox(self.frame, variable=self.out_dev_var,
                                              values=[], width=130, height=26, state="readonly")
        self.out_dev_combo.grid(row=0, column=col, padx=2, pady=4); col += 1

        self.out_ch_var = tk.StringVar(value="1")
        self.out_ch_spin = ctk.CTkEntry(self.frame, textvariable=self.out_ch_var, width=30,
                                         height=26, placeholder_text="ch")
        self.out_ch_spin.grid(row=0, column=col, padx=1, pady=4); col += 1

        # --- VOX Send toggle + threshold ---
        self.vox_send_btn = ctk.CTkButton(self.frame, text="VOX→", width=50, height=26,
                                           font=("SF Pro Display", 11, "bold"),
                                           fg_color=COLOR_BLUE, hover_color="#1976d2",
                                           text_color="white",
                                           command=self._toggle_vox_send)
        self.vox_send_btn.grid(row=0, column=col, padx=2, pady=4); col += 1

        self.vox_send_db_var = tk.StringVar(value="-40")
        self.vox_send_db_entry = ctk.CTkEntry(self.frame, textvariable=self.vox_send_db_var,
                                               width=42, placeholder_text="dB", height=26)
        self.vox_send_db_entry.grid(row=0, column=col, padx=2, pady=4); col += 1

        # Send level meter
        self.send_meter_canvas = tk.Canvas(self.frame, width=40, height=16,
                                           bg=bg, highlightthickness=0, bd=0)
        self.send_meter_canvas.grid(row=0, column=col, padx=2, pady=4); col += 1
        self.send_meter_bg = self.send_meter_canvas.create_rectangle(0, 1, 40, 15,
                                                                     fill="#2a2a4a", outline="#333355")
        self.send_meter_bar = self.send_meter_canvas.create_rectangle(0, 1, 0, 15,
                                                                      fill=COLOR_GREEN, outline="")

        # VOX send badge
        self.vox_send_badge = ctk.CTkLabel(self.frame, text="", font=("SF Pro Display", 10, "bold"),
                                            text_color=COLOR_RED, width=30)
        self.vox_send_badge.grid(row=0, column=col, padx=1); col += 1

        # --- VOX Recv toggle + threshold ---
        self.vox_recv_btn = ctk.CTkButton(self.frame, text="VOX←", width=50, height=26,
                                           font=("SF Pro Display", 11, "bold"),
                                           fg_color=COLOR_DIM, hover_color="#555577",
                                           text_color="white",
                                           command=self._toggle_vox_recv)
        self.vox_recv_btn.grid(row=0, column=col, padx=2, pady=4); col += 1

        self.vox_recv_db_var = tk.StringVar(value="-40")
        self.vox_recv_db_entry = ctk.CTkEntry(self.frame, textvariable=self.vox_recv_db_var,
                                               width=42, placeholder_text="dB", height=26)
        self.vox_recv_db_entry.grid(row=0, column=col, padx=2, pady=4); col += 1

        # Recv level meter
        self.recv_meter_canvas = tk.Canvas(self.frame, width=40, height=16,
                                           bg=bg, highlightthickness=0, bd=0)
        self.recv_meter_canvas.grid(row=0, column=col, padx=2, pady=4); col += 1
        self.recv_meter_bg = self.recv_meter_canvas.create_rectangle(0, 1, 40, 15,
                                                                     fill="#2a2a4a", outline="#333355")
        self.recv_meter_bar = self.recv_meter_canvas.create_rectangle(0, 1, 0, 15,
                                                                      fill=COLOR_ACCENT2, outline="")

        # VOX recv badge
        self.vox_recv_badge = ctk.CTkLabel(self.frame, text="", font=("SF Pro Display", 10, "bold"),
                                            text_color=COLOR_ORANGE, width=30)
        self.vox_recv_badge.grid(row=0, column=col, padx=1); col += 1

        # RX badge (incoming audio from Winus)
        self.rx_badge = ctk.CTkLabel(self.frame, text="", font=("SF Pro Display", 11, "bold"),
                                      text_color=COLOR_ACCENT2, width=24)
        self.rx_badge.grid(row=0, column=col, padx=1); col += 1

        # Per-channel connect button
        self.ch_connect_btn = ctk.CTkButton(self.frame, text="▶", width=30, height=26,
                                             font=("SF Pro Display", 12, "bold"),
                                             fg_color=COLOR_GREEN, hover_color="#00c853",
                                             text_color="#1a1a2e",
                                             command=self._on_connect_click)
        self.ch_connect_btn.grid(row=0, column=col, padx=(2, 8), pady=4)

        # Apply initial VOX toggle visuals
        self._update_vox_send_visual()
        self._update_vox_recv_visual()

    def set_directory(self, users: list, groups: list):
        self._directory["user"] = [(u["id"], u["display_name"]) for u in users]
        self._directory["group"] = [(g["id"], g["name"]) for g in groups]
        self._update_target_dropdown()

    def _update_target_dropdown(self):
        ttype = self.ttype_var.get()
        items = self._directory.get(ttype, [])
        display_values = [f"{name} ({id})" for id, name in items]
        self.tid_combo.configure(values=display_values)
        if self.tid_var.get() not in display_values:
            if display_values:
                self.tid_combo.set(display_values[0])
            else:
                self.tid_combo.set("")

    def _get_target_id(self) -> int:
        val = self.tid_var.get()
        try:
            return int(val.rsplit("(", 1)[1].rstrip(")"))
        except (IndexError, ValueError):
            return 0

    def _toggle_vox_send(self):
        self._vox_send_enabled = not self._vox_send_enabled
        self._update_vox_send_visual()

    def _toggle_vox_recv(self):
        self._vox_recv_enabled = not self._vox_recv_enabled
        self._update_vox_recv_visual()

    def _update_vox_send_visual(self):
        if self._vox_send_enabled:
            self.vox_send_btn.configure(fg_color=COLOR_BLUE, hover_color="#1976d2")
            self.vox_send_db_entry.configure(state="normal")
        else:
            self.vox_send_btn.configure(fg_color=COLOR_DIM, hover_color="#555577")
            self.vox_send_db_entry.configure(state="disabled")

    def _update_vox_recv_visual(self):
        if self._vox_recv_enabled:
            self.vox_recv_btn.configure(fg_color=COLOR_BLUE, hover_color="#1976d2")
            self.vox_recv_db_entry.configure(state="normal")
        else:
            self.vox_recv_btn.configure(fg_color=COLOR_DIM, hover_color="#555577")
            self.vox_recv_db_entry.configure(state="disabled")

    def get_config(self) -> dict | None:
        user = self.user_var.get().strip()
        pwd = self.pass_var.get().strip()
        if not user or not pwd:
            return None
        tid = self._get_target_id()
        try:
            vox_send_db = float(self.vox_send_db_var.get())
        except ValueError:
            vox_send_db = -40.0
        try:
            vox_recv_db = float(self.vox_recv_db_var.get())
        except ValueError:
            vox_recv_db = -40.0
        return {
            "index": self.index + 1,
            "username": user,
            "password": pwd,
            "target_type": self.ttype_var.get(),
            "target_id": tid,
            "input_device": self.in_dev_var.get(),
            "input_channel": int(self.in_ch_var.get() or "1"),
            "output_device": self.out_dev_var.get(),
            "output_channel": int(self.out_ch_var.get() or "1"),
            "vox_send_enabled": self._vox_send_enabled,
            "vox_send_threshold_db": vox_send_db,
            "vox_send_hold_ms": 300,
            "vox_recv_enabled": self._vox_recv_enabled,
            "vox_recv_threshold_db": vox_recv_db,
            "vox_recv_hold_ms": 300,
        }

    def set_config(self, cfg: dict):
        self.user_var.set(cfg.get("username", ""))
        self.pass_var.set(cfg.get("password", ""))
        self.ttype_var.set(cfg.get("target_type", "user"))
        self._pending_target_id = cfg.get("target_id", 0)
        # Per-channel audio devices
        if cfg.get("input_device"):
            self.in_dev_var.set(cfg["input_device"])
        if cfg.get("output_device"):
            self.out_dev_var.set(cfg["output_device"])
        self.in_ch_var.set(str(cfg.get("input_channel", self.index + 1)))
        self.out_ch_var.set(str(cfg.get("output_channel", self.index + 1)))
        # VOX send
        self._vox_send_enabled = cfg.get("vox_send_enabled", False)
        self.vox_send_db_var.set(str(cfg.get("vox_send_threshold_db",
                                              cfg.get("vox_threshold_db", -40))))
        self._update_vox_send_visual()
        # VOX recv
        self._vox_recv_enabled = cfg.get("vox_recv_enabled", True)
        self.vox_recv_db_var.set(str(cfg.get("vox_recv_threshold_db", -40)))
        self._update_vox_recv_visual()

    def apply_pending_target(self):
        tid = self._pending_target_id
        ttype = self.ttype_var.get()
        items = self._directory.get(ttype, [])
        for item_id, name in items:
            if item_id == tid:
                self.tid_combo.set(f"{name} ({item_id})")
                return
        if tid:
            self.tid_combo.set(str(tid))

    def update_status(self):
        ch = self.channel
        if ch is None or not ch.connected:
            self.status_dot.configure(text_color=COLOR_DIM)
            self.send_meter_canvas.coords(self.send_meter_bar, 0, 1, 0, 15)
            self.recv_meter_canvas.coords(self.recv_meter_bar, 0, 1, 0, 15)
            # Grey out meter backgrounds when not connected
            self.send_meter_canvas.itemconfig(self.send_meter_bg, fill="#333344", outline="#444455")
            self.recv_meter_canvas.itemconfig(self.recv_meter_bg, fill="#333344", outline="#444455")
            self.vox_send_badge.configure(text="")
            self.vox_recv_badge.configure(text="")
            self.rx_badge.configure(text="")
            if ch and ch.error:
                self.status_dot.configure(text_color=COLOR_RED)
            return

        self.status_dot.configure(text_color=COLOR_GREEN)
        # Restore meter backgrounds when connected
        self.send_meter_canvas.itemconfig(self.send_meter_bg, fill="#2a2a4a", outline="#333355")
        self.recv_meter_canvas.itemconfig(self.recv_meter_bg, fill="#2a2a4a", outline="#333355")

        # Send level meter
        send_db = max(-60, min(0, ch.level_send_db))
        send_w = int((send_db + 60) / 60 * 40)
        send_color = COLOR_RED if ch.vox_send_active else COLOR_GREEN
        self.send_meter_canvas.coords(self.send_meter_bar, 0, 1, send_w, 15)
        self.send_meter_canvas.itemconfig(self.send_meter_bar, fill=send_color)

        # Recv level meter
        recv_db = max(-60, min(0, ch.level_recv_db))
        recv_w = int((recv_db + 60) / 60 * 40)
        recv_color = COLOR_ORANGE if ch.vox_recv_active else COLOR_ACCENT2
        self.recv_meter_canvas.coords(self.recv_meter_bar, 0, 1, recv_w, 15)
        self.recv_meter_canvas.itemconfig(self.recv_meter_bar, fill=recv_color)

        # Badges
        if ch.vox_send_enabled:
            self.vox_send_badge.configure(text="TX" if ch.vox_send_active else "")
        else:
            self.vox_send_badge.configure(text="ON")  # permanent PTT indicator

        if ch.vox_recv_enabled:
            self.vox_recv_badge.configure(text="RV" if ch.vox_recv_active else "")
        else:
            self.vox_recv_badge.configure(text="")

        self.rx_badge.configure(text="RX" if ch.receiving else "")

    def set_devices(self, inputs: list, outputs: list):
        """Update per-channel device dropdowns."""
        self.in_dev_combo.configure(values=inputs)
        self.out_dev_combo.configure(values=outputs)
        # Set default if empty
        if not self.in_dev_var.get() and inputs:
            self.in_dev_var.set(inputs[0])
        if not self.out_dev_var.get() and outputs:
            self.out_dev_var.set(outputs[0])

    def set_enabled(self, enabled: bool):
        state = "normal" if enabled else "disabled"
        self.user_entry.configure(state=state)
        self.pass_entry.configure(state=state)
        self.ttype_combo.configure(state="readonly" if enabled else "disabled")
        self.tid_combo.configure(state="readonly" if enabled else "disabled")
        self.in_dev_combo.configure(state="readonly" if enabled else "disabled")
        self.out_dev_combo.configure(state="readonly" if enabled else "disabled")
        self.in_ch_spin.configure(state=state)
        self.out_ch_spin.configure(state=state)
        self.vox_send_btn.configure(state=state)
        self.vox_recv_btn.configure(state=state)
        if enabled:
            self._update_vox_send_visual()
            self._update_vox_recv_visual()
        else:
            self.vox_send_db_entry.configure(state="disabled")
            self.vox_recv_db_entry.configure(state="disabled")

    def _on_connect_click(self):
        if self._on_connect_cb:
            self._on_connect_cb(self)

    def set_connected(self, connected: bool):
        if connected:
            self.ch_connect_btn.configure(text="■", fg_color=COLOR_RED, hover_color="#d32f2f")
            self.set_enabled(False)
        else:
            self.ch_connect_btn.configure(text="▶", fg_color=COLOR_GREEN, hover_color="#00c853")
            self.set_enabled(True)


class BridgeApp:
    """Main application window."""

    def __init__(self):
        ctk.set_appearance_mode("dark")
        ctk.set_default_color_theme("blue")

        self.root = ctk.CTk()
        self.root.title("TieLine Bridge")
        self.root.geometry("1600x650")
        self.root.minsize(1400, 500)
        self.root.configure(fg_color=COLOR_BG)

        self.audio_pool: AudioDevicePool | None = None
        self.channels: list[TieLineChannel] = []
        self.channel_rows: list[ChannelRow] = []
        self.running = False
        self.async_thread = None
        self.loop = None
        self._input_devices: list[str] = []
        self._output_devices: list[str] = []
        self._admin_authenticated = False  # Gate: must login before connecting

        self._build_ui()
        self._load_config()
        self._refresh_devices()
        self._start_status_timer()
        # Disable connect buttons until admin login
        self._update_auth_state()

    def _build_ui(self):
        # ---- Header with logo ----
        header = ctk.CTkFrame(self.root, fg_color=COLOR_CARD, corner_radius=0, height=60)
        header.pack(fill="x")
        header.pack_propagate(False)

        # Try to load logo
        logo_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logo.png")
        if os.path.exists(logo_path):
            try:
                from PIL import Image
                img = Image.open(logo_path).resize((40, 40))
                self._logo_img = ctk.CTkImage(light_image=img, dark_image=img, size=(40, 40))
                ctk.CTkLabel(header, image=self._logo_img, text="").pack(side="left", padx=(16, 8), pady=8)
            except ImportError:
                pass  # PIL not available, skip logo

        ctk.CTkLabel(header, text="TieLine Bridge",
                     font=("SF Pro Display", 22, "bold"),
                     text_color="white").pack(side="left", padx=4, pady=8)

        ctk.CTkLabel(header, text="Audio Matrix Bridge v.3.2.2",
                     font=("SF Pro Display", 13),
                     text_color=COLOR_DIM).pack(side="left", padx=8, pady=8)

        # ---- Config panel ----
        config_frame = ctk.CTkFrame(self.root, fg_color=COLOR_CARD, corner_radius=10)
        config_frame.pack(fill="x", padx=12, pady=(8, 4))

        # Row 1: Server + buttons
        row1 = ctk.CTkFrame(config_frame, fg_color="transparent")
        row1.pack(fill="x", padx=12, pady=(10, 2))

        ctk.CTkLabel(row1, text="Server", font=("SF Pro Display", 12),
                     text_color=COLOR_DIM).pack(side="left", padx=(0, 4))
        self.server_var = tk.StringVar(value="https://192.168.4.8:8443")
        self._server_entry = ctk.CTkEntry(row1, textvariable=self.server_var, width=280, height=32)
        self._server_entry.pack(side="left", padx=4)

        # Server status indicator (full-height LED)
        self._server_status = ctk.CTkLabel(row1, text="●", font=("Arial", 36),
                                            text_color=COLOR_DIM, width=40)
        self._server_status.pack(side="left", padx=(0, 8))

        # Auto-detect server changes
        self.server_var.trace_add("write", self._on_server_changed)
        self._server_check_timer = None

        self.connect_btn = ctk.CTkButton(row1, text="▶  Connect", width=130, height=36,
                                          font=("SF Pro Display", 14, "bold"),
                                          fg_color=COLOR_GREEN, hover_color="#00c853",
                                          text_color="#1a1a2e",
                                          command=self._on_connect)
        self.connect_btn.pack(side="right", padx=4)

        ctk.CTkButton(row1, text="↻ Users", width=100, height=32,
                      fg_color=COLOR_ACCENT2, hover_color="#00a0b0",
                      text_color="#1a1a2e",
                      command=self._fetch_directory).pack(side="right", padx=4)

        ctk.CTkButton(row1, text="🔒 Login", width=100, height=32,
                      fg_color=COLOR_ORANGE, hover_color="#ff8f00",
                      text_color="#1a1a2e",
                      command=self._show_login_dialog).pack(side="right", padx=4)

        ctk.CTkButton(row1, text="↻ Devices", width=100, height=32,
                      fg_color=COLOR_ACCENT, hover_color="#6a1fd6",
                      command=self._refresh_devices).pack(side="right", padx=4)

        # Row 2: Default devices (fill-all) — aligned with per-channel columns
        row2 = ctk.CTkFrame(config_frame, fg_color="transparent")
        row2.pack(fill="x", padx=12, pady=(2, 10))

        ctk.CTkLabel(row2, text="Default In", font=("SF Pro Display", 12),
                     text_color=COLOR_DIM).pack(side="left", padx=(0, 4))
        self.input_dev_var = tk.StringVar()
        self.input_combo = ctk.CTkComboBox(row2, variable=self.input_dev_var,
                                            width=200, height=32, state="readonly")
        self.input_combo.pack(side="left", padx=4)

        ctk.CTkLabel(row2, text="Default Out", font=("SF Pro Display", 12),
                     text_color=COLOR_DIM).pack(side="left", padx=(16, 4))
        self.output_dev_var = tk.StringVar()
        self.output_combo = ctk.CTkComboBox(row2, variable=self.output_dev_var,
                                             width=200, height=32, state="readonly")
        self.output_combo.pack(side="left", padx=4)

        self.num_ch_var = tk.StringVar(value="16")

        ctk.CTkLabel(row2, text="Bridge IP", font=("SF Pro Display", 12),
                     text_color=COLOR_DIM).pack(side="left", padx=(16, 4))
        self.bridge_ip_var = tk.StringVar(value="")
        ctk.CTkEntry(row2, textvariable=self.bridge_ip_var, width=140, height=32,
                     placeholder_text="auto").pack(side="left", padx=4)

        ctk.CTkButton(row2, text="▶ Apply to all", width=120, height=32,
                      font=("SF Pro Display", 12, "bold"),
                      fg_color=COLOR_BLUE, hover_color="#1976d2",
                      command=self._apply_defaults_to_all).pack(side="left", padx=(12, 4))

        # ---- Column headers ----
        # Use a grid-based frame matching the ChannelRow layout for exact alignment
        hdr_frame = ctk.CTkFrame(self.root, fg_color="transparent")
        hdr_frame.pack(fill="x", padx=16, pady=(8, 0))
        hdr_frame.grid_columnconfigure(5, weight=1)  # Target column expands (matches ChannelRow)
        headers = [
            # (text, width, padx) — matching ChannelRow widget widths and paddings
            ("CH", 50, (8, 4)),
            ("", 26, 2),
            ("Usuario", 110, 4),
            ("Password", 90, 4),
            ("Tipo", 80, 4),
            ("Target", 120, 4),
            ("In Device", 130, 2),
            ("ch", 30, 1),
            ("Out Device", 130, 2),
            ("ch", 30, 1),
            ("VOX→", 50, 2),
            ("dB", 42, 2),
            ("TX", 40, 2),
            ("", 30, 1),
            ("VOX←", 50, 2),
            ("dB", 42, 2),
            ("RX", 40, 2),
            ("", 30, 1),
            ("", 24, 1),
            ("", 30, (2, 8)),
        ]
        for col, (text, w, px) in enumerate(headers):
            lbl = ctk.CTkLabel(hdr_frame, text=text, font=("SF Pro Display", 11, "bold"),
                               text_color=COLOR_DIM, width=w)
            sticky = "ew" if col == 5 else ""
            lbl.grid(row=0, column=col, padx=px, sticky=sticky)

        # ---- Scrollable channel list ----
        self.scroll_frame = ctk.CTkScrollableFrame(self.root, fg_color=COLOR_BG,
                                                    corner_radius=0)
        self.scroll_frame.pack(fill="both", expand=True, padx=12, pady=4)
        self.scroll_frame.grid_columnconfigure(0, weight=1)

        self.channel_rows = []
        for i in range(16):
            row = ChannelRow(self.scroll_frame, i, i, on_connect=self._on_channel_connect)
            self.channel_rows.append(row)

        # ---- Status bar ----
        status_frame = ctk.CTkFrame(self.root, fg_color=COLOR_CARD, corner_radius=0, height=32)
        status_frame.pack(fill="x")
        status_frame.pack_propagate(False)
        self.status_var = tk.StringVar(value="Disconnected")
        self.status_label = ctk.CTkLabel(status_frame, textvariable=self.status_var,
                                          font=("SF Pro Display", 12),
                                          text_color=COLOR_DIM)
        self.status_label.pack(side="left", padx=12, pady=4)

    # ======================== SERVER VALIDATION ========================

    def _on_server_changed(self, *_args):
        """Called when server_var changes. Debounce and validate."""
        self._server_status.configure(text_color=COLOR_ORANGE)
        if self._server_check_timer:
            self.root.after_cancel(self._server_check_timer)
        self._server_check_timer = self.root.after(800, self._validate_server)

    def _validate_server(self):
        """Check server reachability and save config."""
        server = self.server_var.get().strip()
        if not server:
            self._server_status.configure(text_color=COLOR_DIM)
            return
        self._save_config()
        self.status_var.set(f"Verificando {server}...")
        threading.Thread(target=self._check_server_bg, args=(server,), daemon=True).start()

    def _check_server_bg(self, server: str):
        """Background thread: ping the server API."""
        import asyncio as _aio
        loop = _aio.new_event_loop()
        try:
            loop.run_until_complete(self._check_server_async(server))
            self.root.after(0, self._server_ok, server)
        except Exception as e:
            self.root.after(0, self._server_fail, server, str(e))
        finally:
            loop.close()

    async def _check_server_async(self, server: str):
        timeout = aiohttp.ClientTimeout(total=5)
        conn = aiohttp.TCPConnector(ssl=False)
        async with aiohttp.ClientSession(connector=conn, timeout=timeout) as session:
            async with session.get(f"{server}/api/health") as resp:
                if resp.status != 200:
                    raise RuntimeError(f"HTTP {resp.status}")

    def _server_ok(self, server: str):
        # Only update if server hasn't changed since check started
        if self.server_var.get().strip() == server:
            self._server_status.configure(text_color=COLOR_GREEN)
            self.status_var.set(f"✓ Server OK: {server}")

    def _server_fail(self, server: str, error: str):
        if self.server_var.get().strip() == server:
            self._server_status.configure(text_color=COLOR_RED)
            self.status_var.set(f"✗ Server no alcanzable: {error}")

    def _refresh_devices(self):
        try:
            devices = sd.query_devices()
        except Exception as e:
            messagebox.showerror("Error", f"Cannot list devices:\n{e}")
            return

        inputs = []
        outputs = []
        for i, d in enumerate(devices):
            if d['max_input_channels'] > 0:
                inputs.append(f"{i}: {d['name']} ({d['max_input_channels']}ch)")
            if d['max_output_channels'] > 0:
                outputs.append(f"{i}: {d['name']} ({d['max_output_channels']}ch)")

        self.input_combo.configure(values=inputs)
        self.output_combo.configure(values=outputs)
        self._input_devices = inputs
        self._output_devices = outputs
        # Update per-channel device dropdowns
        for row in self.channel_rows:
            row.set_devices(inputs, outputs)

        for item in inputs:
            try:
                ch_count = int(item.rsplit("(", 1)[1].split("ch")[0])
            except (IndexError, ValueError):
                ch_count = 0
            if ch_count > 2:
                self.input_dev_var.set(item)
                break
        else:
            if inputs:
                self.input_dev_var.set(inputs[0])

        for item in outputs:
            try:
                ch_count = int(item.rsplit("(", 1)[1].split("ch")[0])
            except (IndexError, ValueError):
                ch_count = 0
            if ch_count > 2:
                self.output_dev_var.set(item)
                break
        else:
            if outputs:
                self.output_dev_var.set(outputs[0])

    def _get_device_id(self, combo_value: str) -> int:
        try:
            return int(combo_value.split(":")[0])
        except (ValueError, IndexError):
            return -1

    def _apply_defaults_to_all(self):
        """Apply the default In/Out device to all channel rows."""
        default_in = self.input_dev_var.get()
        default_out = self.output_dev_var.get()
        if not default_in and not default_out:
            messagebox.showwarning("Config", "Select at least one default device")
            return
        count = 0
        for row in self.channel_rows:
            if row.channel is not None:
                continue  # Don't change connected channels
            if default_in:
                row.in_dev_var.set(default_in)
            if default_out:
                row.out_dev_var.set(default_out)
            count += 1
        self.status_var.set(f"✓ Default devices applied to {count} channels")

    # ======================== LOGIN & DOWNLOAD CONFIG ========================

    def _show_login_dialog(self):
        """Show admin login dialog, then download bridge config + directory."""
        server = self.server_var.get().strip()
        if not server:
            messagebox.showwarning("Login", "Enter the server URL first")
            return

        dialog = ctk.CTkToplevel(self.root)
        dialog.title("Admin Login")
        dialog.geometry("340x260")
        dialog.resizable(False, False)
        dialog.configure(fg_color=COLOR_CARD)
        dialog.transient(self.root)
        dialog.grab_set()

        ctk.CTkLabel(dialog, text="Admin credentials", font=("SF Pro Display", 16, "bold"),
                     text_color=COLOR_TEXT).pack(pady=(16, 4))
        ctk.CTkLabel(dialog, text=f"Server: {server}", font=("SF Pro Display", 11),
                     text_color=COLOR_DIM).pack(pady=(0, 12))

        user_var = tk.StringVar(value="admin")
        pass_var = tk.StringVar()

        ctk.CTkEntry(dialog, textvariable=user_var, width=260, height=32,
                     placeholder_text="Username").pack(pady=4)
        pass_entry = ctk.CTkEntry(dialog, textvariable=pass_var, width=260, height=32,
                                   placeholder_text="Password", show="\u2022")
        pass_entry.pack(pady=4)
        pass_entry.focus()

        status_label = ctk.CTkLabel(dialog, text="", font=("SF Pro Display", 11),
                                      text_color=COLOR_RED)
        status_label.pack(pady=(4, 0))

        def do_login():
            u = user_var.get().strip()
            p = pass_var.get().strip()
            if not u or not p:
                return
            status_label.configure(text="Connecting...", text_color=COLOR_ORANGE)
            threading.Thread(target=self._login_and_download, args=(server, (u, p), dialog, status_label), daemon=True).start()

        pass_entry.bind("<Return>", lambda _: do_login())
        ctk.CTkButton(dialog, text="Login & Download Config", width=260, height=36,
                      font=("SF Pro Display", 13, "bold"),
                      fg_color=COLOR_GREEN, hover_color="#00c853",
                      text_color="#1a1a2e",
                      command=do_login).pack(pady=(12, 8))

    def _login_and_download(self, server: str, creds: tuple, dialog, status_label):
        """Background: authenticate admin, then download config. Close dialog only on success."""
        import asyncio as _aio
        loop = _aio.new_event_loop()
        try:
            result = loop.run_until_complete(self._download_config_async(server, creds))
            if result:
                self._admin_authenticated = True
                self.root.after(0, dialog.destroy)
                self.root.after(0, self._apply_server_config, result)
                self.root.after(0, self._update_auth_state)
        except Exception as e:
            self._admin_authenticated = False
            msg = str(e)
            self.root.after(0, lambda: status_label.configure(text=f"\u2717 {msg}", text_color=COLOR_RED))
            self.root.after(0, lambda: self.status_var.set(f"Login failed: {msg}"))
        finally:
            loop.close()

    def _update_auth_state(self):
        """Enable/disable connect buttons based on auth state."""
        for row in self.channel_rows:
            if self._admin_authenticated:
                row.ch_connect_btn.configure(state="normal")
            else:
                row.ch_connect_btn.configure(state="disabled")
        self.connect_btn.configure(state="normal" if self._admin_authenticated else "disabled")

    async def _download_config_async(self, server: str, creds: tuple):
        timeout = aiohttp.ClientTimeout(total=10)
        conn = aiohttp.TCPConnector(ssl=False)
        async with aiohttp.ClientSession(connector=conn, timeout=timeout) as session:
            # Login as admin (bridge users may not have admin access)
            async with session.post(f"{server}/api/auth/login",
                                    json={"username": creds[0], "password": creds[1]}) as resp:
                if resp.status != 200:
                    raise RuntimeError(f"Login failed: {resp.status}")
                data = await resp.json()
                token = data["token"]
            # Fetch bridge config
            async with session.get(f"{server}/api/admin/bridge-config",
                                   headers={"Authorization": f"Bearer {token}"}) as resp:
                if resp.status != 200:
                    raise RuntimeError(f"Bridge config: HTTP {resp.status}")
                return await resp.json()

    def _apply_server_config(self, config: dict):
        """Apply downloaded server config to channel rows."""
        channels = config.get("channels", [])
        count = 0
        for ch in channels:
            idx = ch.get("index", 0) - 1
            if 0 <= idx < len(self.channel_rows):
                row = self.channel_rows[idx]
                if row.channel is not None:
                    continue  # Don't modify connected channels
                row.user_var.set(ch.get("username", ""))
                row.pass_var.set(ch.get("password", ""))
                row.ttype_var.set(ch.get("target_type", "user"))
                row._pending_target_id = ch.get("target_id", 0)
                if ch.get("input_device"):
                    row.in_dev_var.set(ch["input_device"])
                if ch.get("output_device"):
                    row.out_dev_var.set(ch["output_device"])
                row.in_ch_var.set(str(ch.get("input_channel", idx + 1)))
                row.out_ch_var.set(str(ch.get("output_channel", idx + 1)))
                row._vox_send_enabled = ch.get("vox_send_enabled", False)
                row.vox_send_db_var.set(str(ch.get("vox_send_threshold_db", -40)))
                row._update_vox_send_visual()
                row._vox_recv_enabled = ch.get("vox_recv_enabled", True)
                row.vox_recv_db_var.set(str(ch.get("vox_recv_threshold_db", -40)))
                row._update_vox_recv_visual()
                count += 1
        # Now fetch directory to resolve target names
        self._fetch_directory()
        self._save_config()
        self.status_var.set(f"\u2713 Config downloaded: {count} channels configured")

    # ======================== DIRECTORY ========================

    def _fetch_directory(self):
        server = self.server_var.get().strip()
        if not server:
            messagebox.showwarning("Config", "Enter the server URL")
            return
        creds = None
        for row in self.channel_rows:
            u = row.user_var.get().strip()
            p = row.pass_var.get().strip()
            if u and p:
                creds = (u, p)
                break
        if not creds:
            messagebox.showwarning("Config", "Configure at least one channel with username/password")
            return
        self.status_var.set("Loading users...")
        threading.Thread(target=self._fetch_directory_bg, args=(server, creds), daemon=True).start()

    def _fetch_directory_bg(self, server: str, creds: tuple):
        import asyncio as _aio
        loop = _aio.new_event_loop()
        try:
            print(f"[Directory] Fetching from {server} with user={creds[0]}")
            result = loop.run_until_complete(self._fetch_directory_async(server, creds))
            if result:
                print(f"[Directory] Got {len(result.get('users',[]))} users, {len(result.get('groups',[]))} groups")
                self.root.after(0, self._apply_directory, result)
            else:
                print("[Directory] Empty result")
                self.root.after(0, lambda: self.status_var.set("Error: respuesta vacía"))
        except Exception as e:
            err_msg = str(e)
            print(f"[Directory] Error: {err_msg}")
            self.root.after(0, lambda msg=err_msg: self.status_var.set(f"Error: {msg}"))
        finally:
            loop.close()

    async def _fetch_directory_async(self, server: str, creds: tuple):
        timeout = aiohttp.ClientTimeout(total=10)
        conn = aiohttp.TCPConnector(ssl=False)
        async with aiohttp.ClientSession(connector=conn, timeout=timeout) as session:
            async with session.post(f"{server}/api/auth/login",
                                    json={"username": creds[0], "password": creds[1], "client_type": "bridge"}) as resp:
                if resp.status != 200:
                    body = await resp.text()
                    raise RuntimeError(f"Login failed ({resp.status}): {body}")
                data = await resp.json()
                token = data["token"]
            async with session.get(f"{server}/api/rooms/directory",
                                   headers={"Authorization": f"Bearer {token}"}) as resp:
                if resp.status != 200:
                    raise RuntimeError(f"Directory: {resp.status}")
                return await resp.json()

    def _apply_directory(self, directory: dict):
        users = directory.get("users", [])
        groups = directory.get("groups", [])
        for row in self.channel_rows:
            row.set_directory(users, groups)
            row.apply_pending_target()
        self.status_var.set(f"✓ {len(users)} usuarios, {len(groups)} grupos")

    # ======================== CONNECT / DISCONNECT ========================

    def _on_connect(self):
        """Global connect/disconnect toggle."""
        if self.channels:
            self._disconnect_all()
        else:
            self._connect_all()

    def _connect_all(self):
        """Connect all configured channels."""
        server = self.server_var.get().strip()
        if not server:
            messagebox.showwarning("Config", "Enter the server URL")
            return
        rows = [r for r in self.channel_rows if r.get_config() and r.channel is None]
        if not rows:
            messagebox.showwarning("Config", "Configure at least one channel")
            return
        self._save_config()
        for row in rows:
            self._connect_channel(row)

    def _disconnect_all(self):
        """Disconnect all active channels."""
        for row in self.channel_rows:
            if row.channel:
                self._disconnect_channel(row)

    def _on_channel_connect(self, row: ChannelRow):
        """Per-channel connect/disconnect callback from row button."""
        if row.channel:
            self._disconnect_channel(row)
        else:
            server = self.server_var.get().strip()
            if not server:
                messagebox.showwarning("Config", "Enter the server URL")
                return
            cfg = row.get_config()
            if not cfg:
                messagebox.showwarning("Config", f"Configura CH {row.index + 1}")
                return
            self._save_config()
            self._connect_channel(row)

    def _connect_channel(self, row: ChannelRow):
        """Create and start a single channel."""
        cfg = row.get_config()
        if not cfg:
            return
        server = self.server_var.get().strip()
        try:
            self._ensure_audio_pool()
        except Exception as e:
            messagebox.showerror("Audio", f"Cannot open audio device:\n{e}")
            return
        self._ensure_async_loop()

        # Resolve per-channel devices (fall back to global)
        in_dev_str = cfg.get("input_device") or self.input_dev_var.get()
        out_dev_str = cfg.get("output_device") or self.output_dev_var.get()
        in_dev = self._get_device_id(in_dev_str)
        out_dev = self._get_device_id(out_dev_str)
        in_ch = cfg.get("input_channel", cfg["index"]) - 1  # 1-based → 0-based
        out_ch = cfg.get("output_channel", cfg["index"]) - 1

        if in_dev < 0 or out_dev < 0:
            messagebox.showwarning("Audio", f"CH {row.index + 1}: Select input and output devices")
            return

        # Open devices via pool
        try:
            self.audio_pool.open_input(in_dev)
            self.audio_pool.open_output(out_dev)
        except Exception as e:
            messagebox.showerror("Audio", f"Cannot open device:\n{e}")
            return

        ch = TieLineChannel(
            index=cfg["index"] - 1, server_url=server,
            username=cfg["username"], password=cfg["password"],
            target_type=cfg["target_type"], target_id=cfg["target_id"],
            audio_pool=self.audio_pool,
            input_device=in_dev, input_channel=in_ch,
            output_device=out_dev, output_channel=out_ch,
            vox_send_enabled=cfg["vox_send_enabled"],
            vox_send_threshold_db=cfg["vox_send_threshold_db"],
            vox_send_hold_ms=cfg["vox_send_hold_ms"],
            vox_recv_enabled=cfg["vox_recv_enabled"],
            vox_recv_threshold_db=cfg["vox_recv_threshold_db"],
            vox_recv_hold_ms=cfg["vox_recv_hold_ms"],
            bridge_ip=self.bridge_ip_var.get().strip())
        row.channel = ch
        row.set_connected(True)
        self.channels.append(ch)
        self._update_global_button()
        self.status_var.set(f"Conectando CH {row.index + 1}...")
        asyncio.run_coroutine_threadsafe(self._run_channel(row, ch), self.loop)

    def _disconnect_channel(self, row: ChannelRow):
        """Request a single channel to stop."""
        ch = row.channel
        if ch and self.loop:
            asyncio.run_coroutine_threadsafe(ch.stop(), self.loop)

    async def _run_channel(self, row: ChannelRow, ch: TieLineChannel):
        """Run a channel's async loop and notify UI when done."""
        try:
            await ch.run()
        except Exception as e:
            print(f"[{ch.label}] Error: {e}")
        finally:
            self.root.after(0, lambda: self._on_channel_stopped(row, ch))

    def _on_channel_stopped(self, row: ChannelRow, ch: TieLineChannel):
        """Called on main thread when a channel finishes."""
        if row.channel is not ch:
            return
        row.channel = None
        if ch in self.channels:
            self.channels.remove(ch)
        row.set_connected(False)
        self._update_global_button()
        self._maybe_stop_resources()

    def _ensure_audio_pool(self):
        """Create audio device pool if not already created."""
        if self.audio_pool is not None:
            return
        self.audio_pool = AudioDevicePool(sample_rate=48000)

    def _ensure_async_loop(self):
        """Start the async event loop thread if not running."""
        if self.loop is not None and self.loop.is_running():
            return
        self.async_thread = threading.Thread(target=self._run_event_loop, daemon=True)
        self.async_thread.start()
        import time
        for _ in range(100):
            if self.loop is not None and self.loop.is_running():
                break
            time.sleep(0.01)

    def _run_event_loop(self):
        """Background thread running the asyncio event loop."""
        self.loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self.loop)
        self.loop.run_forever()
        self.loop.close()
        self.loop = None

    def _maybe_stop_resources(self):
        """Stop audio pool when no channels are active."""
        if self.channels:
            return
        if self.audio_pool:
            self.audio_pool.stop_all()
            self.audio_pool = None
        self.status_var.set("Disconnected")

    def _update_global_button(self):
        """Update the global connect button based on channel state."""
        if self.channels:
            self.running = True
            self.connect_btn.configure(text="■  Desconectar", fg_color=COLOR_RED,
                                        hover_color="#d32f2f")
        else:
            self.running = False
            self.connect_btn.configure(text="▶  Connect", fg_color=COLOR_GREEN,
                                        hover_color="#00c853")

    # ======================== STATUS TIMER ========================

    def _start_status_timer(self):
        for row in self.channel_rows:
            row.update_status()
        if self.running:
            connected = sum(1 for ch in self.channels if ch.connected)
            vox_count = sum(1 for ch in self.channels if ch.vox_active)
            self.status_var.set(
                f"● {connected}/{len(self.channels)} conectados  │  VOX: {vox_count}")
        self.root.after(200, self._start_status_timer)

    # ======================== CONFIG ========================

    def _save_config(self):
        channels = []
        for row in self.channel_rows:
            cfg = row.get_config()
            if cfg:
                channels.append(cfg)
        config = {
            "server": self.server_var.get().strip(),
            "input_device": self.input_dev_var.get(),
            "output_device": self.output_dev_var.get(),
            "bridge_ip": self.bridge_ip_var.get().strip(),
            "num_device_channels": int(self.num_ch_var.get()),
            "sample_rate": 48000,
            "channels": channels,
        }
        try:
            with open(CONFIG_FILE, "w") as f:
                json.dump(config, f, indent=2)
        except Exception as e:
            print(f"Error saving config: {e}")

    def _load_config(self):
        if not os.path.exists(CONFIG_FILE):
            return
        try:
            with open(CONFIG_FILE) as f:
                config = json.load(f)
        except Exception:
            return
        self.server_var.set(config.get("server", "https://192.168.4.8:8443"))
        self.bridge_ip_var.set(config.get("bridge_ip", ""))
        self.num_ch_var.set(str(config.get("num_device_channels", 16)))
        saved_input = config.get("input_device", "")
        saved_output = config.get("output_device", "")
        if saved_input:
            self.input_dev_var.set(saved_input)
        if saved_output:
            self.output_dev_var.set(saved_output)
        for ch_cfg in config.get("channels", []):
            idx = ch_cfg.get("index", 0) - 1
            if 0 <= idx < len(self.channel_rows):
                self.channel_rows[idx].set_config(ch_cfg)

    # ======================== RUN ========================

    def run(self):
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)
        self.root.mainloop()

    def _on_close(self):
        for row in self.channel_rows:
            ch = row.channel
            if ch and self.loop:
                asyncio.run_coroutine_threadsafe(ch.stop(), self.loop)
        if self.audio_pool:
            self.audio_pool.stop_all()
            self.audio_pool = None
        if self.loop:
            self.loop.call_soon_threadsafe(self.loop.stop)
        self._save_config()
        self.root.destroy()


def main():
    app = BridgeApp()
    app.run()


if __name__ == "__main__":
    main()
