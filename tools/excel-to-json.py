#!/usr/bin/env python3
"""Excel/CSV → Winus Intercom JSON converter.

Reads an Excel (.xlsx) or CSV file with columns:
  Display Name, Username, Password, First Name, Last Name, EMAIL, Phone, Role

Outputs a JSON file compatible with the Winus Intercom import API,
with the option to append to an existing config or replace everything.

Dependencies: pip install openpyxl customtkinter
"""

import csv
import json
import os
import sys
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox

try:
    import customtkinter as ctk
    ctk.set_appearance_mode("dark")
    ctk.set_default_color_theme("dark-blue")
    HAS_CTK = True
except ImportError:
    HAS_CTK = False

try:
    import openpyxl
    HAS_OPENPYXL = True
except ImportError:
    HAS_OPENPYXL = False

# Theme
COLOR_BG = "#1a1a2e"
COLOR_CARD = "#16213e"
COLOR_ACCENT = "#7b2ff7"
COLOR_ACCENT2 = "#00c9db"
COLOR_GREEN = "#00e676"
COLOR_RED = "#ff5252"
COLOR_TEXT = "#e0e0e0"
COLOR_DIM = "#666680"

BRIDGE_ID_START = 1001
WINUS_ID = 99999  # superadmin — excluded from id calculations

# Column name normalisation — map common variations to our canonical keys.
COLUMN_MAP = {
    "display name": "display_name",
    "display_name": "display_name",
    "displayname": "display_name",
    "nombre": "display_name",
    "name": "display_name",
    "username": "username",
    "user": "username",
    "login": "username",
    "usuario": "username",
    "password": "password",
    "pass": "password",
    "contraseña": "password",
    "first name": "first_name",
    "first_name": "first_name",
    "firstname": "first_name",
    "nombre_pila": "first_name",
    "last name": "last_name",
    "last_name": "last_name",
    "lastname": "last_name",
    "apellido": "last_name",
    "email": "email",
    "e-mail": "email",
    "correo": "email",
    "phone": "phone",
    "teléfono": "phone",
    "telefono": "phone",
    "tel": "phone",
    "role": "role",
    "rol": "role",
}


def _norm_header(h: str) -> str:
    """Normalise a header string to a canonical key."""
    return COLUMN_MAP.get(h.strip().lower().replace("\ufeff", ""), "")


def read_excel(path: str) -> list[dict]:
    """Read an .xlsx file and return a list of user dicts."""
    if not HAS_OPENPYXL:
        raise RuntimeError("openpyxl not installed. Run: pip install openpyxl")
    wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
    ws = wb.active
    rows = list(ws.iter_rows(values_only=True))
    if not rows:
        return []
    headers = [_norm_header(str(h or "")) for h in rows[0]]
    users = []
    for row in rows[1:]:
        entry = {}
        for i, val in enumerate(row):
            if i < len(headers) and headers[i]:
                entry[headers[i]] = str(val).strip() if val is not None else ""
        if entry.get("display_name") or entry.get("username"):
            users.append(entry)
    return users


