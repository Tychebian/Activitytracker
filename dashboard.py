#!/usr/bin/env python3
"""Flask API server for the activity dashboard."""
import sqlite3
import sys
from pathlib import Path

from flask import Flask, jsonify, render_template, request

sys.path.insert(0, str(Path(__file__).parent))
from datetime import datetime
from db import DB_PATH, init_db, get_focus_topics_with_stats
import config as cfg

PORT = 5001
app = Flask(__name__, template_folder=str(Path(__file__).parent / "templates"))


@app.before_request
def _ensure_db():
    init_db()


def _q(sql, params=()):
    with sqlite3.connect(DB_PATH) as conn:
        conn.row_factory = sqlite3.Row
        return [dict(r) for r in conn.execute(sql, params).fetchall()]


# ── meta ──────────────────────────────────────────────────────────────────────

@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/meta")
def api_meta():
    cats = cfg.get_categories()
    return jsonify({
        "categories": [c["name"] for c in cats],
        "colors":     {c["name"]: c["color"] for c in cats},
    })


# ── category CRUD ─────────────────────────────────────────────────────────────

@app.route("/api/categories", methods=["GET"])
def api_cat_list():
    return jsonify(cfg.get_categories())


@app.route("/api/categories/add", methods=["POST"])
def api_cat_add():
    data = request.get_json(force=True)
    name  = (data.get("name") or "").strip()
    color = (data.get("color") or "").strip()
    if not name:
        return jsonify({"error": "name required"}), 400
    try:
        entry = cfg.add_category(name, color)
        return jsonify(entry)
    except ValueError as e:
        return jsonify({"error": str(e)}), 409


@app.route("/api/categories/update", methods=["POST"])
def api_cat_update():
    data      = request.get_json(force=True)
    old_name  = (data.get("old_name") or "").strip()
    new_name  = (data.get("new_name") or "").strip()
    new_color = (data.get("color") or "").strip()
    if not old_name:
        return jsonify({"error": "old_name required"}), 400
    # rename in DB if needed
    if new_name and new_name != old_name:
        with sqlite3.connect(DB_PATH) as conn:
            conn.execute("UPDATE activities SET category=? WHERE category=?",
                         (new_name, old_name))
    try:
        resolved = cfg.update_category(old_name, new_name, new_color)
        return jsonify({"ok": True, "name": resolved})
    except KeyError as e:
        return jsonify({"error": str(e)}), 404


@app.route("/api/categories/delete", methods=["POST"])
def api_cat_delete():
    name = (request.get_json(force=True).get("name") or "").strip()
    if not name:
        return jsonify({"error": "name required"}), 400
    try:
        cfg.delete_category(name)
        # leave existing activities untouched — category name preserved as-is
        return jsonify({"ok": True})
    except ValueError as e:
        return jsonify({"error": str(e)}), 400


# ── activities ────────────────────────────────────────────────────────────────

@app.route("/api/activities")
def api_activities():
    start = request.args.get("start", "")
    end   = request.args.get("end", "")
    if not start or not end:
        return jsonify({"error": "start and end required"}), 400
    rows = _q(
        "SELECT id,timestamp,category,note FROM activities "
        "WHERE timestamp>=? AND timestamp<? ORDER BY timestamp ASC",
        (start, end),
    )
    return jsonify(rows)


@app.route("/api/category_stats")
def api_cat_stats():
    start = request.args.get("start", "")
    end   = request.args.get("end", "")
    if not start or not end:
        return jsonify({"error": "start and end required"}), 400
    # Base: all known categories at zero
    result = {c["name"]: 0 for c in cfg.get_categories()}
    for r in _q(
        "SELECT category,COUNT(*) cnt FROM activities "
        "WHERE timestamp>=? AND timestamp<? GROUP BY category",
        (start, end),
    ):
        result[r["category"]] = r["cnt"]  # unknown (deleted) cats appear as extras
    return jsonify(result)


