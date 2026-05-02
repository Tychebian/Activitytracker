#!/usr/bin/env python3
"""
macOS menu bar activity tracker.

• Single-panel dialog (tkinter): category buttons + note combobox in one window.
• NSApp.activateIgnoringOtherApps_ fixes focus from background processes.
• Timer resets from submission time (not the slot boundary).
• Global hotkey ⌃⌥A triggers the dialog immediately.
"""
import json
import subprocess
import sys
import threading
from datetime import datetime, timedelta
from pathlib import Path

import rumps

sys.path.insert(0, str(Path(__file__).parent))
from db import init_db, save_activity_for_slot, get_slot_record

DIR      = Path(__file__).parent
INTERVAL = 15 * 60          # seconds between auto-popups
HOTKEY   = "⌃⌥A"           # displayed in the menu item label
PYNPUT_COMBO = "<ctrl>+<alt>+a"   # pynput GlobalHotKeys format

APP_PATH = Path.home() / "Applications" / "ActivityTracker.app"
PLIST    = Path.home() / "Library/LaunchAgents/com.activitytracker.tracker.plist"


# ── LaunchAgent auto-install ───────────────────────────────────────────────────

def ensure_launch_agent():
    if PLIST.exists():
        return
    PLIST.parent.mkdir(parents=True, exist_ok=True)
    PLIST.write_text(f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.activitytracker.tracker</string>
  <key>ProgramArguments</key>
  <array>
    <string>{sys.executable}</string>
    <string>{Path(__file__).resolve()}</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key>
  <string>{Path.home()}/.activity_tracker/error.log</string>
</dict></plist>
""")
    subprocess.run(["launchctl", "load", str(PLIST)], capture_output=True)


# ── single-panel dialog via dialog_helper.py subprocess ───────────────────────

def _ask_dialog(message: str, existing: dict | None = None) -> dict | None:
    helper = DIR / "dialog_helper.py"
    args   = [sys.executable, str(helper), message]
    if existing:
        args.append(json.dumps(existing, ensure_ascii=False))
    r = subprocess.run(args, capture_output=True, text=True)
    text = r.stdout.strip()
    if not text:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None


# ── resettable timer ───────────────────────────────────────────────────────────

class ResettableTimer:
    """Fires a callback every `interval` seconds, but the countdown resets
    after each fire (or explicit reset), measuring from the actual submission
    time rather than the theoretical slot boundary."""

    def __init__(self, interval: int, callback):
        self._interval = interval
        self._callback = callback
        self._next     = datetime.now() + timedelta(seconds=interval)
        self._wake     = threading.Event()
        self._thread   = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def _loop(self):
        while True:
            remaining = (self._next - datetime.now()).total_seconds()
            if remaining <= 0:
                # Set tentative next-fire BEFORE calling callback so that
                # if the user skips, the schedule is still maintained.
                self._next = datetime.now() + timedelta(seconds=self._interval)
                try:
                    self._callback()
                except Exception:
                    pass
            else:
                self._wake.wait(timeout=min(remaining, 10))
                self._wake.clear()

    def reset_from_now(self):
        """Call after a successful submission to restart the 15-min countdown."""
        self._next = datetime.now() + timedelta(seconds=self._interval)
        self._wake.set()   # interrupt the sleep immediately

    @property
    def next_fire(self) -> datetime:
        return self._next


# ── rumps app ──────────────────────────────────────────────────────────────────

class ActivityTracker(rumps.App):
    def __init__(self):
        super().__init__("⏱", quit_button=None)

        self._dialog_lock = threading.Lock()
        self._timer = ResettableTimer(INTERVAL, self._timer_fired)

        self.menu = [
            rumps.MenuItem(
                f"记录当前活动  [{HOTKEY}]",
                callback=self.prompt_activity,
            ),
            rumps.MenuItem("查看 Dashboard", callback=self.open_dashboard),
            None,
            rumps.MenuItem("退出", callback=self.quit_app),
        ]

        self._setup_hotkey()

    # ── hotkey ─────────────────────────────────────────────────────────────────

    def _setup_hotkey(self):
        try:
            from pynput import keyboard

            def on_activate():
                # run in its own thread to avoid blocking the pynput listener
                threading.Thread(
                    target=self.prompt_activity, args=(None,), daemon=True
                ).start()

            listener = keyboard.GlobalHotKeys({PYNPUT_COMBO: on_activate})
            listener.daemon = True
            listener.start()
        except Exception:
            # pynput unavailable or Input Monitoring permission not granted
            pass

    # ── timer callback ─────────────────────────────────────────────────────────

    def _timer_fired(self):
        self.prompt_activity(None)

    # ── core recording ─────────────────────────────────────────────────────────

    def prompt_activity(self, _):
        # Prevent two concurrent dialogs (hotkey + timer firing simultaneously)
        if not self._dialog_lock.acquire(blocking=False):
            return
        try:
            now        = datetime.now()
            slot_min   = (now.minute // 15) * 15
            slot_start = now.replace(minute=slot_min, second=0, microsecond=0)
            existing   = get_slot_record(slot_start)
            existing_d = {"category": existing[1], "note": existing[2]} if existing else None

            data = _ask_dialog(
                f"现在 {now.strftime('%H:%M')}，你在做什么？", existing_d
            )

            if data:
                save_activity_for_slot(data["category"], data["note"], slot_start)
                # ← key change: reset the 15-min countdown from THIS moment
                self._timer.reset_from_now()
                try:
                    rumps.notification(
                        title=f"✓ {data['category']}",
                        subtitle="",
                        message=data["note"],
                        sound=False,
                    )
                except Exception:
                    pass
        finally:
            self._dialog_lock.release()

    # ── menu actions ───────────────────────────────────────────────────────────

    def open_dashboard(self, _):
        app = APP_PATH if APP_PATH.exists() else Path("/Applications/ActivityTracker.app")
        subprocess.Popen(["open", str(app)])

    def quit_app(self, _):
        rumps.quit_application()


if __name__ == "__main__":
    init_db()
    ensure_launch_agent()
    ActivityTracker().run()
