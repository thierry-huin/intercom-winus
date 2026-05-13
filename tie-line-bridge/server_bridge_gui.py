#!/usr/bin/env python3
"""Server Bridge GUI — Visual interface for connecting two Winus Intercom servers.

Requires: customtkinter, aiohttp, websockets, Pillow (optional, for logo)
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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from server_bridge import BridgeEndpoint, ServerBridgeLink

CONFIG_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "server_bridge.json")

# Theme
COLOR_BG = "#1a1a2e"
COLOR_CARD = "#16213e"
COLOR_ACCENT = "#7b2ff7"
COLOR_ACCENT2 = "#00c9db"
COLOR_GREEN = "#00e676"
COLOR_RED = "#ff5252"
COLOR_ORANGE = "#ffab40"
COLOR_TEXT = "#e0e0e0"
COLOR_DIM = "#666680"
COLOR_ROW_EVEN = "#1a1a2e"
COLOR_ROW_ODD = "#0f3460"
COLOR_BLUE = "#2196f3"

_ssl_ctx = ssl.create_default_context()
_ssl_ctx.check_hostname = False
_ssl_ctx.verify_mode = ssl.CERT_NONE


# ═══════════════════════════════════════════════════════════════
#  LinkRow
# ═══════════════════════════════════════════════════════════════

class LinkRow:
    def __init__(self, parent, index, row):
        self.index = index
        self.link = None
        self._dir_a = {}
        self._dir_b = {}
        self._online_a = set()
        self._online_b = set()
        self._on_connect_cb = None
        self._on_disconnect_cb = None

        bg = COLOR_ROW_ODD if index % 2 else COLOR_ROW_EVEN
        self.frame = ctk.CTkFrame(parent, fg_color=bg, corner_radius=6, height=44)
        self.frame.grid(row=row, column=0, sticky="ew", padx=4, pady=2)

        col = 0
        self.lbl = ctk.CTkLabel(self.frame, text=f"{index+1}", font=("SF Pro Display", 13, "bold"),
                                text_color=COLOR_ACCENT2, width=28)
        self.lbl.grid(row=0, column=col, padx=(6,2), pady=6); col += 1

        self.status_dot = ctk.CTkLabel(self.frame, text="●", font=("Arial", 22),
                                       text_color=COLOR_DIM, width=24)
        self.status_dot.grid(row=0, column=col, padx=2); col += 1

        # Side A
        self.a_user_var = tk.StringVar()
        self.a_user = ctk.CTkEntry(self.frame, textvariable=self.a_user_var, width=95,
                                    placeholder_text="bridge user", height=28, font=("SF Pro Display", 11))
        self.a_user.grid(row=0, column=col, padx=2, pady=3); col += 1

        self.a_pass_var = tk.StringVar()
        self.a_pass = ctk.CTkEntry(self.frame, textvariable=self.a_pass_var, width=70,
                                    placeholder_text="pass", show="•", height=28)
        self.a_pass.grid(row=0, column=col, padx=2, pady=3); col += 1

        self.a_ttype_var = tk.StringVar(value="user")
        self.a_ttype = ctk.CTkComboBox(self.frame, variable=self.a_ttype_var, values=["user","group"],
                                        width=65, height=26, state="readonly", font=("SF Pro Display",10),
                                        command=lambda _: self._update_dropdown("a"))
        self.a_ttype.grid(row=0, column=col, padx=2, pady=3); col += 1

        self.a_tid_var = tk.StringVar()
        self.a_tid = ctk.CTkComboBox(self.frame, variable=self.a_tid_var, values=[], width=140,
                                      height=26, state="readonly", font=("SF Pro Display",10))
        self.a_tid.grid(row=0, column=col, padx=2, pady=3); col += 1

        ctk.CTkLabel(self.frame, text="↔", font=("Arial",14), text_color=COLOR_DIM,
                     width=20).grid(row=0, column=col, padx=1); col += 1

        # Side B
        self.b_user_var = tk.StringVar()
        self.b_user = ctk.CTkEntry(self.frame, textvariable=self.b_user_var, width=95,
                                    placeholder_text="bridge user", height=28, font=("SF Pro Display", 11))
        self.b_user.grid(row=0, column=col, padx=2, pady=3); col += 1

        self.b_pass_var = tk.StringVar()
        self.b_pass = ctk.CTkEntry(self.frame, textvariable=self.b_pass_var, width=70,
                                    placeholder_text="pass", show="•", height=28)
        self.b_pass.grid(row=0, column=col, padx=2, pady=3); col += 1

        self.b_ttype_var = tk.StringVar(value="user")
        self.b_ttype = ctk.CTkComboBox(self.frame, variable=self.b_ttype_var, values=["user","group"],
                                        width=65, height=26, state="readonly", font=("SF Pro Display",10),
                                        command=lambda _: self._update_dropdown("b"))
        self.b_ttype.grid(row=0, column=col, padx=2, pady=3); col += 1

        self.b_tid_var = tk.StringVar()
        self.b_tid = ctk.CTkComboBox(self.frame, variable=self.b_tid_var, values=[], width=140,
                                      height=26, state="readonly", font=("SF Pro Display",10))
        self.b_tid.grid(row=0, column=col, padx=2, pady=3); col += 1

        self.pkt_label = ctk.CTkLabel(self.frame, text="—", font=("SF Mono",9),
                                       text_color=COLOR_DIM, width=50)
        self.pkt_label.grid(row=0, column=col, padx=2); col += 1

        self.connect_btn = ctk.CTkButton(self.frame, text="▶", width=30, height=26,
                                          font=("SF Pro Display",12,"bold"),
                                          fg_color=COLOR_GREEN, hover_color="#00c853",
                                          text_color="#1a1a2e", command=self._on_connect_click)
        self.connect_btn.grid(row=0, column=col, padx=(2,6), pady=3)

    def set_directory(self, side, users, groups):
        users = [u for u in users if u.get("role") not in ("admin","superadmin")]
        items = [(u["id"], u["display_name"]) for u in users]
        gitems = [(g["id"], g["name"]) for g in groups]
        if side == "a": self._dir_a = {"user": items, "group": gitems}
        else:           self._dir_b = {"user": items, "group": gitems}
        self._update_dropdown(side)

    def set_online_users(self, side, usernames):
        if side == "a": self._online_a = usernames
        else:           self._online_b = usernames

    def _update_dropdown(self, side):
        if side == "a":
            ttype, d, combo, var = self.a_ttype_var.get(), self._dir_a, self.a_tid, self.a_tid_var
        else:
            ttype, d, combo, var = self.b_ttype_var.get(), self._dir_b, self.b_tid, self.b_tid_var
        items = d.get(ttype, []) if isinstance(d, dict) else []
        vals = [f"{name} ({id})" for id, name in items]
        combo.configure(values=vals)
        if var.get() not in vals and vals: combo.set(vals[0])

    def _parse_tid(self, val):
        try: return int(val.rsplit("(",1)[1].rstrip(")"))
        except: return 0

    def get_config(self):
        return {
            "label": f"Link {self.index+1}",
            "a_username": self.a_user_var.get().strip(), "a_password": self.a_pass_var.get().strip(),
            "a_target_type": self.a_ttype_var.get(), "a_target_id": self._parse_tid(self.a_tid_var.get()),
            "b_username": self.b_user_var.get().strip(), "b_password": self.b_pass_var.get().strip(),
            "b_target_type": self.b_ttype_var.get(), "b_target_id": self._parse_tid(self.b_tid_var.get()),
        }

    def set_config(self, cfg):
        self.a_user_var.set(cfg.get("a_username","")); self.a_pass_var.set(cfg.get("a_password",""))
        self.a_ttype_var.set(cfg.get("a_target_type","user"))
        self.b_user_var.set(cfg.get("b_username","")); self.b_pass_var.set(cfg.get("b_password",""))
        self.b_ttype_var.set(cfg.get("b_target_type","user"))
        self._pending_a_tid = cfg.get("a_target_id",0)
        self._pending_b_tid = cfg.get("b_target_id",0)

    def apply_pending_targets(self):
        for side, tid in [("a", getattr(self,"_pending_a_tid",0)),
                          ("b", getattr(self,"_pending_b_tid",0))]:
            d = self._dir_a if side=="a" else self._dir_b
            if not isinstance(d, dict): continue
            ttype = self.a_ttype_var.get() if side=="a" else self.b_ttype_var.get()
            combo = self.a_tid if side=="a" else self.b_tid
            for item_id, name in d.get(ttype, []):
                if item_id == tid: combo.set(f"{name} ({item_id})"); break

    def update_status(self):
        link = self.link
        if link is None:
            self.status_dot.configure(text_color=COLOR_DIM)
            self.pkt_label.configure(text="—")
        else:
            a_ok, b_ok = link.a.connected, link.b.connected
            if a_ok and b_ok:     self.status_dot.configure(text_color=COLOR_GREEN)
            elif a_ok or b_ok:    self.status_dot.configure(text_color=COLOR_ORANGE)
            else:                 self.status_dot.configure(text_color=COLOR_RED)
            self.pkt_label.configure(text="A↔B")
        # Username collision
        for side in ("a","b"):
            entry = self.a_user if side=="a" else self.b_user
            uname = (self.a_user_var if side=="a" else self.b_user_var).get().strip()
            online = self._online_a if side=="a" else self._online_b
            we_own = (link is not None and
                      ((side=="a" and link.a.connected) or (side=="b" and link.b.connected)))
            if uname and uname in online and not we_own:
                entry.configure(fg_color=COLOR_RED, text_color="white")
            else:
                entry.configure(fg_color=("#343638","#343638"), text_color=COLOR_TEXT)

    def _on_connect_click(self):
        if self.link is not None:
            if self._on_disconnect_cb: self._on_disconnect_cb(self.index)
        else:
            if self._on_connect_cb: self._on_connect_cb(self.index)

    def set_enabled(self, enabled):
        st = "normal" if enabled else "disabled"
        for w in (self.a_user,self.a_pass,self.b_user,self.b_pass): w.configure(state=st)
        rs = "readonly" if enabled else "disabled"
        for w in (self.a_ttype,self.a_tid,self.b_ttype,self.b_tid): w.configure(state=rs)

    def update_connect_btn(self):
        if self.link is not None:
            self.connect_btn.configure(text="■", fg_color=COLOR_RED, hover_color="#d32f2f")
        else:
            self.connect_btn.configure(text="▶", fg_color=COLOR_GREEN, hover_color="#00c853")


# ═══════════════════════════════════════════════════════════════
#  App
# ═══════════════════════════════════════════════════════════════

class ServerBridgeApp(ctk.CTk):
    NUM_LINKS = 8

    def __init__(self):
        super().__init__()
        self.title("Winus Server Bridge")
        self.geometry("1360x620")
        self.configure(fg_color=COLOR_BG)
        self._running = False
        self._loop = None
        self._thread = None
        self._link_tasks = []
        self._online_a = set()
        self._online_b = set()
        ctk.set_appearance_mode("dark")

        # ── Header ──
        hdr = ctk.CTkFrame(self, fg_color=COLOR_CARD, corner_radius=10)
        hdr.pack(fill="x", padx=10, pady=(10,4))
        logo_path = os.path.join(os.path.dirname(__file__), "logo.png")
        if os.path.exists(logo_path):
            try:
                from PIL import Image
                img = Image.open(logo_path).resize((36,36))
                self._logo_img = ctk.CTkImage(img, size=(36,36))
                ctk.CTkLabel(hdr, image=self._logo_img, text="").pack(side="left", padx=(10,4))
            except: pass
        ctk.CTkLabel(hdr, text="Server Bridge", font=("SF Pro Display",18,"bold"),
                     text_color=COLOR_TEXT).pack(side="left", padx=(0,16))
        btn_frame = ctk.CTkFrame(hdr, fg_color="transparent")
        btn_frame.pack(side="right", padx=8)
        self.refresh_btn = ctk.CTkButton(btn_frame, text="↻ Targets", width=85, height=30,
                                          fg_color=COLOR_ACCENT, hover_color="#6a1fd0",
                                          font=("SF Pro Display",12), command=self._on_refresh)
        self.refresh_btn.pack(side="left", padx=4)
        self.connect_btn = ctk.CTkButton(btn_frame, text="▶ All", width=80, height=30,
                                          fg_color=COLOR_GREEN, hover_color="#00c853",
                                          text_color="#1a1a2e", font=("SF Pro Display",12,"bold"),
                                          command=self._on_connect)
        self.connect_btn.pack(side="left", padx=4)

        # ── Server config panel ──
        srv = ctk.CTkFrame(self, fg_color=COLOR_CARD, corner_radius=8)
        srv.pack(fill="x", padx=10, pady=(2,4))

        for side, label, color in [("a","Server A",COLOR_ACCENT), ("b","Server B",COLOR_ORANGE)]:
            row = ctk.CTkFrame(srv, fg_color="transparent")
            row.pack(fill="x", padx=10, pady=(6 if side=="a" else 2, 2 if side=="a" else 6))
            led = ctk.CTkLabel(row, text="●", font=("Arial",18), text_color=COLOR_DIM, width=22)
            led.pack(side="left", padx=(0,4))
            setattr(self, f"srv_{side}_led", led)
            ctk.CTkLabel(row, text=label, font=("SF Pro Display",12,"bold"),
                         text_color=color, width=70).pack(side="left")
            var_url = tk.StringVar(value=f"https://server-{side}:8443")
            setattr(self, f"srv_{side}_var", var_url)
            ctk.CTkEntry(row, textvariable=var_url, width=280, height=26,
                         font=("SF Pro Display",11)).pack(side="left", padx=4)
            ctk.CTkLabel(row, text="Login:", font=("SF Pro Display",10),
                         text_color=COLOR_DIM).pack(side="left", padx=(12,4))
            var_user = tk.StringVar()
            setattr(self, f"srv_{side}_user_var", var_user)
            ctk.CTkEntry(row, textvariable=var_user, width=100, height=26,
                         placeholder_text="bridge user", font=("SF Pro Display",11)).pack(side="left", padx=2)
            var_pass = tk.StringVar()
            setattr(self, f"srv_{side}_pass_var", var_pass)
            ctk.CTkEntry(row, textvariable=var_pass, width=80, height=26,
                         placeholder_text="pass", show="•", font=("SF Pro Display",11)).pack(side="left", padx=2)

        # ── Column headers ──
        ch = ctk.CTkFrame(self, fg_color="transparent")
        ch.pack(fill="x", padx=14, pady=(4,0))
        for text, w in [("#",28),("●",24),("User A",95),("Pass A",70),("Type",65),("Target A",140),
                        ("",20),("User B",95),("Pass B",70),("Type",65),("Target B",140),("",50),("",30)]:
            ctk.CTkLabel(ch, text=text, font=("SF Pro Display",9), text_color=COLOR_DIM,
                         width=w).pack(side="left", padx=2)

        # ── Link rows ──
        self.scroll = ctk.CTkScrollableFrame(self, fg_color=COLOR_BG)
        self.scroll.pack(fill="both", expand=True, padx=10, pady=4)
        self.scroll.grid_columnconfigure(0, weight=1)
        self.rows = []
        for i in range(self.NUM_LINKS):
            lr = LinkRow(self.scroll, i, i)
            lr._on_connect_cb = self._start_single
            lr._on_disconnect_cb = self._stop_single
            self.rows.append(lr)

        self._load_config()
        self._poll_status()

    # ── Config ──

    def _load_config(self):
        if not os.path.exists(CONFIG_FILE): self._save_config(); return
        try:
            with open(CONFIG_FILE) as f: cfg = json.load(f)
            self.srv_a_var.set(cfg.get("server_a",""))
            self.srv_b_var.set(cfg.get("server_b",""))
            self.srv_a_user_var.set(cfg.get("login_a_user",""))
            self.srv_a_pass_var.set(cfg.get("login_a_pass",""))
            self.srv_b_user_var.set(cfg.get("login_b_user",""))
            self.srv_b_pass_var.set(cfg.get("login_b_pass",""))
            for i, lk in enumerate(cfg.get("links",[])):
                if i >= len(self.rows): break
                self.rows[i].set_config(lk)
        except Exception as e: print(f"Config load error: {e}")

    def _save_config(self):
        cfg = {
            "server_a": self.srv_a_var.get().strip(), "server_b": self.srv_b_var.get().strip(),
            "login_a_user": self.srv_a_user_var.get().strip(),
            "login_a_pass": self.srv_a_pass_var.get().strip(),
            "login_b_user": self.srv_b_user_var.get().strip(),
            "login_b_pass": self.srv_b_pass_var.get().strip(),
            "links": [r.get_config() for r in self.rows
                       if r.get_config()["a_username"] and r.get_config()["b_username"]],
        }
        try:
            with open(CONFIG_FILE,"w") as f: json.dump(cfg, f, indent=2)
        except Exception as e: print(f"Config save error: {e}")

    # ── Refresh targets ──

    def _on_refresh(self):
        self.refresh_btn.configure(state="disabled", text="Loading...")
        self.srv_a_led.configure(text_color=COLOR_DIM)
        self.srv_b_led.configure(text_color=COLOR_DIM)
        self._save_config()
        threading.Thread(target=self._fetch_targets, daemon=True).start()

    def _fetch_targets(self):
        async def fetch(url, user, pwd):
            conn = aiohttp.TCPConnector(ssl=False)
            async with aiohttp.ClientSession(connector=conn) as s:
                async with s.post(f"{url}/api/auth/login",
                                  json={"username":user,"password":pwd,"client_type":"bridge"}) as r:
                    data = await r.json()
                    if r.status != 200: return None, None, None
                    token = data["token"]
                async with s.get(f"{url}/api/rooms/my-targets",
                                 headers={"Authorization":f"Bearer {token}"}) as r:
                    if r.status != 200: return None, None, None
                    tdata = await r.json()
                # Online detection
                online_names = set()
                try:
                    async with s.get(f"{url}/api/admin/online",
                                     headers={"Authorization":f"Bearer {token}"}) as r2:
                        if r2.status == 200:
                            odata = await r2.json()
                            oids = set(odata.get("userIds",[]))
                            all_users = tdata.get("users",[])
                            for u in all_users:
                                if u["id"] in oids: online_names.add(u.get("username",""))
                except: pass
                return tdata.get("users",[]), tdata.get("groups",[]), online_names

        a_user = self.srv_a_user_var.get().strip()
        a_pass = self.srv_a_pass_var.get().strip()
        b_user = self.srv_b_user_var.get().strip()
        b_pass = self.srv_b_pass_var.get().strip()
        # Fallback to first link creds
        if not a_user or not b_user:
            for r in self.rows:
                cfg = r.get_config()
                if cfg["a_username"] and not a_user: a_user,a_pass = cfg["a_username"],cfg["a_password"]
                if cfg["b_username"] and not b_user: b_user,b_pass = cfg["b_username"],cfg["b_password"]

        ua=ga=oa=ub=gb=ob=None
        try:
            loop = asyncio.new_event_loop()
            if a_user: ua,ga,oa = loop.run_until_complete(fetch(self.srv_a_var.get().strip(), a_user, a_pass))
            if b_user: ub,gb,ob = loop.run_until_complete(fetch(self.srv_b_var.get().strip(), b_user, b_pass))
            loop.close()
        except Exception as e: print(f"Fetch error: {e}")

        def apply():
            self.srv_a_led.configure(text_color=COLOR_GREEN if ua is not None else COLOR_RED)
            self.srv_b_led.configure(text_color=COLOR_GREEN if ub is not None else COLOR_RED)
            if oa is not None: self._online_a = oa
            if ob is not None: self._online_b = ob
            for r in self.rows:
                if ua is not None: r.set_directory("a", ua, ga or [])
                if ub is not None: r.set_directory("b", ub, gb or [])
                r.set_online_users("a", self._online_a)
                r.set_online_users("b", self._online_b)
                r.apply_pending_targets()
            self.refresh_btn.configure(state="normal", text="↻ Targets")
        self.after(0, apply)

    # ── Connect ──

    def _on_connect(self):
        if self._running: self._stop_all()
        else: self._start_all()

    def _start_all(self):
        self._save_config(); self._running = True
        self.connect_btn.configure(text="■ Stop", fg_color=COLOR_RED, hover_color="#d32f2f")
        for r in self.rows: r.set_enabled(False)
        self._loop = asyncio.new_event_loop()
        self._thread = threading.Thread(target=self._run_loop, daemon=True)
        self._thread.start()

    def _run_loop(self):
        asyncio.set_event_loop(self._loop)
        sa, sb = self.srv_a_var.get().strip(), self.srv_b_var.get().strip()
        for r in self.rows:
            cfg = r.get_config()
            if not cfg["a_username"] or not cfg["b_username"]: continue
            ea = BridgeEndpoint(label=f"L{r.index+1}/A", server_url=sa, username=cfg["a_username"],
                                password=cfg["a_password"], target_type=cfg["a_target_type"], target_id=cfg["a_target_id"])
            eb = BridgeEndpoint(label=f"L{r.index+1}/B", server_url=sb, username=cfg["b_username"],
                                password=cfg["b_password"], target_type=cfg["b_target_type"], target_id=cfg["b_target_id"])
            link = ServerBridgeLink(label=f"Link {r.index+1}", endpoint_a=ea, endpoint_b=eb)
            r.link = link
            self._link_tasks.append(self._loop.create_task(link.run()))
        if self._link_tasks:
            self._loop.run_until_complete(asyncio.gather(*self._link_tasks, return_exceptions=True))

    def _stop_all(self):
        self._running = False
        for r in self.rows:
            if r.link: r.link.stop(); r.link = None; r.update_connect_btn()
        if self._loop:
            for t in self._link_tasks: self._loop.call_soon_threadsafe(t.cancel)
        self._link_tasks.clear()
        self.connect_btn.configure(text="▶ All", fg_color=COLOR_GREEN, hover_color="#00c853")
        for r in self.rows: r.set_enabled(True)

    def _start_single(self, idx):
        r = self.rows[idx]; cfg = r.get_config()
        if not cfg["a_username"] or not cfg["b_username"]: return
        self._save_config()
        sa, sb = self.srv_a_var.get().strip(), self.srv_b_var.get().strip()
        r.set_enabled(False)
        if self._loop is None or not self._loop.is_running():
            self._loop = asyncio.new_event_loop()
            self._thread = threading.Thread(target=self._loop.run_forever, daemon=True)
            self._thread.start()
        def create():
            ea = BridgeEndpoint(label=f"L{idx+1}/A", server_url=sa, username=cfg["a_username"],
                                password=cfg["a_password"], target_type=cfg["a_target_type"], target_id=cfg["a_target_id"])
            eb = BridgeEndpoint(label=f"L{idx+1}/B", server_url=sb, username=cfg["b_username"],
                                password=cfg["b_password"], target_type=cfg["b_target_type"], target_id=cfg["b_target_id"])
            link = ServerBridgeLink(label=f"Link {idx+1}", endpoint_a=ea, endpoint_b=eb)
            r.link = link
            self._link_tasks.append(self._loop.create_task(link.run()))
            self.after(0, r.update_connect_btn)
        self._loop.call_soon_threadsafe(create)

    def _stop_single(self, idx):
        r = self.rows[idx]
        if r.link: self._loop.call_soon_threadsafe(r.link.stop); r.link = None
        r.set_enabled(True); r.update_connect_btn()

    def _poll_status(self):
        for r in self.rows: r.update_status(); r.update_connect_btn()
        self.after(500, self._poll_status)


def main():
    app = ServerBridgeApp()
    app.mainloop()

if __name__ == "__main__":
    main()