def read_csv(path: str) -> list[dict]:
    """Read a .csv file and return a list of user dicts."""
    users = []
    with open(path, newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        norm_fields = {_norm_header(k): k for k in (reader.fieldnames or [])}
        for row in reader:
            entry = {}
            for canon, orig in norm_fields.items():
                if canon:
                    entry[canon] = (row.get(orig) or "").strip()
            if entry.get("display_name") or entry.get("username"):
                users.append(entry)
    return users


def users_to_import_json(users: list[dict], mode: str = "replace",
                          existing: dict | None = None,
                          start_id: int = 1) -> dict:
    """Convert user dicts to Winus Intercom import JSON format.

    mode: 'replace' clears everything; 'append' merges into existing.

    ID assignment rules:
      - Regular users (user/admin/superuser): continue from the last used
        id among existing non-bridge, non-Winus users.
      - Bridge users: ids start at BRIDGE_ID_START (10001) and continue
        from the last used bridge id.
      - The Winus superadmin (id 99999) is always excluded from id
        calculations so it doesn't shift the sequence.
    """
    if mode == "append" and existing:
        ex_users = existing.get("users", [])
        ex_groups = existing.get("groups", [])
        ex_perms = existing.get("permissions", [])
        ex_gperms = existing.get("group_permissions", [])
        ex_members = existing.get("group_members", [])
        ex_config = existing.get("server_config", {})
    else:
        ex_users = []
        ex_groups = []
        ex_perms = []
        ex_gperms = []
        ex_members = []
        ex_config = {}

    # Compute next free ids from existing users, excluding Winus (99999).
    used_ids = {u["id"] for u in ex_users if u["id"] != WINUS_ID}
    regular_ids = {uid for uid in used_ids if uid < BRIDGE_ID_START}
    bridge_ids = {uid for uid in used_ids if uid >= BRIDGE_ID_START}
    next_regular = (max(regular_ids, default=0) + 1) if regular_ids else start_id
    next_bridge = (max(bridge_ids, default=BRIDGE_ID_START - 1) + 1)

    # Separate new users into regular and bridge
    new_users = []
    for u in users:
        role = (u.get("role") or "user").lower().strip()
        if role not in ("admin", "user", "bridge", "superuser"):
            role = "user"

        if role == "bridge":
            uid = next_bridge
            next_bridge += 1
        else:
            uid = next_regular
            next_regular += 1
            # Skip over reserved ranges
            while uid >= BRIDGE_ID_START or uid == WINUS_ID:
                uid += 1
                next_regular = uid + 1

        new_users.append({
            "id": uid,
            "username": u.get("username") or u.get("display_name", f"user{uid}").lower().replace(" ", "_"),
            "display_name": u.get("display_name") or u.get("username", f"User {uid}"),
            "role": role,
            "room_id": uid,
            "color": None,
            "first_name": u.get("first_name") or None,
            "last_name": u.get("last_name") or None,
            "email": u.get("email") or None,
            "phone": u.get("phone") or None,
            "password": u.get("password") or "1234",
        })

    all_users = ex_users + new_users

    return {
        "version": 1,
        "users": all_users,
        "groups": ex_groups,
        "group_members": ex_members,
        "permissions": ex_perms,
        "group_permissions": ex_gperms,
        "server_config": ex_config,
    }


class App:
    def __init__(self):
        if HAS_CTK:
            self.root = ctk.CTk()
            self.root.configure(fg_color=COLOR_BG)
        else:
            self.root = tk.Tk()
        self.root.title("Excel → Winus Intercom JSON")
        self.root.geometry("620x520")
        self.root.resizable(True, True)

        self._users: list[dict] = []
        self._existing: dict | None = None

        self._build_ui()

    def _build_ui(self):
        # Title
        self._label("Excel / CSV → Winus Intercom Import JSON",
                     font=("SF Pro Display", 16, "bold"), pady=(16, 4))
        self._label("Convierte una lista de usuarios a JSON para importar en el servidor",
                     font=("SF Pro Display", 11), fg=COLOR_DIM, pady=(0, 12))

        # File selection
        frame = self._frame()
        self._btn(frame, "📂 Abrir Excel / CSV", self._open_file,
                  fg=COLOR_ACCENT2, width=200)
        self.file_label = self._label("(ningún archivo)", font=("SF Pro Display", 11),
                                       fg=COLOR_DIM, parent=frame, side="left", padx=12)

        # Preview
        self._label("Vista previa:", font=("SF Pro Display", 12, "bold"), pady=(12, 4))
        if HAS_CTK:
            self.preview = ctk.CTkTextbox(self.root, height=180, fg_color="#0f0f1e",
                                           text_color=COLOR_TEXT, font=("Menlo", 11))
        else:
            self.preview = tk.Text(self.root, height=10, bg="#0f0f1e", fg=COLOR_TEXT,
                                    font=("Menlo", 11))
        self.preview.pack(fill="both", expand=True, padx=16, pady=4)

        # Mode
        mode_frame = self._frame()
        self._label("Modo:", font=("SF Pro Display", 12), parent=mode_frame, side="left")
        self.mode_var = tk.StringVar(value="replace")
        for val, text in [("replace", "🔄 Replace (reemplaza todo)"),
                          ("append", "➕ Append (añadir a existente)")]:
            if HAS_CTK:
                ctk.CTkRadioButton(mode_frame, text=text, variable=self.mode_var,
                                    value=val, font=("SF Pro Display", 12)).pack(side="left", padx=8)
            else:
                tk.Radiobutton(mode_frame, text=text, variable=self.mode_var,
                                value=val).pack(side="left", padx=8)

        # Existing JSON (for append mode)
        append_frame = self._frame()
        self._btn(append_frame, "📎 Cargar JSON existente (para append)", self._load_existing,
                  fg=COLOR_DIM, width=300)
        self.existing_label = self._label("", font=("SF Pro Display", 10),
                                           fg=COLOR_DIM, parent=append_frame, side="left", padx=8)

        # Export
        export_frame = self._frame(pady=(12, 16))
        self._btn(export_frame, "💾 Exportar JSON", self._export,
                  fg=COLOR_GREEN, width=200, text_color="#1a1a2e",
                  font=("SF Pro Display", 14, "bold"))
        self.status_label = self._label("", font=("SF Pro Display", 11),
                                         fg=COLOR_GREEN, parent=export_frame, side="left", padx=12)

    def _label(self, text, font=None, fg=COLOR_TEXT, pady=0, parent=None, side=None, padx=0):
        p = parent or self.root
        if HAS_CTK:
            lbl = ctk.CTkLabel(p, text=text, font=font, text_color=fg)
        else:
            lbl = tk.Label(p, text=text, font=font, fg=fg, bg=COLOR_BG)
        if side:
            lbl.pack(side=side, padx=padx)
        else:
            lbl.pack(anchor="w", padx=16, pady=pady)
        return lbl

    def _frame(self, pady=4):
        if HAS_CTK:
            f = ctk.CTkFrame(self.root, fg_color="transparent")
        else:
            f = tk.Frame(self.root, bg=COLOR_BG)
        f.pack(fill="x", padx=16, pady=pady)
        return f

    def _btn(self, parent, text, cmd, fg=COLOR_ACCENT, width=120, text_color="white", font=None):
        if HAS_CTK:
            b = ctk.CTkButton(parent, text=text, command=cmd, fg_color=fg,
                               width=width, height=34, text_color=text_color,
                               font=font or ("SF Pro Display", 12))
        else:
            b = tk.Button(parent, text=text, command=cmd, width=width // 8)
        b.pack(side="left", padx=4)
        return b

    def _open_file(self):
        path = filedialog.askopenfilename(
            title="Abrir Excel / CSV",
            filetypes=[("Excel / CSV", "*.xlsx *.xls *.csv"), ("All files", "*.*")])
        if not path:
            return
        try:
            if path.lower().endswith(".csv"):
                self._users = read_csv(path)
            else:
                self._users = read_excel(path)
        except Exception as e:
            messagebox.showerror("Error", f"No se pudo leer el archivo:\n{e}")
            return

        self.file_label.configure(text=f"{Path(path).name} — {len(self._users)} usuarios")
        self._update_preview()

    def _load_existing(self):
        path = filedialog.askopenfilename(
            title="Cargar JSON existente (export del servidor)",
            filetypes=[("JSON / TXT", "*.json *.txt"), ("All files", "*.*")])
        if not path:
            return
        try:
            with open(path) as f:
                self._existing = json.load(f)
            n = len(self._existing.get("users", []))
            self.existing_label.configure(text=f"✓ {Path(path).name} ({n} usuarios)")
        except Exception as e:
            messagebox.showerror("Error", f"No se pudo leer:\n{e}")

    def _update_preview(self):
        if HAS_CTK:
            self.preview.delete("1.0", "end")
        else:
            self.preview.delete("1.0", tk.END)
        if not self._users:
            return
        lines = [f"{'#':>3}  {'Display Name':<20} {'Username':<15} {'Role':<8} {'First':<12} {'Last':<12} {'Email':<25} {'Phone'}"]
        lines.append("-" * 110)
        for i, u in enumerate(self._users[:50], 1):
            lines.append(
                f"{i:>3}  {u.get('display_name',''):<20} {u.get('username',''):<15} "
                f"{u.get('role','user'):<8} {u.get('first_name',''):<12} "
                f"{u.get('last_name',''):<12} {u.get('email',''):<25} {u.get('phone','')}"
            )
        if len(self._users) > 50:
            lines.append(f"\n... y {len(self._users) - 50} más")
        text = "\n".join(lines)
        if HAS_CTK:
            self.preview.insert("1.0", text)
        else:
            self.preview.insert(tk.END, text)

    def _export(self):
        if not self._users:
            messagebox.showwarning("Export", "Primero abre un archivo Excel / CSV")
            return

        mode = self.mode_var.get()
        if mode == "append" and not self._existing:
            messagebox.showwarning("Export",
                "Para modo Append, carga primero el JSON existente del servidor\n"
                "(Admin → Settings → Export)")
            return

        result = users_to_import_json(self._users, mode=mode, existing=self._existing)

        path = filedialog.asksaveasfilename(
            title="Guardar JSON",
            defaultextension=".txt",
            initialfile=f"winus-import-{len(self._users)}users.txt",
            filetypes=[("JSON / TXT", "*.json *.txt")])
        if not path:
            return

        with open(path, "w") as f:
            json.dump(result, f, indent=2, ensure_ascii=False)

        self.status_label.configure(
            text=f"✓ {len(self._users)} usuarios → {Path(path).name}")

    def run(self):
        self.root.mainloop()


def main():
    if not HAS_OPENPYXL:
        print("⚠ openpyxl not installed. Excel (.xlsx) support disabled.")
        print("  Install with: pip install openpyxl")
        print("  CSV files will still work.\n")
    App().run()


if __name__ == "__main__":
    main()
