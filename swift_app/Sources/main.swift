import AppKit

// MARK: - Singleton guard (PID file)

private let pidFilePath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".activity_tracker/tracker.pid").path

private func cleanupPID() { try? FileManager.default.removeItem(atPath: pidFilePath) }

private func ensureSingleton() -> Bool {
    if let existing = try? String(contentsOfFile: pidFilePath, encoding: .utf8),
       let pid = pid_t(existing.trimmingCharacters(in: .whitespacesAndNewlines)) {
        if kill(pid, 0) == 0 {
            // Another instance is running
            return false
        }
    }
    try? FileManager.default.createDirectory(
        atPath: (pidFilePath as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true)
    try? String(ProcessInfo.processInfo.processIdentifier)
        .write(toFile: pidFilePath, atomically: true, encoding: .utf8)
    atexit(cleanupPID)
    return true
}

// MARK: - Entry point

guard ensureSingleton() else {
    // Already running — nothing to do (macOS will bring existing window to front via Reopen)
    exit(0)
}

let app      = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
