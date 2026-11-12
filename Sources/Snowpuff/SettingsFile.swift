import AppKit
import ServiceManagement

/// Every setting is also kept in `~/Library/Application Support/Snowpuff/settings.json`. Removing the app leaves the
/// file behind, so Snowpuff installed again (or on another Mac, with the file copied over) starts with every choice
/// it had, Open at Login included.
enum SettingsFile {
    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Snowpuff", isDirectory: true)
    static let url = folder.appendingPathComponent("settings.json")

    /// The preferences the file carries.
    private static let keys = [
        "snowfall", "behindWindows", "meltSnow", "accumulate", "snowOnWindows", "welcomed", "showInScreenshots",
        "icicles", "warmGlow", "puff", "quietOnCalls", "ambience", "ambienceVolume", "autoUpdate", "overFullScreen",
        "rain", "maxPerformance", "autumn", "addedToLoginItems",
    ]
    private static var pending: DispatchWorkItem?
    private static var observer: NSObjectProtocol?

    /// A fresh install with a file left from before takes its settings from the file. Runs before the defaults
    /// are registered, so a setting that was never changed still counts as unset here.
    static func restoreIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "welcomed") == nil,
              let data = try? Data(contentsOf: url),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        for key in keys {
            if let value = saved[key] { defaults.set(value, forKey: key) }
        }
        if let login = saved["openAtLogin"] as? Bool {
            defaults.set(true, forKey: "addedToLoginItems")
            do {
                if login, SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
                if !login, SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Snowpuff: Open at Login not restored: \(error)")
            }
        }
        NSLog("Snowpuff: settings restored from \(url.path)")
    }

    /// Writes the file now and again a moment after any setting changes.
    static func startSaving() {
        save()
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            scheduleSave()
        }
    }

    /// Open at Login lives with the system, not in the defaults: whoever changes it saves.
    static func scheduleSave() {
        pending?.cancel()
        let work = DispatchWorkItem { save() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    static func save() {
        let defaults = UserDefaults.standard
        var values: [String: Any] = [:]
        for key in keys {
            if let value = defaults.object(forKey: key) { values[key] = value }
        }
        values["openAtLogin"] = SMAppService.mainApp.status == .enabled
        values["version"] = Updater.version
        guard JSONSerialization.isValidJSONObject(values),
              let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Snowpuff: settings file not saved: \(error)")
        }
    }
}
