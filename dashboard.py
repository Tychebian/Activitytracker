#!/usr/bin/env python3
"""Flask API server for the activity dashboard."""
import sqlite3
import sys
from pathlib import Path

from flask import Flask, jsonify, render_template, request

sys.path.insert(0, str(Path(__file__).parent))
from datetime import datetime
from db import DB_PATH, init_db, get_focus_topics_with_stats, migrate_topic_category, get_focus_topics_by_category
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
    cats   = cfg.get_categories()
    topics = get_focus_topics_with_stats()
    return jsonify({
        "categories":       [c["name"] for c in cats],
        "colors":           {c["name"]: c["color"] for c in cats},
        "topic_priorities": {t["name"]: t["priority"] for t in topics},
        "version":          cfg.__version__,
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

@app.route("/api/config/auto_popup", methods=["GET", "POST"])
def api_auto_popup():
    if request.method == "POST":
        data = request.get_json(force=True)
        cfg.set_auto_popup(bool(data.get("enabled", True)))
        return jsonify({"ok": True})
    return jsonify({"enabled": cfg.get_auto_popup()})


@app.route("/api/config/interval", methods=["GET", "POST"])
def api_interval():
    if request.method == "GET":
        return jsonify({"interval": cfg.get_interval()})
    mins = int((request.get_json(force=True) or {}).get("interval", 20))
    try:
        cfg.set_interval(mins)
        return jsonify({"ok": True, "interval": mins})
    except ValueError as e:
        return jsonify({"error": str(e)}), 400


@app.route("/api/activities")
def api_activities():
    start = request.args.get("start", "")
    end   = request.args.get("end", "")
    if not start or not end:
        return jsonify({"error": "start and end required"}), 400
    rows = _q(
        "SELECT id,timestamp,end_time,category,note,detail FROM activities "
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
    iv = cfg.get_interval()
    result = {c["name"]: {"mins": 0, "cnt": 0} for c in cfg.get_categories()}
    for r in _q(
        """SELECT category, COUNT(*) AS cnt,
                  SUM(CASE WHEN end_time IS NOT NULL
                    THEN CAST((julianday(end_time) - julianday(timestamp)) * 1440 AS INTEGER)
                    ELSE ? END) AS total_mins
           FROM activities WHERE timestamp>=? AND timestamp<? GROUP BY category""",
        (iv, start, end),
    ):
        result[r["category"]] = {"mins": r["total_mins"] or 0, "cnt": r["cnt"]}
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
    data     = request.get_json(force=True)
    name     = (data.get("name") or "").strip()
    category = (data.get("category") or "").strip()
    priority = (data.get("priority") or "中").strip()
    if priority not in ("高", "中", "低"):
        priority = "中"
    if not name:
        return jsonify({"error": "name required"}), 400
    # 高优先级：同分类只能一个，新增时先降级旧的
    downgraded = []
    if priority == "高" and category:
        with sqlite3.connect(DB_PATH) as conn:
            rows = conn.execute(
                "SELECT id, name FROM focus_topics WHERE category=? AND priority='高'",
                (category,),
            ).fetchall()
            for row in rows:
                conn.execute("UPDATE focus_topics SET priority='中' WHERE id=?", (row[0],))
                downgraded.append(row[1])
    try:
        with sqlite3.connect(DB_PATH) as conn:
            conn.execute(
                "INSERT INTO focus_topics (name, category, priority, created_at) VALUES (?, ?, ?, ?)",
                (name, category, priority, datetime.now().isoformat(timespec="seconds")),
            )
        return jsonify({"ok": True, "downgraded": downgraded})
    except sqlite3.IntegrityError:
        return jsonify({"error": "already exists"}), 409


@app.route("/api/focus_topics/<int:tid>", methods=["PUT"])
def api_focus_topic_update(tid):
    data     = request.get_json(force=True)
    name     = (data.get("name") or "").strip()
    category = (data.get("category") or "").strip()
    priority = (data.get("priority") or "").strip()
    migrated = 0
    downgraded = []

    with sqlite3.connect(DB_PATH) as conn:
        if name:
            conn.execute("UPDATE focus_topics SET name=? WHERE id=?", (name, tid))
        if priority:
            if priority not in ("高", "中", "低"):
                return jsonify({"error": "invalid priority"}), 400
            # 高：同分类只能一个，先降级其他高优先级主题
            if priority == "高":
                row = conn.execute("SELECT category FROM focus_topics WHERE id=?", (tid,)).fetchone()
                if row:
                    cat = row[0]
                    others = conn.execute(
                        "SELECT id, name FROM focus_topics WHERE category=? AND priority='高' AND id!=?",
                        (cat, tid),
                    ).fetchall()
                    for r in others:
                        conn.execute("UPDATE focus_topics SET priority='中' WHERE id=?", (r[0],))
                        downgraded.append(r[1])
            conn.execute("UPDATE focus_topics SET priority=? WHERE id=?", (priority, tid))

    if category:
        try:
            migrated = migrate_topic_category(tid, category)
        except KeyError as e:
            return jsonify({"error": str(e)}), 404

    return jsonify({"ok": True, "migrated": migrated, "downgraded": downgraded})


@app.route("/api/focus_topics/<int:tid>", methods=["DELETE"])
def api_focus_topic_delete(tid):
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute("DELETE FROM focus_topics WHERE id=?", (tid,))
    return jsonify({"ok": True})


@app.route("/api/activities/add_manual", methods=["POST"])
def api_add_manual():
    """Add a record for any arbitrary past time, with optional end_time."""
    from datetime import datetime as dt
    data     = request.get_json(force=True)
    date_str = (data.get("date") or "").strip()      # YYYY-MM-DD
    time_str = (data.get("time") or "").strip()      # HH:MM  (start)
    end_time = (data.get("end_time") or "").strip() or None  # full ISO
    category = (data.get("category") or "").strip()
    note     = (data.get("note") or "").strip()
    if not date_str or not time_str or not category:
        return jsonify({"error": "date, time, and category required"}), 400
    try:
        hour, minute = map(int, time_str.split(":"))
        slot_start = dt.strptime(date_str, "%Y-%m-%d").replace(
            hour=hour, minute=minute, second=0, microsecond=0
        )
    except (ValueError, AttributeError) as e:
        return jsonify({"error": f"invalid date/time: {e}"}), 400

    from db import save_activity_for_slot
    save_activity_for_slot(category, note or category, slot_start,
                           ts=slot_start, end_time=end_time)
    return jsonify({"ok": True})


@app.route("/api/activities/<int:aid>", methods=["PUT"])
def api_act_update(aid):
    data     = request.get_json(force=True)
    category = (data.get("category") or "").strip()
    note     = (data.get("note") or "").strip()
    end_time = (data.get("end_time") or "").strip() or None
    detail   = data.get("detail")  # may be None or ""
    if detail is not None:
        detail = detail.strip() or None
    if not category:
        return jsonify({"error": "category required"}), 400
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute("UPDATE activities SET category=?,note=?,end_time=?,detail=? WHERE id=?",
                     (category, note, end_time, detail, aid))
    return jsonify({"ok": True})


@app.route("/api/activities/<int:aid>/detail", methods=["PATCH"])
def api_act_detail(aid):
    detail = (request.get_json(force=True) or {}).get("detail")
    if detail is not None:
        detail = str(detail).strip() or None
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute("UPDATE activities SET detail=? WHERE id=?", (detail, aid))
    return jsonify({"ok": True})


@app.route("/api/activities/<int:aid>", methods=["DELETE"])
def api_act_delete(aid):
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute("DELETE FROM activities WHERE id=?", (aid,))
    return jsonify({"ok": True})


@app.route("/api/tasks", methods=["GET"])
def api_tasks_list():
    scope      = request.args.get("scope")
    scope_date = request.args.get("scope_date")
    topic      = request.args.get("topic")
    done       = request.args.get("done")
    with sqlite3.connect(DB_PATH) as conn:
        conn.row_factory = sqlite3.Row
        conds, params = ["1=1"], []
        if scope:      conds.append("scope=?");       params.append(scope)
        if scope_date: conds.append("scope_date=?");  params.append(scope_date)
        if topic:      conds.append("topic_name=?");  params.append(topic)
        if done is not None:
            try: params.append(int(done)); conds.append("done=?")
            except ValueError: pass
        rows = conn.execute(
            f"SELECT * FROM tasks WHERE {' AND '.join(conds)} ORDER BY created_at DESC",
            params
        ).fetchall()
    return jsonify([dict(r) for r in rows])


@app.route("/api/tasks", methods=["POST"])
def api_tasks_create():
    data       = request.get_json(force=True) or {}
    title      = (data.get("title") or "").strip()
    topic_name = (data.get("topic_name") or "").strip()
    category   = (data.get("category") or "").strip()
    scope      = (data.get("scope") or "day").strip()
    scope_date = (data.get("scope_date") or "").strip()
    if not title: return jsonify({"error": "title required"}), 400
    if scope not in ("day", "week", "month"):
        return jsonify({"error": "invalid scope"}), 400
    with sqlite3.connect(DB_PATH) as conn:
        cur = conn.execute(
            "INSERT INTO tasks (title,topic_name,category,scope,scope_date,created_at) VALUES (?,?,?,?,?,?)",
            (title, topic_name, category, scope, scope_date,
             datetime.now().isoformat(timespec="seconds"))
        )
    return jsonify({"ok": True, "id": cur.lastrowid})


@app.route("/api/tasks/<int:tid>", methods=["PUT"])
def api_tasks_update(tid):
    data  = request.get_json(force=True) or {}
    title = (data.get("title") or "").strip()
    if not title: return jsonify({"error": "title required"}), 400
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute("UPDATE tasks SET title=? WHERE id=?", (title, tid))
    return jsonify({"ok": True})


@app.route("/api/tasks/<int:tid>", methods=["DELETE"])
def api_tasks_delete(tid):
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute("DELETE FROM tasks WHERE id=?", (tid,))
    return jsonify({"ok": True})


@app.route("/api/tasks/<int:tid>/complete", methods=["POST"])
def api_tasks_complete(tid):
    from db import save_activity_for_slot, get_slot_record
    data      = request.get_json(force=True) or {}
    category  = (data.get("category") or "").strip() or "工作"
    note      = (data.get("note") or "").strip()
    timestamp = (data.get("timestamp") or datetime.now().isoformat(timespec="seconds")).strip()
    end_time  = (data.get("end_time") or "").strip() or None
    with sqlite3.connect(DB_PATH) as conn:
        row = conn.execute("SELECT title FROM tasks WHERE id=?", (tid,)).fetchone()
        if not row: return jsonify({"error": "task not found"}), 404
        if not note: note = row[0]
        conn.execute(
            "INSERT INTO activities (timestamp,category,note,end_time) VALUES (?,?,?,?)",
            (timestamp, category, note, end_time)
        )
        act_id = conn.execute("SELECT last_insert_rowid()").fetchone()[0]
        conn.execute(
            "UPDATE tasks SET done=1,done_at=?,activity_id=? WHERE id=?",
            (datetime.now().isoformat(timespec="seconds"), act_id, tid)
        )
    return jsonify({"ok": True, "activity_id": act_id})


@app.route("/api/export")
def api_export():
    from flask import Response
    start = request.args.get("start", "")
    end   = request.args.get("end", "")
    if not start or not end:
        return jsonify({"error": "start and end required"}), 400

    iv = cfg.get_interval()
    topics = {t["name"]: t for t in get_focus_topics_with_stats()}
    prio_label = {"高": "★高", "中": "◆中", "低": "▽低"}

    acts = _q(
        "SELECT id,timestamp,end_time,category,note,detail FROM activities "
        "WHERE timestamp>=? AND timestamp<? ORDER BY timestamp ASC",
        (start, end + "T23:59:59"),
    )

    # ── helpers ───────────────────────────────────────────────
    def dur_mins(a):
        if a["end_time"]:
            from datetime import datetime as _dt
            diff = (_dt.fromisoformat(a["end_time"]) - _dt.fromisoformat(a["timestamp"])).total_seconds()
            return max(1, int(diff / 60))
        return iv

    def fmt_dur(mins):
        if mins < 60:
            return f"{mins}分钟"
        h, m = divmod(mins, 60)
        return f"{h}小时{m}分钟" if m else f"{h}小时"

    def fmt_time(iso):
        return iso[11:16] if iso else "—"

    # ── group by date ─────────────────────────────────────────
    from collections import defaultdict
    by_date = defaultdict(list)
    for a in acts:
        by_date[a["timestamp"][:10]].append(a)

    # ── summary stats ─────────────────────────────────────────
    cat_stats = defaultdict(lambda: {"cnt": 0, "mins": 0})
    note_stats = defaultdict(lambda: {"cnt": 0, "mins": 0})
    for a in acts:
        m = dur_mins(a)
        cat_stats[a["category"]]["cnt"] += 1
        cat_stats[a["category"]]["mins"] += m
        note_stats[a["note"]]["cnt"] += 1
        note_stats[a["note"]]["mins"] += m

    total_cnt  = len(acts)
    total_mins = sum(dur_mins(a) for a in acts)

    weekdays = "一二三四五六日"

    # ── build markdown ────────────────────────────────────────
    lines = [
        "# ActivityTracker 活动导出",
        f"**日期范围**：{start} 至 {end}  ",
        f"**导出时间**：{datetime.now().strftime('%Y-%m-%d %H:%M')}",
        "",
        "---",
        "",
        "## 汇总",
        "",
        f"- **总记录**：{total_cnt} 条 · **总时长**：{fmt_dur(total_mins)}",
        "",
        "| 分类 | 次数 | 累计时长 |",
        "|------|------|---------|",
    ]
    for cat, s in sorted(cat_stats.items(), key=lambda x: -x[1]["mins"]):
        lines.append(f"| {cat} | {s['cnt']} | {fmt_dur(s['mins'])} |")

    high_topics = [n for n, t in topics.items() if t.get("priority") == "高" and note_stats[n]["cnt"] > 0]
    if high_topics:
        lines += ["", f"**高优先主题**：{'、'.join(high_topics)}"]

    lines += ["", "---", "", "## 每日记录", ""]

    for date_str in sorted(by_date.keys()):
        from datetime import date as _date
        d = _date.fromisoformat(date_str)
        wd = weekdays[d.weekday()]
        day_acts = by_date[date_str]
        day_mins = sum(dur_mins(a) for a in day_acts)

        lines.append(f"### {date_str}（周{wd}）· {len(day_acts)}条 · {fmt_dur(day_mins)}")
        lines.append("")

        # group by category within day
        cat_groups = defaultdict(list)
        for a in day_acts:
            cat_groups[a["category"]].append(a)

        for cat, cat_acts in cat_groups.items():
            cat_mins = sum(dur_mins(a) for a in cat_acts)
            lines.append(f"**{cat}**（{len(cat_acts)}次 · {fmt_dur(cat_mins)}）")
            for a in cat_acts:
                t = topics.get(a["note"], {})
                prio = prio_label.get(t.get("priority", ""), "")
                prio_str = f" [{prio}]" if prio else ""
                end_str = fmt_time(a["end_time"]) if a["end_time"] else f"~{fmt_time(str(datetime.fromisoformat(a['timestamp']) + __import__('datetime').timedelta(minutes=iv)))}"
                line = f"- `{fmt_time(a['timestamp'])}–{end_str}`{prio_str} **{a['note']}**"
                if a.get("detail"):
                    line += f"  \n  > {a['detail']}"
                lines.append(line)
            lines.append("")

    md = "\n".join(lines)
    return Response(md, mimetype="text/plain; charset=utf-8")


if __name__ == "__main__":
    init_db()
    app.run(host="127.0.0.1", port=PORT, debug=False)
