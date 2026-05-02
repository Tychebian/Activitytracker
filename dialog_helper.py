#!/usr/bin/env python3
"""
Single-panel recording dialog.
Category buttons + note combobox in one window.

Focus fix: call NSApp.activateIgnoringOtherApps_ BEFORE mainloop() so the
very first click hits the button, not just the window activation.

Suggestion fix: only show notes from currently configured categories so that
deleted categories' notes don't keep reappearing.
"""
import json
import sqlite3
import sys
from datetime import datetime, timedelta
from pathlib import Path
import tkinter as tk
from tkinter import ttk

sys.path.insert(0, str(Path(__file__).parent))
from config import get_categories
from db import DB_PATH

# ── Slayers parchment theme ──────────────────────────────────────────────────
BG      = "#f8f0df"
BG2     = "#f0e4c8"
BG3     = "#e8d8b4"
BORDER  = "#c8a870"
INK     = "#2c1400"
INK2    = "#7a4810"
INK3    = "#b08050"
ACCENT  = "#c8320a"


def _blend(hex_color: str, mix: float = 0.12) -> str:
    bg = (248, 240, 223)
    r = int(int(hex_color[1:3], 16) * mix + bg[0] * (1 - mix))
    g = int(int(hex_color[3:5], 16) * mix + bg[1] * (1 - mix))
    b = int(int(hex_color[5:7], 16) * mix + bg[2] * (1 - mix))
    return f"#{r:02x}{g:02x}{b:02x}"


def _recent_notes(cat_names: list) -> list:
    """
    Top notes from the past 5 days.
    Only includes notes whose category is still in the current config
    (prevents deleted-category notes from reappearing).
    Excludes bare category names.
    """
    if not cat_names:
        return []
    try:
        cutoff = (datetime.now() - timedelta(days=5)).isoformat()
        ph = ",".join("?" * len(cat_names))
        with sqlite3.connect(DB_PATH) as conn:
            rows = conn.execute(
                f"SELECT note, COUNT(*) c FROM activities "
                f"WHERE timestamp > ? "
                f"  AND category IN ({ph}) "   # ← only live categories
                f"  AND note NOT IN ({ph}) "   # ← exclude bare category names
                f"GROUP BY note ORDER BY c DESC LIMIT 10",
                (cutoff, *cat_names, *cat_names),
            ).fetchall()
        return [r[0] for r in rows]
    except Exception:
        return []


