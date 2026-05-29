import AppKit

struct DialogResult {
    let category: String
    let note: String
    let detail: String?
}

enum ActivityDialog {

    // Must be called on the main thread
    static func show(prompt: String, existing: [String: Any]?) -> DialogResult? {
        let cats = ConfigStore.shared.categories
        guard !cats.isEmpty else { return nil }
        let catNames = cats.map(\.name)

        let existingCat  = existing?["category"] as? String
        let existingNote = existing?["note"] as? String

        // ── Step 1: Category ──────────────────────────────────────
        let popup1 = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26), pullsDown: false)
        popup1.addItems(withTitles: catNames)
        if let ec = existingCat, let idx = catNames.firstIndex(of: ec) { popup1.selectItem(at: idx) }

        var info1 = "第一步：选择活动分类"
        if let ec = existingCat, let en = existingNote {
            info1 += "\n本时段已有：\(ec) · \(en)（将覆盖）"
        }

        let alert1 = NSAlert()
        alert1.messageText = prompt
        alert1.informativeText = info1
        alert1.addButton(withTitle: "下一步")
        alert1.addButton(withTitle: "跳过")
        alert1.accessoryView = popup1

        NSApp.activate(ignoringOtherApps: true)
        guard alert1.runModal() == .alertFirstButtonReturn else { return nil }
        let selectedCat = popup1.titleOfSelectedItem ?? catNames[0]

        // ── Step 2: Topic ─────────────────────────────────────────
        let prioPrefix = ["高": "★ ", "中": "", "低": "▽ "]
        let topics = Database.shared.getFocusTopicsByCategory(selectedCat)

        // Sort: priority order then frequency
        let prioOrder = ["高": 0, "中": 1, "低": 2]
        let sorted = topics.sorted {
            let pa = prioOrder[$0["priority"] as? String ?? "中"] ?? 1
            let pb = prioOrder[$1["priority"] as? String ?? "中"] ?? 1
            if pa != pb { return pa < pb }
            return ($0["cnt"] as? Int ?? 0) > ($1["cnt"] as? Int ?? 0)
        }

        var displayToName = [String: String]()
        var noteItems = [String]()
        for t in sorted {
            guard let name = t["name"] as? String else { continue }
            let prefix  = prioPrefix[t["priority"] as? String ?? "中"] ?? ""
            let display = prefix + name
            displayToName[display] = name
            noteItems.append(display)
        }

        // Fallback to recent notes if no topics defined
        if noteItems.isEmpty {
            let recent = Database.shared.recentNotes(categories: [selectedCat])
            for n in recent { displayToName[n] = n; noteItems.append(n) }
        }

        let CUSTOM = "✏  自定义输入…"
        noteItems.append(CUSTOM)

        let popup2 = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26), pullsDown: false)
        popup2.addItems(withTitles: noteItems)

        // Pre-select existing note
        if let en = existingNote {
            let defDisplay = displayToName.first(where: { $0.value == en })?.key ?? en
            if let idx = noteItems.firstIndex(of: defDisplay) { popup2.selectItem(at: idx) }
        }

        let alert2 = NSAlert()
        alert2.messageText = "⏱ \(selectedCat)"
        alert2.informativeText = "在做什么？（★ 高优先  ▽ 低优先  无标=中优先）"
        alert2.addButton(withTitle: "记录")
        alert2.addButton(withTitle: "跳过")
        alert2.accessoryView = popup2

        guard alert2.runModal() == .alertFirstButtonReturn else { return nil }
        let selectedDisplay = popup2.titleOfSelectedItem ?? CUSTOM

        if selectedDisplay == CUSTOM {
            guard let note = showCustomInput(category: selectedCat) else { return nil }
            return DialogResult(category: selectedCat, note: note, detail: nil)
        }

        let note = displayToName[selectedDisplay] ?? selectedDisplay
        return DialogResult(category: selectedCat, note: note, detail: nil)
    }

    private static func showCustomInput(category: String) -> String? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "请输入活动内容…"

        let alert = NSAlert()
        alert.messageText = "⏱ \(category)"
        alert.informativeText = "输入活动内容："
        alert.addButton(withTitle: "确认")
        alert.addButton(withTitle: "跳过")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

}
