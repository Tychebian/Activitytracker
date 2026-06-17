import WebKit

// MARK: - WKURLSchemeHandler

final class SchemeHandler: NSObject, WKURLSchemeHandler {

    // JS patch injected before page loads:
    // moves fetch() body to X-Body-Payload header (WKWebView strips httpBody)
static let fetchPatchScript = """
(function() {
    const _orig = window.fetch;
    window.fetch = function(url, opts) {
        opts = Object.assign({}, opts || {});
        const method = (opts.method || 'GET').toUpperCase();
        if (opts.body && ['POST','PUT','PATCH','DELETE'].includes(method)) {
            opts.headers = Object.assign({}, opts.headers || {});
            // Use encodeURIComponent so non-ASCII chars (e.g. Chinese) survive HTTP headers
            const body = typeof opts.body === 'string' ? opts.body : JSON.stringify(opts.body);
            opts.headers['X-Body-Payload'] = encodeURIComponent(body);
            opts.body = undefined;
        }
        return _orig.call(this, url, opts);
    };
})();
"""

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }

        let path   = url.path.isEmpty ? "/" : url.path
        let method = task.request.httpMethod ?? "GET"

        // Body comes via custom header (percent-encoded to preserve non-ASCII chars)
        let bodyData: Data? = task.request.value(forHTTPHeaderField: "X-Body-Payload")
            .flatMap { $0.removingPercentEncoding }?
            .data(using: .utf8)

        // Root → serve index.html
        if path == "/" || path == "" {
            serveHTML(task: task, url: url)
            return
        }

        // Parse query params
        var queryItems = [String: String]()
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let items = comps.queryItems {
            for item in items { queryItems[item.name] = item.value ?? "" }
        }

        // Try to match a route
        do {
            let response = try route(method: method, path: path,
                                      query: queryItems, bodyData: bodyData)
            send(task: task, url: url, response: response)
        } catch let e as APIError {
            let r = try? APIResponse.err(e)
            send(task: task, url: url, response: r ?? .text("Error", status: e.statusCode))
        } catch {
            let r = try? APIResponse.json(["error": error.localizedDescription], status: 500)
            send(task: task, url: url, response: r ?? .text("Internal error", status: 500))
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    // MARK: - Router

    private static let routes: [(String, String, (Req) throws -> APIResponse)] = [
        ("GET",    "/api/meta",                   APIHandlers.meta),
        ("GET",    "/api/config/interval",        APIHandlers.getInterval),
        ("POST",   "/api/config/interval",        APIHandlers.setInterval),
        ("GET",    "/api/config/auto_popup",      APIHandlers.getAutoPopup),
        ("POST",   "/api/config/auto_popup",      APIHandlers.setAutoPopup),
        ("GET",    "/api/categories",             APIHandlers.listCategories),
        ("POST",   "/api/categories/add",         APIHandlers.addCategory),
        ("POST",   "/api/categories/update",      APIHandlers.updateCategory),
        ("POST",   "/api/categories/delete",      APIHandlers.deleteCategory),
        ("GET",    "/api/activities",             APIHandlers.listActivities),
        ("GET",    "/api/activities/by_topic",    APIHandlers.activitiesByTopic),
        ("POST",   "/api/activities/add_manual",  APIHandlers.addManual),
        ("PUT",    "/api/activities/{id}",        APIHandlers.updateActivity),
        ("DELETE", "/api/activities/{id}",        APIHandlers.deleteActivity),
        ("PATCH",  "/api/activities/{id}/detail", APIHandlers.patchDetail),
        ("GET",    "/api/category_stats",         APIHandlers.categoryStats),
        ("GET",    "/api/month_stats",            APIHandlers.monthStats),
        ("GET",    "/api/focus_topics",                    APIHandlers.listFocusTopics),
        ("POST",   "/api/focus_topics",                    APIHandlers.addFocusTopic),
        ("GET",    "/api/focus_topics/archived",           APIHandlers.listArchivedTopics),
        ("POST",   "/api/focus_topics/{id}/archive",       APIHandlers.archiveTopic),
        ("POST",   "/api/focus_topics/{id}/unarchive",     APIHandlers.unarchiveTopic),
        ("PUT",    "/api/focus_topics/{id}",               APIHandlers.updateFocusTopic),
        ("DELETE", "/api/focus_topics/{id}",               APIHandlers.deleteFocusTopic),
        ("GET",    "/api/period_goals/archive",            APIHandlers.listPeriodGoalsArchive),
        ("GET",    "/api/period_goals",                    APIHandlers.getPeriodGoals),
        ("PUT",    "/api/period_goals",                    APIHandlers.upsertPeriodGoals),
        ("GET",    "/api/export",                 APIHandlers.export),
        ("GET",    "/api/export_topic",           APIHandlers.exportTopic),
        ("GET",    "/api/tasks",                  APIHandlers.listTasks),
        ("POST",   "/api/tasks",                  APIHandlers.createTask),
        ("PUT",    "/api/tasks/{id}",             APIHandlers.updateTask),
        ("DELETE", "/api/tasks/{id}",             APIHandlers.deleteTask),
        ("POST",   "/api/tasks/{id}/complete",    APIHandlers.completeTask),
        ("GET",    "/api/daily_plans",            APIHandlers.listDailyPlans),
        ("POST",   "/api/daily_plans",            APIHandlers.createDailyPlan),
        ("PUT",    "/api/daily_plans/{id}",       APIHandlers.updateDailyPlan),
        ("DELETE", "/api/daily_plans/{id}",       APIHandlers.deleteDailyPlan),
        ("GET",    "/api/day_activities",         APIHandlers.listDayActivities),
    ]

    private func route(method: String, path: String, query: [String: String], bodyData: Data?) throws -> APIResponse {
        for (rm, pattern, handler) in Self.routes {
            if rm == method, let pathParams = matchPath(path: path, pattern: pattern) {
                var q = query
                pathParams.forEach { q[$0.key] = $0.value }  // merge path params into query
                let req = Req(method: method, path: path, query: q, pathParams: pathParams, bodyData: bodyData)
                return try handler(req)
            }
        }
        throw APIError.notFound("Not Found")
    }

    // Pattern matching: /api/focus_topics/{id} against /api/focus_topics/42
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

    // MARK: - Serve HTML

    private func serveHTML(task: WKURLSchemeTask, url: URL) {
        guard let htmlURL = Bundle.main.url(forResource: "index", withExtension: "html"),
              let data = try? Data(contentsOf: htmlURL) else {
            send(task: task, url: url, response: .text("index.html not found", status: 404))
            return
        }
        send(task: task, url: url, response: .html(data))
    }

    // MARK: - Send response

    private func send(task: WKURLSchemeTask, url: URL, response: APIResponse) {
        let httpResp = HTTPURLResponse(
            url: url,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type":                response.contentType,
                "Access-Control-Allow-Origin": "*",
                "Cache-Control":               "no-cache",
            ]
        )!
        task.didReceive(httpResp)
        task.didReceive(response.body)
        task.didFinish()
    }
}
