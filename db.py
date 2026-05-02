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
    category: str, note: str, slot_start: datetime, ts: datetime | None = None
):
    """Upsert: delete any prior record in the same 15-min slot, then insert.

    ts overrides the stored timestamp (used for backdated manual adds).
    Defaults to datetime.now() for live timer recordings.
    """
    s, e = _slot_bounds(slot_start)
    stored_ts = (ts or datetime.now()).isoformat(timespec="seconds")
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute("DELETE FROM activities WHERE timestamp >= ? AND timestamp < ?", (s, e))
        conn.execute(
            "INSERT INTO activities (timestamp, category, note) VALUES (?, ?, ?)",
            (stored_ts, category, note),
        )


# kept for dashboard edit/delete which don't use slot logic
def save_activity(category: str, note: str):
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute(
            "INSERT INTO activities (timestamp, category, note) VALUES (?, ?, ?)",
            (datetime.now().isoformat(timespec="seconds"), category, note),
        )
