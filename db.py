#!/usr/bin/env python3
"""Shared database helpers."""
import sqlite3
from datetime import datetime, timedelta
from pathlib import Path

APP_DIR = Path.home() / ".activity_tracker"
DB_PATH = APP_DIR / "activities.db"


def init_db():
    APP_DIR.mkdir(exist_ok=True)
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS activities (
                id        INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT NOT NULL,
                category  TEXT NOT NULL DEFAULT '工作',
                note      TEXT NOT NULL DEFAULT ''
            )
        """)
        cols = {row[1] for row in conn.execute("PRAGMA table_info(activities)")}
        if "category" not in cols:
            conn.execute(
                "ALTER TABLE activities ADD COLUMN category TEXT NOT NULL DEFAULT '工作'"
            )
        if "end_time" not in cols:
            conn.execute("ALTER TABLE activities ADD COLUMN end_time TEXT")
        if "detail" not in cols:
            conn.execute("ALTER TABLE activities ADD COLUMN detail TEXT")
        conn.execute("""
            CREATE TABLE IF NOT EXISTS focus_topics (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                name       TEXT UNIQUE NOT NULL,
                created_at TEXT NOT NULL
            )
        """)
        cols_ft = {row[1] for row in conn.execute("PRAGMA table_info(focus_topics)")}
        if "category" not in cols_ft:
            conn.execute("ALTER TABLE focus_topics ADD COLUMN category TEXT NOT NULL DEFAULT ''")
        if "priority" not in cols_ft:
            conn.execute("ALTER TABLE focus_topics ADD COLUMN priority TEXT NOT NULL DEFAULT '中'")


def _slot_bounds(slot_start: datetime):
    return (
        slot_start.isoformat(timespec="seconds"),
        (slot_start + timedelta(minutes=15)).isoformat(timespec="seconds"),
    )


def get_slot_record(slot_start: datetime):
    """Return (id, category, note) of any existing record in the 15-min slot, else None."""
    s, e = _slot_bounds(slot_start)
    with sqlite3.connect(DB_PATH) as conn:
        return conn.execute(
            "SELECT id, category, note FROM activities "
            "WHERE timestamp >= ? AND timestamp < ? ORDER BY timestamp DESC LIMIT 1",
            (s, e),
        ).fetchone()


def save_activity_for_slot(
    category: str, note: str, slot_start: datetime,
    ts: datetime | None = None, end_time: str | None = None,
):
    """Upsert: delete any prior record in the same 15-min slot, then insert."""
    s, e = _slot_bounds(slot_start)
    stored_ts = (ts or datetime.now()).isoformat(timespec="seconds")
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute("DELETE FROM activities WHERE timestamp >= ? AND timestamp < ?", (s, e))
        conn.execute(
            "INSERT INTO activities (timestamp, category, note, end_time) VALUES (?, ?, ?, ?)",
            (stored_ts, category, note, end_time),
        )


def get_focus_topics_with_stats():
    """All focus topics with duration stats, sorted by total minutes desc."""
    from config import get_interval
    iv = get_interval()
    week_ago = (datetime.now() - timedelta(days=7)).isoformat(timespec="seconds")
    with sqlite3.connect(DB_PATH) as conn:
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            SELECT ft.id, ft.name, ft.category, ft.priority,
                   COUNT(a.id) AS total_cnt,
                   COALESCE(SUM(
                     CASE WHEN a.end_time IS NOT NULL
                       THEN CAST((julianday(a.end_time) - julianday(a.timestamp)) * 1440 AS INTEGER)
                       ELSE ?
                     END
                   ), 0) AS total_mins,
                   SUM(CASE WHEN a.timestamp >= ? THEN 1 ELSE 0 END) AS cnt_7d
            FROM focus_topics ft
            LEFT JOIN activities a ON a.note = ft.name
            GROUP BY ft.id
            ORDER BY total_mins DESC
            """,
            (iv, week_ago),
        ).fetchall()
    return [dict(r) for r in rows]


def get_focus_topics_by_category(category: str) -> list:
    """Return focus topics for a category sorted by priority then recent activity count."""
    cutoff = (datetime.now() - timedelta(days=30)).isoformat(timespec="seconds")
    prio_order = {"高": 0, "中": 1, "低": 2}
    with sqlite3.connect(DB_PATH) as conn:
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            SELECT ft.name, ft.priority,
                   COUNT(a.id) AS cnt
            FROM focus_topics ft
            LEFT JOIN activities a ON a.note = ft.name AND a.timestamp > ?
            WHERE ft.category = ?
            GROUP BY ft.id
            """,
            (cutoff, category),
        ).fetchall()
    result = [dict(r) for r in rows]
    result.sort(key=lambda r: (prio_order.get(r["priority"], 1), -r["cnt"]))
    return result


def migrate_topic_category(topic_id: int, new_category: str) -> int:
    """Move a focus topic to a new category and migrate all matching activity records."""
    with sqlite3.connect(DB_PATH) as conn:
        row = conn.execute("SELECT name FROM focus_topics WHERE id=?", (topic_id,)).fetchone()
        if not row:
            raise KeyError(f"topic {topic_id} not found")
        topic_name = row[0]
        cur = conn.execute(
            "UPDATE activities SET category=? WHERE note=?",
            (new_category, topic_name),
        )
        migrated = cur.rowcount
        conn.execute(
            "UPDATE focus_topics SET category=? WHERE id=?",
            (new_category, topic_id),
        )
    return migrated


# kept for dashboard edit/delete which don't use slot logic
def save_activity(category: str, note: str):
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute(
            "INSERT INTO activities (timestamp, category, note) VALUES (?, ?, ?)",
            (datetime.now().isoformat(timespec="seconds"), category, note),
        )
