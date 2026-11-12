import AppKit
import ServiceManagement
import SwiftUI

/// What falls.
enum SnowMode: Int, CaseIterable, Identifiable {
    case snow, autumn, rain
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .snow: tr("Snow", "Снег")
        case .autumn: tr("Autumn Leaves", "Осенние листья")
        case .rain: tr("Rain", "Дождь")
        }
    }
}

/// What the settings window and the onboarding change; the app delegate carries it out.
protocol SnowControls: AnyObject {
    func setSnowfall(_ snowfall: Snowfall)
    func setMode(_ mode: SnowMode)
    func setAccumulate(_ on: Bool)
    func setMelt(_ on: Bool)
    func setSnowOnWindows(_ on: Bool)
    func setIcicles(_ on: Bool)
    func setWarmGlow(_ on: Bool)
    func setPuff(_ on: Bool, done: @escaping (Bool) -> Void)
    func setSound(_ mode: Ambience.Mode)
    func setVolume(_ volume: Float)
    func setQuietOnCalls(_ on: Bool)
    func setBehindWindows(_ on: Bool)
    func setOverFullScreen(_ on: Bool)
    func setShowInScreenshots(_ on: Bool)
    func setMaxPerformance(_ on: Bool)
    func setOpenAtLogin(_ on: Bool)
    func setAutoUpdate(_ on: Bool)
    func clearSnow()
    func checkForUpdates()
}

/// The night palette of snowpuff.ehroz.pro, shared by the app's windows: a cold blue night, cream text and the
/// window's amber as the one warm colour.
enum Night {
    static let deep = Color(red: 0.043, green: 0.063, blue: 0.09)
    static let background = Color(red: 0.067, green: 0.094, blue: 0.137)
    static let raised = Color(red: 0.09, green: 0.125, blue: 0.188)
    static let horizon = Color(red: 0.11, green: 0.165, blue: 0.243)
    static let amber = Color(red: 0.949, green: 0.706, blue: 0.361)
    static let cream = Color(red: 0.965, green: 0.906, blue: 0.812)
    static let ink = Color(red: 0.914, green: 0.929, blue: 0.953)
    static let muted = Color(red: 0.84, green: 0.87, blue: 0.92).opacity(0.72)
    static let snow = Color(red: 0.957, green: 0.969, blue: 0.984)
    static let label = Color(red: 0.165, green: 0.086, blue: 0.051)
}

/// Every setting the windows show, read from the preferences and passed to the app as it changes.
final class SettingsModel: ObservableObject {
    weak var controls: SnowControls?
    /// Set while the values are read back, so reading doesn't count as a change.
    private var loading = false

    @Published var snowfall = Snowfall.steady { didSet { changed(oldValue != snowfall) { $0.setSnowfall(snowfall) } } }
    @Published var mode = SnowMode.snow { didSet { changed(oldValue != mode) { $0.setMode(mode) } } }
    @Published var accumulate = true { didSet { changed(oldValue != accumulate) { $0.setAccumulate(accumulate) } } }
    @Published var melt = true { didSet { changed(oldValue != melt) { $0.setMelt(melt) } } }
    @Published var snowOnWindows = true { didSet { changed(oldValue != snowOnWindows) { $0.setSnowOnWindows(snowOnWindows) } } }
    @Published var icicles = true { didSet { changed(oldValue != icicles) { $0.setIcicles(icicles) } } }
    @Published var warmGlow = true { didSet { changed(oldValue != warmGlow) { $0.setWarmGlow(warmGlow) } } }
    @Published var puff = false {
        didSet {
            changed(oldValue != puff) { controls in
                controls.setPuff(puff) { [weak self] on in
                    // Without access to the microphone the switch goes back off.
                    self?.reading { $0.puff = on }
                }
            }
        }
    }
    @Published var sound = Ambience.Mode.off { didSet { changed(oldValue != sound) { $0.setSound(sound) } } }
    @Published var volume: Float = 0.5 { didSet { changed(oldValue != volume) { $0.setVolume(volume) } } }
    @Published var quietOnCalls = true { didSet { changed(oldValue != quietOnCalls) { $0.setQuietOnCalls(quietOnCalls) } } }
    @Published var behindWindows = false { didSet { changed(oldValue != behindWindows) { $0.setBehindWindows(behindWindows) } } }
    @Published var overFullScreen = false { didSet { changed(oldValue != overFullScreen) { $0.setOverFullScreen(overFullScreen) } } }
    @Published var showInScreenshots = false { didSet { changed(oldValue != showInScreenshots) { $0.setShowInScreenshots(showInScreenshots) } } }
    @Published var maxPerformance = false { didSet { changed(oldValue != maxPerformance) { $0.setMaxPerformance(maxPerformance) } } }
    @Published var openAtLogin = true { didSet { changed(oldValue != openAtLogin) { $0.setOpenAtLogin(openAtLogin) } } }
    @Published var autoUpdate = true { didSet { changed(oldValue != autoUpdate) { $0.setAutoUpdate(autoUpdate) } } }

    init(controls: SnowControls) {
        self.controls = controls
        reload()
    }

    /// Reads every value again, as the menu may have changed some.
    func reload() {
        reading { model in
            model.snowfall = Preferences.snowfall
            model.mode = Preferences.rain ? .rain : Preferences.autumn ? .autumn : .snow
            model.accumulate = Preferences.accumulate
            model.melt = Preferences.meltSnow
            model.snowOnWindows = Preferences.snowOnWindows
            model.icicles = Preferences.icicles
            model.warmGlow = Preferences.warmGlow
            model.puff = Preferences.puff
            model.sound = Preferences.ambience
            model.volume = Preferences.ambienceVolume
            model.quietOnCalls = Preferences.quietOnCalls
            model.behindWindows = Preferences.behindWindows
            model.overFullScreen = Preferences.overFullScreen
            model.showInScreenshots = Preferences.showInScreenshots
            model.maxPerformance = Preferences.maxPerformance
            model.openAtLogin = SMAppService.mainApp.status == .enabled
            model.autoUpdate = Preferences.autoUpdate
        }
    }

    private func reading(_ change: (SettingsModel) -> Void) {
        loading = true
        change(self)
        loading = false
    }

    private func changed(_ different: Bool, _ apply: (SnowControls) -> Void) {
        guard different, !loading, let controls else { return }
        apply(controls)
    }
}

/// A row with a label and a hint under it, for the settings window.
struct SettingLabel: View {
    let title: String
    var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let hint {
                Text(hint).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}
