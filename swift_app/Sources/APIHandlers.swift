import Foundation

// MARK: - Error types

enum APIError: Error {
    case bad(String)
    case notFound(String)
    case conflict(String)
    var statusCode: Int {
        switch self { case .bad: return 400; case .notFound: return 404; case .conflict: return 409 }
    }
    var message: String {
        switch self { case .bad(let m), .notFound(let m), .conflict(let m): return m }
    }
}

// MARK: - Response

struct APIResponse {
    let status: Int
    let contentType: String
    let body: Data

    static func json(_ obj: Any, status: Int = 200) throws -> APIResponse {
        let data = try JSONSerialization.data(withJSONObject: obj)
        return APIResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }
    static func text(_ s: String, status: Int = 200) -> APIResponse {
        APIResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(s.utf8))
    }
    static func html(_ data: Data) -> APIResponse {
        APIResponse(status: 200, contentType: "text/html; charset=utf-8", body: data)
    }
    static func err(_ e: APIError) throws -> APIResponse {
        try .json(["error": e.message], status: e.statusCode)
    }
}

// MARK: - Request parsing helpers

struct Req {
    let method: String
    let path: String
    let query: [String: String]
    let pathParams: [String: String]
    let bodyData: Data?

    var body: [String: Any] {
        guard let d = bodyData,
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return obj
    }
    func q(_ key: String) -> String? { query[key] }
    func pp(_ key: String) -> String? { pathParams[key] }
    func ppInt(_ key: String) -> Int? { pathParams[key].flatMap(Int.init) }
    func str(_ key: String) -> String? { (body[key] as? String)?.trimmingCharacters(in: .whitespaces).nonEmpty }
    func bool(_ key: String, default def: Bool) -> Bool { body[key] as? Bool ?? def }
    func int(_ key: String, default def: Int) -> Int { body[key] as? Int ?? def }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - API Handlers

enum APIHandlers {

    // ── /api/meta ─────────────────────────────────────────────
    static func meta(_ r: Req) throws -> APIResponse {
        let cats    = ConfigStore.shared.categories
        let iv      = ConfigStore.shared.interval
        let topics  = Database.shared.getFocusTopicsWithStats(interval: iv)
        let prios   = Dictionary(uniqueKeysWithValues: topics.compactMap { t -> (String, String)? in
            guard let n = t["name"] as? String, let p = t["priority"] as? String else { return nil }
            return (n, p)
        })
        return try .json([
            "categories":       cats.map { $0.name },
            "colors":           Dictionary(uniqueKeysWithValues: cats.map { ($0.name, $0.color) }),
            "topic_priorities": prios,
            "version":          ConfigStore.version,
        ])
    }

    // ── /api/config/interval ──────────────────────────────────
    static func getInterval(_ r: Req) throws -> APIResponse {
        try .json(["interval": ConfigStore.shared.interval])
    }
    static func setInterval(_ r: Req) throws -> APIResponse {
        let mins = r.int("interval", default: -1)
        guard (5...120).contains(mins) else { throw APIError.bad("interval must be 5-120") }
        ConfigStore.shared.interval = mins
        return try .json(["ok": true, "interval": mins])
    }

    // ── /api/config/auto_popup ────────────────────────────────
    static func getAutoPopup(_ r: Req) throws -> APIResponse {
        try .json(["enabled": ConfigStore.shared.autoPopup])
    }
    static func setAutoPopup(_ r: Req) throws -> APIResponse {
        ConfigStore.shared.autoPopup = r.bool("enabled", default: true)
        return try .json(["ok": true])
    }

