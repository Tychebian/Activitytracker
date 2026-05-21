import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var dashboardWindow: NSWindow?
    private var webView: WKWebView?
    private var timer: ResettableTimer?
    private let dialogLock = NSLock()

    // MARK: - Launch

    func applicationDidFinishLaunching(_ n: Notification) {
        Database.shared.initializeSchema()
        LaunchAgent.ensureRegistered()
        setupStatusItem()
        setupTimer()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showDashboard() }
        return true
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⏱"
        let menu = NSMenu()
        menu.addItem(makeItem("记录当前活动…", sel: #selector(manualPrompt)))
        menu.addItem(makeItem("查看 Dashboard",  sel: #selector(openDashboard)))
        menu.addItem(.separator())
        menu.addItem(makeItem("退出",            sel: #selector(quitApp), key: "q"))
        statusItem.menu = menu
    }

    private func makeItem(_ title: String, sel: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func manualPrompt() { triggerDialog(force: true) }
    @objc private func openDashboard() { showDashboard() }
    @objc private func quitApp() { NSApp.terminate(nil) }

    // MARK: - Timer

    private func setupTimer() {
        timer = ResettableTimer { [weak self] in self?.onTimerFired() }
    }

    private func onTimerFired() {
        guard ConfigStore.shared.autoPopup else { return }
        triggerDialog(force: false)
    }

    func triggerDialog(force: Bool) {
        // Acquire lock on caller thread to prevent double-prompt
        guard dialogLock.try() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { self?.dialogLock.unlock(); return }
            defer { self.dialogLock.unlock() }
            self.runDialog(force: force)
        }
    }

    private func runDialog(force: Bool) {
        let now       = Date()
        let slotStart = now.slotStart
        let existing  = Database.shared.getSlotRecord(slotStart: slotStart)

        if !force, existing != nil {
            timer?.resetFromNow()
            return
        }

        guard let result = ActivityDialog.show(prompt: "现在 \(now.hhmm)，你在做什么？",
                                               existing: existing) else { return }
        Database.shared.saveActivityForSlot(category: result.category, note: result.note,
                                            slotStart: slotStart)
        timer?.resetFromNow()

        // Refresh dashboard if open
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript("if(typeof render === 'function') render();", completionHandler: nil)
        }

        // Notification
        let n = NSUserNotification()
        n.title   = "✓ \(result.category)"
        n.informativeText = result.note
        n.soundName = nil
        NSUserNotificationCenter.default.deliver(n)
    }

    // MARK: - Dashboard window

    func showDashboard() {
        if dashboardWindow == nil {
            dashboardWindow = makeDashboard()
        }
        dashboardWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeDashboard() -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1020, height: 760),
            styleMask:   [.titled, .closable, .miniaturizable, .resizable],
            backing:     .buffered,
            defer:       false
        )
        win.title   = "活动记录"
        win.minSize = NSSize(width: 700, height: 500)
        win.center()

        // WebView + custom scheme
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(SchemeHandler(), forURLScheme: "activitytracker")

        // Patch fetch() to pass body via header (WKWebView strips httpBody)
        let script = WKUserScript(source: SchemeHandler.fetchPatchScript,
                                  injectionTime: .atDocumentStart,
                                  forMainFrameOnly: true)
        cfg.userContentController.addUserScript(script)

        let wv = WKWebView(frame: win.contentView!.bounds, configuration: cfg)
        wv.autoresizingMask = [.width, .height]
        win.contentView?.addSubview(wv)

        // Load entry point — relative fetch('/api/…') resolves to activitytracker://app/api/…
        wv.load(URLRequest(url: URL(string: "activitytracker://app/")!))
        self.webView = wv
        return win
    }
}

// MARK: - ResettableTimer

final class ResettableTimer {
    private let callback: () -> Void
    private var nextFire: Date
    private let sem = DispatchSemaphore(value: 0)
    private var stopped = false

    init(callback: @escaping () -> Void) {
        self.callback = callback
        self.nextFire = Date().addingTimeInterval(Double(ConfigStore.shared.interval) * 60)
        let t = Thread { [weak self] in self?.loop() }
        t.name = "activity-timer"
        t.start()
    }

    private func loop() {
        while !stopped {
            let remaining = nextFire.timeIntervalSinceNow
            if remaining <= 0 {
                nextFire = Date().addingTimeInterval(Double(ConfigStore.shared.interval) * 60)
                callback()
            } else {
                _ = sem.wait(timeout: .now() + min(remaining, 10))
            }
        }
    }

    func resetFromNow() {
        nextFire = Date().addingTimeInterval(Double(ConfigStore.shared.interval) * 60)
        sem.signal()
    }

    deinit { stopped = true; sem.signal() }
}

// MARK: - Date helpers

extension Date {
    var slotStart: Date {
        var c = Calendar.current.dateComponents([.year,.month,.day,.hour,.minute], from: self)
        c.minute = ((c.minute ?? 0) / 15) * 15
        c.second = 0
        return Calendar.current.date(from: c) ?? self
    }
    var hhmm: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: self)
    }
}