@app.route("/api/month_stats")
def api_month_stats():
    month = request.args.get("month", "")
    if not month:
        return jsonify({"error": "month required"}), 400
    year, m = map(int, month.split("-"))
    start = f"{month}-01"
    end   = f"{year+1}-01-01" if m == 12 else f"{year}-{m+1:02d}-01"
    rows = _q(
        "SELECT DATE(timestamp) day,COUNT(*) cnt FROM activities "
        "WHERE timestamp>=? AND timestamp<? GROUP BY day",
        (start, end),
    )
    return jsonify({r["day"]: r["cnt"] for r in rows})


@app.route("/api/top_notes")
def api_top_notes():
    start = request.args.get("start", "")
    end   = request.args.get("end", "")
    limit = int(request.args.get("limit", 8))
    if not start or not end:
        return jsonify({"error": "start and end required"}), 400
    cat_names = {c["name"] for c in cfg.get_categories()}
    rows = _q(
        "SELECT note, category, COUNT(*) cnt FROM activities "
        "WHERE timestamp>=? AND timestamp<? GROUP BY note ORDER BY cnt DESC LIMIT ?",
        (start, end, limit * 2),   # fetch extra so we can filter
    )
    # exclude bare category names (auto-fill defaults)
    filtered = [r for r in rows if r["note"] not in cat_names][:limit]
    return jsonify(filtered)


@app.route("/api/focus_topics", methods=["GET"])
def api_focus_topics_list():
    return jsonify(get_focus_topics_with_stats())


@app.route("/api/focus_topics", methods=["POST"])
def api_focus_topic_add():
    name = (request.get_json(force=True).get("name") or "").strip()
    if not name:
        return jsonify({"error": "name required"}), 400
    try:
        with sqlite3.connect(DB_PATH) as conn:
            conn.execute(
                "INSERT INTO focus_topics (name, created_at) VALUES (?, ?)",
                (name, datetime.now().isoformat(timespec="seconds")),
            )
        return jsonify({"ok": True})
    except sqlite3.IntegrityError:
        return jsonify({"error": "already exists"}), 409


@app.route("/api/focus_topics/<int:tid>", methods=["PUT"])
def api_focus_topic_update(tid):
    name = (request.get_json(force=True).get("name") or "").strip()
    if not name:
        return jsonify({"error": "name required"}), 400
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute("UPDATE focus_topics SET name=? WHERE id=?", (name, tid))
    return jsonify({"ok": True})


@app.route("/api/focus_topics/<int:tid>", methods=["DELETE"])
def api_focus_topic_delete(tid):
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute("DELETE FROM focus_topics WHERE id=?", (tid,))
    return jsonify({"ok": True})


@app.route("/api/activities/add_manual", methods=["POST"])
def api_add_manual():
    """Add a record for any arbitrary past 15-min slot."""
    from datetime import datetime as dt
    data     = request.get_json(force=True)
    date_str = (data.get("date") or "").strip()      # YYYY-MM-DD
    time_str = (data.get("time") or "").strip()      # HH:MM
    category = (data.get("category") or "").strip()
    note     = (data.get("note") or "").strip()
    if not date_str or not time_str or not category:
        return jsonify({"error": "date, time, and category required"}), 400
    try:
        hour, minute = map(int, time_str.split(":"))
        slot_min = (minute // 15) * 15
        slot_start = dt.strptime(date_str, "%Y-%m-%d").replace(
            hour=hour, minute=slot_min, second=0, microsecond=0
        )
    except (ValueError, AttributeError) as e:
        return jsonify({"error": f"invalid date/time: {e}"}), 400

    from db import save_activity_for_slot
    save_activity_for_slot(category, note or category, slot_start, ts=slot_start)
    return jsonify({"ok": True})


@app.route("/api/activities/<int:aid>", methods=["PUT"])
def api_act_update(aid):
    data     = request.get_json(force=True)
    category = (data.get("category") or "").strip()
    note     = (data.get("note") or "").strip()
    if not category:
        return jsonify({"error": "category required"}), 400
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute("UPDATE activities SET category=?,note=? WHERE id=?",
                     (category, note, aid))
    return jsonify({"ok": True})


@app.route("/api/activities/<int:aid>", methods=["DELETE"])
def api_act_delete(aid):
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute("DELETE FROM activities WHERE id=?", (aid,))
    return jsonify({"ok": True})


if __name__ == "__main__":
    init_db()
    app.run(host="127.0.0.1", port=PORT, debug=False)