def main():
    msg      = sys.argv[1] if len(sys.argv) > 1 else "你在做什么？"
    existing = json.loads(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else None

    cats   = get_categories()
    names  = [c["name"] for c in cats]
    colors = {c["name"]: c["color"] for c in cats}
    recent = _recent_notes(names)

    # ── window ────────────────────────────────────────────────────────────────
    root = tk.Tk()
    root.title("⏱ 活动记录")
    root.resizable(False, False)
    root.configure(bg=BG)

    # Activate immediately — NSApp is valid as soon as tk.Tk() runs.
    # Must happen BEFORE mainloop so the first click reaches the button,
    # not the OS window-activation handler.
    try:
        from AppKit import NSApp
        NSApp.activateIgnoringOtherApps_(True)
    except Exception:
        pass

    result   = []
    init_cat = (existing or {}).get("category", names[0] if names else "")
    cat_var  = tk.StringVar(value=init_cat)

    outer = tk.Frame(root, padx=20, pady=14, bg=BG)
    outer.pack(fill="both", expand=True)

    # ── existing-slot banner ─────────────────────────────────────────────────
    if existing:
        tk.Label(
            outer,
            text=f"本时段已有：{existing['category']} · {existing['note']}  （将覆盖）",
            font=("Helvetica", 10), bg=BG3, fg=INK2,
            padx=8, pady=4, wraplength=340, justify="left",
        ).pack(fill="x", pady=(0, 10))

    tk.Label(outer, text=msg, font=("Helvetica", 13, "bold"),
             bg=BG, fg=INK, anchor="w").pack(fill="x", pady=(0, 12))

    # ── category radio buttons ────────────────────────────────────────────────
    cat_frame = tk.Frame(outer, bg=BG)
    cat_frame.pack(fill="x", pady=(0, 12))
    btn_refs = {}

    def refresh(*_):
        sel = cat_var.get()
        for cat, btn in btn_refs.items():
            c = colors.get(cat, "#c8960a")
            if cat == sel:
                btn.config(fg=c, bg=_blend(c, .18), relief="solid", bd=1,
                           highlightbackground=c, highlightthickness=1)
            else:
                btn.config(fg=INK2, bg=BG, relief="solid", bd=1,
                           highlightbackground=BORDER, highlightthickness=1)

    for idx, cat in enumerate(names):
        row, col = divmod(idx, 3)
        color = colors.get(cat, "#c8960a")
        btn = tk.Radiobutton(
            cat_frame, text=cat, variable=cat_var, value=cat,
            font=("Helvetica", 12), bg=BG, fg=INK2,
            activebackground=_blend(color, .18), activeforeground=color,
            selectcolor=_blend(color, .18), indicatoron=False,
            relief="solid", bd=1, padx=10, pady=6, cursor="hand2",
        )
        btn.grid(row=row, column=col, sticky="ew", padx=4, pady=3)
        btn_refs[cat] = btn

    cat_var.trace_add("write", refresh)
    refresh()

    # ── note combobox ─────────────────────────────────────────────────────────
    tk.Label(outer, text="在做什么？", font=("Helvetica", 11),
             bg=BG, fg=INK3, anchor="w").pack(fill="x", pady=(2, 3))

    style = ttk.Style()
    style.theme_use("default")
    style.configure("S.TCombobox",
                    fieldbackground=BG2, background=BG2, foreground=INK,
                    arrowcolor=INK2, bordercolor=BORDER, insertcolor=INK,
                    selectbackground=ACCENT, selectforeground="#fff")

    note_var = tk.StringVar(value=(existing or {}).get("note", ""))
    combo = ttk.Combobox(outer, textvariable=note_var, values=recent,
                         font=("Helvetica", 13), style="S.TCombobox")
    combo.pack(fill="x", ipady=4)

    # ── action buttons ────────────────────────────────────────────────────────
    btn_row = tk.Frame(outer, bg=BG)
    btn_row.pack(fill="x", pady=(14, 0))

    def record():
        cat  = cat_var.get()
        note = note_var.get().strip()
        result.append(json.dumps({"category": cat, "note": note or cat},
                                 ensure_ascii=False))
        root.destroy()

    def skip():
        root.destroy()

    combo.bind("<Return>", lambda _: record())
    combo.bind("<Escape>", lambda _: skip())
    root.protocol("WM_DELETE_WINDOW", skip)

    tk.Button(btn_row, text="记录", command=record, width=7,
              bg=ACCENT, fg="#ffffff",
              activebackground="#a02008", activeforeground="#ffffff",
              relief="raised", bd=1, cursor="hand2",
              font=("Helvetica", 12, "bold")).pack(side="right")
    tk.Button(btn_row, text="跳过", command=skip, width=7,
              bg=BG2, fg=INK, activebackground=BG3, activeforeground=INK,
              relief="raised", bd=1, cursor="hand2",
              font=("Helvetica", 12)).pack(side="right", padx=(0, 8))

    # ── position and show ─────────────────────────────────────────────────────
    root.update_idletasks()
    w, h = root.winfo_reqwidth(), root.winfo_reqheight()
    sw, sh = root.winfo_screenwidth(), root.winfo_screenheight()
    root.geometry(f"{w}x{h}+{(sw - w)//2}+{max(0, (sh - h)//2 - 80)}")

    # Keep on top briefly so nothing can cover it before the user notices
    root.attributes("-topmost", True)
    root.after(800, lambda: root.attributes("-topmost", False))
    root.focus_force()

    root.mainloop()

    if result:
        sys.stdout.write(result[0])
        sys.stdout.flush()


if __name__ == "__main__":
    main()
