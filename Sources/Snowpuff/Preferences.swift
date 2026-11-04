import AppKit

enum Snowfall: Int, CaseIterable {
    case off, light, steady, heavy, variable

    var title: String {
        switch self {
        case .off: tr("Off", "Выкл")
        case .light: tr("Light", "Лёгкий")
        case .steady: tr("Steady", "Ровный")
        case .heavy: tr("Heavy", "Метель")
        case .variable: tr("Variable", "Переменный")
        }
    }

    var flakesPerMegapoint: Float {
        switch self {
        case .off: 0
        case .light: 150
        case .steady: 380
        case .heavy: 800
        case .variable: 380
        }
    }
}

enum Preferences {
    private static let defaults = UserDefaults.standard
    private static let snowfallKey = "snowfall"
    private static let behindWindowsKey = "behindWindows"
    private static let meltSnowKey = "meltSnow"
    private static let accumulateKey = "accumulate"
    private static let snowOnWindowsKey = "snowOnWindows"
    private static let welcomedKey = "welcomed"
    private static let showInScreenshotsKey = "showInScreenshots"
    private static let iciclesKey = "icicles"
    private static let warmGlowKey = "warmGlow"
    private static let puffKey = "puff"
    private static let quietOnCallsKey = "quietOnCalls"
    private static let ambienceKey = "ambience"
    private static let ambienceVolumeKey = "ambienceVolume"
    private static let autoUpdateKey = "autoUpdate"
    private static let overFullScreenKey = "overFullScreen"
    private static let rainKey = "rain"
    private static let maxPerformanceKey = "maxPerformance"
    private static let autumnKey = "autumn"

    static func registerDefaults() {
        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        defaults.register(defaults: [
            snowfallKey: (calm ? Snowfall.light : .steady).rawValue,
            behindWindowsKey: false,
            meltSnowKey: true,
            accumulateKey: true,
            snowOnWindowsKey: true,
            showInScreenshotsKey: false,
            iciclesKey: true,
            warmGlowKey: true,
            puffKey: false,
            quietOnCallsKey: true,
            ambienceKey: 0,
            ambienceVolumeKey: 0.5,
            autoUpdateKey: true,
            overFullScreenKey: false,
            rainKey: false,
            maxPerformanceKey: false,
            autumnKey: false,
        ])
    }

    static var snowfall: Snowfall {
        get { Snowfall(rawValue: defaults.integer(forKey: snowfallKey)) ?? .steady }
        set { defaults.set(newValue.rawValue, forKey: snowfallKey) }
    }

    static var snowOnWindows: Bool {
        get { defaults.bool(forKey: snowOnWindowsKey) }
        set { defaults.set(newValue, forKey: snowOnWindowsKey) }
    }

    static var accumulate: Bool {
        get { defaults.bool(forKey: accumulateKey) }
        set { defaults.set(newValue, forKey: accumulateKey) }
    }

    static var meltSnow: Bool {
        get { defaults.bool(forKey: meltSnowKey) }
        set { defaults.set(newValue, forKey: meltSnowKey) }
    }

    static var welcomed: Bool {
        get { defaults.bool(forKey: welcomedKey) }
        set { defaults.set(newValue, forKey: welcomedKey) }
    }

    static var behindWindows: Bool {
        get { defaults.bool(forKey: behindWindowsKey) }
        set { defaults.set(newValue, forKey: behindWindowsKey) }
    }

    static var showInScreenshots: Bool {
        get { defaults.bool(forKey: showInScreenshotsKey) }
        set { defaults.set(newValue, forKey: showInScreenshotsKey) }
    }

    static var icicles: Bool {
        get { defaults.bool(forKey: iciclesKey) }
        set { defaults.set(newValue, forKey: iciclesKey) }
    }

    static var autumn: Bool {
        get { defaults.bool(forKey: autumnKey) }
        set { defaults.set(newValue, forKey: autumnKey) }
    }

    static var warmGlow: Bool {
        get { defaults.bool(forKey: warmGlowKey) }
        set { defaults.set(newValue, forKey: warmGlowKey) }
    }

    static var puff: Bool {
        get { defaults.bool(forKey: puffKey) }
        set { defaults.set(newValue, forKey: puffKey) }
    }

    static var quietOnCalls: Bool {
        get { defaults.bool(forKey: quietOnCallsKey) }
        set { defaults.set(newValue, forKey: quietOnCallsKey) }
    }

    static var ambience: Ambience.Mode {
        get { Ambience.Mode(rawValue: defaults.integer(forKey: ambienceKey)) ?? .off }
        set { defaults.set(newValue.rawValue, forKey: ambienceKey) }
    }

    /// Every frame is drawn at the display's full rate, for the smoothest motion at some cost in power.
    static var maxPerformance: Bool {
        get { defaults.bool(forKey: maxPerformanceKey) }
        set { defaults.set(newValue, forKey: maxPerformanceKey) }
    }

    /// Rain falls instead of snow or leaves.
    static var rain: Bool {
        get { defaults.bool(forKey: rainKey) }
        set { defaults.set(newValue, forKey: rainKey) }
    }

    /// The snow stays over full-screen apps and games.
    static var overFullScreen: Bool {
        get { defaults.bool(forKey: overFullScreenKey) }
        set { defaults.set(newValue, forKey: overFullScreenKey) }
    }

    /// New versions from GitHub install themselves.
    static var autoUpdate: Bool {
        get { defaults.bool(forKey: autoUpdateKey) }
        set { defaults.set(newValue, forKey: autoUpdateKey) }
    }

    static var ambienceVolume: Float {
        get { defaults.float(forKey: ambienceVolumeKey) }
        set { defaults.set(newValue, forKey: ambienceVolumeKey) }
    }
}

/// The app speaks Russian on a Russian system and English everywhere else.
let speaksRussian = Locale.preferredLanguages.first?.lowercased().hasPrefix("ru") ?? false

func tr(_ english: String, _ russian: String) -> String {
    speaksRussian ? russian : english
}
