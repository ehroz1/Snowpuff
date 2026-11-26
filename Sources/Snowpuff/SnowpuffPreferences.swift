import AppKit

/// Snowpuff's own settings, over Snowhush's: icicles, the window's glow, breath, calls, sound, the extras, updates.
extension Preferences {
    private static var store: UserDefaults { .standard }

    /// Snowpuff's defaults, and the settings of Snowpuff 1.3 carried over to the names they have now.
    static func registerSnowpuffDefaults() {
        let defaults = store
        defaults.register(defaults: [
            "icicles": true,
            "warmGlow": true,
            "puff": false,
            "quietOnCalls": true,
            "ambience": 0,
            "ambienceVolume": 0.5,
            "autoUpdate": true,
            "hotkeys": true,
            "blizzard": true,
            "fog": false,
            "stars": true,
            "garland": false,
            "frost": true,
            "creatures": true,
            "words": false,
            "soundEffects": true,
            "liveWeather": false,
            "hail": false,
        ])
        // Snowpuff 1.3 kept what falls as one weather: snow, leaves, petals, rain or hail, and rain mixed in apart.
        if defaults.object(forKey: "mode") == nil, let weather = defaults.object(forKey: "weather") as? Int {
            let mode: Mode = [.snow, .autumn, .blossom, .rain, .snow][min(max(weather, 0), 4)]
            defaults.set(mode.rawValue, forKey: "mode")
            if weather == 4 { defaults.set(true, forKey: "hail") }
            if defaults.bool(forKey: "mixRain"), mode != .rain {
                defaults.set(true, forKey: "mixed")
                defaults.set([mode.rawValue, Mode.rain.rawValue], forKey: "mix")
                defaults.set(Mode.rain.rawValue, forKey: "mode")
            }
            defaults.removeObject(forKey: "weather")
            defaults.removeObject(forKey: "mixRain")
        }
        for (old, new) in [("overFullScreen", "showOverFullScreen"), ("opacity", "fallingOpacity")] {
            if let value = defaults.object(forKey: old) {
                if defaults.object(forKey: new) == nil { defaults.set(value, forKey: new) }
                defaults.removeObject(forKey: old)
            }
        }
        if let on = defaults.object(forKey: "maxPerformance") as? Bool {
            if defaults.object(forKey: "performance") == nil { defaults.set(on ? 1 : 0, forKey: "performance") }
            defaults.removeObject(forKey: "maxPerformance")
        }
        if let on = defaults.object(forKey: "snowOnDock") as? Bool {
            if !on { defaults.set(false, forKey: "settleDock") }
            defaults.removeObject(forKey: "snowOnDock")
        }
    }

    private static func flag(_ key: String) -> Bool { store.bool(forKey: key) }
    private static func set(_ key: String, _ value: Any?) { store.set(value, forKey: key) }

    static var icicles: Bool { get { flag("icicles") } set { set("icicles", newValue) } }
    /// The front window glows warm, and the snow by it with it.
    static var warmGlow: Bool { get { flag("warmGlow") } set { set("warmGlow", newValue) } }
    /// Blowing into the microphone blows the snow about.
    static var puff: Bool { get { flag("puff") } set { set("puff", newValue) } }
    static var quietOnCalls: Bool { get { flag("quietOnCalls") } set { set("quietOnCalls", newValue) } }
    /// 0 off, 1 wind, 2 fireplace, 3 both.
    static var ambience: Int { get { store.integer(forKey: "ambience") } set { set("ambience", newValue) } }
    static var ambienceVolume: Float { get { store.float(forKey: "ambienceVolume") } set { set("ambienceVolume", newValue) } }
    static var soundEffects: Bool { get { flag("soundEffects") } set { set("soundEffects", newValue) } }
    /// New versions from GitHub install themselves.
    static var autoUpdate: Bool { get { flag("autoUpdate") } set { set("autoUpdate", newValue) } }
    /// Control-Option-letter shortcuts work anywhere.
    static var hotkeys: Bool { get { flag("hotkeys") } set { set("hotkeys", newValue) } }
    /// A swirl of snow behind a fast cursor.
    static var blizzard: Bool { get { flag("blizzard") } set { set("blizzard", newValue) } }
    static var fog: Bool { get { flag("fog") } set { set("fog", newValue) } }
    static var stars: Bool { get { flag("stars") } set { set("stars", newValue) } }
    static var garland: Bool { get { flag("garland") } set { set("garland", newValue) } }
    static var frost: Bool { get { flag("frost") } set { set("frost", newValue) } }
    /// The cat in the drift and the bullfinch on the windows.
    static var creatures: Bool { get { flag("creatures") } set { set("creatures", newValue) } }
    /// Typing "snow" brings a flurry.
    static var words: Bool { get { flag("words") } set { set("words", newValue) } }
    /// It snows, rains or hails as it does outside.
    static var liveWeather: Bool { get { flag("liveWeather") } set { set("liveWeather", newValue) } }
    /// Hail beats down instead of snow.
    static var hail: Bool { get { flag("hail") } set { set("hail", newValue) } }

    /// The version whose news was last shown, to show What's New once after an update.
    static var lastSeenVersion: String? { get { store.string(forKey: "lastSeenVersion") } set { set("lastSeenVersion", newValue) } }
}

/// Snowpuff's own texts come in English and Russian: Russian on a Russian system, English everywhere else.
let speaksRussian = Locale.preferredLanguages.first?.lowercased().hasPrefix("ru") ?? false

func tr(_ english: String, _ russian: String) -> String {
    speaksRussian ? russian : english
}
