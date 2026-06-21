import WebKit

// MARK: - WKScriptMessageHandlerWithReply bridge
// JS calls: window.webkit.messageHandlers.bridge.postMessage({method, path, params, body})
// Swift replies: {ok: true, data: ...} or {ok: false, error: "..."}

final class BridgeHandler: NSObject, WKScriptMessageHandlerWithReply {

    @MainActor
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let dict   = message.body as? [String: Any],
              let method = dict["method"] as? String,
              let path   = dict["path"]   as? String else {
            replyHandler(["ok": false, "error": "bad message format"], nil)
            return
        }

        let rawParams = dict["params"] as? [String: Any] ?? [:]
        let params    = rawParams.compactMapValues { $0 as? String }
        let bodyDict  = dict["body"] as? [String: Any] ?? [:]
        let bodyData  = try? JSONSerialization.data(withJSONObject: bodyDict)

        // AI endpoints: dispatch to background thread (network I/O), reply back on main
        if path.hasPrefix("/api/ai") {
            DispatchQueue.global(qos: .userInitiated).async {
                self.handle(method: method, path: path, params: params, bodyData: bodyData) { result, err in
                    DispatchQueue.main.async { replyHandler(result, err) }
                }
            }
        } else {
            handle(method: method, path: path, params: params, bodyData: bodyData, reply: replyHandler)
        }
    }

    private func handle(method: String, path: String, params: [String: String],
                        bodyData: Data?, reply: (Any?, String?) -> Void) {
        do {
            let resp = try route(method: method, path: path, query: params, bodyData: bodyData)
            if let json = try? JSONSerialization.jsonObject(with: resp.body) {
                reply(["ok": true, "data": json], nil)
            } else {
                reply(["ok": true, "data": String(data: resp.body, encoding: .utf8) ?? ""], nil)
            }
        } catch let e as APIError {
            reply(["ok": false, "error": e.message], nil)
        } catch {
            reply(["ok": false, "error": error.localizedDescription], nil)
        }
    }

    // MARK: - Router

    private static let routes: [(String, String, (Req) throws -> APIResponse)] = [
        ("GET",    "/api/meta",                            APIHandlers.meta),
        ("GET",    "/api/config/interval",                 APIHandlers.getInterval),
        ("POST",   "/api/config/interval",                 APIHandlers.setInterval),
        ("GET",    "/api/config/auto_popup",               APIHandlers.getAutoPopup),
        ("POST",   "/api/config/auto_popup",               APIHandlers.setAutoPopup),
        ("GET",    "/api/categories",                      APIHandlers.listCategories),
        ("POST",   "/api/categories/add",                  APIHandlers.addCategory),
        ("POST",   "/api/categories/update",               APIHandlers.updateCategory),
        ("POST",   "/api/categories/delete",               APIHandlers.deleteCategory),
        ("GET",    "/api/activities",                      APIHandlers.listActivities),
        ("GET",    "/api/activities/by_topic",             APIHandlers.activitiesByTopic),
        ("POST",   "/api/activities/check_conflicts",      APIHandlers.checkManualConflicts),
        ("POST",   "/api/activities/add_manual",           APIHandlers.addManual),
        ("PUT",    "/api/activities/{id}",                 APIHandlers.updateActivity),
        ("DELETE", "/api/activities/{id}",                 APIHandlers.deleteActivity),
        ("PATCH",  "/api/activities/{id}/detail",          APIHandlers.patchDetail),
        ("GET",    "/api/category_stats",                  APIHandlers.categoryStats),
        ("GET",    "/api/month_stats",                     APIHandlers.monthStats),
        ("GET",    "/api/focus_topics",                    APIHandlers.listFocusTopics),
        ("POST",   "/api/focus_topics",                    APIHandlers.addFocusTopic),
        ("GET",    "/api/focus_topics/archived",           APIHandlers.listArchivedTopics),
        ("POST",   "/api/focus_topics/{id}/archive",       APIHandlers.archiveTopic),
        ("POST",   "/api/focus_topics/{id}/unarchive",     APIHandlers.unarchiveTopic),
        ("PUT",    "/api/focus_topics/{id}",               APIHandlers.updateFocusTopic),
        ("DELETE", "/api/focus_topics/{id}",               APIHandlers.deleteFocusTopic),
        ("GET",    "/api/period_goals/archive",            APIHandlers.listPeriodGoalsArchive),
        ("GET",    "/api/period_goals/quotes",             APIHandlers.listDailyQuotes),
        ("GET",    "/api/tags",                            APIHandlers.listAllTags),
        ("DELETE", "/api/tags",                            APIHandlers.deleteTag),
        ("POST",   "/api/tags/exclude",                    APIHandlers.excludeTagActivity),
        ("GET",    "/api/activities/tagged",               APIHandlers.listTaggedActivities),
        ("PUT",    "/api/period_goals/quote",              APIHandlers.upsertDailyQuote),
        ("GET",    "/api/period_goals",                    APIHandlers.getPeriodGoals),
        ("PUT",    "/api/period_goals",                    APIHandlers.upsertPeriodGoals),
        ("GET",    "/api/export",                          APIHandlers.export),
        ("GET",    "/api/export_topic",                    APIHandlers.exportTopic),
        ("GET",    "/api/tasks",                           APIHandlers.listTasks),
        ("POST",   "/api/tasks",                           APIHandlers.createTask),
        ("PUT",    "/api/tasks/{id}",                      APIHandlers.updateTask),
        ("DELETE", "/api/tasks/{id}",                      APIHandlers.deleteTask),
        ("POST",   "/api/tasks/{id}/complete",             APIHandlers.completeTask),
        ("GET",    "/api/daily_plans",                     APIHandlers.listDailyPlans),
        ("POST",   "/api/daily_plans",                     APIHandlers.createDailyPlan),
        ("PUT",    "/api/daily_plans/{id}",                APIHandlers.updateDailyPlan),
        ("DELETE", "/api/daily_plans/{id}",                APIHandlers.deleteDailyPlan),
        ("GET",    "/api/day_activities",                  APIHandlers.listDayActivities),
        // AI Assistant (DeepSeek / Kimi)
        ("GET",    "/api/config/ai",                       APIHandlers.getAiConfig),
        ("POST",   "/api/config/ai",                       APIHandlers.setAiConfig),
        ("POST",   "/api/ai/chat",                         APIHandlers.aiChat),
        ("GET",    "/api/ai/wisdom",                       APIHandlers.listWisdom),
        ("POST",   "/api/ai/run_prompt",                   APIHandlers.runPrompt),
    ]

    private func route(method: String, path: String, query: [String: String],
                       bodyData: Data?) throws -> APIResponse {
        for (rm, pattern, handler) in Self.routes {
            if rm == method, let pathParams = matchPath(path: path, pattern: pattern) {
                var q = query
                pathParams.forEach { q[$0.key] = $0.value }
                let req = Req(method: method, path: path, query: q,
                              pathParams: pathParams, bodyData: bodyData)
                return try handler(req)
            }
        }
        throw APIError.notFound("Not Found: \(method) \(path)")
    }

    private func matchPath(path: String, pattern: String) -> [String: String]? {
        let ps = path.split(separator: "/", omittingEmptySubsequences: true)
        let ts = pattern.split(separator: "/", omittingEmptySubsequences: true)
        guard ps.count == ts.count else { return nil }
        var params = [String: String]()
        for (p, t) in zip(ps, ts) {
            if t.hasPrefix("{") && t.hasSuffix("}") {
                params[String(t.dropFirst().dropLast())] = String(p)
            } else if p != t {
                return nil
            }
        }
        return params
    }
}
