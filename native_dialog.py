"""
Native macOS recording dialog via NSAlert + accessory view.
Runs entirely in the main AppKit thread — no subprocess, no focus issues.
NSAlert.runModal() is a system-level modal call that always gets keyboard
focus on the very first interaction.
"""
import sqlite3
import threading
from datetime import datetime, timedelta

import objc
from AppKit import (
    NSAlert, NSComboBox, NSPopUpButton, NSView,
    NSAlertFirstButtonReturn, NSApp, NSMakeRect,
)
from Foundation import NSObject


# ── dispatch helper ─────────────────────────────────��──────────────────────────

class _Invoker(NSObject):
    """Run a Python callable on the AppKit main thread and return its value."""
    _func   = None
    _result = None

    def call_(self, _):
        self._result = self._func()

    @classmethod
    def on_main(cls, func):
        if threading.current_thread() is threading.main_thread():
            return func()
        inv = cls.alloc().init()
        inv._func = func
        inv.performSelectorOnMainThread_withObject_waitUntilDone_(
            "call:", None, True
        )
        return inv._result


# ── recent-notes helper ────────────────────────────────────────────────────────

def _recent_notes(cat_names: list) -> list:
    from db import DB_PATH
    if not cat_names:
        return []
    try:
        cutoff = (datetime.now() - timedelta(days=5)).isoformat()
        ph = ",".join("?" * len(cat_names))
        with sqlite3.connect(DB_PATH) as conn:
            rows = conn.execute(
                f"SELECT note, COUNT(*) c FROM activities "
                f"WHERE timestamp > ? AND category IN ({ph}) AND note NOT IN ({ph}) "
                f"GROUP BY note ORDER BY c DESC LIMIT 10",
                (cutoff, *cat_names, *cat_names),
            ).fetchall()
        return [r[0] for r in rows]
    except Exception:
        return []


# ── main dialog ─────────────────────────────────��──────────────────────────────

def ask(message: str, cats: list, existing: dict | None = None) -> dict | None:
    """
    Show a single-panel recording dialog.
    Dispatches to the main thread if needed.
    Returns {"category": ..., "note": ...} or None (skipped / closed).
    """
    def _show():
        cat_names = [c["name"] for c in cats]
        recent    = _recent_notes(cat_names)

        W = 340
        view = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, W, 62))

        # ── category dropdown ─────────��────────────────────────────────────
        popup = NSPopUpButton.alloc().initWithFrame_(NSMakeRect(0, 34, W, 26))
        popup.addItemsWithTitles_(cat_names)
        if existing and existing.get("category") in cat_names:
            popup.selectItemAtIndex_(cat_names.index(existing["category"]))
        view.addSubview_(popup)

        # ── note combobox ───────────────��──────────────────────────���───────
        combo = NSComboBox.alloc().initWithFrame_(NSMakeRect(0, 2, W, 26))
        for note in recent:
            combo.addItemWithObjectValue_(note)
        combo.setPlaceholderString_("在做什么？（可选高频内容或直接输入）")
        if existing:
            note_val = existing.get("note", "")
            if note_val and note_val not in cat_names:
                combo.setStringValue_(note_val)
        view.addSubview_(combo)

        # ── alert ───────────────────────────────���──────────────────────────
        alert = NSAlert.alloc().init()
        alert.setMessageText_(message)
        alert.addButtonWithTitle_("记录")
        alert.addButtonWithTitle_("跳过")
        alert.setAccessoryView_(view)
        alert.window().makeFirstResponder_(combo)

        # Activate immediately — we are on the main thread, so this is
        # synchronous and takes effect before runModal() starts.
        NSApp.activateIgnoringOtherApps_(True)

        response = alert.runModal()

        if response == NSAlertFirstButtonReturn:
            cat  = str(popup.titleOfSelectedItem() or cat_names[0])
            note = str(combo.stringValue() or "").strip()
            return {"category": cat, "note": note or cat}
        return None

    return _Invoker.on_main(_show)
