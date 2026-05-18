#!/usr/bin/env python3
"""macOS menu bar activity tracker — osascript dialogs, resettable timer."""
import atexit
import os
import sqlite3
import subprocess
import sys
import threading
from datetime import datetime, timedelta
from pathlib import Path

import rumps

sys.path.insert(0, str(Path(__file__).parent))
from db import init_db, save_activity_for_slot, get_slot_record, DB_PATH, get_focus_topics_by_category
from config import get_categories, get_interval

DIR      = Path(__file__).parent
APP_PATH = Path.home() / "Applications" / "ActivityTracker.app"
PLIST    = Path.home() / "Library/LaunchAgents/com.activitytracker.tracker.plist"
PID_FILE = Path.home() / ".activity_tracker" / "tracker.pid"


def _ensure_singleton():
    """Exit immediately if another tracker instance is already running."""
    if PID_FILE.exists():
        try:
            old_pid = int(PID_FILE.read_text().strip())
            os.kill(old_pid, 0)   # signal 0 = existence check
            # Process is alive → we are the duplicate, exit silently
            sys.exit(0)
        except ProcessLookupError:
            pass   # stale PID file, continue
        except (ValueError, OSError):
            pass
    PID_FILE.parent.mkdir(exist_ok=True)
    PID_FILE.write_text(str(os.getpid()))
    atexit.register(lambda: PID_FILE.unlink(missing_ok=True))


# ── LaunchAgent ───────────────────────────────────────────────────────────────

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


# ── osascript dialog ──────────────────────────────────────────────────────────

def _as(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def _recent_notes(cat_names: list) -> list:
    try:
        cutoff = (datetime.now() - timedelta(days=5)).isoformat()
        ph = ",".join("?" * len(cat_names))
        with sqlite3.connect(DB_PATH) as conn:
            rows = conn.execute(
                f"SELECT note, COUNT(*) c FROM activities "
                f"WHERE timestamp > ? AND category IN ({ph}) AND note NOT IN ({ph}) "
                f"GROUP BY note ORDER BY c DESC LIMIT 7",
                (cutoff, *cat_names, *cat_names),
            ).fetchall()
        return [r[0] for r in rows]
    except Exception:
        return []


def ask_via_osascript(prompt: str, existing: dict | None = None) -> dict | None:
    cats   = get_categories()
    names  = [c["name"] for c in cats]
    if not names:
        return None

    recent  = _recent_notes(names)
    def_cat = existing["category"] if existing else names[0]
    banner  = (f"\\n本时段已有：{_as(existing['category'])} · {_as(existing['note'])}（将覆盖）"
               if existing else "")

    # step 1 — choose category (activate first so dialog steals focus)
    cats_as = "{" + ",".join(f'"{_as(n)}"' for n in names) + "}"
    r1 = subprocess.run(["osascript", "-e", f"""
tell application "System Events" to activate
set catList to {cats_as}
set chosen to choose from list catList ¬
    with title "⏱ 活动记录" ¬
    with prompt "{_as(prompt)}{banner}" ¬
    default items {{"{_as(def_cat)}"}}
if chosen is false then return "SKIP"
return item 1 of chosen
"""], capture_output=True, text=True)
    category = r1.stdout.strip()
    if r1.returncode != 0 or category in ("", "SKIP"):
        return None

    # step 2 — 按分类下定义的关注主题（带优先级标记）+ 自定义输入
    PRIO_PREFIX = {"高": "★ ", "中": "", "低": "▽ "}
    cat_topics = get_focus_topics_by_category(category)  # sorted: prio then freq

    display_to_name: dict[str, str] = {}
    note_items: list[str] = []
    for t in cat_topics:
        prefix  = PRIO_PREFIX.get(t["priority"], "")
        display = f"{prefix}{t['name']}"
        display_to_name[display] = t["name"]
        note_items.append(display)

    # 如果该分类下没有定义主题，回落到最近的历史 note
    if not note_items:
        for n in _recent_notes([category]):
            display_to_name[n] = n
            note_items.append(n)

    CUSTOM = "✏  自定义输入…"
    note_items.append(CUSTOM)

    # 默认选中：优先匹配已有记录的主题
    if existing and existing["note"]:
        existing_note = existing["note"]
        def_display = next(
            (d for d, n in display_to_name.items() if n == existing_note),
            existing_note,
        )
    else:
        def_display = note_items[0]

    notes_as = "{" + ",".join(f'"{_as(n)}"' for n in note_items) + "}"

    r2 = subprocess.run(["osascript", "-e", f"""
set noteList to {notes_as}
set chosen to choose from list noteList ¬
    with title "⏱ {_as(category)}" ¬
    with prompt "在做什么？（★高优先  ▽低优先  无标=中优先）" ¬
    default items {{"{_as(def_display)}"}}
if chosen is false then return "SKIP"
set theNote to item 1 of chosen
if theNote is "✏  自定义输入…" then
    set r to display dialog "输入活动内容：" ¬
        with title "⏱ {_as(category)}" ¬
        default answer "" ¬
        buttons {{"跳过", "确认"}} default button "确认"
    if button returned of r is "跳过" then return "SKIP"
    set theNote to text returned of r
    if theNote is "" then set theNote to "{_as(category)}"
end if
return theNote
"""], capture_output=True, text=True)

    note_display = r2.stdout.strip()
    if r2.returncode != 0 or note_display in ("", "SKIP"):
        return None

    # 还原真实主题名（去掉优先级前缀）
    note = display_to_name.get(note_display, note_display)

    return {"category": category, "note": note}


# ── resettable timer ──────────────────────────────────────────────────────────

class ResettableTimer:
    def __init__(self, callback):
        self._callback = callback
        self._next     = datetime.now() + timedelta(seconds=get_interval() * 60)
        self._wake     = threading.Event()
        threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self):
        while True:
            remaining = (self._next - datetime.now()).total_seconds()
            if remaining <= 0:
                self._next = datetime.now() + timedelta(seconds=get_interval() * 60)
                try:
                    self._callback()
                except Exception:
                    pass
            else:
                self._wake.wait(timeout=min(remaining, 10))
                self._wake.clear()

    def reset_from_now(self):
        self._next = datetime.now() + timedelta(seconds=get_interval() * 60)
        self._wake.set()


