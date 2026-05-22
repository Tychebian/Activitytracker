import Foundation

enum LaunchAgent {
    private static let label = "com.activitytracker.tracker"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func ensureRegistered() {
        let execPath = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]
        let logDir   = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".activity_tracker").path

        // Check if existing plist already points to this executable
        if FileManager.default.fileExists(atPath: plistURL.path),
           let existing = try? String(contentsOf: plistURL, encoding: .utf8),
           existing.contains(execPath) {
            return  // already correct — nothing to do
        }

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
          "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key>
          <array><string>\(execPath)</string></array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <key>StandardErrorPath</key><string>\(logDir)/error.log</string>
          <key>StandardOutPath</key><string>\(logDir)/output.log</string>
        </dict></plist>
        """
        try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        // Unload old agent first (ignore errors if not loaded)
        let unload = Process()
        unload.launchPath = "/bin/launchctl"
        unload.arguments  = ["unload", plistURL.path]
        try? unload.run(); unload.waitUntilExit()

        try? plist.write(to: plistURL, atomically: true, encoding: .utf8)

        let load = Process()
        load.launchPath = "/bin/launchctl"
        load.arguments  = ["load", plistURL.path]
        try? load.run()
    }
}
