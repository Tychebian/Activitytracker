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
        let prios   = Dictionary(topics.compactMap { t -> (String, String)? in
            guard let n = t["name"] as? String, let p = t["priority"] as? String else { return nil }
            return (n, p)
        }, uniquingKeysWith: { first, _ in first })
        return try .json([
            "categories":       cats.map { $0.name },
            "colors":           Dictionary(cats.map { ($0.name, $0.color) }, uniquingKeysWith: { first, _ in first }),
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
    static func checkManualConflicts(_ r: Req) throws -> APIResponse {
        guard let dateStr = r.str("date"),
              let timeStr = r.str("time") else { throw APIError.bad("date and time required") }
        let ts      = "\(dateStr)T\(timeStr):00"
        let endTime = r.str("end_time")
        let e       = endTime ?? Database.isoDate((Database.date(from: ts) ?? Date()).addingTimeInterval(15*60))
        let rows    = Database.shared.getConflicts(start: ts, end: e)
        return try .json(["conflicts": rows.map { nullToNil($0) }])
    }

    static func addManual(_ r: Req) throws -> APIResponse {
        guard let dateStr = r.str("date"),
              let timeStr = r.str("time"),
              let cat = r.str("category") else { throw APIError.bad("date, time, and category required") }
        let endTime = r.str("end_time")
        let note    = r.str("note") ?? cat
        let detail  = r.str("detail")
        let ts = "\(dateStr)T\(timeStr):00"
        Database.shared.addManual(category: cat, note: note, timestamp: ts, endTime: endTime, detail: detail)
        return try .json(["ok": true])
    }

    // ── /api/activities/by_topic ──────────────────────────
    static func activitiesByTopic(_ r: Req) throws -> APIResponse {
        guard let topic = r.q("topic") else { throw APIError.bad("topic required") }
        let limit = r.q("limit").flatMap(Int.init) ?? 300
        let rows = Database.shared.getActivitiesByTopic(topicName: topic, limit: limit)
        return try .json(rows.map { nullToNil($0) })
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
        let dict  = Dictionary(rows.compactMap { row -> (String, Int)? in
            guard let day = row["day"] as? String, let cnt = row["cnt"] as? Int else { return nil }
            return (day, cnt)
        }, uniquingKeysWith: { first, _ in first })
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
    static func listArchivedTopics(_ r: Req) throws -> APIResponse {
        let iv = ConfigStore.shared.interval
        return try .json(Database.shared.getArchivedTopics(interval: iv).map { nullToNil($0) })
    }
    static func archiveTopic(_ r: Req) throws -> APIResponse {
        guard let id = r.ppInt("id") else { throw APIError.bad("id required") }
        let summary = r.str("summary")
        let review  = r.str("review")
        Database.shared.archiveTopic(id: id, summary: summary, review: review)
        return try .json(["ok": true])
    }
    static func unarchiveTopic(_ r: Req) throws -> APIResponse {
        guard let id = r.ppInt("id") else { throw APIError.bad("id required") }
        Database.shared.unarchiveTopic(id: id)
        return try .json(["ok": true])
    }

    // ── /api/period_goals ─────────────────────────────────────
    static func getPeriodGoals(_ r: Req) throws -> APIResponse {
        guard let period = r.q("period"), let key = r.q("key") else { throw APIError.bad("period and key required") }
        let row = Database.shared.getPeriodGoals(period: period, key: key)
        return try .json(row.map { nullToNil($0) } ?? [:])
    }
    static func upsertPeriodGoals(_ r: Req) throws -> APIResponse {
        guard let period = r.str("period"), let key = r.str("key") else { throw APIError.bad("period and key required") }
        Database.shared.upsertPeriodGoals(period: period, key: key,
                                          g1: r.str("goal_1"), g2: r.str("goal_2"), g3: r.str("goal_3"),
                                          quote: r.str("quote"))
        return try .json(["ok": true])
    }
    static func upsertDailyQuote(_ r: Req) throws -> APIResponse {
        guard let key = r.str("key") else { throw APIError.bad("key required") }
        Database.shared.upsertDailyQuote(key: key, quote: r.str("quote"))
        return try .json(["ok": true])
    }
    static func listPeriodGoalsArchive(_ r: Req) throws -> APIResponse {
        return try .json(Database.shared.listPeriodGoalsArchive().map { nullToNil($0) })
    }
    static func listDailyQuotes(_ r: Req) throws -> APIResponse {
        return try .json(Database.shared.listDailyQuotes().map { nullToNil($0) })
    }
    static func listAllTags(_ r: Req) throws -> APIResponse {
        return try .json(Database.shared.listAllTags())
    }
    static func deleteTag(_ r: Req) throws -> APIResponse {
        guard let tag = r.q("tag"), !tag.isEmpty else { throw APIError.bad("tag required") }
        Database.shared.deleteTag(tag: tag)
        return try .json(["ok": true])
    }
    static func excludeTagActivity(_ r: Req) throws -> APIResponse {
        guard let tag = r.str("tag"), !tag.isEmpty else { throw APIError.bad("tag required") }
        guard let aid = r.body["activity_id"] as? Int else { throw APIError.bad("activity_id required") }
        Database.shared.excludeTagActivity(tag: tag, activityId: aid)
        return try .json(["ok": true])
    }
    static func listTaggedActivities(_ r: Req) throws -> APIResponse {
        let tag = r.q("tag") ?? "资讯"
        return try .json(Database.shared.listTaggedActivities(tag: tag).map { nullToNil($0) })
    }

    // ── /api/export ───────────────────────────────────────────
    static func export(_ r: Req) throws -> APIResponse {
        guard let start = r.q("start"), let end = r.q("end") else { throw APIError.bad("start and end required") }
        let iv     = ConfigStore.shared.interval
        let acts   = Database.shared.getActivities(start: start, end: "\(end)T23:59:59")
        let topics = Database.shared.getFocusTopicsWithStats(interval: iv)
        let prioLabel = ["高": "★高", "中": "◆中", "低": "▽低"]
        let topicMap  = Dictionary(topics.compactMap { t -> (String, [String:Any])? in
            guard let n = t["name"] as? String else { return nil }
            return (n, t)
        }, uniquingKeysWith: { first, _ in first })

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
            let cs = catStats[cat] ?? (0, 0)
            catStats[cat] = (cs.cnt + 1, cs.mins + m)
            let ns = noteStats[note] ?? (0, 0)
            noteStats[note] = (ns.cnt + 1, ns.mins + m)
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

    // ── /api/export_topic ─────────────────────────────────────
    static func exportTopic(_ r: Req) throws -> APIResponse {
        guard let topicName = r.q("topic"), !topicName.isEmpty else { throw APIError.bad("topic required") }
        let iv = ConfigStore.shared.interval

        guard let topicInfo = Database.shared.getTopicInfo(name: topicName) else {
            throw APIError.notFound("topic not found")
        }
        let acts = Database.shared.getActivitiesByTopicAll(topicName: topicName)

        func durMins(_ a: [String: Any]) -> Int {
            if let et = a["end_time"] as? String,
               let ts = a["timestamp"] as? String,
               let endDate  = Database.date(from: et),
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

        let category       = topicInfo["category"] as? String ?? ""
        let priority       = topicInfo["priority"] as? String ?? "中"
        let archived       = (topicInfo["archived"] as? Int ?? 0) == 1
        let archiveSummary = topicInfo["archive_summary"] as? String ?? ""
        let archiveReview  = topicInfo["archive_review"]  as? String ?? ""
        let prioLabel      = ["高": "★高", "中": "◆中", "低": "▽低"]
        let totalCnt       = acts.count
        let totalMins      = acts.reduce(0) { $0 + durMins($1) }

        var lines: [String] = [
            "# ActivityTracker 主题导出",
            "",
            "**主题**：\(topicName)  ",
            "**分类**：\(category)  ",
            "**优先级**：\(prioLabel[priority] ?? priority)  ",
            "**状态**：\(archived ? "已归档" : "进行中")  ",
            "**活动记录**：共 \(totalCnt) 条 · 累计 \(fmtDur(totalMins))  ",
            "**导出时间**：\(Database.isoNow().prefix(16).replacingOccurrences(of: "T", with: " "))",
            "", "---", "",
        ]

        if archived && (!archiveSummary.isEmpty || !archiveReview.isEmpty) {
            if !archiveSummary.isEmpty { lines += ["## 项目总结", "", archiveSummary, ""] }
            if !archiveReview.isEmpty  { lines += ["## 复盘建议", "", archiveReview,  ""] }
            lines += ["---", ""]
        }

        if acts.isEmpty {
            lines.append("（该主题暂无活动记录）")
            return .text(lines.joined(separator: "\n"))
        }

        lines += ["## 每日记录", ""]

        var byDate = [String: [[String: Any]]]()
        for a in acts {
            guard let ts = a["timestamp"] as? String else { continue }
            byDate[String(ts.prefix(10)), default: []].append(a)
        }

        let weekdayNames = ["一","二","三","四","五","六","日"]
        func weekday(_ dateStr: String) -> String {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            guard let d = f.date(from: dateStr) else { return "" }
            let idx = Calendar.current.component(.weekday, from: d) - 2
            return weekdayNames[(idx + 7) % 7]
        }

        for dateStr in byDate.keys.sorted() {
            let dayActs = byDate[dateStr]!
            let dayMins = dayActs.reduce(0) { $0 + durMins($1) }
            lines.append("### \(dateStr)（周\(weekday(dateStr))）· \(dayActs.count)条 · \(fmtDur(dayMins))")
            lines.append("")
            for a in dayActs {
                let ts = a["timestamp"] as? String ?? ""
                let et = a["end_time"] as? String
                let endStr: String
                if let etStr = et { endStr = fmtTime(etStr) }
                else {
                    let calcEnd = (Database.date(from: ts) ?? Date()).addingTimeInterval(Double(iv)*60)
                    let f = DateFormatter(); f.dateFormat = "HH:mm"
                    endStr = "~\(f.string(from: calcEnd))"
                }
                var line = "- `\(fmtTime(ts))–\(endStr)`"
                if let detail = a["detail"] as? String, !detail.isEmpty {
                    line += "  \n  > \(detail)"
                }
                lines.append(line)
            }
            lines.append("")
        }
        return .text(lines.joined(separator: "\n"))
    }

    // ── /api/tasks ────────────────────────────────────────────
    static func listTasks(_ r: Req) throws -> APIResponse {
        let scope    = r.q("scope")
        let sd       = r.q("scope_date")
        let topic    = r.q("topic")
        let doneInt  = r.q("done").flatMap(Int.init)
        let tasks    = Database.shared.getTasks(scope: scope, scopeDate: sd, topicName: topic, done: doneInt)
        return try .json(tasks)
    }

    static func createTask(_ r: Req) throws -> APIResponse {
        guard let title = r.str("title") else { throw APIError.bad("title required") }
        let topicName = r.str("topic_name") ?? ""
        let category  = r.str("category")  ?? ""
        let scope     = r.str("scope")     ?? "day"
        let scopeDate = r.str("scope_date") ?? ""
        let timeStart = r.str("time_start")
        let timeEnd   = r.str("time_end")
        guard ["day","week","month"].contains(scope) else { throw APIError.bad("invalid scope") }
        Database.shared.addTask(title: title, topicName: topicName, category: category,
                                scope: scope, scopeDate: scopeDate,
                                timeStart: timeStart, timeEnd: timeEnd)
        // If time range provided on a day task, auto-create a daily_plan entry
        if let ts = timeStart, !ts.isEmpty, let te = timeEnd, !te.isEmpty,
           scope == "day", !scopeDate.isEmpty {
            Database.shared.addDailyPlan(date: scopeDate, startTime: ts, endTime: te,
                                         category: category, topicName: topicName, note: title)
        }
        return try .json(["ok": true, "id": Database.shared.lastInsertRowID])
    }

    static func updateTask(_ r: Req) throws -> APIResponse {
        guard let id = r.ppInt("id") else { throw APIError.bad("id required") }
        let title     = r.str("title")
        let topicName = r.str("topic_name")
        let category  = r.str("category")
        let scope     = r.str("scope")
        let scopeDate = r.str("scope_date")
        let timeStart = r.str("time_start")
        let timeEnd   = r.str("time_end")
        if let s = scope, !["day","week","month"].contains(s) { throw APIError.bad("invalid scope") }
        Database.shared.updateTask(id: id, title: title, topicName: topicName,
                                   category: category, scope: scope, scopeDate: scopeDate,
                                   timeStart: timeStart, timeEnd: timeEnd)
        return try .json(["ok": true])
    }

    static func deleteTask(_ r: Req) throws -> APIResponse {
        guard let id = r.ppInt("id") else { throw APIError.bad("id required") }
        Database.shared.deleteTask(id: id)
        return try .json(["ok": true])
    }

    static func completeTask(_ r: Req) throws -> APIResponse {
        guard let id   = r.ppInt("id") else { throw APIError.bad("id required") }
        guard let task = Database.shared.getTask(id: id) else { throw APIError.notFound("task not found") }
        let category  = r.str("category")  ?? (task["category"]  as? String ?? "工作")
        let note      = r.str("note")      ?? (task["title"]      as? String ?? "")
        let timestamp = r.str("timestamp") ?? Database.isoNow()
        let endTime   = r.str("end_time")
        Database.shared.addManual(category: category, note: note, timestamp: timestamp, endTime: endTime)
        let actId = Database.shared.lastInsertRowID
        Database.shared.completeTask(id: id, activityId: actId)
        return try .json(["ok": true, "activity_id": actId])
    }

    // MARK: - Daily Plans

    static func listDailyPlans(_ r: Req) throws -> APIResponse {
        guard let date = r.q("date") else { throw APIError.bad("date required") }
        return try .json(Database.shared.getDailyPlans(date: date))
    }

    static func createDailyPlan(_ r: Req) throws -> APIResponse {
        guard let date      = r.str("date")       else { throw APIError.bad("date required") }
        guard let startTime = r.str("start_time") else { throw APIError.bad("start_time required") }
        guard let endTime   = r.str("end_time")   else { throw APIError.bad("end_time required") }
        let category  = r.str("category")   ?? ""
        let topicName = r.str("topic_name") ?? ""
        let note      = r.str("note")       ?? ""
        Database.shared.addDailyPlan(date: date, startTime: startTime, endTime: endTime,
                                     category: category, topicName: topicName, note: note)
        return try .json(["ok": true, "id": Database.shared.lastInsertRowID])
    }

    static func updateDailyPlan(_ r: Req) throws -> APIResponse {
        guard let id        = r.ppInt("id")       else { throw APIError.bad("id required") }
        guard let startTime = r.str("start_time") else { throw APIError.bad("start_time required") }
        guard let endTime   = r.str("end_time")   else { throw APIError.bad("end_time required") }
        let category  = r.str("category")   ?? ""
        let topicName = r.str("topic_name") ?? ""
        let note      = r.str("note")       ?? ""
        Database.shared.updateDailyPlan(id: id, startTime: startTime, endTime: endTime,
                                        category: category, topicName: topicName, note: note)
        return try .json(["ok": true])
    }

    static func deleteDailyPlan(_ r: Req) throws -> APIResponse {
        guard let id = r.ppInt("id") else { throw APIError.bad("id required") }
        Database.shared.deleteDailyPlan(id: id)
        return try .json(["ok": true])
    }

    static func listDayActivities(_ r: Req) throws -> APIResponse {
        guard let date = r.q("date") else { throw APIError.bad("date required") }
        return try .json(Database.shared.getActivitiesForDay(date: date))
    }

    // MARK: - AI Assistant (DeepSeek / Kimi)

    static func getAiConfig(_ r: Req) throws -> APIResponse {
        return try .json([
            "provider":             ConfigStore.shared.aiProvider,
            "deepseek_configured":  ConfigStore.shared.deepseekApiKey != nil,
            "kimi_configured":      ConfigStore.shared.kimiApiKey != nil,
            "prompt":               ConfigStore.shared.aiPrompt ?? "",
            "data_days":            ConfigStore.shared.aiDataDays,
            "frequency":            ConfigStore.shared.aiFrequency,
            "last_run_date":        ConfigStore.shared.aiLastRunDate ?? "",
        ] as [String: Any])
    }

    static func setAiConfig(_ r: Req) throws -> APIResponse {
        if let provider = r.str("provider") { ConfigStore.shared.aiProvider = provider }
        if let key = r.body["deepseek_key"] as? String {
            ConfigStore.shared.deepseekApiKey = key.isEmpty ? nil : key
        }
        if let key = r.body["kimi_key"] as? String {
            ConfigStore.shared.kimiApiKey = key.isEmpty ? nil : key
        }
        if let prompt = r.body["prompt"] as? String {
            ConfigStore.shared.aiPrompt = prompt.isEmpty ? nil : prompt
        }
        if let days = r.body["data_days"] as? Int {
            ConfigStore.shared.aiDataDays = days
        }
        if let freq = r.str("frequency") {
            ConfigStore.shared.aiFrequency = freq
        }
        return try .json(["ok": true])
    }

    static func listWisdom(_ r: Req) throws -> APIResponse {
        return try .json(Database.shared.listWisdom())
    }

    static func runPrompt(_ r: Req) throws -> APIResponse {
        guard let prompt = ConfigStore.shared.aiPrompt, !prompt.isEmpty else {
            throw APIError.bad("prompt 未配置，请先在「AI助手设置」中填写 prompt 植入")
        }
        let providerName = ConfigStore.shared.aiProvider
        guard let provider = AIClient.Provider(rawValue: providerName) else {
            throw APIError.bad("unknown provider: \(providerName)")
        }
        let apiKey: String
        switch provider {
        case .deepseek:
            guard let k = ConfigStore.shared.deepseekApiKey else { throw APIError.bad("DeepSeek API Key 未配置") }
            apiKey = k
        case .kimi:
            guard let k = ConfigStore.shared.kimiApiKey else { throw APIError.bad("Kimi API Key 未配置") }
            apiKey = k
        }

        let dataDays = ConfigStore.shared.aiDataDays
        let iv       = ConfigStore.shared.interval
        let stats    = Database.shared.categoryStats(
            start: Database.isoDate(Date().addingTimeInterval(Double(-dataDays) * 86400)),
            end:   Database.isoDate(Date()),
            interval: iv
        )
        let topics = Database.shared.getFocusTopicsWithStats(interval: iv)

        var ctx = "## 近\(dataDays)天活动统计\n"
        for s in stats {
            if let cat = s["category"] as? String, let mins = s["total_mins"] as? Int {
                ctx += "- \(cat): \(mins/60)h\(mins%60)m\n"
            }
        }
        ctx += "\n## 当前关注主题\n"
        for t in topics {
            if let name = t["name"] as? String, let cat = t["category"] as? String {
                let mins = t["total_mins"] as? Int ?? 0
                ctx += "- [\(cat)] \(name)（累计 \(mins/60)h）\n"
            }
        }

        let system = """
        你是用户的个人时间管理顾问。以下是用户的活动数据：

        \(ctx)

        请严格按照用户的指令执行任务，结合以上数据给出回答。用中文回答，语言简洁直接。
        """

        let messages: [[String: Any]] = [["role": "user", "content": prompt]]
        let content = try AIClient.chat(provider: provider, apiKey: apiKey,
                                        system: system, history: messages)

        Database.shared.addWisdom(content: content, prompt: prompt, dataDays: dataDays)
        ConfigStore.shared.aiLastRunDate = String(Database.isoNow().prefix(10))

        return try .json(["ok": true, "content": content, "generated_at": Database.isoNow()] as [String: Any])
    }

    static func aiChat(_ r: Req) throws -> APIResponse {
        guard let userMsg = r.str("message") else { throw APIError.bad("message required") }
        let providerName = r.str("provider") ?? ConfigStore.shared.aiProvider

        guard let provider = AIClient.Provider(rawValue: providerName) else {
            throw APIError.bad("unknown provider: \(providerName)")
        }
        let apiKey: String
        switch provider {
        case .deepseek:
            guard let k = ConfigStore.shared.deepseekApiKey else {
                throw APIError.bad("DeepSeek API Key 未配置")
            }
            apiKey = k
        case .kimi:
            guard let k = ConfigStore.shared.kimiApiKey else {
                throw APIError.bad("Kimi API Key 未配置")
            }
            apiKey = k
        }

        // Build activity context from DB
        let iv     = ConfigStore.shared.interval
        let stats  = Database.shared.categoryStats(
            start: Database.isoDate(Date().addingTimeInterval(-30 * 86400)),
            end:   Database.isoDate(Date()),
            interval: iv
        )
        let topics = Database.shared.getFocusTopicsWithStats(interval: iv)

        var ctx = "## 用户近30天活动统计\n"
        for s in stats {
            if let cat = s["category"] as? String, let mins = s["total_mins"] as? Int {
                ctx += "- \(cat): \(mins/60)h\(mins%60)m\n"
            }
        }
        ctx += "\n## 当前关注主题\n"
        for t in topics {
            if let name = t["name"] as? String, let cat = t["category"] as? String {
                let mins = t["total_mins"] as? Int ?? 0
                ctx += "- [\(cat)] \(name)（累计 \(mins/60)h）\n"
            }
        }

        let system = """
        你是用户的个人时间管理顾问。用户用 ActivityTracker 记录每天的时间使用情况。

        \(ctx)

        根据用户的问题，结合以上数据给出个性化建议。重点方向：
        - 推荐具体的学习资料（书籍、课程、文章、论文）
        - 推荐音频/视频资源（播客、YouTube 频道、B 站 UP 主、在线课程平台）
        - 建议要具体可执行，附上名称和理由，不要泛泛而谈
        用中文回答，语言简洁直接。
        """

        let history  = r.body["history"] as? [[String: Any]] ?? []
        var messages = history
        messages.append(["role": "user", "content": userMsg])

        let reply = try AIClient.chat(provider: provider, apiKey: apiKey,
                                      system: system, history: messages)

        var updated = messages
        updated.append(["role": "assistant", "content": reply])
        return try .json(["reply": reply, "history": updated])
    }

    // MARK: - Helpers
    // NSNull is kept as-is: JSONSerialization serializes it to JSON null correctly
    private static func nullToNil(_ row: [String: Any]) -> [String: Any] { row }
}