# ── rumps app ─────────────────────────────────────────────────────────────────

class ActivityTracker(rumps.App):
    def __init__(self):
        super().__init__("⏱", quit_button=None)
        self._lock  = threading.Lock()
        self._timer = ResettableTimer(self._on_timer)
        self.menu   = [
            rumps.MenuItem("记录当前活动 …", callback=self._manual_prompt),
            rumps.MenuItem("查看 Dashboard", callback=self.open_dashboard),
            None,
            rumps.MenuItem("退出",           callback=self.quit_app),
        ]

    def _on_timer(self):
        from config import get_auto_popup
        if get_auto_popup():
            self.prompt_activity(None, force=False)

    def _manual_prompt(self, _):
        self.prompt_activity(None, force=True)

    def prompt_activity(self, _, force=True):
        if not self._lock.acquire(blocking=False):
            return
        try:
            now        = datetime.now()
            slot_start = now.replace(minute=(now.minute // 15) * 15,
                                     second=0, microsecond=0)
            existing   = get_slot_record(slot_start)

            # Auto-trigger: current slot already recorded — silently skip
            if not force and existing:
                self._timer.reset_from_now()
                return

            existing_d = {"category": existing[1], "note": existing[2]} if existing else None

            data = ask_via_osascript(
                f"现在 {now.strftime('%H:%M')}，你在做什么？", existing_d
            )
            if data:
                save_activity_for_slot(data["category"], data["note"], slot_start)
                self._timer.reset_from_now()
                try:
                    rumps.notification(
                        title=f"✓ {data['category']}", subtitle="",
                        message=data["note"], sound=False,
                    )
                except Exception:
                    pass
        finally:
            self._lock.release()

    def open_dashboard(self, _):
        app = APP_PATH if APP_PATH.exists() else Path("/Applications/ActivityTracker.app")
        subprocess.Popen(["open", str(app)])

    def quit_app(self, _):
        rumps.quit_application()


if __name__ == "__main__":
    _ensure_singleton()
    init_db()
    ensure_launch_agent()
    ActivityTracker().run()