    // ── /api/categories ───────────────────────────────────────
    static func listCategories(_ r: Req) throws -> APIResponse {
        let cats = ConfigStore.shared.categories.map { ["name": $0.name, "color": $0.color] }
        return try .json(cats)
    }
    static func addCategory(_ r: Req) throws -> APIResponse {
        guard let name = r.str("name") else { throw APIError.bad("name required") }
        let color = r.str("color")
        do {
            let entry = try ConfigStore.shared.addCategory(name: name, color: color)
            return try .json(["name": entry.name, "color": entry.color])
        } catch let e as APIError { return try .err(e) }
    }
    static func updateCategory(_ r: Req) throws -> APIResponse {
        guard let old = r.str("old_name") else { throw APIError.bad("old_name required") }
        let newName = r.str("new_name")
        let color   = r.str("color")
        // Also update activities table if renaming
        if let n = newName, n != old {
            Database.shared.exec("UPDATE activities SET category=? WHERE category=?",
                                 params: [.text(n), .text(old)])
        }
        do {
            let resolved = try ConfigStore.shared.updateCategory(oldName: old, newName: newName, color: color)
            return try .json(["ok": true, "name": resolved])
        } catch let e as APIError { return try .err(e) }
    }
    static func deleteCategory(_ r: Req) throws -> APIResponse {
        guard let name = r.str("name") else { throw APIError.bad("name required") }
        do { try ConfigStore.shared.deleteCategory(name: name) } catch let e as APIError { return try .err(e) }
        return try .json(["ok": true])
    }

    // ── /api/activities ───────────────────────────────────────
    static func listActivities(_ r: Req) throws -> APIResponse {
        guard let start = r.q("start"), let end = r.q("end") else { throw APIError.bad("start and end required") }
        let rows = Database.shared.getActivities(start: start, end: end)
        return try .json(rows.map { nullToNil($0) })
    }
    static func updateActivity(_ r: Req) throws -> APIResponse {
        guard let id = r.ppInt("id") else { throw APIError.bad("id required") }
        guard let cat = r.str("category") else { throw APIError.bad("category required") }
        let note    = r.str("note") ?? cat
        let endTime = r.str("end_time")
        let detail  = r.str("detail")
        Database.shared.updateActivity(id: id, category: cat, note: note, endTime: endTime, detail: detail)
        return try .json(["ok": true])
    }
    static func deleteActivity(_ r: Req) throws -> APIResponse {
        guard let id = r.ppInt("id") else { throw APIError.bad("id required") }
        Database.shared.deleteActivity(id: id)
        return try .json(["ok": true])
    }
    static func patchDetail(_ r: Req) throws -> APIResponse {
        guard let id = r.ppInt("id") else { throw APIError.bad("id required") }
        let detail = r.str("detail")
        Database.shared.patchDetail(id: id, detail: detail)
        return try .json(["ok": true])
    }
    static func addManual(_ r: Req) throws -> APIResponse {
        guard let dateStr = r.str("date"),
              let timeStr = r.str("time"),
              let cat = r.str("category") else { throw APIError.bad("date, time, and category required") }
        let endTime = r.str("end_time")
        let note    = r.str("note") ?? cat
        // Build ISO timestamp from date + time
        let ts = "\(dateStr)T\(timeStr):00"
        Database.shared.addManual(category: cat, note: note, timestamp: ts, endTime: endTime)
        return try .json(["ok": true])
    }

    // ── /api/category_stats ───────────────────────────────────
    static func categoryStats(_ r: Req) throws -> APIResponse {
        guard let start = r.q("start"), let end = r.q("end") else { throw APIError.bad("start and end required") }
        let iv = ConfigStore.shared.interval
        let rows = Database.shared.categoryStats(start: start, end: end, interval: iv)
        var result = ConfigStore.shared.categories.reduce(into: [String: Any]()) { d, cat in
            d[cat.name] = ["mins": 0, "cnt": 0]
        }
        for row in rows {
            guard let cat = row["category"] as? String else { continue }
            result[cat] = ["mins": row["total_mins"] ?? 0, "cnt": row["cnt"] ?? 0]
        }
        return try .json(result)
    }

