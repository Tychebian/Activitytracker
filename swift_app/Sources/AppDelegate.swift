import AppKit
import WebKit
import UserNotifications
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var dashboardWindow: NSWindow?
    private var webView: WKWebView?
    private var timer: ResettableTimer?
    private let dialogLock = NSLock()

    // MARK: - Launch

    func applicationDidFinishLaunching(_ n: Notification) {
        Database.shared.initializeSchema()
        registerLoginItem()
        setupStatusItem()
        setupTimer()
        showDashboard()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    // MARK: - WKNavigationDelegate
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Page loaded — nothing extra needed; JS init calls setView('day') on its own
    }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showDashboard() }
        return true
    }

    // MARK: - Login Item (SMAppService — macOS 13+)

    private func registerLoginItem() {
        let svc = SMAppService.mainApp
        if svc.status == .notRegistered {
            try? svc.register()
        }
    }

    // MARK: - Menu bar

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(makeItem("记录当前活动…", sel: #selector(manualPrompt)))
        menu.addItem(makeItem("查看 Dashboard",  sel: #selector(openDashboard)))
        menu.addItem(.separator())
        menu.addItem(makeItem("退出",            sel: #selector(quitApp), key: "q"))
        return menu
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = "⏱"
        statusItem.isVisible = true
        statusItem.menu = buildMenu()
        try? "setupStatusItem called, isVisible=\(statusItem.isVisible), button=\(String(describing: statusItem.button))\n"
            .write(toFile: "/tmp/at_statusitem_debug.txt", atomically: true, encoding: .utf8)
    }

    // Dock right-click menu (bug 1 fix)
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { buildMenu() }

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
                                            detail: result.detail, slotStart: slotStart)
        timer?.resetFromNow()

        // Refresh dashboard if open
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript("if(typeof render === 'function') render();", completionHandler: nil)
        }

        // Notification
        let content = UNMutableNotificationContent()
        content.title = "✓ \(result.category)"
        content.body  = result.note
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    // MARK: - Dashboard window

    func showDashboard() {
        if dashboardWindow == nil {
            dashboardWindow = makeDashboard()
        }
        dashboardWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // NSWindowDelegate — intercept close and hide instead of destroying the window.
    // Destroying a window while WKWebView's WebCore threads are running causes
    // _NSWindowTransformAnimation to hold a zeroing-weak-ref to a CA layer that
    // WebCore can free first, producing a SIGSEGV on the animation's dealloc path.
    // Keeping the window + webView alive for the app's lifetime eliminates this entirely.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    private func makeDashboard() -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1020, height: 760),
            styleMask:   [.titled, .closable, .miniaturizable, .resizable],
            backing:     .buffered,
            defer:       false
        )
        win.title             = "活动记录"
        win.minSize           = NSSize(width: 700, height: 500)
        win.delegate          = self
        win.center()

        // WebView + JS↔Swift message bridge
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.addScriptMessageHandler(
            BridgeHandler(), contentWorld: .page, name: "bridge"
        )

        let wv = WKWebView(frame: win.contentView!.bounds, configuration: cfg)
        wv.autoresizingMask = [.width, .height]
        wv.navigationDelegate = self
        win.contentView?.addSubview(wv)

        // Load HTML directly from bundle (no custom URL scheme needed)
        if let htmlURL = Bundle.main.url(forResource: "index", withExtension: "html") {
            wv.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        }
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
