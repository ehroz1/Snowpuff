import AppKit

/// The path the crash handler marks, set once at start so the handler itself only makes system calls.
private var crashMarker: UnsafeMutablePointer<CChar>?

/// Runs inside a crash: leaves the marker for the watchdog and lets the crash go on as it would have.
private func crashed(_ signal: Int32) {
    if let marker = crashMarker {
        let file = open(marker, O_CREAT | O_WRONLY, 0o644)
        if file >= 0 { close(file) }
    }
    Darwin.signal(signal, SIG_DFL)
    raise(signal)
}

/// Should Snowpuff ever crash, it opens again by itself instead of leaving the screen bare until someone notices.
/// A small watchdog waits for this process to end and reopens the app only if a crash handler marked it: quitting,
/// updating, logging out or a force quit leave no mark and stay quit. Three crashes within ten minutes stop the
/// reopening for that run, so a crash at start can't loop.
enum CrashGuard {
    static func start() {
        let folder = SettingsFile.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let marker = folder.appendingPathComponent("crashed")
        let history = folder.appendingPathComponent("crashes")
        let files = FileManager.default

        var recent: [TimeInterval] = []
        if let text = try? String(contentsOf: history, encoding: .utf8) {
            recent = text.split(separator: "\n").compactMap { TimeInterval($0) }
        }
        let now = Date().timeIntervalSince1970
        recent = recent.filter { now - $0 < 600 }
        if files.fileExists(atPath: marker.path) {
            NSLog("Snowpuff: reopened after a crash")
            recent.append(now)
            try? files.removeItem(at: marker)
        }
        try? recent.map { String($0) }.joined(separator: "\n").write(to: history, atomically: true, encoding: .utf8)

        crashMarker = strdup(marker.path)
        for signal in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE] {
            Darwin.signal(signal, crashed)
        }
        guard recent.count < 3 else {
            NSLog("Snowpuff: crashed \(recent.count) times in ten minutes; not reopening after the next one")
            return
        }
        watch(marker: marker)
    }

    private static func watch(marker: URL) {
        let script = """
        if [ -x /usr/bin/pwait ]; then /usr/bin/pwait "$1" 2>/dev/null; fi
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 5; done
        [ -f "$2" ] && /usr/bin/open -g "$3"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "snowpuff-watchdog", String(ProcessInfo.processInfo.processIdentifier), marker.path, Bundle.main.bundlePath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSLog("Snowpuff: no crash watchdog: \(error)")
        }
    }
}
