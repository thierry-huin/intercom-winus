#!/usr/bin/env python3
"""Winus Intercom — Control Center.

A single-window GUI that exposes the most common maintenance actions for the
project: building apps / packages, starting/stopping/restarting the local
Docker stack, installing .deb files and deploying them to a remote server.

The intention is to avoid having to remember the ~14 shell scripts that live in
``/opt/winus-intercom/`` and provide live output in a shared log panel.

Dependencies: ``customtkinter`` (already required by tie-line-bridge).
"""
from __future__ import annotations

import json
import os
import queue
import shlex
import shutil
import subprocess
import sys
import threading
import tkinter as tk
from datetime import datetime
from pathlib import Path
from tkinter import filedialog, messagebox

import customtkinter as ctk

# ======================== PATHS / CONFIG ========================
PROJECT_DIR = Path("/opt/winus-intercom")
BRIDGE_DIR = PROJECT_DIR / "tie-line-bridge"
CONFIG_DIR = Path.home() / ".config"
CONFIG_FILE = CONFIG_DIR / "winus-control-center.json"

# ======================== THEME (mirrors bridge_gui.py) ========================
COLOR_BG = "#1a1a2e"
COLOR_CARD = "#16213e"
COLOR_ACCENT = "#7b2ff7"
COLOR_ACCENT2 = "#00c9db"
COLOR_GREEN = "#00e676"
COLOR_RED = "#ff5252"
COLOR_ORANGE = "#ffab40"
COLOR_BLUE = "#2196f3"
COLOR_TEXT = "#e0e0e0"
COLOR_DIM = "#666680"
COLOR_ROW_EVEN = "#1a1a2e"
COLOR_ROW_ODD = "#0f3460"

ctk.set_appearance_mode("dark")
ctk.set_default_color_theme("dark-blue")


# ======================== CONFIG PERSISTENCE ========================
def load_config() -> dict:
    try:
        with open(CONFIG_FILE) as f:
            return json.load(f)
    except Exception:
        return {}


def save_config(cfg: dict) -> None:
    try:
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        with open(CONFIG_FILE, "w") as f:
            json.dump(cfg, f, indent=2)
    except Exception as e:
        print(f"[config] save error: {e}", file=sys.stderr)


# ======================== SHELL RUNNER ========================
class ShellRunner:
    """Runs a shell command, streaming stdout/stderr line-by-line into a Tk
    text widget on the main thread via a thread-safe queue.

    Commands starting with ``sudo`` are transformed to ``sudo -S -p ''`` so we
    can pipe the user's password via stdin. The password is obtained from the
    app (either from the header entry or a modal prompt) and kept in memory
    only for the duration of the session.
    """

    def __init__(self, app: "ControlCenter"):
        self.app = app
        self.proc: subprocess.Popen | None = None
        self._queue: queue.Queue = queue.Queue()
        self._busy = False
        self._pump_running = False

    @property
    def busy(self) -> bool:
        return self._busy

    @staticmethod
    def _needs_sudo(cmd) -> bool:
        """True iff the command starts with ``sudo`` AND is not already
        non-interactive (``-n``) or stdin-fed (``-S``)."""
        if isinstance(cmd, list) and cmd and cmd[0] == "sudo":
            rest = cmd[1:4]
            if "-n" in rest or "-S" in rest:
                return False
            return True
        if isinstance(cmd, str) and cmd.strip().startswith("sudo "):
            head = cmd.strip().split()[:4]
            if "-n" in head or "-S" in head:
                return False
            return True
        return False

    @staticmethod
    def _inject_sudo_flags(cmd):
        """Insert ``-S -p ''`` right after ``sudo`` so the password can be fed
        via stdin and sudo does not print its own prompt."""
        if isinstance(cmd, list):
            # Skip if already -S or -n (non-interactive)
            rest = cmd[1:]
            if "-S" in rest[:3] or "-n" in rest[:3]:
                return cmd
            return [cmd[0], "-S", "-p", "", *rest]
        # Shell string
        return cmd.replace("sudo ", "sudo -S -p '' ", 1)

    def run(self, cmd, *, shell: bool = False, cwd: str | None = None,
            env: dict | None = None, title: str = "",
            stdin_data: str | None = None) -> None:
        """Fire-and-forget command execution.

        `stdin_data`, when provided, is written to the subprocess's stdin
        before streaming starts. Used to feed the remote `sudo -S`
        password through `ssh` for deploy actions."""
        if self._busy:
            self.app.log("⚠  Ya hay una acción en curso. Espera a que termine.", level="warn")
            return

        # Resolve sudo password on the MAIN thread (modal requires it).
        sudo_pw: str | None = None
        if self._needs_sudo(cmd):
            sudo_pw = self.app.get_sudo_password(prompt_if_missing=True)
            if sudo_pw is None:
                self.app.log("✖ Acción cancelada: se necesita la contraseña de sudo.",
                             level="error")
                return
            cmd = self._inject_sudo_flags(cmd)

        # Either local sudo or caller-supplied stdin (mutually exclusive
        # in practice — local sudo gates a non-ssh command, while ssh-led
        # remote sudo skips _needs_sudo because the head of the cmd is
        # "ssh", not "sudo").
        feed_stdin: str | None = None
        if sudo_pw is not None:
            feed_stdin = sudo_pw + "\n"
        elif stdin_data is not None:
            feed_stdin = stdin_data

        self._busy = True
        self.app.set_running(True, title)

        def _worker():
            start = datetime.now()
            label = title or (" ".join(cmd) if isinstance(cmd, list) else cmd)
            self._queue.put(("banner", f"\n━━━ ▶ {label}\n    {start:%H:%M:%S}  ({cwd or os.getcwd()})\n"))
            auth_failed = False
            try:
                self.proc = subprocess.Popen(
                    cmd,
                    shell=shell,
                    cwd=cwd,
                    env=env,
                    stdin=subprocess.PIPE if feed_stdin is not None else None,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    bufsize=1,
                    universal_newlines=True,
                )
                assert self.proc.stdout is not None
                # Feed password + close stdin, then stream output.
                if feed_stdin is not None and self.proc.stdin is not None:
                    try:
                        self.proc.stdin.write(feed_stdin)
                        self.proc.stdin.flush()
                        self.proc.stdin.close()
                    except Exception:
                        pass
                for line in self.proc.stdout:
                    low = line.lower()
                    if "incorrect password" in low or "sudo: 1 incorrect" in low:
                        auth_failed = True
                    self._queue.put(("line", line.rstrip("\n")))
                self.proc.wait()
                rc = self.proc.returncode
            except FileNotFoundError as e:
                self._queue.put(("error", f"✖ Comando no encontrado: {e}"))
                rc = 127
            except Exception as e:
                self._queue.put(("error", f"✖ Error: {e}"))
                rc = 1
            finally:
                elapsed = (datetime.now() - start).total_seconds()
                if rc == 0:
                    self._queue.put(("done", f"✓ OK  (rc=0, {elapsed:.1f}s)\n"))
                else:
                    if auth_failed:
                        self._queue.put(("invalidate_sudo", None))
                        self._queue.put(("error",
                                          "✖ Contraseña de sudo incorrecta. Se ha borrado de memoria; "
                                          "vuelve a introducirla en la cabecera y reintenta.\n"))
                    else:
                        self._queue.put(("error", f"✖ Falló (rc={rc}, {elapsed:.1f}s)\n"))
                self._queue.put(("finish", None))

        threading.Thread(target=_worker, daemon=True).start()
        if not self._pump_running:
            self._pump_running = True
            self.app.root.after(50, self._pump)

    def _pump(self):
        """Drain the queue onto the UI from the main thread."""
        try:
            while True:
                kind, payload = self._queue.get_nowait()
                if kind == "banner":
                    self.app.log(payload, level="info")
                elif kind == "line":
                    self.app.log(payload, level="line")
                elif kind == "done":
                    self.app.log(payload, level="ok")
                elif kind == "error":
                    self.app.log(payload, level="error")
                elif kind == "invalidate_sudo":
                    self.app.invalidate_sudo_password()
                elif kind == "finish":
                    self._busy = False
                    self.app.set_running(False)
        except queue.Empty:
            pass
        # Keep pumping forever while the app is alive.
        self.app.root.after(100, self._pump)


