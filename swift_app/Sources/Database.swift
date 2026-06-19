import Foundation
import SQLite3

// MARK: - SQLite value type for safe binding

enum SQLVal {
    case text(String)
    case int(Int)
    case int64(Int64)
    case real(Double)
    case null
}

// MARK: - Database

final class Database {
    static let shared = Database()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.activitytracker.db", qos: .userInitiated)

    // SQLITE_TRANSIENT tells SQLite to copy the string immediately
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".activity_tracker")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("activities.db").path
        sqlite3_open_v2(path, &db,
                        SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        exec("PRAGMA journal_mode=WAL")
    }

    // MARK: - Schema

    func initializeSchema() {
        exec("""
            CREATE TABLE IF NOT EXISTS activities (
                id        INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT NOT NULL,
                category  TEXT NOT NULL DEFAULT '工作',
                note      TEXT NOT NULL DEFAULT '',
                end_time  TEXT,
                detail    TEXT
            )
        """)
        exec("""
            CREATE TABLE IF NOT EXISTS focus_topics (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                name       TEXT UNIQUE NOT NULL,
                category   TEXT NOT NULL DEFAULT '',
                priority   TEXT NOT NULL DEFAULT '中',
                created_at TEXT NOT NULL
            )
        """)
        let actCols = columnNames(table: "activities")
        if !actCols.contains("end_time") { exec("ALTER TABLE activities ADD COLUMN end_time TEXT") }
        if !actCols.contains("detail")   { exec("ALTER TABLE activities ADD COLUMN detail TEXT") }
        let ftCols = columnNames(table: "focus_topics")
        if !ftCols.contains("category") { exec("ALTER TABLE focus_topics ADD COLUMN category TEXT NOT NULL DEFAULT ''") }
        if !ftCols.contains("priority") { exec("ALTER TABLE focus_topics ADD COLUMN priority TEXT NOT NULL DEFAULT '中'") }
        if !ftCols.contains("archived")         { exec("ALTER TABLE focus_topics ADD COLUMN archived INTEGER NOT NULL DEFAULT 0") }
        if !ftCols.contains("archive_summary") { exec("ALTER TABLE focus_topics ADD COLUMN archive_summary TEXT") }
        if !ftCols.contains("archive_review")  { exec("ALTER TABLE focus_topics ADD COLUMN archive_review TEXT") }
        migrateFocusTopicsUniqueConstraint()

        exec("""
            CREATE TABLE IF NOT EXISTS period_goals (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                period      TEXT NOT NULL,
                period_key  TEXT NOT NULL,
                goal_1      TEXT,
                goal_2      TEXT,
                goal_3      TEXT,
                updated_at  TEXT DEFAULT (datetime('now','localtime')),
                UNIQUE(period, period_key)
            )
        """)

        // One-time migration: Z-suffix (UTC) timestamps → local time, so SQLite
        // julianday() arithmetic stays consistent with Python-written local-time values.
        exec("UPDATE activities SET timestamp=datetime(timestamp,'localtime') WHERE timestamp LIKE '%Z'")
        exec("UPDATE activities SET end_time=datetime(end_time,'localtime') WHERE end_time LIKE '%Z'")

        exec("""
            CREATE TABLE IF NOT EXISTS tasks (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                title       TEXT NOT NULL,
                topic_name  TEXT NOT NULL DEFAULT '',
                category    TEXT NOT NULL DEFAULT '',
                scope       TEXT NOT NULL DEFAULT 'day',
                scope_date  TEXT NOT NULL DEFAULT '',
                created_at  TEXT NOT NULL,
                done        INTEGER NOT NULL DEFAULT 0,
                done_at     TEXT,
                activity_id INTEGER
            )
        """)
        exec("""
            CREATE TABLE IF NOT EXISTS daily_plans (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                date       TEXT NOT NULL,
                start_time TEXT NOT NULL,
                end_time   TEXT NOT NULL,
                category   TEXT NOT NULL DEFAULT '',
                topic_name TEXT NOT NULL DEFAULT '',
                note       TEXT NOT NULL DEFAULT '',
                created_at TEXT NOT NULL DEFAULT (datetime('now','localtime'))
            )
        """)
        let dpCols = columnNames(table: "daily_plans")
        if !dpCols.contains("topic_name") { exec("ALTER TABLE daily_plans ADD COLUMN topic_name TEXT NOT NULL DEFAULT ''") }
    }

    // MARK: - Daily Plans

    func getDailyPlans(date: String) -> [[String: Any]] {
        query("SELECT * FROM daily_plans WHERE date=? ORDER BY start_time", params: [.text(date)])
    }

    func addDailyPlan(date: String, startTime: String, endTime: String, category: String, topicName: String, note: String) {
        exec("INSERT INTO daily_plans (date,start_time,end_time,category,topic_name,note) VALUES (?,?,?,?,?,?)",
             params: [.text(date), .text(startTime), .text(endTime), .text(category), .text(topicName), .text(note)])
    }

    func updateDailyPlan(id: Int, startTime: String, endTime: String, category: String, topicName: String, note: String) {
        exec("UPDATE daily_plans SET start_time=?,end_time=?,category=?,topic_name=?,note=? WHERE id=?",
             params: [.text(startTime), .text(endTime), .text(category), .text(topicName), .text(note), .int(id)])
    }

    func deleteDailyPlan(id: Int) {
        exec("DELETE FROM daily_plans WHERE id=?", params: [.int(id)])
    }

    func getActivitiesForDay(date: String) -> [[String: Any]] {
        let start = "\(date)T00:00:00"
        let end   = "\(date)T23:59:59"
        return query(
            "SELECT id,timestamp,end_time,category,note,detail FROM activities WHERE timestamp>=? AND timestamp<=? ORDER BY timestamp",
            params: [.text(start), .text(end)]
        )
    }

    private func columnNames(table: String) -> Set<String> {
        Set(query("PRAGMA table_info(\(table))").compactMap { $0["name"] as? String })
    }

    // MARK: - Core query / exec

    func query(_ sql: String, params: [SQLVal] = []) -> [[String: Any]] {
        queue.sync { _query(sql, params: params) }
    }

    @discardableResult
    func exec(_ sql: String, params: [SQLVal] = []) -> Int {
        queue.sync { _exec(sql, params: params) }
    }

    var lastInsertRowID: Int64 {
        queue.sync { sqlite3_last_insert_rowid(db) }
    }

    private func _bind(_ stmt: OpaquePointer?, _ idx: Int32, _ val: SQLVal) {
        switch val {
        case .text(let s):
            sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
        case .int(let i):
            sqlite3_bind_int64(stmt, idx, Int64(i))
        case .int64(let i):
            sqlite3_bind_int64(stmt, idx, i)
        case .real(let d):
            sqlite3_bind_double(stmt, idx, d)
        case .null:
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func _query(_ sql: String, params: [SQLVal]) -> [[String: Any]] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        for (i, p) in params.enumerated() { _bind(stmt, Int32(i + 1), p) }
        var rows: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            let n = sqlite3_column_count(stmt)
            for col in 0..<n {
                let name = String(cString: sqlite3_column_name(stmt, col))
                switch sqlite3_column_type(stmt, col) {
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(stmt, col))
                case SQLITE_FLOAT:   row[name] = sqlite3_column_double(stmt, col)
                case SQLITE_TEXT:    row[name] = String(cString: sqlite3_column_text(stmt, col))
                case SQLITE_NULL:    row[name] = NSNull()
                default:             row[name] = NSNull()
                }
            }
            rows.append(row)
        }
        return rows
    }

    @discardableResult
    private func _exec(_ sql: String, params: [SQLVal]) -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        for (i, p) in params.enumerated() { _bind(stmt, Int32(i + 1), p) }
        sqlite3_step(stmt)
        return Int(sqlite3_changes(db))
    }

    // MARK: - Activity operations

    // Match Python's datetime.isoformat(timespec="seconds") — no timezone suffix
    private static let isoFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    static func isoNow() -> String { isoFmt.string(from: Date()) }
    static func isoDate(_ d: Date) -> String { isoFmt.string(from: d) }
    static func date(from s: String) -> Date? {
        // Try the primary format first
        if let d = isoFmt.date(from: s) { return d }
        // Fallback: ISO8601 with Z suffix (legacy records)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        return iso.date(from: s)
    }

    func slotBounds(slotStart: Date) -> (String, String) {
        (Self.isoDate(slotStart), Self.isoDate(slotStart.addingTimeInterval(15 * 60)))
    }

    func getSlotRecord(slotStart: Date) -> [String: Any]? {
        let (s, e) = slotBounds(slotStart: slotStart)
        return query(
            "SELECT id,category,note FROM activities WHERE timestamp>=? AND timestamp<? ORDER BY timestamp DESC LIMIT 1",
            params: [.text(s), .text(e)]
        ).first
    }

    func saveActivityForSlot(category: String, note: String, detail: String?, slotStart: Date) {
        let (s, e) = slotBounds(slotStart: slotStart)
        let ts = Self.isoDate(Date())
        exec("DELETE FROM activities WHERE timestamp>=? AND timestamp<?", params: [.text(s), .text(e)])
        exec("INSERT INTO activities (timestamp,category,note,detail) VALUES (?,?,?,?)",
             params: [.text(ts), .text(category), .text(note), detail.map { .text($0) } ?? .null])
    }

    func getActivities(start: String, end: String) -> [[String: Any]] {
        query(
            "SELECT id,timestamp,end_time,category,note,detail FROM activities WHERE timestamp>=? AND timestamp<? ORDER BY timestamp ASC",
            params: [.text(start), .text(end)]
        )
    }

    func getActivitiesByTopic(topicName: String, limit: Int = 300) -> [[String: Any]] {
        query(
            "SELECT id,timestamp,end_time,category,note,detail FROM activities WHERE note=? ORDER BY timestamp DESC LIMIT ?",
            params: [.text(topicName), .int(limit)]
        )
    }

    func updateActivity(id: Int, category: String, note: String, endTime: String?, detail: String?) -> Int {
        exec("UPDATE activities SET category=?,note=?,end_time=?,detail=? WHERE id=?",
             params: [.text(category), .text(note), endTime.map { .text($0) } ?? .null,
                      detail.map { .text($0) } ?? .null, .int(id)])
    }

    func deleteActivity(id: Int) { exec("DELETE FROM activities WHERE id=?", params: [.int(id)]) }

    func patchDetail(id: Int, detail: String?) {
        exec("UPDATE activities SET detail=? WHERE id=?",
             params: [detail.map { .text($0) } ?? .null, .int(id)])
    }

    func addManual(category: String, note: String, timestamp: String, endTime: String?, detail: String? = nil) {
        let s = timestamp
        let e = endTime ?? Self.isoDate((Self.date(from: timestamp) ?? Date()).addingTimeInterval(15*60))
        exec("DELETE FROM activities WHERE timestamp>=? AND timestamp<?", params: [.text(s), .text(e)])
        exec("INSERT INTO activities (timestamp,category,note,end_time,detail) VALUES (?,?,?,?,?)",
             params: [.text(timestamp), .text(category), .text(note),
                      endTime.map { .text($0) } ?? .null,
                      detail.map { .text($0) } ?? .null])
    }

    func categoryStats(start: String, end: String, interval: Int) -> [[String: Any]] {
        query("""
            SELECT category, COUNT(*) AS cnt,
                   SUM(CASE WHEN end_time IS NOT NULL
                     THEN CAST((julianday(end_time)-julianday(timestamp))*1440 AS INTEGER)
                     ELSE ? END) AS total_mins
            FROM activities WHERE timestamp>=? AND timestamp<? GROUP BY category
        """, params: [.int(interval), .text(start), .text(end)])
    }

    func monthStats(month: String, start: String, end: String) -> [[String: Any]] {
        query("SELECT DATE(timestamp) day,COUNT(*) cnt FROM activities WHERE timestamp>=? AND timestamp<? GROUP BY day",
              params: [.text(start), .text(end)])
    }

    func recentNotes(categories: [String], limit: Int = 7) -> [String] {
        guard !categories.isEmpty else { return [] }
        let cutoff = Self.isoDate(Date().addingTimeInterval(-5 * 86400))
        let ph = categories.map { _ in "?" }.joined(separator: ",")
        let excludePh = ph
        let rows = query(
            "SELECT note,COUNT(*) c FROM activities WHERE timestamp>? AND category IN (\(ph)) AND note NOT IN (\(excludePh)) GROUP BY note ORDER BY c DESC LIMIT ?",
            params: [.text(cutoff)] + categories.map { .text($0) } + categories.map { .text($0) } + [.int(limit)]
        )
        return rows.compactMap { $0["note"] as? String }
    }

    // MARK: - Migrations

    // SQLite 不支持 DROP UNIQUE CONSTRAINT，需要重建表。
    // 旧表：name TEXT UNIQUE（全局唯一）→ 新表：UNIQUE(name, category)（分类内唯一）
    private func migrateFocusTopicsUniqueConstraint() {
        let sql = query("SELECT sql FROM sqlite_master WHERE type='table' AND name='focus_topics'")
                      .first?["sql"] as? String ?? ""
        guard !sql.contains("UNIQUE(name, category)") else { return }
        exec("""
            CREATE TABLE IF NOT EXISTS focus_topics_new (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                name            TEXT NOT NULL,
                category        TEXT NOT NULL DEFAULT '',
                priority        TEXT NOT NULL DEFAULT '中',
                created_at      TEXT NOT NULL,
                archived        INTEGER NOT NULL DEFAULT 0,
                archive_summary TEXT,
                archive_review  TEXT,
                UNIQUE(name, category)
            )
        """)
        exec("""
            INSERT OR IGNORE INTO focus_topics_new
                (id, name, category, priority, created_at, archived, archive_summary, archive_review)
            SELECT id, name,
                   COALESCE(category,''), COALESCE(priority,'中'), created_at,
                   COALESCE(archived,0), archive_summary, archive_review
            FROM focus_topics
        """)
        exec("DROP TABLE focus_topics")
        exec("ALTER TABLE focus_topics_new RENAME TO focus_topics")
    }

    // MARK: - Focus topics

    func getFocusTopicsWithStats(interval: Int) -> [[String: Any]] {
        let weekAgo = Self.isoDate(Date().addingTimeInterval(-7 * 86400))
        return query("""
            SELECT ft.id, ft.name, ft.category, ft.priority,
                   COUNT(a.id) AS total_cnt,
                   COALESCE(SUM(
                     CASE WHEN a.end_time IS NOT NULL
                       THEN CAST((julianday(a.end_time)-julianday(a.timestamp))*1440 AS INTEGER)
                       ELSE ? END
                   ), 0) AS total_mins,
                   SUM(CASE WHEN a.timestamp>=? THEN 1 ELSE 0 END) AS cnt_7d
            FROM focus_topics ft
            LEFT JOIN activities a ON a.note=ft.name AND a.category=ft.category
            WHERE ft.archived=0
            GROUP BY ft.id ORDER BY total_mins DESC
        """, params: [.int(interval), .text(weekAgo)])
    }

    func getArchivedTopics(interval: Int) -> [[String: Any]] {
        let weekAgo = Self.isoDate(Date().addingTimeInterval(-7 * 86400))
        return query("""
            SELECT ft.id, ft.name, ft.category, ft.priority,
                   COUNT(a.id) AS total_cnt,
                   COALESCE(SUM(
                     CASE WHEN a.end_time IS NOT NULL
                       THEN CAST((julianday(a.end_time)-julianday(a.timestamp))*1440 AS INTEGER)
                       ELSE ? END
                   ), 0) AS total_mins,
                   SUM(CASE WHEN a.timestamp>=? THEN 1 ELSE 0 END) AS cnt_7d
            FROM focus_topics ft
            LEFT JOIN activities a ON a.note=ft.name AND a.category=ft.category
            WHERE ft.archived=1
            GROUP BY ft.id ORDER BY ft.category, ft.name
        """, params: [.int(interval), .text(weekAgo)])
    }

    func archiveTopic(id: Int, summary: String? = nil, review: String? = nil) {
        exec("UPDATE focus_topics SET archived=1, archive_summary=?, archive_review=? WHERE id=?",
             params: [summary.map { .text($0) } ?? .null,
                      review.map  { .text($0) } ?? .null,
                      .int(id)])
    }
    func unarchiveTopic(id: Int) { exec("UPDATE focus_topics SET archived=0 WHERE id=?", params: [.int(id)]) }

    func getTopicInfo(name: String) -> [String: Any]? {
        query("SELECT * FROM focus_topics WHERE name=?", params: [.text(name)]).first
    }

    func getActivitiesByTopicAll(topicName: String) -> [[String: Any]] {
        query(
            "SELECT id,timestamp,end_time,category,note,detail FROM activities WHERE note=? ORDER BY timestamp ASC",
            params: [.text(topicName)]
        )
    }

    func getFocusTopicsByCategory(_ category: String) -> [[String: Any]] {
        let cutoff = Self.isoDate(Date().addingTimeInterval(-30 * 86400))
        return query("""
            SELECT ft.name, ft.priority, COUNT(a.id) AS cnt
            FROM focus_topics ft
            LEFT JOIN activities a ON a.note=ft.name AND a.category=ft.category AND a.timestamp>?
            WHERE ft.category=? GROUP BY ft.id
        """, params: [.text(cutoff), .text(category)])
    }

    func addFocusTopic(name: String, category: String, priority: String) throws {
        let now = Self.isoNow()
        let r = exec(
            "INSERT OR IGNORE INTO focus_topics (name,category,priority,created_at) VALUES (?,?,?,?)",
            params: [.text(name), .text(category), .text(priority), .text(now)])
        if r == 0 { throw APIError.conflict("already exists") }
    }

    func downgradeHighPriority(inCategory cat: String, exceptId: Int) -> [String] {
        let rows = query("SELECT id,name FROM focus_topics WHERE category=? AND priority='高' AND id!=?",
                         params: [.text(cat), .int(exceptId)])
        let names = rows.compactMap { $0["name"] as? String }
        if !names.isEmpty {
            exec("UPDATE focus_topics SET priority='中' WHERE category=? AND priority='高' AND id!=?",
                 params: [.text(cat), .int(exceptId)])
        }
        return names
    }

    func updateFocusTopic(id: Int, name: String?, priority: String?) -> [String] {
        var downgraded: [String] = []
        if let n = name {
            // Fetch old name first so we can cascade the rename to activity records and tasks
            let oldName = query("SELECT name FROM focus_topics WHERE id=?",
                                params: [.int(id)]).first?["name"] as? String
            exec("UPDATE focus_topics SET name=? WHERE id=?", params: [.text(n), .int(id)])
            if let old = oldName, old != n {
                exec("UPDATE activities SET note=? WHERE note=?", params: [.text(n), .text(old)])
                exec("UPDATE tasks SET topic_name=? WHERE topic_name=?", params: [.text(n), .text(old)])
            }
        }
        if let p = priority {
            if p == "高" {
                if let row = query("SELECT category FROM focus_topics WHERE id=?", params: [.int(id)]).first,
                   let cat = row["category"] as? String {
                    downgraded = downgradeHighPriority(inCategory: cat, exceptId: id)
                }
            }
            exec("UPDATE focus_topics SET priority=? WHERE id=?", params: [.text(p), .int(id)])
        }
        return downgraded
    }

    func migrateTopic(id: Int, toCategory newCat: String) -> Int {
        guard let row = query("SELECT name FROM focus_topics WHERE id=?", params: [.int(id)]).first,
              let name = row["name"] as? String else { return 0 }
        let changed = exec("UPDATE activities SET category=? WHERE note=?",
                           params: [.text(newCat), .text(name)])
        exec("UPDATE focus_topics SET category=? WHERE id=?", params: [.text(newCat), .int(id)])
        return changed
    }

    func deleteFocusTopic(id: Int) { exec("DELETE FROM focus_topics WHERE id=?", params: [.int(id)]) }

    // MARK: - Period goals

    func getPeriodGoals(period: String, key: String) -> [String: Any]? {
        query("SELECT * FROM period_goals WHERE period=? AND period_key=?",
              params: [.text(period), .text(key)]).first
    }

    func upsertPeriodGoals(period: String, key: String, g1: String?, g2: String?, g3: String?) {
        func v(_ s: String?) -> SQLVal { s.map { .text($0) } ?? .null }
        exec("""
            INSERT INTO period_goals (period, period_key, goal_1, goal_2, goal_3, updated_at)
            VALUES (?,?,?,?,?, datetime('now','localtime'))
            ON CONFLICT(period, period_key) DO UPDATE SET
                goal_1=excluded.goal_1, goal_2=excluded.goal_2, goal_3=excluded.goal_3,
                updated_at=excluded.updated_at
        """, params: [.text(period), .text(key), v(g1), v(g2), v(g3)])
    }

    func listPeriodGoalsArchive() -> [[String: Any]] {
        query("SELECT * FROM period_goals ORDER BY period, period_key DESC")
    }

    // MARK: - Tasks

    func getTasks(scope: String?, scopeDate: String?, topicName: String?, done: Int?) -> [[String: Any]] {
        var conds = ["1=1"]
        var params: [SQLVal] = []
        if let s = scope      { conds.append("scope=?");       params.append(.text(s)) }
        if let sd = scopeDate { conds.append("scope_date=?");  params.append(.text(sd)) }
        if let tn = topicName { conds.append("topic_name=?");  params.append(.text(tn)) }
        if let d  = done      { conds.append("done=?");        params.append(.int(d)) }
        return query("SELECT * FROM tasks WHERE \(conds.joined(separator:" AND ")) ORDER BY created_at DESC",
                     params: params)
    }

    func getTask(id: Int) -> [String: Any]? {
        query("SELECT * FROM tasks WHERE id=?", params: [.int(id)]).first
    }

    func addTask(title: String, topicName: String, category: String, scope: String, scopeDate: String) {
        exec("INSERT INTO tasks (title,topic_name,category,scope,scope_date,created_at) VALUES (?,?,?,?,?,?)",
             params: [.text(title), .text(topicName), .text(category),
                      .text(scope), .text(scopeDate), .text(Self.isoNow())])
    }

    func updateTask(id: Int, title: String?, topicName: String?, category: String?,
                    scope: String?, scopeDate: String?) {
        var sets: [String] = []
        var params: [SQLVal] = []
        if let v = title      { sets.append("title=?");      params.append(.text(v)) }
        if let v = topicName  { sets.append("topic_name=?"); params.append(.text(v)) }
        if let v = category   { sets.append("category=?");   params.append(.text(v)) }
        if let v = scope      { sets.append("scope=?");      params.append(.text(v)) }
        if let v = scopeDate  { sets.append("scope_date=?"); params.append(.text(v)) }
        guard !sets.isEmpty else { return }
        params.append(.int(id))
        exec("UPDATE tasks SET \(sets.joined(separator: ",")) WHERE id=?", params: params)
    }

    func deleteTask(id: Int) { exec("DELETE FROM tasks WHERE id=?", params: [.int(id)]) }

    func completeTask(id: Int, activityId: Int64) {
        exec("UPDATE tasks SET done=1,done_at=?,activity_id=? WHERE id=?",
             params: [.text(Self.isoNow()), .int64(activityId), .int(id)])
    }
}
