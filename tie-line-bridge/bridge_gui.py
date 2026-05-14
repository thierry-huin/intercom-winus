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
        # `index` is the *logical* channel id (0–based) currently shown in
        # this row. The same widget is reused across banks of 8 channels,
        # so the index can change at runtime via `set_logical_index()`.
        self.index = index
        self.channel: TieLineChannel | None = None
        self._directory: dict = {"user": [], "group": []}
        self._all_users: list = []  # full list incl. bridges, used to resolve display_name
        self._pending_target_id: int = 0
        self._on_connect_cb = on_connect
        self._vox_send_enabled = True
        self._vox_recv_enabled = True
        self._external_in_use = False  # username online from another bridge

        bg = COLOR_ROW_ODD if index % 2 else COLOR_ROW_EVEN

        # Row frame
        self.frame = ctk.CTkFrame(parent, fg_color=bg, corner_radius=6, height=40)
        self.frame.grid(row=row, column=0, sticky="ew", padx=4, pady=2)
        self.frame.grid_columnconfigure(6, weight=1)  # Target column expands

        col = 0

        # Channel number (updated on bank switch via set_logical_index).
        self.lbl = ctk.CTkLabel(self.frame, text=f"CH {index + 1}",
                                font=("SF Pro Display", 14, "bold"),
                                text_color=COLOR_ACCENT2, width=50)
        self.lbl.grid(row=0, column=col, padx=(8, 4), pady=6); col += 1

        # Status dot (big LED) — grey when idle, green when this bridge
        # owns the connection, red when an error occurred locally. Sized up
        # so it's clearly visible at a glance from across the room.
        self.status_dot = ctk.CTkLabel(self.frame, text="●", font=("Arial", 32),
                                       text_color=COLOR_DIM, width=44)
        self.status_dot.grid(row=0, column=col, padx=4); col += 1

        # Username — fg_color flips to red when the same username is
        # online from another bridge instance ("external in use").
        self.user_var = tk.StringVar()
        # Capture the default fg_color so we can restore it when the
        # external flag clears. CTkEntry uses a 2-tuple (light, dark) for
        # fg_color; we store both ends.
        self._user_default_fg = ("#343638", "#343638")  # ctk dark default
        self.user_entry = ctk.CTkEntry(self.frame, textvariable=self.user_var, width=120,
                                        placeholder_text="usuario", height=32,
                                        font=("SF Pro Display", 13, "bold"))
        self.user_entry.grid(row=0, column=col, padx=4, pady=4); col += 1

        # Display name resolved from the server directory. Rendered as a
        # read-only Entry so it visually matches the Usuario column (same
        # bordered box, same height) — a bare label looked like the field
        # was missing.
        self.display_var = tk.StringVar(value="")
        self.display_entry = ctk.CTkEntry(self.frame, textvariable=self.display_var,
                                           width=120, height=32,
                                           font=("SF Pro Display", 13, "bold"),
                                           state="readonly")
        self.display_entry.grid(row=0, column=col, padx=4, pady=4); col += 1
        # Refresh display name whenever the username field changes.
        self.user_var.trace_add("write", lambda *_: self._refresh_display_name())

        # Password
        self.pass_var = tk.StringVar()
        self.pass_entry = ctk.CTkEntry(self.frame, textvariable=self.pass_var, width=100,
                                        placeholder_text="password", show="•", height=32)
        self.pass_entry.grid(row=0, column=col, padx=4, pady=4); col += 1

        # Target type
        self.ttype_var = tk.StringVar(value="user")
        self.ttype_combo = ctk.CTkComboBox(self.frame, variable=self.ttype_var,
                                            values=["user", "group"], width=80,
                                            height=30, state="readonly",
                                            command=lambda _: self._update_target_dropdown())
        self.ttype_combo.grid(row=0, column=col, padx=4, pady=4); col += 1

        # Target dropdown — wide enough to show the full "Display name (id)"
        # without truncation for typical bridge directory entries.
        self.tid_var = tk.StringVar(value="")
        self.tid_combo = ctk.CTkComboBox(self.frame, variable=self.tid_var,
                                          values=[], width=200, height=32, state="readonly")
        self.tid_combo.grid(row=0, column=col, padx=4, pady=4, sticky="ew"); col += 1

        # --- Per-channel audio device selection ---
        self.in_dev_var = tk.StringVar(value="")
        self.in_dev_combo = ctk.CTkComboBox(self.frame, variable=self.in_dev_var,
                                             values=[], width=210, height=28, state="readonly")
        self.in_dev_combo.grid(row=0, column=col, padx=2, pady=4); col += 1

        self.in_ch_var = tk.StringVar(value="1")
        self.in_ch_spin = ctk.CTkEntry(self.frame, textvariable=self.in_ch_var, width=30,
                                        height=26, placeholder_text="ch")
        self.in_ch_spin.grid(row=0, column=col, padx=1, pady=4); col += 1

        self.out_dev_var = tk.StringVar(value="")
        self.out_dev_combo = ctk.CTkComboBox(self.frame, variable=self.out_dev_var,
                                              values=[], width=210, height=28, state="readonly")
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
                                               width=58, placeholder_text="dB", height=28)
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
                                               width=58, placeholder_text="dB", height=28)
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
        # Filter out admin / superadmin accounts: they're system-level
        # roles, never PTT endpoints, and used to leak into the Target
        # dropdown along with the regular users.
        users = [u for u in users
                  if u.get("role") not in ("admin", "superadmin")]
        # Cache full (filtered) user list so we can map username →
        # display_name on demand (the dropdown values only carry
        # display_name + id).
        self._all_users = users
        self._directory["user"] = [(u["id"], u["display_name"]) for u in users]
        self._directory["group"] = [(g["id"], g["name"]) for g in groups]
        self._update_target_dropdown()
        self._refresh_display_name()

    def _refresh_display_name(self):
        """Look up the configured username in the cached directory and
        reflect its display_name on the small label next to the entry.
        Called both when the directory arrives and whenever user_var changes."""
        uname = self.user_var.get().strip()
        if not uname:
            self.display_var.set("")
            return
        for u in self._all_users:
            if u.get("username") == uname:
                self.display_var.set(u.get("display_name") or "")
                return
        # Username not yet known to the server; clear the label.
        self.display_var.set("")

    def set_external_in_use(self, in_use: bool):
        """Signal that this username is already online from another bridge
        instance. To keep the visual cue tight (and avoid the previous
        "the whole row turns red" effect) we limit the alert to two
        elements: the Usuario entry's fill colour and the status LED.
        We also block the per-channel ▶ button so the operator can't
        accidentally collide with the foreign session — they have to
        wait for the other bridge to release the slot.

        Suppressed automatically while we own the connection ourselves;
        no point alarming the operator about their own session."""
        if self.channel is not None and self.channel.connected:
            in_use = False
        if in_use == self._external_in_use:
            return
        self._external_in_use = in_use
        if in_use:
            self.user_entry.configure(fg_color=COLOR_RED, text_color="white")
            self.status_dot.configure(text_color=COLOR_RED)
            # Block the play button while the username is taken elsewhere.
            self.ch_connect_btn.configure(state="disabled")
        else:
            self.user_entry.configure(fg_color=self._user_default_fg,
                                       text_color=COLOR_TEXT)
            # Only restore the LED to grey if the channel is not running
            # locally; otherwise update_status() will reassert green next
            # tick. Setting it to dim here is fine — it'll flip back on
            # the next 200 ms refresh.
            self.status_dot.configure(text_color=COLOR_DIM)
            # Re-enable the play button (update_auth_state will override
            # to disabled again if the admin isn't authenticated yet).
            self.ch_connect_btn.configure(state="normal")

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
            # Idle. The LED defaults to grey, but when this username is
            # online from another bridge we keep it red so the operator
            # has a constant visual cue — update_status() runs every
            # 200 ms, so without this branch it would erase the red set
            # by set_external_in_use().
            if self._external_in_use:
                self.status_dot.configure(text_color=COLOR_RED)
            else:
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
        # display_entry stays read-only either way (its content is
        # resolved from the server, never typed by the operator).
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

    def set_logical_index(self, new_index: int):
        """Reuse the same row widget for a different logical channel id.
        Called on bank switching so 8 widgets cover 8/16/24/32 channels."""
        self.index = new_index
        self.lbl.configure(text=f"CH {new_index + 1}")

    def clear_fields(self):
        """Reset every field to defaults; used when paging into an empty
        bank slot. Doesn't touch self.channel — callers must ensure the
        channel is None before swapping data."""
        self.user_var.set("")
        self.pass_var.set("")
        self.ttype_var.set("user")
        self.tid_var.set("")
        self._pending_target_id = 0
        self.in_dev_var.set("")
        self.out_dev_var.set("")
        self.in_ch_var.set(str(self.index + 1))
        self.out_ch_var.set(str(self.index + 1))
        self._vox_send_enabled = False
        self.vox_send_db_var.set("-40")
        self._update_vox_send_visual()
        self._vox_recv_enabled = True
        self.vox_recv_db_var.set("-40")
        self._update_vox_recv_visual()
        # Reset the red "external in use" tint if it was applied.
        self._external_in_use = False
        self.user_entry.configure(fg_color=self._user_default_fg, text_color=COLOR_TEXT)
        self.status_dot.configure(text_color=COLOR_DIM)

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
        self.root.geometry("1850x650")
        self.root.minsize(1500, 500)
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
        self._admin_token: str | None = None
        self._admin_creds: tuple | None = None
        self._bridge_status_timer = None

        # ---- Channel paging ----
        # The GUI builds exactly ROWS_PER_BANK ChannelRow widgets and reuses
        # them across banks. Anything beyond what's visible lives in
        # `_channel_data` as plain dicts. macOS customtkinter cannot create
        # 32 widget-rich rows in a reasonable time, so this paging keeps
        # the on-screen widget count constant and small.
        self.ROWS_PER_BANK = 8
        self._total_channels = 16  # default; user can pick 8/16/24/32
        self._current_bank = 0     # index of the bank currently shown
        self._channel_data: list[dict] = [{} for _ in range(32)]
        self._channels_running: list[TieLineChannel | None] = [None] * 32

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

        ctk.CTkLabel(header, text="Audio Matrix Bridge v.3.3.0",
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
        # Empty by default — forces the user to fill in the right URL on a
        # fresh install. No more hardcoded LAN IPs that could send the
        # validation thread chasing a host that doesn't exist.
        self.server_var = tk.StringVar(value="")
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

        ctk.CTkButton(row1, text="🗑 Reset", width=90, height=32,
                      fg_color=COLOR_RED, hover_color="#d32f2f",
                      command=self._reset_config).pack(side="right", padx=4)

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

        # Number of UI channel rows. macOS customtkinter chokes well before
        # the 32 widget-rich rows are built (~700 widgets), so we cap at 16
        # which is what the v3.2 release shipped with and is known to work.
        # Linux can comfortably go higher; we'll lift this back to 32 once
        # the row layout is rewritten in plain tk for performance.
        self.num_ch_var = tk.StringVar(value="16")

        # Bridge IP was removed from the UI — the channel now auto-detects the
        # right local IP (`_get_local_ip_for(server)` in channel.py). Kept as a
        # hidden StringVar so the rest of the code (save/load/reset) doesn't
        # need touching.
        self.bridge_ip_var = tk.StringVar(value="")

        ctk.CTkButton(row2, text="▶ Apply to all", width=120, height=32,
                      font=("SF Pro Display", 12, "bold"),
                      fg_color=COLOR_BLUE, hover_color="#1976d2",
                      command=self._apply_defaults_to_all).pack(side="left", padx=(12, 4))

        # ---- Total channel count (8 / 16 / 24 / 32) ----
        ctk.CTkLabel(row2, text="  Total channels", font=("SF Pro Display", 12),
                     text_color=COLOR_DIM).pack(side="left", padx=(16, 4))
        self._total_var = tk.StringVar(value=str(self._total_channels))
        ctk.CTkComboBox(row2, variable=self._total_var,
                         values=["8", "16", "24", "32"], width=70, height=32,
                         state="readonly",
                         command=lambda v: self._on_total_changed(int(v))
                         ).pack(side="left", padx=4)

        # ---- Bank selector (◀  Bank N/M  ▶) ----
        ctk.CTkLabel(row2, text="  Bank", font=("SF Pro Display", 12),
                     text_color=COLOR_DIM).pack(side="left", padx=(16, 4))
        self._bank_prev_btn = ctk.CTkButton(
            row2, text="◀", width=32, height=32,
            fg_color=COLOR_ACCENT2, hover_color="#00a0b0", text_color="#1a1a2e",
            command=self._bank_prev)
        self._bank_prev_btn.pack(side="left", padx=2)
        self._bank_label = ctk.CTkLabel(row2, text="1–8 / 16",
                                         font=("SF Pro Display", 12, "bold"),
                                         text_color=COLOR_TEXT, width=80)
        self._bank_label.pack(side="left", padx=2)
        self._bank_next_btn = ctk.CTkButton(
            row2, text="▶", width=32, height=32,
            fg_color=COLOR_ACCENT2, hover_color="#00a0b0", text_color="#1a1a2e",
            command=self._bank_next)
        self._bank_next_btn.pack(side="left", padx=2)

        # ---- Column headers ----
        # Use a grid-based frame matching the ChannelRow layout for exact alignment.
        # Two new columns vs the original layout: an external-in-use LED right
        # after the local status LED, and the resolved display_name label right
        # after the username entry. Target column index moves from 5 to 6.
        # Header row — widths must mirror the ChannelRow widgets exactly
        # for vertical alignment. The external_dot column has been
        # eliminated; the red highlight now paints the Username / Display
        # name / Password fields directly.
        hdr_frame = ctk.CTkFrame(self.root, fg_color="transparent")
        hdr_frame.pack(fill="x", padx=16, pady=(8, 0))
        # Target sits at column 6 (after CH/LED/Usuario/Display/Password/Tipo)
        # and is the only column that should grow when the window is wide.
        hdr_frame.grid_columnconfigure(6, weight=1)
        headers = [
            ("CH", 50, (8, 4)),
            ("", 44, 4),         # large status LED
            ("Usuario", 120, 4),
            ("Display name", 120, 4),
            ("Password", 100, 4),
            ("Tipo", 80, 4),
            ("Target", 200, 4),
            ("In Device", 210, 2),
            ("ch", 30, 1),
            ("Out Device", 210, 2),
            ("ch", 30, 1),
            ("VOX→", 50, 2),
            ("dB", 58, 2),
            ("TX", 40, 2),
            ("", 30, 1),
            ("VOX←", 50, 2),
            ("dB", 58, 2),
            ("RX", 40, 2),
            ("", 30, 1),
            ("", 24, 1),
            ("", 30, (2, 8)),
        ]
        for col, (text, w, px) in enumerate(headers):
            lbl = ctk.CTkLabel(hdr_frame, text=text, font=("SF Pro Display", 11, "bold"),
                               text_color=COLOR_DIM, width=w)
            sticky = "ew" if col == 6 else ""
            lbl.grid(row=0, column=col, padx=px, sticky=sticky)

        # ---- Scrollable channel list ----
        self.scroll_frame = ctk.CTkScrollableFrame(self.root, fg_color=COLOR_BG,
                                                    corner_radius=0)
        self.scroll_frame.pack(fill="both", expand=True, padx=12, pady=4)
        self.scroll_frame.grid_columnconfigure(0, weight=1)

        # Build a fixed pool of 8 widget rows. Their logical index is
        # remapped on bank switches via ChannelRow.set_logical_index().
        self.channel_rows = []
        for i in range(self.ROWS_PER_BANK):
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

    # ======================== CHANNEL PAGING ========================

    def _bank_count(self) -> int:
        return max(1, self._total_channels // self.ROWS_PER_BANK)

    def _refresh_bank_indicators(self):
        n = self._bank_count()
        b = self._current_bank + 1
        first = self._current_bank * self.ROWS_PER_BANK + 1
        last = first + self.ROWS_PER_BANK - 1
        self._bank_label.configure(
            text=f"{first}–{last} / {self._total_channels}")
        # Enable/disable nav buttons based on position.
        self._bank_prev_btn.configure(
            state="normal" if self._current_bank > 0 else "disabled")
        self._bank_next_btn.configure(
            state="normal" if b < n else "disabled")

    def _stash_visible_into_data(self):
        """Save the 8 currently-visible row configs back into
        `_channel_data` so the next bank-load can find them."""
        offset = self._current_bank * self.ROWS_PER_BANK
        for i, row in enumerate(self.channel_rows):
            cfg = row.get_config()
            self._channel_data[offset + i] = cfg if cfg else {}
            self._channels_running[offset + i] = row.channel

    def _load_visible_from_data(self):
        """Push the bank's 8 entries from `_channel_data` into the
        on-screen rows. Empty slots clear the row."""
        offset = self._current_bank * self.ROWS_PER_BANK
        for i, row in enumerate(self.channel_rows):
            new_idx = offset + i
            row.set_logical_index(new_idx)
            data = self._channel_data[new_idx] or {}
            if data:
                row.set_config(data)
            else:
                row.clear_fields()
            # Re-bind any running channel object that lives in this slot.
            row.channel = self._channels_running[new_idx]
            row.set_connected(row.channel is not None)

    def _switch_bank(self, new_bank: int):
        if new_bank == self._current_bank:
            return
        if not (0 <= new_bank < self._bank_count()):
            return
        # Channels keep running across bank switches: their TieLineChannel
        # instances live in `_channels_running[]` and we just remap which
        # 8 of them (and their config) are bound to the visible widgets.
        self._stash_visible_into_data()
        self._current_bank = new_bank
        self._load_visible_from_data()
        self._refresh_bank_indicators()

    def _bank_prev(self):
        self._switch_bank(self._current_bank - 1)

    def _bank_next(self):
        self._switch_bank(self._current_bank + 1)

    def _on_total_changed(self, new_total: int):
        if new_total == self._total_channels:
            return
        # If shrinking, refuse only if a channel running in a slot beyond
        # the new total would be silently dropped — that we still want to
        # avoid.
        if new_total < self._total_channels:
            running_after = [ch for ch in self._channels_running[new_total:]
                              if ch is not None]
            if running_after:
                messagebox.showwarning(
                    "Total channels",
                    f"Disconnect channels in slots > {new_total} "
                    "before reducing the total.")
                self._total_var.set(str(self._total_channels))
                return
        # Stash whatever's visible so we don't lose it.
        self._stash_visible_into_data()
        self._total_channels = new_total
        # Wipe entries past the new total so they aren't saved.
        for i in range(new_total, 32):
            self._channel_data[i] = {}
        # Snap current bank into range.
        max_bank = self._bank_count() - 1
        if self._current_bank > max_bank:
            self._current_bank = max_bank
        self._load_visible_from_data()
        self._refresh_bank_indicators()
        self._save_config()

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
        """Background thread: ping the server API. We wrap the async call
        in a hard timeout (asyncio.wait_for) on top of aiohttp's own one,
        so that even a hung TLS handshake or silently-dropped TCP SYN
        can never leave the LED stuck on orange."""
        import asyncio as _aio
        loop = _aio.new_event_loop()
        try:
            loop.run_until_complete(
                _aio.wait_for(self._check_server_async(server), timeout=6))
            self.root.after(0, self._server_ok, server)
        except _aio.TimeoutError:
            self.root.after(0, self._server_fail, server, "timeout")
        except Exception as e:
            err = str(e) or e.__class__.__name__
            print(f"[server-check] {server!r} → {err}")
            self.root.after(0, self._server_fail, server, err)
        finally:
            loop.close()

    async def _check_server_async(self, server: str):
        # Explicit connect / sock_connect timeouts on top of the global
        # `total` so a stuck TLS handshake aborts in <5 s. ssl=False on the
        # connector accepts self-signed certs (the server typically uses
        # one when it's not behind a public CA).
        timeout = aiohttp.ClientTimeout(total=5, connect=4, sock_connect=4, sock_read=4)
        conn = aiohttp.TCPConnector(ssl=False, force_close=True)
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
            # Cache the admin token + creds so the bridge-status poller can
            # keep refreshing without prompting the user for a password
            # again. Tokens are short-lived; if they expire, we fall back
            # to re-authenticating with the cached creds.
            self._admin_token = token
            self._admin_creds = creds
            self.root.after(0, self._start_bridge_status_polling)
            # Fetch bridge config
            async with session.get(f"{server}/api/admin/bridge-config",
                                   headers={"Authorization": f"Bearer {token}"}) as resp:
                if resp.status != 200:
                    raise RuntimeError(f"Bridge config: HTTP {resp.status}")
                return await resp.json()

    # ======================== BRIDGE-STATUS POLLING ========================

    def _start_bridge_status_polling(self):
        """Kick off the periodic /api/admin/bridge-status poll. Each row
        gets its external_dot lit red whenever its configured username is
        already online from another bridge instance."""
        if self._bridge_status_timer is not None:
            return  # already running
        self._poll_bridge_status()

    def _poll_bridge_status(self):
        """Poll once and reschedule. Always reschedules even on errors so
        a transient HTTP failure doesn't kill the indicator forever."""
        if not self._admin_authenticated or not self._admin_token:
            self._bridge_status_timer = self.root.after(5000, self._poll_bridge_status)
            return
        server = self.server_var.get().strip()
        token = self._admin_token
        threading.Thread(target=self._poll_bridge_status_bg,
                          args=(server, token), daemon=True).start()
        self._bridge_status_timer = self.root.after(5000, self._poll_bridge_status)

    def _poll_bridge_status_bg(self, server: str, token: str):
        import asyncio as _aio
        loop = _aio.new_event_loop()
        try:
            status = loop.run_until_complete(
                self._fetch_bridge_status_async(server, token))
            self.root.after(0, self._apply_bridge_status, status)
        except Exception as e:
            # Likely token expired — try to re-login silently with cached creds.
            if self._admin_creds:
                try:
                    new_token = loop.run_until_complete(
                        self._refresh_admin_token(server, self._admin_creds))
                    self._admin_token = new_token
                    status = loop.run_until_complete(
                        self._fetch_bridge_status_async(server, new_token))
                    self.root.after(0, self._apply_bridge_status, status)
                except Exception as e2:
                    print(f"[bridge-status] poll failed: {e2}")
            else:
                print(f"[bridge-status] poll failed: {e}")
        finally:
            loop.close()

    async def _refresh_admin_token(self, server: str, creds: tuple) -> str:
        timeout = aiohttp.ClientTimeout(total=8)
        conn = aiohttp.TCPConnector(ssl=False)
        async with aiohttp.ClientSession(connector=conn, timeout=timeout) as session:
            async with session.post(f"{server}/api/auth/login",
                                    json={"username": creds[0], "password": creds[1]}) as resp:
                if resp.status != 200:
                    raise RuntimeError(f"Re-login failed: HTTP {resp.status}")
                data = await resp.json()
                return data["token"]

    async def _fetch_bridge_status_async(self, server: str, token: str):
        timeout = aiohttp.ClientTimeout(total=8)
        conn = aiohttp.TCPConnector(ssl=False)
        async with aiohttp.ClientSession(connector=conn, timeout=timeout) as session:
            async with session.get(f"{server}/api/admin/bridge-status",
                                   headers={"Authorization": f"Bearer {token}"}) as resp:
                if resp.status != 200:
                    raise RuntimeError(f"bridge-status: HTTP {resp.status}")
                return await resp.json()

    def _apply_bridge_status(self, status):
        """Push the result of GET /api/admin/bridge-status into each row's
        external_dot. The endpoint returns a list of bridge users with an
        `online` flag — if it's True for a username that we have not
        connected ourselves, somebody else owns the slot."""
        if not isinstance(status, list):
            return
        online_usernames = {
            (b.get("username") or ""): bool(b.get("online"))
            for b in status
        }
        for row in self.channel_rows:
            uname = row.user_var.get().strip()
            in_use = bool(uname) and online_usernames.get(uname, False)
            row.set_external_in_use(in_use)

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
        # Prefer admin credentials (from Login dialog) over channel creds.
        # Channel bridge users can also fetch /directory (it only requires
        # authMiddleware), but admin creds are more reliable and avoid
        # confusion when the channel user doesn't exist yet on the server.
        creds = getattr(self, '_admin_creds', None)
        if not creds:
            for row in self.channel_rows:
                u = row.user_var.get().strip()
                p = row.pass_var.get().strip()
                if u and p:
                    creds = (u, p)
                    break
        if not creds:
            messagebox.showwarning("Config", "Use \ud83d\udd12 Login first, or configure at least one channel with username/password")
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
        """Disconnect every running channel, even those in banks that are
        not currently on screen."""
        for ch in list(self._channels_running):
            if ch is not None and self.loop:
                asyncio.run_coroutine_threadsafe(ch.stop(), self.loop)

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
        # Track the channel by its logical slot so it survives bank
        # switches — even if the user navigates away from this row, the
        # channel keeps running and we can rebind it when they come back.
        self._channels_running[row.index] = ch
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
        """Called on main thread when a channel finishes. The row argument
        may already be displaying a different bank by now — we locate the
        slot via `_channels_running` instead of trusting `row.channel`."""
        # Drop from the per-slot tracker.
        for i, c in enumerate(self._channels_running):
            if c is ch:
                self._channels_running[i] = None
                # If that slot is currently on screen, refresh its row.
                offset = self._current_bank * self.ROWS_PER_BANK
                if offset <= i < offset + self.ROWS_PER_BANK:
                    visible_row = self.channel_rows[i - offset]
                    visible_row.channel = None
                    visible_row.set_connected(False)
                break
        if ch in self.channels:
            self.channels.remove(ch)
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

    def _reset_config(self):
        """Wipe config.json and reset all fields to defaults. Useful when
        moving the bridge to a different server and the cached channel
        configuration (users/IDs from the previous server) no longer
        matches the new directory."""
        if not messagebox.askyesno(
            "Reset configuration",
            "This will delete config.json and clear all channel settings.\n\n"
            "The bridge will be disconnected and you'll need to re-enter the\n"
            "server URL and re-download the bridge config.\n\n"
            "Continue?",
        ):
            return

        # Stop any connected channels first
        for row in self.channel_rows:
            ch = row.channel
            if ch and self.loop:
                try:
                    asyncio.run_coroutine_threadsafe(ch.stop(), self.loop)
                except Exception:
                    pass
            row.channel = None
            try:
                row.set_connected(False)
            except Exception:
                pass
        self.channels.clear()

        # Remove the on-disk config
        try:
            if os.path.exists(CONFIG_FILE):
                os.remove(CONFIG_FILE)
        except Exception as e:
            messagebox.showerror("Reset", f"Could not delete config.json: {e}")
            return

        # Clear in-memory fields
        self.server_var.set("")
        self.bridge_ip_var.set("")
        self.num_ch_var.set("16")
        self.input_dev_var.set("")
        self.output_dev_var.set("")
        for row in self.channel_rows:
            try:
                row.user_var.set("")
                row.pass_var.set("")
                row.ttype_var.set("user")
                row.target_var.set("")
                row.in_dev_var.set("")
                row.out_dev_var.set("")
                row.in_ch_var.set(str(row.index + 1))
                row.out_ch_var.set(str(row.index + 1))
                row._pending_target_id = None
                row._vox_send_enabled = False
                row.vox_send_db_var.set("-40")
                row._update_vox_send_visual()
                row._vox_recv_enabled = True
                row.vox_recv_db_var.set("-40")
                row._update_vox_recv_visual()
            except Exception:
                pass

        # Gate buttons again until the user logs in against the new server
        self._admin_authenticated = False
        self._update_auth_state()
        self._server_status.configure(text_color=COLOR_DIM)
        self.status_var.set("Config reset — enter the new server URL and press 🔒 Login")

    def _save_config(self):
        # Pull the freshest data from the visible rows into `_channel_data`,
        # then dump everything (visible + paged-out) up to total_channels.
        self._stash_visible_into_data()
        channels = []
        for i in range(self._total_channels):
            data = self._channel_data[i] or {}
            if data:
                # Force the index to match the slot, in case it was loaded
                # from a config that used a different slot ordering.
                data = dict(data)
                data["index"] = i + 1
                channels.append(data)
        config = {
            "server": self.server_var.get().strip(),
            "input_device": self.input_dev_var.get(),
            "output_device": self.output_dev_var.get(),
            "bridge_ip": self.bridge_ip_var.get().strip(),
            "num_device_channels": int(self.num_ch_var.get()),
            "total_channels": self._total_channels,
            "current_bank": self._current_bank,
            "sample_rate": 48000,
            "channels": channels,
        }
        try:
            with open(CONFIG_FILE, "w") as f:
                json.dump(config, f, indent=2)
        except Exception as e:
            print(f"Error saving config: {e}")

    def _load_config(self):
        # Try `config.json` first; fall back to a bundled `config.default.json`
        # next to bridge_gui.py if no per-user config has been saved yet. That
        # default file is shipped empty (no server, no channels) so a fresh
        # install starts the user with a blank slate instead of the previous
        # hardcoded 192.168.4.8 default.
        path = CONFIG_FILE
        if not os.path.exists(path):
            default_path = os.path.join(
                os.path.dirname(os.path.abspath(__file__)), "config.default.json")
            if os.path.exists(default_path):
                path = default_path
            else:
                return
        try:
            with open(path) as f:
                config = json.load(f)
        except Exception:
            return
        self.server_var.set(config.get("server", ""))
        self.bridge_ip_var.set(config.get("bridge_ip", ""))
        self.num_ch_var.set(str(config.get("num_device_channels", 16)))
        saved_input = config.get("input_device", "")
        saved_output = config.get("output_device", "")
        if saved_input:
            self.input_dev_var.set(saved_input)
        if saved_output:
            self.output_dev_var.set(saved_output)
        # Restore total channels + last visible bank from the saved config
        # (defaults to 16 / first bank when missing).
        total = config.get("total_channels", 16)
        if total in (8, 16, 24, 32):
            self._total_channels = total
            self._total_var.set(str(total))
        # Spread saved channels into _channel_data by their index.
        for ch_cfg in config.get("channels", []):
            idx = ch_cfg.get("index", 0) - 1
            if 0 <= idx < 32:
                self._channel_data[idx] = ch_cfg
        bank = config.get("current_bank", 0)
        max_bank = self._bank_count() - 1
        self._current_bank = max(0, min(bank, max_bank))
        # Hydrate the 8 visible rows with the entries belonging to the
        # current bank.
        self._load_visible_from_data()
        self._refresh_bank_indicators()

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