# ======================== MAIN APP ========================
class ControlCenter:
    def __init__(self):
        self.cfg = load_config()
        self.runner = ShellRunner(self)
        # In-memory sudo password (never persisted).
        self._sudo_password: str | None = None

        self.root = ctk.CTk()
        self.root.title("Winus Intercom — Control Center")
        self.root.geometry("1180x780")
        self.root.configure(fg_color=COLOR_BG)

        self._build_ui()
        self._refresh_deb_list()
        self._refresh_status_loop()

    # -------------------- SUDO PASSWORD --------------------
    def get_sudo_password(self, prompt_if_missing: bool = False) -> str | None:
        """Return the cached sudo password, reading it from the header entry
        if necessary, or opening a modal dialog if the entry is empty.
        Runs on the main Tk thread."""
        if self._sudo_password:
            return self._sudo_password
        # Prefer the header entry if the user already typed there.
        try:
            typed = self.sudo_entry_var.get().strip()
        except Exception:
            typed = ""
        if typed:
            self._sudo_password = typed
            return self._sudo_password
        if not prompt_if_missing:
            return None
        pw = self._ask_sudo_modal()
        if pw:
            self._sudo_password = pw
            try:
                self.sudo_entry_var.set(pw)
            except Exception:
                pass
        return self._sudo_password

    def invalidate_sudo_password(self) -> None:
        """Forget any cached password (called on auth failure)."""
        self._sudo_password = None
        try:
            self.sudo_entry_var.set("")
        except Exception:
            pass

    def _ask_sudo_modal(self) -> str | None:
        """Modal dialog to ask for the sudo password. Blocks until the user
        enters it or cancels. Returns the password or None."""
        dlg = ctk.CTkToplevel(self.root)
        dlg.title("sudo password")
        dlg.geometry("360x170")
        dlg.configure(fg_color=COLOR_CARD)
        dlg.transient(self.root)
        # grab_set() requires the window to be visible. Deferring via
        # wait_visibility() avoids the "grab failed: window not viewable" error.
        def _do_grab():
            try:
                dlg.wait_visibility()
                dlg.grab_set()
                dlg.focus_force()
            except Exception:
                pass
        dlg.after(50, _do_grab)

        ctk.CTkLabel(dlg, text="Contraseña de sudo",
                     font=("SF Pro Display", 14, "bold"),
                     text_color=COLOR_ACCENT2).pack(pady=(16, 4))
        ctk.CTkLabel(dlg,
                     text="Se usa en memoria para esta sesión. No se guarda.",
                     font=("SF Pro Display", 11),
                     text_color=COLOR_DIM).pack(pady=(0, 10))

        var = tk.StringVar()
        entry = ctk.CTkEntry(dlg, textvariable=var, width=260, height=32,
                              show="•", placeholder_text="password")
        entry.pack(pady=4)
        entry.focus()

        result = {"pw": None}

        def ok():
            result["pw"] = var.get()
            dlg.destroy()

        def cancel():
            dlg.destroy()

        entry.bind("<Return>", lambda _: ok())
        entry.bind("<Escape>", lambda _: cancel())

        btns = ctk.CTkFrame(dlg, fg_color="transparent")
        btns.pack(pady=10)
        ctk.CTkButton(btns, text="Cancelar", width=100, height=30,
                      fg_color=COLOR_DIM, command=cancel).pack(side="left", padx=6)
        ctk.CTkButton(btns, text="OK", width=100, height=30,
                      fg_color=COLOR_GREEN, text_color="#1a1a2e",
                      command=ok).pack(side="left", padx=6)

        dlg.wait_window()
        return result["pw"] or None

    # -------------------- UI LAYOUT --------------------
    def _build_ui(self):
        # Header
        header = ctk.CTkFrame(self.root, fg_color=COLOR_CARD, corner_radius=0, height=54)
        header.pack(fill="x", side="top")
        header.pack_propagate(False)

        ctk.CTkLabel(header, text="Winus Intercom  •  Control Center",
                     font=("SF Pro Display", 18, "bold"),
                     text_color=COLOR_ACCENT2).pack(side="left", padx=16)

        self.status_badge = ctk.CTkLabel(header, text="● idle",
                                          font=("SF Pro Display", 12, "bold"),
                                          text_color=COLOR_DIM)
        self.status_badge.pack(side="right", padx=16)

        self.containers_badge = ctk.CTkLabel(header, text="Docker: —",
                                              font=("SF Pro Display", 11),
                                              text_color=COLOR_DIM)
        self.containers_badge.pack(side="right", padx=(0, 12))

        # Sudo password (in-memory only, never saved to disk)
        sudo_box = ctk.CTkFrame(header, fg_color="transparent")
        sudo_box.pack(side="right", padx=(0, 12))
        ctk.CTkLabel(sudo_box, text="sudo:",
                     font=("SF Pro Display", 11),
                     text_color=COLOR_DIM).pack(side="left", padx=(0, 4))
        self.sudo_entry_var = tk.StringVar()
        self.sudo_entry = ctk.CTkEntry(sudo_box, textvariable=self.sudo_entry_var,
                                        width=150, height=28, show="•",
                                        placeholder_text="contraseña")
        self.sudo_entry.pack(side="left")
        self.sudo_entry_var.trace_add("write", lambda *_: self._on_sudo_entry_change())

        # Main horizontal split: left = tabs, right = log
        body = ctk.CTkFrame(self.root, fg_color=COLOR_BG)
        body.pack(fill="both", expand=True, padx=10, pady=10)
        body.grid_columnconfigure(0, weight=1)
        body.grid_columnconfigure(1, weight=1)
        body.grid_rowconfigure(0, weight=1)

        # --- Left: tabview ---
        self.tabview = ctk.CTkTabview(body, fg_color=COLOR_CARD,
                                       segmented_button_selected_color=COLOR_ACCENT,
                                       segmented_button_selected_hover_color="#6a25d0")
        self.tabview.grid(row=0, column=0, sticky="nsew", padx=(0, 6))
        self.tabview.add("Build")
        self.tabview.add("Server")
        self.tabview.add("Install")
        self.tabview.add("Deploy")
        self.tabview.add("Bridge")

        self._build_tab_build(self.tabview.tab("Build"))
        self._build_tab_server(self.tabview.tab("Server"))
        self._build_tab_install(self.tabview.tab("Install"))
        self._build_tab_deploy(self.tabview.tab("Deploy"))
        self._build_tab_bridge(self.tabview.tab("Bridge"))

        # --- Right: logs panel ---
        log_frame = ctk.CTkFrame(body, fg_color=COLOR_CARD)
        log_frame.grid(row=0, column=1, sticky="nsew", padx=(6, 0))
        log_frame.grid_rowconfigure(1, weight=1)
        log_frame.grid_columnconfigure(0, weight=1)

        log_header = ctk.CTkFrame(log_frame, fg_color="transparent")
        log_header.grid(row=0, column=0, sticky="ew", padx=8, pady=(8, 2))
        ctk.CTkLabel(log_header, text="Logs",
                     font=("SF Pro Display", 13, "bold"),
                     text_color=COLOR_ACCENT2).pack(side="left")
        ctk.CTkButton(log_header, text="Clear", width=60, height=24,
                      fg_color=COLOR_DIM, hover_color="#555577",
                      command=self._clear_log).pack(side="right", padx=4)
        ctk.CTkButton(log_header, text="Stop", width=60, height=24,
                      fg_color=COLOR_RED, hover_color="#d32f2f",
                      command=self._stop_current).pack(side="right", padx=4)

        self.log_text = tk.Text(log_frame, bg="#0f0f1e", fg=COLOR_TEXT,
                                 insertbackground=COLOR_TEXT,
                                 font=("Menlo", 11), wrap="word",
                                 borderwidth=0, highlightthickness=0)
        self.log_text.grid(row=1, column=0, sticky="nsew", padx=8, pady=(0, 8))
        sb = ctk.CTkScrollbar(log_frame, command=self.log_text.yview)
        sb.grid(row=1, column=1, sticky="ns", pady=(0, 8))
        self.log_text.configure(yscrollcommand=sb.set, state="disabled")

        # Tags for colored lines
        self.log_text.tag_config("info", foreground=COLOR_ACCENT2)
        self.log_text.tag_config("ok", foreground=COLOR_GREEN)
        self.log_text.tag_config("warn", foreground=COLOR_ORANGE)
        self.log_text.tag_config("error", foreground=COLOR_RED)
        self.log_text.tag_config("line", foreground=COLOR_TEXT)

    # -------------------- TAB: BUILD --------------------
    def _build_tab_build(self, parent):
        ctk.CTkLabel(parent, text="Compilar apps y paquetes",
                     font=("SF Pro Display", 14, "bold"),
                     text_color=COLOR_ACCENT2).pack(anchor="w", padx=14, pady=(12, 6))

        grid = ctk.CTkFrame(parent, fg_color="transparent")
        grid.pack(fill="x", padx=14, pady=4)

        specs = [
            ("Web + APK", "Flutter web + APK + deploy a nginx",
             lambda: self.runner.run(["bash", str(PROJECT_DIR / "build-apps.sh")],
                                      cwd=str(PROJECT_DIR), title="build-apps.sh")),
            ("Bridge .deb", "tie-line-bridge/build_deb.sh",
             lambda: self.runner.run(["bash", str(BRIDGE_DIR / "build_deb.sh")],
                                      cwd=str(BRIDGE_DIR), title="build_deb.sh (bridge)")),
            (".deb server slim", "create-deb-server.sh (~8 MB, sin APK)",
             lambda: self.runner.run(["bash", str(PROJECT_DIR / "create-deb-server.sh")],
                                      cwd=str(PROJECT_DIR), title="create-deb-server.sh")),
            (".deb completo", "create-deb.sh (incluye APK, ~358 MB)",
             lambda: self.runner.run(["bash", str(PROJECT_DIR / "create-deb.sh")],
                                      cwd=str(PROJECT_DIR), title="create-deb.sh")),
            (".tar package", "create-package.sh (Linux/macOS/Windows, Docker images + sources + Control Center)",
             lambda: self.runner.run(["bash", str(PROJECT_DIR / "create-package.sh")],
                                      cwd=str(PROJECT_DIR), title="create-package.sh")),
            ("📦 Export Proxmox", "build-and-export.sh (imágenes Docker pre-compiladas para Proxmox, sin build en destino)",
             lambda: self.runner.run(["bash", str(PROJECT_DIR / "build-and-export.sh")],
                                      cwd=str(PROJECT_DIR), title="build-and-export.sh")),
        ]
        for label, desc, cmd in specs:
            card = ctk.CTkFrame(grid, fg_color=COLOR_ROW_ODD, corner_radius=6)
            card.pack(fill="x", padx=6, pady=6)
            ctk.CTkButton(card, text=label, height=40, width=200,
                          font=("SF Pro Display", 13, "bold"),
                          fg_color=COLOR_ACCENT, hover_color="#6a25d0",
                          command=cmd).pack(side="left", padx=10, pady=10)
            ctk.CTkLabel(card, text=desc, font=("SF Pro Display", 11),
                         text_color=COLOR_DIM, anchor="w",
                         justify="left").pack(side="left", padx=8,
                                              fill="x", expand=True)

    # -------------------- TAB: SERVER --------------------
    def _build_tab_server(self, parent):
        ctk.CTkLabel(parent, text="Servidor local (Docker stack)",
                     font=("SF Pro Display", 14, "bold"),
                     text_color=COLOR_ACCENT2).pack(anchor="w", padx=14, pady=(12, 6))

        btns = ctk.CTkFrame(parent, fg_color="transparent")
        btns.pack(fill="x", padx=14, pady=4)

        def dc(*args, title=""):
            cmd = ["sudo", "docker", "compose",
                   "-f", str(PROJECT_DIR / "docker-compose.yml"), *args]
            self.runner.run(cmd, cwd=str(PROJECT_DIR), title=title or " ".join(args))

        ctk.CTkButton(btns, text="▶ Start", width=110, height=34,
                      fg_color=COLOR_GREEN, hover_color="#00c853",
                      text_color="#1a1a2e",
                      command=lambda: dc("up", "-d", title="docker compose up -d")
                      ).pack(side="left", padx=4)
        ctk.CTkButton(btns, text="⟳ Restart", width=110, height=34,
                      fg_color=COLOR_BLUE, hover_color="#1976d2",
                      command=lambda: dc("restart", title="docker compose restart")
                      ).pack(side="left", padx=4)
        ctk.CTkButton(btns, text="■ Stop", width=110, height=34,
                      fg_color=COLOR_RED, hover_color="#d32f2f",
                      command=lambda: dc("down", title="docker compose down")
                      ).pack(side="left", padx=4)
        ctk.CTkButton(btns, text="🔨 Rebuild backend", width=170, height=34,
                      fg_color=COLOR_ACCENT, hover_color="#6a25d0",
                      command=lambda: dc("up", "-d", "--build", "backend",
                                          title="rebuild backend")
                      ).pack(side="left", padx=4)
        ctk.CTkButton(btns, text="⟳ Recreate nginx", width=160, height=34,
                      fg_color=COLOR_ORANGE, hover_color="#ff8f00",
                      text_color="#1a1a2e",
                      command=lambda: dc("up", "-d", "--force-recreate", "nginx",
                                          title="recreate nginx")
                      ).pack(side="left", padx=4)

        # Logs by service
        ctk.CTkLabel(parent, text="Ver logs (últimas 100 líneas)",
                     font=("SF Pro Display", 12),
                     text_color=COLOR_DIM).pack(anchor="w", padx=14, pady=(14, 2))
        logs_row = ctk.CTkFrame(parent, fg_color="transparent")
        logs_row.pack(fill="x", padx=14, pady=2)
        for svc in ("backend", "nginx", "coturn"):
            ctk.CTkButton(logs_row, text=f"logs {svc}", width=120, height=30,
                          fg_color=COLOR_DIM, hover_color="#555577",
                          command=lambda s=svc: dc("logs", "--tail=100", s,
                                                    title=f"logs {s}")
                          ).pack(side="left", padx=4)

        # BD tweak
        ctk.CTkLabel(parent, text="Ajustes rápidos de server_config (BD)",
                     font=("SF Pro Display", 12),
                     text_color=COLOR_DIM).pack(anchor="w", padx=14, pady=(14, 2))
        bd_row = ctk.CTkFrame(parent, fg_color="transparent")
        bd_row.pack(fill="x", padx=14, pady=2)

        ctk.CTkLabel(bd_row, text="announced_ips:").pack(side="left", padx=(0, 4))
        self.announced_var = tk.StringVar(value=self.cfg.get("announced_ips", "huin.tv"))
        ctk.CTkEntry(bd_row, textvariable=self.announced_var, width=300, height=30
                     ).pack(side="left", padx=4)
        ctk.CTkLabel(bd_row, text="turn_host:").pack(side="left", padx=(10, 4))
        self.turn_var = tk.StringVar(value=self.cfg.get("turn_host", "huin.tv"))
        ctk.CTkEntry(bd_row, textvariable=self.turn_var, width=140, height=30
                     ).pack(side="left", padx=4)
        ctk.CTkButton(bd_row, text="Aplicar", width=90, height=30,
                      fg_color=COLOR_GREEN, text_color="#1a1a2e",
                      command=self._apply_db_config).pack(side="left", padx=8)
        ctk.CTkButton(bd_row, text="Leer", width=60, height=30,
                      fg_color=COLOR_DIM,
                      command=self._read_db_config).pack(side="left", padx=4)

    def _apply_db_config(self):
        announced = self.announced_var.get().strip()
        turn = self.turn_var.get().strip()
        if not announced or not turn:
            messagebox.showwarning("server_config",
                                    "Rellena announced_ips y turn_host")
            return
        # Persist for next launch
        self.cfg["announced_ips"] = announced
        self.cfg["turn_host"] = turn
        save_config(self.cfg)

        node_script = (
            'const db = require("./src/database").db;'
            'const upd = db.prepare("UPDATE server_config SET value=? WHERE key=?");'
            f'const r1 = upd.run({json.dumps(announced)}, "announced_ips");'
            f'const r2 = upd.run({json.dumps(turn)}, "turn_host");'
            'console.log("announced_ips changes:", r1.changes, "turn_host changes:", r2.changes);'
            'console.log(db.prepare("SELECT key,value FROM server_config").all());'
        )
        cmd = ["sudo", "docker", "compose",
               "-f", str(PROJECT_DIR / "docker-compose.yml"),
               "exec", "-T", "backend", "node", "-e", node_script]
        self.runner.run(cmd, cwd=str(PROJECT_DIR),
                         title="UPDATE server_config + restart backend")
        # Queue a restart right after (it will wait in ShellRunner busy loop if needed)
        self.root.after(500, lambda: self._chain_restart_when_free())

    def _chain_restart_when_free(self):
        if self.runner.busy:
            self.root.after(500, self._chain_restart_when_free)
            return
        cmd = ["sudo", "docker", "compose",
               "-f", str(PROJECT_DIR / "docker-compose.yml"),
               "restart", "backend"]
        self.runner.run(cmd, cwd=str(PROJECT_DIR), title="restart backend")

    def _read_db_config(self):
        node_script = (
            'const db = require("./src/database").db;'
            'console.log(db.prepare("SELECT key,value FROM server_config").all());'
        )
        cmd = ["sudo", "docker", "compose",
               "-f", str(PROJECT_DIR / "docker-compose.yml"),
               "exec", "-T", "backend", "node", "-e", node_script]
        self.runner.run(cmd, cwd=str(PROJECT_DIR), title="SELECT server_config")

    # -------------------- TAB: INSTALL --------------------
    def _build_tab_install(self, parent):
        ctk.CTkLabel(parent, text="Instalar paquetes .deb locales",
                     font=("SF Pro Display", 14, "bold"),
                     text_color=COLOR_ACCENT2).pack(anchor="w", padx=14, pady=(12, 6))

        hint = ctk.CTkLabel(parent,
                             text=("Muestra los .deb de /opt/winus-intercom/ y de "
                                   "tie-line-bridge/. El botón ejecuta sudo apt install -y."),
                             font=("SF Pro Display", 11), text_color=COLOR_DIM,
                             wraplength=520, justify="left")
        hint.pack(anchor="w", padx=14, pady=(0, 6))

        self.deb_list_frame = ctk.CTkScrollableFrame(parent, fg_color=COLOR_ROW_ODD,
                                                     height=280)
        self.deb_list_frame.pack(fill="both", expand=True, padx=14, pady=6)

        actions = ctk.CTkFrame(parent, fg_color="transparent")
        actions.pack(fill="x", padx=14, pady=(4, 10))
        ctk.CTkButton(actions, text="Refrescar", width=110, height=30,
                      fg_color=COLOR_DIM, command=self._refresh_deb_list
                      ).pack(side="left", padx=4)
        ctk.CTkButton(actions, text="Elegir archivo…", width=140, height=30,
                      fg_color=COLOR_ACCENT, hover_color="#6a25d0",
                      command=self._install_custom_deb
                      ).pack(side="left", padx=4)

    def _refresh_deb_list(self):
        # Clear previous rows
        for w in self.deb_list_frame.winfo_children():
            w.destroy()

        debs = sorted(
            list(PROJECT_DIR.glob("*.deb")) + list(BRIDGE_DIR.glob("*.deb")),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
        if not debs:
            ctk.CTkLabel(self.deb_list_frame,
                          text="(no hay .deb generados todavía)",
                          text_color=COLOR_DIM).pack(padx=10, pady=10)
            return

        for p in debs:
            size_mb = p.stat().st_size / (1024 * 1024)
            mtime = datetime.fromtimestamp(p.stat().st_mtime)
            row = ctk.CTkFrame(self.deb_list_frame, fg_color=COLOR_ROW_EVEN,
                                corner_radius=4)
            row.pack(fill="x", padx=4, pady=3)

            ctk.CTkLabel(row, text=p.name, anchor="w",
                          font=("Menlo", 11), text_color=COLOR_TEXT,
                          width=300).pack(side="left", padx=8, pady=6)
            ctk.CTkLabel(row, text=f"{size_mb:,.1f} MB", width=80,
                          text_color=COLOR_DIM).pack(side="left")
            ctk.CTkLabel(row, text=f"{mtime:%Y-%m-%d %H:%M}", width=140,
                          text_color=COLOR_DIM).pack(side="left")
            ctk.CTkButton(row, text="Instalar", width=90, height=26,
                          fg_color=COLOR_GREEN, text_color="#1a1a2e",
                          command=lambda path=p: self._install_deb(path)
                          ).pack(side="right", padx=8, pady=4)

    def _install_custom_deb(self):
        path = filedialog.askopenfilename(
            title="Elegir .deb",
            initialdir=str(PROJECT_DIR),
            filetypes=[("Debian package", "*.deb")])
        if path:
            self._install_deb(Path(path))

    def _install_deb(self, path: Path):
        cmd = ["sudo", "apt", "install", "-y", str(path)]
        self.runner.run(cmd, title=f"apt install {path.name}")

    # -------------------- TAB: DEPLOY --------------------
    def _build_tab_deploy(self, parent):
        ctk.CTkLabel(parent, text="Deploy remoto (SSH/SCP)",
                     font=("SF Pro Display", 14, "bold"),
                     text_color=COLOR_ACCENT2).pack(anchor="w", padx=14, pady=(12, 6))

        # Config row
        form = ctk.CTkFrame(parent, fg_color="transparent")
        form.pack(fill="x", padx=14, pady=4)

        ctk.CTkLabel(form, text="Usuario:").grid(row=0, column=0, sticky="w", pady=3)
        self.ssh_user_var = tk.StringVar(value=self.cfg.get("ssh_user", "ubuntu"))
        ctk.CTkEntry(form, textvariable=self.ssh_user_var, width=140, height=28
                     ).grid(row=0, column=1, padx=6, pady=3)

        ctk.CTkLabel(form, text="Host:").grid(row=0, column=2, sticky="w", padx=(12, 0), pady=3)
        self.ssh_host_var = tk.StringVar(value=self.cfg.get("ssh_host", "winus.overon.es"))
        ctk.CTkEntry(form, textvariable=self.ssh_host_var, width=240, height=28
                     ).grid(row=0, column=3, padx=6, pady=3)

        # Port (defaults to 22). Stored as a string so an empty value falls
        # back to ssh's own default — no need to inject `-p 22` explicitly.
        ctk.CTkLabel(form, text="Port:").grid(row=0, column=4, sticky="w", padx=(12, 0), pady=3)
        self.ssh_port_var = tk.StringVar(value=str(self.cfg.get("ssh_port", "22")))
        ctk.CTkEntry(form, textvariable=self.ssh_port_var, width=70, height=28,
                      placeholder_text="22").grid(row=0, column=5, padx=6, pady=3)

        ctk.CTkLabel(form, text="Key (opcional):").grid(row=1, column=0, sticky="w", pady=3)
        self.ssh_key_var = tk.StringVar(value=self.cfg.get("ssh_key", ""))
        ctk.CTkEntry(form, textvariable=self.ssh_key_var, width=390, height=28,
                      placeholder_text="~/.ssh/id_ed25519").grid(
            row=1, column=1, columnspan=4, padx=6, pady=3, sticky="w")

        # Password — used only when there's no key. Kept in memory; never
        # written to disk by _save_deploy_cfg. Routed via sshpass(1) so the
        # GUI doesn't need a TTY for the ssh prompt.
        ctk.CTkLabel(form, text="Password (no key):").grid(row=2, column=0, sticky="w", pady=3)
        self.ssh_pass_var = tk.StringVar()
        ctk.CTkEntry(form, textvariable=self.ssh_pass_var, width=240, height=28,
                      show="•",
                      placeholder_text="solo si no usas key (no se guarda)"
                      ).grid(row=2, column=1, columnspan=3, padx=6, pady=3, sticky="w")

        ctk.CTkButton(form, text="💾 Guardar", width=100, height=28,
                      fg_color=COLOR_DIM,
                      command=self._save_deploy_cfg).grid(row=0, column=6, padx=(12, 0))

        # Actions — Row 1: SSH + .deb deploy
        ctk.CTkLabel(parent, text="Acciones",
                     font=("SF Pro Display", 12),
                     text_color=COLOR_DIM).pack(anchor="w", padx=14, pady=(16, 2))

        act1 = ctk.CTkFrame(parent, fg_color="transparent")
        act1.pack(fill="x", padx=14, pady=2)
        ctk.CTkButton(act1, text="🧪 Probar SSH", width=150, height=32,
                      fg_color=COLOR_DIM,
                      command=self._deploy_test_ssh
                      ).pack(side="left", padx=4)
        ctk.CTkButton(act1, text="⬆ Subir + instalar slim .deb", width=240, height=32,
                      fg_color=COLOR_GREEN, text_color="#1a1a2e",
                      command=self._deploy_upload_slim
                      ).pack(side="left", padx=4)
        ctk.CTkButton(act1, text="⬆ Subir + instalar full .deb (APK)", width=260, height=32,
                      fg_color=COLOR_ACCENT2, hover_color="#00a0b0",
                      text_color="#1a1a2e",
                      command=self._deploy_upload_full
                      ).pack(side="left", padx=4)

        # Row 2: Remote management
        act2 = ctk.CTkFrame(parent, fg_color="transparent")
        act2.pack(fill="x", padx=14, pady=2)
        ctk.CTkButton(act2, text="🔨 Rebuild backend remoto", width=220, height=32,
                      fg_color=COLOR_ACCENT, hover_color="#6a25d0",
                      command=self._deploy_rebuild_backend
                      ).pack(side="left", padx=4)
        ctk.CTkButton(act2, text="📝 Logs remotos", width=150, height=32,
                      fg_color=COLOR_BLUE,
                      command=self._deploy_remote_logs
                      ).pack(side="left", padx=4)

        # Row 3: Proxmox deploy
        act3 = ctk.CTkFrame(parent, fg_color="transparent")
        act3.pack(fill="x", padx=14, pady=2)
        ctk.CTkButton(act3, text="📦 Subir + deploy Proxmox tar.gz",
                      width=280, height=32,
                      font=("SF Pro Display", 12, "bold"),
                      fg_color=COLOR_ACCENT, hover_color="#6a25d0",
                      command=self._deploy_upload_proxmox
                      ).pack(side="left", padx=4)

    def _ssh_port(self) -> str:
        """Return the configured SSH port, or empty string if it's the
        default (22) so we don't bother adding `-p 22` to every command."""
        port = self.ssh_port_var.get().strip()
        if not port or port == "22":
            return ""
        return port

    # Common -o flags that every ssh/scp invocation in this tab needs:
    # - StrictHostKeyChecking=accept-new lets a brand new host fingerprint
    #   be auto-added to known_hosts (otherwise BatchMode=yes makes the
    #   first connection fail with "Host key verification failed"). It
    #   still rejects a *changed* key, so MITM is detected.
    # - UserKnownHostsFile points at the regular user file so the entry
    #   persists across runs.
    _SSH_HOST_OPTS = [
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", f"UserKnownHostsFile={os.path.expanduser('~/.ssh/known_hosts')}",
    ]

    def _ssh_args(self) -> list[str]:
        """Args for the `ssh` binary. ssh uses lowercase -p for port."""
        args: list[str] = list(self._SSH_HOST_OPTS)
        port = self._ssh_port()
        if port:
            args += ["-p", port]
        key = self.ssh_key_var.get().strip()
        if key:
            args += ["-i", os.path.expanduser(key)]
        return args

    def _scp_args(self) -> list[str]:
        """Args for the `scp` binary. scp takes the port via uppercase -P
        (lowercase -p means "preserve modification times" in scp)."""
        args: list[str] = list(self._SSH_HOST_OPTS)
        port = self._ssh_port()
        if port:
            args += ["-P", port]
        key = self.ssh_key_var.get().strip()
        if key:
            args += ["-i", os.path.expanduser(key)]
        return args

    def _ssh_target(self) -> str:
        return f"{self.ssh_user_var.get().strip()}@{self.ssh_host_var.get().strip()}"

    def _ssh_password(self) -> str:
        """Return the in-memory SSH password (only used when no key is
        configured). Never persisted to disk."""
        try:
            return self.ssh_pass_var.get()
        except Exception:
            return ""

    def _use_password_auth(self) -> bool:
        return bool(self._ssh_password()) and not self.ssh_key_var.get().strip()

    def _wrap_with_sshpass(self, cmd: list[str]) -> tuple[list[str], dict | None]:
        """If a password is configured (and no key), prepend `sshpass -e`
        and return an env dict carrying SSHPASS. Otherwise return the cmd
        unchanged with env=None. We pass the password via env (not -p) so
        it doesn't show up in `ps`."""
        if not self._use_password_auth():
            return cmd, None
        if shutil.which("sshpass") is None:
            self.log("✖ sshpass no está instalado. Instálalo con: "
                     "sudo apt install -y sshpass  (o configura una key SSH).",
                     level="error")
            # Return as-is; ssh will then fail with "Permission denied"
            # which is fine — the log already explained why.
            return cmd, None
        new_cmd = ["sshpass", "-e", *cmd]
        env = {**os.environ, "SSHPASS": self._ssh_password()}
        return new_cmd, env

    def _save_deploy_cfg(self):
        self.cfg["ssh_user"] = self.ssh_user_var.get().strip()
        self.cfg["ssh_host"] = self.ssh_host_var.get().strip()
        self.cfg["ssh_port"] = self.ssh_port_var.get().strip() or "22"
        self.cfg["ssh_key"] = self.ssh_key_var.get().strip()
        # Deliberately NOT saving ssh_pass — it's session-only.
        save_config(self.cfg)
        self.log("✓ SSH config guardada (password no se persiste)", level="ok")

    def _deploy_test_ssh(self):
        # BatchMode=yes is incompatible with sshpass (it disables
        # password auth in the client). Drop it when using password.
        extra = [] if self._use_password_auth() else ["-o", "BatchMode=yes"]
        cmd = ["ssh", *self._ssh_args(), *extra,
               "-o", "ConnectTimeout=5", self._ssh_target(),
               "echo OK && hostname && uptime"]
        cmd, env = self._wrap_with_sshpass(cmd)
        self.runner.run(cmd, env=env, title=f"ssh {self._ssh_target()} (test)")

    def _deploy_upload_slim(self):
        # Slim build is the one created by create-deb-server.sh; package
        # name is `winus-intercom-server_*.deb`.
        self._deploy_upload_deb(
            label="slim",
            picker=lambda p: p.name.startswith("winus-intercom-server_"),
            hint="Usa tab Build → .deb server slim.",
        )

    def _deploy_upload_full(self):
        # Full build comes from create-deb.sh; the prefix is exactly
        # `winus-intercom_` so we have to exclude the slim variant which
        # would also match if we used a plain glob.
        self._deploy_upload_deb(
            label="full",
            picker=lambda p: (
                p.name.startswith("winus-intercom_")
                and not p.name.startswith("winus-intercom-server_")
            ),
            hint="Usa tab Build → .deb completo.",
        )

    def _deploy_upload_deb(self, *, label: str, picker, hint: str):
        """Upload the most recent .deb in PROJECT_DIR matching `picker`
        and chain `apt install -y` on the remote. `label` is only used in
        log messages so the operator can tell slim vs full apart."""
        candidates = [p for p in PROJECT_DIR.glob("winus-intercom*.deb")
                       if picker(p)]
        if not candidates:
            self.log(
                f"✖ No hay ningún .deb {label} generado en {PROJECT_DIR}. "
                + hint,
                level="error",
            )
            return
        latest = sorted(candidates, key=lambda p: p.stat().st_mtime,
                         reverse=True)[0]
        size_mb = latest.stat().st_size / (1024 * 1024)
        target = self._ssh_target()
        self.log(
            f"▸ [{label}] {latest.name} ({size_mb:,.1f} MB) → {target}:/tmp/",
            level="info",
        )

        # scp — note `_scp_args()` (uppercase -P) instead of `_ssh_args()`.
        scp_cmd = ["scp", *self._scp_args(), str(latest),
                   f"{target}:/tmp/{latest.name}"]
        scp_cmd, env = self._wrap_with_sshpass(scp_cmd)
        self.runner.run(scp_cmd, env=env,
                         title=f"scp [{label}] {latest.name} → {target}")
        # Chain install after scp finishes
        self.root.after(500, lambda: self._chain_remote_install(latest.name))

    def _remote_sudo_password(self) -> str | None:
        """Best guess for the password the remote `sudo -S` will need.
        Strategy: prefer the SSH password the operator typed in the Deploy
        tab (typical case: same account on local + remote with one shared
        password) and fall back to the local sudo password from the
        header. Returns None if neither is set."""
        ssh_pw = self._ssh_password().strip()
        if ssh_pw:
            return ssh_pw
        try:
            local_pw = self.get_sudo_password(prompt_if_missing=False)
        except Exception:
            local_pw = None
        return local_pw or None

    def _run_remote_sudo(self, remote_cmd: str, *, title: str) -> None:
        """Run a remote command that needs sudo on the remote host. We
        pipe the password through ssh's stdin into `sudo -S -p ''` so
        no TTY is required and the secret never appears in `ps`."""
        # Wrap the command so its sudo invocation reads the password
        # from stdin (the empty -p suppresses sudo's own prompt).
        wrapped = remote_cmd.replace("sudo ", "sudo -S -p '' ", 1)
        cmd = ["ssh", *self._ssh_args(), self._ssh_target(), wrapped]
        cmd, env = self._wrap_with_sshpass(cmd)
        pw = self._remote_sudo_password()
        if pw is None:
            self.log(
                "✖ No hay password para el sudo remoto. Rellena el campo "
                "\"Password (no key)\" en Deploy o el campo sudo de la "
                "cabecera (debe coincidir con el usuario remoto).",
                level="error",
            )
            return
        # Newline-terminated so sudo reads the line straight away.
        self.runner.run(cmd, env=env, title=title, stdin_data=pw + "\n")

    def _chain_remote_install(self, fname: str):
        if self.runner.busy:
            self.root.after(500, lambda: self._chain_remote_install(fname))
            return
        self._run_remote_sudo(
            f"sudo apt install -y /tmp/{fname}",
            title=f"ssh apt install /tmp/{fname}",
        )

    def _deploy_upload_proxmox(self):
        """Upload the most recent Proxmox export tar.gz and run deploy-proxmox.sh remotely."""
        candidates = sorted(
            PROJECT_DIR.glob("winus-intercom-server-*.tar.gz"),
            key=lambda p: p.stat().st_mtime, reverse=True,
        )
        if not candidates:
            self.log(
                "✖ No hay ningún export Proxmox. Usa Build → 📦 Export Proxmox primero.",
                level="error",
            )
            return
        latest = candidates[0]
        size_mb = latest.stat().st_size / (1024 * 1024)
        target = self._ssh_target()
        self.log(
            f"▸ [proxmox] {latest.name} ({size_mb:,.1f} MB) → {target}:/tmp/",
            level="info",
        )
        scp_cmd = ["scp", *self._scp_args(), str(latest),
                   f"{target}:/tmp/{latest.name}"]
        scp_cmd, env = self._wrap_with_sshpass(scp_cmd)
        self.runner.run(scp_cmd, env=env,
                         title=f"scp [proxmox] {latest.name} → {target}")
        self.root.after(500, lambda: self._chain_proxmox_deploy(latest.name))

    def _chain_proxmox_deploy(self, fname: str):
        if self.runner.busy:
            self.root.after(500, lambda: self._chain_proxmox_deploy(fname))
            return
        # Extract + run deploy script on remote
        self._run_remote_sudo(
            f"cd /tmp && tar xzf {fname} && cd winus-intercom-deploy-* && sudo bash deploy-proxmox.sh",
            title=f"ssh deploy-proxmox.sh",
        )

    def _deploy_rebuild_backend(self):
        self._run_remote_sudo(
            "cd /opt/winus-intercom && sudo docker compose up -d --build backend",
            title="remote: rebuild backend",
        )

    def _deploy_remote_logs(self):
        self._run_remote_sudo(
            "cd /opt/winus-intercom && sudo docker compose logs --tail=80 backend",
            title="remote: backend logs",
        )

    # -------------------- TAB: BRIDGE --------------------
    def _build_tab_bridge(self, parent):
        ctk.CTkLabel(parent, text="TieLine Bridge",
                     font=("SF Pro Display", 14, "bold"),
                     text_color=COLOR_ACCENT2).pack(anchor="w", padx=14, pady=(12, 6))

        info = ctk.CTkLabel(parent,
                             text=("Acciones rápidas sobre /opt/winus-intercom/tie-line-bridge/."),
                             font=("SF Pro Display", 11), text_color=COLOR_DIM)
        info.pack(anchor="w", padx=14, pady=(0, 6))

        row = ctk.CTkFrame(parent, fg_color="transparent")
        row.pack(fill="x", padx=14, pady=4)

        ctk.CTkButton(row, text="▶ Abrir GUI del bridge", width=200, height=34,
                      fg_color=COLOR_ACCENT, hover_color="#6a25d0",
                      command=self._bridge_open_gui).pack(side="left", padx=4)
        ctk.CTkButton(row, text="🗑 Reset config.json", width=170, height=34,
                      fg_color=COLOR_RED, hover_color="#d32f2f",
                      command=self._bridge_reset_config).pack(side="left", padx=4)
        ctk.CTkButton(row, text="🔨 Rebuild bridge .deb", width=180, height=34,
                      fg_color=COLOR_GREEN, text_color="#1a1a2e",
                      command=lambda: self.runner.run(
                          ["bash", str(BRIDGE_DIR / "build_deb.sh")],
                          cwd=str(BRIDGE_DIR), title="build_deb.sh (bridge)")
                      ).pack(side="left", padx=4)

        # Distributable packages row
        ctk.CTkLabel(parent, text="Paquetes distribuibles (Linux / macOS / Windows)",
                     font=("SF Pro Display", 12),
                     text_color=COLOR_DIM).pack(anchor="w", padx=14, pady=(14, 2))
        row2 = ctk.CTkFrame(parent, fg_color="transparent")
        row2.pack(fill="x", padx=14, pady=4)

        ctk.CTkButton(row2, text="📦 Package Bridges", width=200, height=34,
                      font=("SF Pro Display", 13, "bold"),
                      fg_color=COLOR_ACCENT2, hover_color="#00a0b0",
                      text_color="#1a1a2e",
                      command=lambda: self.runner.run(
                          ["bash", str(BRIDGE_DIR / "package-bridges.sh")],
                          cwd=str(BRIDGE_DIR), title="package-bridges.sh")
                      ).pack(side="left", padx=4)
        ctk.CTkButton(row2, text="📂 Abrir dist/", width=140, height=34,
                      fg_color=COLOR_DIM, hover_color="#555577",
                      command=self._bridge_open_dist).pack(side="left", padx=4)

    def _bridge_open_dist(self):
        dist_dir = BRIDGE_DIR / "dist"
        if not dist_dir.exists():
            self.log("✖ No existe dist/. Ejecuta '📦 Package Bridges' primero.", level="error")
            return
        try:
            subprocess.Popen(["xdg-open", str(dist_dir)])
            self.log(f"▸ Abierto {dist_dir}", level="ok")
        except Exception as e:
            self.log(f"✖ {e}", level="error")

    def _bridge_open_gui(self):
        gui_path = BRIDGE_DIR / "bridge_gui.py"
        if not gui_path.exists():
            self.log(f"✖ No existe {gui_path}", level="error")
            return
        # Launch detached
        try:
            subprocess.Popen(["python3", str(gui_path)], cwd=str(BRIDGE_DIR),
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.log(f"▸ Lanzado {gui_path.name}", level="ok")
        except Exception as e:
            self.log(f"✖ {e}", level="error")

    def _bridge_reset_config(self):
        cfg_file = BRIDGE_DIR / "config.json"
        if not cfg_file.exists():
            self.log(f"(no hay config.json en {BRIDGE_DIR})", level="warn")
            return
        if not messagebox.askyesno("Reset bridge config",
                                     f"¿Borrar {cfg_file}?"):
            return
        try:
            cfg_file.unlink()
            self.log(f"✓ Borrado {cfg_file}", level="ok")
        except Exception as e:
            self.log(f"✖ {e}", level="error")

    # -------------------- LOG / STATUS --------------------
    def log(self, text: str, level: str = "line") -> None:
        self.log_text.configure(state="normal")
        self.log_text.insert("end", text + ("\n" if not text.endswith("\n") else ""),
                             level)
        self.log_text.see("end")
        self.log_text.configure(state="disabled")

    def _clear_log(self):
        self.log_text.configure(state="normal")
        self.log_text.delete("1.0", "end")
        self.log_text.configure(state="disabled")

    def _stop_current(self):
        if self.runner.proc and self.runner.proc.poll() is None:
            try:
                self.runner.proc.terminate()
                self.log("⚠  terminate() enviado", level="warn")
            except Exception as e:
                self.log(f"✖ {e}", level="error")
        else:
            self.log("(nada que detener)", level="warn")

    def set_running(self, on: bool, title: str = ""):
        if on:
            self.status_badge.configure(
                text=f"⏵ {title[:40]}…" if title else "⏵ running",
                text_color=COLOR_ORANGE)
        else:
            self.status_badge.configure(text="● idle", text_color=COLOR_DIM)

    def _refresh_status_loop(self):
        """Poll docker ps every 3s and update the header badge."""
        def _poll():
            try:
                out = subprocess.check_output(
                    ["sudo", "-n", "docker", "ps",
                     "--format", "{{.Names}}|{{.Status}}"],
                    stderr=subprocess.DEVNULL, timeout=3).decode()
                running = [l for l in out.splitlines() if "intercom-" in l]
                if running:
                    names = ", ".join(l.split("|")[0].replace("intercom-", "") for l in running)
                    msg = f"Docker: {names}"
                    color = COLOR_GREEN
                else:
                    msg = "Docker: (sin contenedores)"
                    color = COLOR_ORANGE
            except Exception:
                msg = "Docker: n/a"
                color = COLOR_DIM
            self.containers_badge.configure(text=msg, text_color=color)

        threading.Thread(target=_poll, daemon=True).start()
        self.root.after(3000, self._refresh_status_loop)

    def run(self):
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)
        self.root.mainloop()

    def _on_close(self):
        save_config(self.cfg)
        # Clear in-memory password before exit (paranoia).
        self._sudo_password = None
        self.root.destroy()

    def _on_sudo_entry_change(self):
        """Sync the header entry into the in-memory cache."""
        v = self.sudo_entry_var.get()
        self._sudo_password = v if v else None


def main():
    app = ControlCenter()
    app.run()


if __name__ == "__main__":
    main()
