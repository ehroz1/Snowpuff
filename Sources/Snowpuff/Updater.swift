import AppKit
import CryptoKit

/// Updates from GitHub releases: the latest release's `Snowpuff.zip` is downloaded, checked against the SHA-256
/// GitHub reports for it, unpacked, checked again as an app, put in place of this one and opened.
final class Updater {
    static let repository = "ehroz1/Snowpuff"
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private static let asset = "Snowpuff.zip"
    /// How often a running Snowpuff looks for a new version.
    private static let interval: TimeInterval = 3 * 60 * 60

    struct Release {
        let version: String
        let url: URL
        let digest: String?
    }

    /// A newer version found while automatic updates are off, offered in the menu.
    private(set) var available: Release?
    private(set) var isBusy = false
    /// Not now: a call is on, say.
    var mayInstallQuietly: () -> Bool = { true }
    private var timer: Timer?
    private var lastChecked: Date?

    func start() {
        // The first look waits until the snow has settled in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.check(asked: false) }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in self?.check(asked: false) }
    }

    /// A Mac that slept through the timer looks once it wakes, if the last look was a while ago.
    func checkIfDue() {
        guard let lastChecked, Date().timeIntervalSince(lastChecked) > 60 * 60 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.check(asked: false) }
    }

    /// `asked` is a check from the menu, which answers even when there's nothing new.
    func check(asked: Bool) {
        lastChecked = Date()
        if let available, asked {
            install(available, asked: true)
            return
        }
        guard !isBusy else { return }
        isBusy = true
        Task {
            let result: Result<Release?, Error>
            do { result = .success(try await Self.latest()) } catch { result = .failure(error) }
            await MainActor.run { self.checked(result, asked: asked) }
        }
    }

    private func checked(_ result: Result<Release?, Error>, asked: Bool) {
        isBusy = false
        switch result {
        case .success(let release?):
            NSLog("Snowpuff: update available: \(release.version)")
            if asked {
                if confirm(release) { install(release, asked: true) } else { available = release }
            } else if Preferences.autoUpdate && mayInstallQuietly() {
                install(release, asked: false)
            } else {
                available = release
            }
        case .success(nil):
            if asked {
                tell(tr("Snowpuff \(Self.version) is the latest version.", "У тебя последняя версия Snowpuff — \(Self.version)."), style: .informational)
            }
        case .failure(let error):
            NSLog("Snowpuff: update check failed: \(error)")
            if asked { tell(tr("Couldn't check for updates.", "Не получилось проверить обновления.") + "\n\n" + error.localizedDescription, style: .warning) }
        }
    }

    private func install(_ release: Release, asked: Bool) {
        guard !isBusy else { return }
        isBusy = true
        NSLog("Snowpuff: installing \(release.version)")
        Task {
            do {
                let app = try await Self.prepare(release)
                await MainActor.run { Self.replaceAndRelaunch(with: app) }
            } catch {
                NSLog("Snowpuff: update failed: \(error)")
                await MainActor.run {
                    self.isBusy = false
                    self.available = release
                    if asked {
                        self.tell(tr("Couldn't update Snowpuff.", "Не получилось обновить Snowpuff.") + "\n\n" + error.localizedDescription, style: .warning)
                    }
                }
            }
        }
    }

    // MARK: - GitHub

    private static func latest() async throws -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Snowpuff/\(version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else { throw Failure(tr("GitHub answered \(status).", "GitHub ответил \(status).")) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]]
        else { throw Failure(tr("GitHub's answer is unreadable.", "Ответ GitHub не читается.")) }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard newer(version, than: Self.version),
              let asset = assets.first(where: { $0["name"] as? String == Self.asset }),
              let link = asset["browser_download_url"] as? String,
              let url = URL(string: link), url.scheme == "https", url.host == "github.com"
        else { return nil }
        let digest = (asset["digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)).lowercased() : nil }
        return Release(version: version, url: url, digest: digest)
    }

    static func newer(_ candidate: String, than current: String) -> Bool {
        let parse = { (version: String) -> [Int] in
            let parts = version.split(separator: ".").map { Int($0) ?? 0 }
            return (parts + [0, 0, 0]).prefix(3).map { $0 }
        }
        return parse(current).lexicographicallyPrecedes(parse(candidate))
    }

    // MARK: - Installing

    /// Downloads, checks and unpacks the release next to this app, so moving it in is a rename on the same disk.
    private static func prepare(_ release: Release) async throws -> URL {
        let (download, response) = try await URLSession.shared.download(from: release.url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(tr("The download failed.", "Скачать не получилось.")) }
        let data = try Data(contentsOf: download, options: .mappedIfSafe)
        if let digest = release.digest {
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard hash == digest else { throw Failure(tr("The download doesn't match the release.", "Скачанный файл не совпадает с релизом.")) }
        }

        let files = FileManager.default
        let current = Bundle.main.bundleURL
        let folder = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: current, create: true)
        let zip = folder.appendingPathComponent(asset)
        try data.write(to: zip)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path])
        let app = folder.appendingPathComponent("Snowpuff.app")
        guard let bundle = Bundle(url: app),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              version == release.version
        else { throw Failure(tr("The download isn't Snowpuff \(release.version).", "В архиве не Snowpuff \(release.version).")) }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    /// Swaps the new app in for this one, then opens it once this process is gone.
    private static func replaceAndRelaunch(with app: URL) {
        let current = Bundle.main.bundleURL
        do {
            _ = try FileManager.default.replaceItemAt(current, withItemAt: app)
        } catch {
            NSLog("Snowpuff: could not replace the app: \(error)")
            NSWorkspace.shared.open(URL(string: "https://github.com/\(repository)/releases/latest")!)
            return
        }
        let script = """
        while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.1; done
        /usr/bin/open "$1"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "updater", current.path]
        try? process.run()
        NSApp.terminate(nil)
    }

    private static func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure("\((path as NSString).lastPathComponent) failed (\(process.terminationStatus))")
        }
    }

    // MARK: - Alerts

    private func confirm(_ release: Release) -> Bool {
        let alert = NSAlert()
        alert.messageText = tr("Snowpuff \(release.version) is out", "Вышел Snowpuff \(release.version)")
        alert.informativeText = tr(
            "You have \(Self.version). Snowpuff restarts in a couple of seconds after the update.",
            "У тебя \(Self.version). После обновления Snowpuff перезапустится через пару секунд."
        )
        alert.addButton(withTitle: tr("Update", "Обновить"))
        alert.addButton(withTitle: tr("Later", "Позже"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func tell(_ text: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = "Snowpuff"
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }
}
