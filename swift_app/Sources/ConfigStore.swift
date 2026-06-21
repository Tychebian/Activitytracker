import Foundation

struct Category: Codable {
    var name: String
    var color: String
}

private struct RawConfig: Codable {
    var categories: [Category]
    var interval: Int
    var auto_popup: Bool
    var ai_provider: String?
    var deepseek_api_key: String?
    var kimi_api_key: String?
    var ai_prompt: String?
    var ai_data_days: Int?
    var ai_frequency: String?
    var ai_last_run_date: String?
}

final class ConfigStore {
    static let shared = ConfigStore()
    static let version = "2.3.0"

    private let path: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".activity_tracker/config.json")

    private static let palette = [
        "#c8320a","#1a5fa3","#6b1a8a","#b07a10","#c83264",
        "#2a8a50","#c87820","#1a7a8a","#8a3a10","#5a1a6b",
        "#a05010","#105a8a","#8a104a","#4a8a10","#c84820",
    ]
    private static let defaultCategories: [Category] = [
        .init(name: "工作",         color: "#c8320a"),
        .init(name: "学习",         color: "#1a5fa3"),
        .init(name: "浪费时间",     color: "#6b1a8a"),
        .init(name: "运动",         color: "#b07a10"),
        .init(name: "和11妹在一起", color: "#c83264"),
    ]

    private func load() -> RawConfig {
        if let data = try? Data(contentsOf: path),
           let cfg = try? JSONDecoder().decode(RawConfig.self, from: data) { return cfg }
        return RawConfig(categories: Self.defaultCategories, interval: 20, auto_popup: true)
    }

    private func save(_ cfg: RawConfig) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(cfg) else { return }
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        try? data.write(to: path, options: .atomic)
    }

    // MARK: - Public accessors

    var categories: [Category] { load().categories }

    var interval: Int {
        get { load().interval }
        set { var c = load(); c.interval = newValue; save(c) }
    }

    var autoPopup: Bool {
        get { load().auto_popup }
        set { var c = load(); c.auto_popup = newValue; save(c) }
    }

    var aiProvider: String {
        get { load().ai_provider ?? "deepseek" }
        set { var c = load(); c.ai_provider = newValue; save(c) }
    }

    var deepseekApiKey: String? {
        get { load().deepseek_api_key.flatMap { $0.isEmpty ? nil : $0 } }
        set { var c = load(); c.deepseek_api_key = newValue; save(c) }
    }

    var kimiApiKey: String? {
        get { load().kimi_api_key.flatMap { $0.isEmpty ? nil : $0 } }
        set { var c = load(); c.kimi_api_key = newValue; save(c) }
    }

    var aiPrompt: String? {
        get { load().ai_prompt.flatMap { $0.isEmpty ? nil : $0 } }
        set { var c = load(); c.ai_prompt = newValue; save(c) }
    }

    var aiDataDays: Int {
        get { load().ai_data_days ?? 1 }
        set { var c = load(); c.ai_data_days = max(1, newValue); save(c) }
    }

    var aiFrequency: String {
        get { load().ai_frequency ?? "daily" }
        set { var c = load(); c.ai_frequency = newValue; save(c) }
    }

    var aiLastRunDate: String? {
        get { load().ai_last_run_date }
        set { var c = load(); c.ai_last_run_date = newValue; save(c) }
    }

    var categoryColors: [String: String] {
        Dictionary(uniqueKeysWithValues: categories.map { ($0.name, $0.color) })
    }

    // MARK: - Category CRUD

    func addCategory(name: String, color: String?) throws -> Category {
        var cfg = load()
        guard !cfg.categories.contains(where: { $0.name == name })
        else { throw APIError.conflict("category '\(name)' already exists") }
        let used = cfg.categories.map(\.color)
        let c = color ?? Self.palette.first(where: { !used.contains($0) })
                      ?? Self.palette[used.count % Self.palette.count]
        let entry = Category(name: name, color: c)
        cfg.categories.append(entry)
        save(cfg)
        return entry
    }

    @discardableResult
    func updateCategory(oldName: String, newName: String?, color: String?) throws -> String {
        var cfg = load()
        guard let idx = cfg.categories.firstIndex(where: { $0.name == oldName })
        else { throw APIError.notFound("category '\(oldName)' not found") }
        if let n = newName, !n.isEmpty, n != oldName { cfg.categories[idx].name = n }
        if let c = color, !c.isEmpty { cfg.categories[idx].color = c }
        let resolved = cfg.categories[idx].name
        save(cfg)
        return resolved
    }

    func deleteCategory(name: String) throws {
        var cfg = load()
        let remaining = cfg.categories.filter { $0.name != name }
        guard !remaining.isEmpty else { throw APIError.bad("cannot delete the last category") }
        cfg.categories = remaining
        save(cfg)
    }
}