    // ── /api/month_stats ──────────────────────────────────────
    static func monthStats(_ r: Req) throws -> APIResponse {
        guard let month = r.q("month") else { throw APIError.bad("month required") }
        let parts = month.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let m = Int(parts[1]) else {
            throw APIError.bad("invalid month")
        }
        let start = "\(month)-01"
        let end   = m == 12 ? "\(year+1)-01-01" : String(format: "%04d-%02d-01", year, m+1)
        let rows  = Database.shared.monthStats(month: month, start: start, end: end)
        let dict  = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, Int)? in
            guard let day = row["day"] as? String, let cnt = row["cnt"] as? Int else { return nil }
            return (day, cnt)
        })
        return try .json(dict)
    }

    // ── /api/focus_topics ─────────────────────────────────────
    static func listFocusTopics(_ r: Req) throws -> APIResponse {
        let iv   = ConfigStore.shared.interval
        let rows = Database.shared.getFocusTopicsWithStats(interval: iv)
        return try .json(rows.map { nullToNil($0) })
    }
    static func addFocusTopic(_ r: Req) throws -> APIResponse {
        guard let name = r.str("name") else { throw APIError.bad("name required") }
        let cat   = r.str("category") ?? ""
        var prio  = r.str("priority") ?? "中"
        if !["高","中","低"].contains(prio) { prio = "中" }
        var downgraded: [String] = []
        if prio == "高" && !cat.isEmpty {
            // downgrade existing 高 before insert (by id=-1 to match all)
            let rows = Database.shared.query(
                "SELECT id,name FROM focus_topics WHERE category=? AND priority='高'",
                params: [.text(cat)])
            for row in rows {
                if let rid = row["id"] as? Int, let rname = row["name"] as? String {
                    Database.shared.exec("UPDATE focus_topics SET priority='中' WHERE id=?", params: [.int(rid)])
                    downgraded.append(rname)
                }
            }
        }
        do { try Database.shared.addFocusTopic(name: name, category: cat, priority: prio) }
        catch let e as APIError { return try .err(e) }
        return try .json(["ok": true, "downgraded": downgraded])
    }
    static func updateFocusTopic(_ r: Req) throws -> APIResponse {
        guard let id = r.ppInt("id") else { throw APIError.bad("id required") }
        let name     = r.str("name")
        let priority = r.str("priority")
        let category = r.str("category")
        var downgraded: [String] = []
        var migrated = 0
        downgraded = Database.shared.updateFocusTopic(id: id, name: name, priority: priority)
        if let cat = category { migrated = Database.shared.migrateTopic(id: id, toCategory: cat) }
        return try .json(["ok": true, "migrated": migrated, "downgraded": downgraded])
    }
    static func deleteFocusTopic(_ r: Req) throws -> APIResponse {
        guard let id = r.ppInt("id") else { throw APIError.bad("id required") }
        Database.shared.deleteFocusTopic(id: id)
        return try .json(["ok": true])
    }

    // ── /api/export ───────────────────────────────────────────
    static func export(_ r: Req) throws -> APIResponse {
        guard let start = r.q("start"), let end = r.q("end") else { throw APIError.bad("start and end required") }
        let iv     = ConfigStore.shared.interval
        let acts   = Database.shared.getActivities(start: start, end: "\(end)T23:59:59")
        let topics = Database.shared.getFocusTopicsWithStats(interval: iv)
        let prioLabel = ["高": "★高", "中": "◆中", "低": "▽低"]
        let topicMap  = Dictionary(uniqueKeysWithValues: topics.compactMap { t -> (String, [String:Any])? in
            guard let n = t["name"] as? String else { return nil }
            return (n, t)
        })

        func durMins(_ a: [String: Any]) -> Int {
            if let et = a["end_time"] as? String,
               let ts = a["timestamp"] as? String,
               let endDate = Database.date(from: et),
               let startDate = Database.date(from: ts) {
                return max(1, Int(endDate.timeIntervalSince(startDate) / 60))
            }
            return iv
        }
        func fmtDur(_ mins: Int) -> String {
            if mins < 60 { return "\(mins)分钟" }
            let h = mins/60, m = mins%60
            return m > 0 ? "\(h)小时\(m)分钟" : "\(h)小时"
        }
        func fmtTime(_ ts: String) -> String { String(ts.dropFirst(11).prefix(5)) }

        // Summary stats
        var catStats = [String: (cnt: Int, mins: Int)]()
        var noteStats = [String: (cnt: Int, mins: Int)]()
        for a in acts {
            guard let cat = a["category"] as? String, let note = a["note"] as? String else { continue }
            let m = durMins(a)
            catStats[cat, default: (0,0)] = (catStats[cat]?.cnt ?? 0 + 1, catStats[cat]?.mins ?? 0 + m)
            noteStats[note, default: (0,0)] = (noteStats[note]?.cnt ?? 0 + 1, noteStats[note]?.mins ?? 0 + m)
        }
        let totalCnt  = acts.count
        let totalMins = acts.reduce(0) { $0 + durMins($1) }

        // Group by date
        var byDate = [String: [[String: Any]]]()
        for a in acts {
            guard let ts = a["timestamp"] as? String else { continue }
            let day = String(ts.prefix(10))
            byDate[day, default: []].append(a)
        }

        let weekdayNames = ["一","二","三","四","五","六","日"]
        func weekday(_ dateStr: String) -> String {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            guard let d = f.date(from: dateStr) else { return "" }
            let idx = Calendar.current.component(.weekday, from: d) - 2
            return weekdayNames[(idx + 7) % 7]
        }

        var lines = [
            "# ActivityTracker 活动导出",
            "**日期范围**：\(start) 至 \(end)  ",
            "**导出时间**：\(Database.isoNow().prefix(16).replacingOccurrences(of: "T", with: " "))",
            "",
            "---", "",
            "## 汇总", "",
            "- **总记录**：\(totalCnt) 条 · **总时长**：\(fmtDur(totalMins))", "",
            "| 分类 | 次数 | 累计时长 |",
            "|------|------|---------|",
        ]
        for (cat, s) in catStats.sorted(by: { $0.value.mins > $1.value.mins }) {
            lines.append("| \(cat) | \(s.cnt) | \(fmtDur(s.mins)) |")
        }
        let highTopics = topics.compactMap { t -> String? in
            guard let n = t["name"] as? String, t["priority"] as? String == "高",
                  let cnt = noteStats[n]?.cnt, cnt > 0 else { return nil }
            return n
        }
        if !highTopics.isEmpty { lines += ["", "**高优先主题**：\(highTopics.joined(separator: "、"))"] }
        lines += ["", "---", "", "## 每日记录", ""]

        for dateStr in byDate.keys.sorted() {
            let dayActs = byDate[dateStr]!
            let dayMins = dayActs.reduce(0) { $0 + durMins($1) }
            lines.append("### \(dateStr)（周\(weekday(dateStr))）· \(dayActs.count)条 · \(fmtDur(dayMins))")
            lines.append("")
            var catGroups = [String: [[String: Any]]]()
            for a in dayActs {
                if let cat = a["category"] as? String { catGroups[cat, default: []].append(a) }
            }
            for (cat, catActs) in catGroups {
                let catMins = catActs.reduce(0) { $0 + durMins($1) }
                lines.append("**\(cat)**（\(catActs.count)次 · \(fmtDur(catMins))）")
                for a in catActs {
                    let ts   = a["timestamp"] as? String ?? ""
                    let et   = a["end_time"] as? String
                    let note = a["note"] as? String ?? ""
                    let t    = topicMap[note]
                    let prio = t.flatMap { $0["priority"] as? String }.flatMap { prioLabel[$0] } ?? ""
                    let prioStr = prio.isEmpty ? "" : " [\(prio)]"
                    let endStr: String
                    if let etStr = et { endStr = fmtTime(etStr) }
                    else {
                        let calcEnd = (Database.date(from: ts) ?? Date()).addingTimeInterval(Double(iv)*60)
                        let f = DateFormatter(); f.dateFormat = "HH:mm"
                        endStr = "~\(f.string(from: calcEnd))"
                    }
                    var line = "- `\(fmtTime(ts))–\(endStr)`\(prioStr) **\(note)**"
                    if let detail = a["detail"] as? String, !detail.isEmpty {
                        line += "  \n  > \(detail)"
                    }
                    lines.append(line)
                }
                lines.append("")
            }
        }
        return .text(lines.joined(separator: "\n"))
    }

    // MARK: - Helpers

    private static func nullToNil(_ row: [String: Any]) -> [String: Any] {
        row.mapValues { $0 is NSNull ? Optional<Any>.none as Any : $0 }
    }
}

