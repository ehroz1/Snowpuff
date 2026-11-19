import AppKit
import CSnowpuffCore
import MetalKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var device: MTLDevice!
    private var screens: [ScreenSnow] = []
    private var snowfall = Snowfall.steady
    private var accumulates = true
    private var thaws = true
    private var snowOnWindows = true
    private var behindWindows = false
    private var snowfallHeld = false
    private var statusItem: NSStatusItem!
    private let snowfallSlider = SnowfallSlider()
    private var weatherItems: [NSMenuItem] = []
    private var mixRainItem: NSMenuItem!
    private var liveWeatherItem: NSMenuItem!
    private var clearItem: NSMenuItem!
    private var countdownItem: NSMenuItem!
    private var accumulateItem: NSMenuItem!
    private var groundItem: NSMenuItem!
    private var dockItem: NSMenuItem!
    private var windowsItem: NSMenuItem!
    private var meltItem: NSMenuItem!
    private var soundItems: [NSMenuItem] = []
    private var volumeSlider: NSSlider!
    private var opacitySlider: NSSlider!
    private var loginItem: NSMenuItem!
    private var updatesItem: NSMenuItem!
    /// Switches that only flip a preference, and what each greys out under.
    private var switches: [(item: NSMenuItem, get: () -> Bool, enabled: () -> Bool)] = []
    private let updater = Updater()
    private let whatsNew = WhatsNewController()
    private let liveWeather = LiveWeather()
    private let snowWord = SnowWord()
    private var observers: [NSObjectProtocol] = []
    private var screensAsleep = false
    private var screenLocked = false
    private var sessionInactive = false
    private var welcome: WelcomeController?
    private let power = PowerMonitor()
    private let ambience = Ambience()
    private let breath = Breath()
    private let calls = CallMonitor()
    /// A call or recording is on: the snow and its sounds step aside.
    private var hushed = false
    private var clockTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if AppMover.moveIfNeeded() {
            NSApp.terminate(nil)
            return
        }
        Preferences.registerDefaults()
        // Macs with two graphics cards keep to the integrated one: snow isn't worth waking the other.
        guard let device = MTLCopyAllDevices().first(where: \.isLowPower) ?? MTLCreateSystemDefaultDevice() else {
            NSApp.terminate(nil)
            return
        }
        self.device = device
        snowfall = Preferences.snowfall
        accumulates = Preferences.accumulate
        thaws = Preferences.meltSnow
        snowOnWindows = Preferences.snowOnWindows
        behindWindows = Preferences.behindWindows
        snowfallHeld = !Preferences.welcomed
        syncScreens()
        guard !screens.isEmpty else {
            NSApp.terminate(nil)
            return
        }

        openAtLoginOnFirstRun()
        statusItem = makeStatusItem()
        updateStatusIcon()
        setUpSound()
        observeSystem()
        applyWeather(switching: false)
        updater.mayInstallQuietly = { [weak self] in !(self?.hushed ?? false) }
        updater.start()
        liveWeather.changed = { [weak self] in self?.applyWeather(switching: true) }
        liveWeather.failed = { [weak self] message in self?.tell(message) }
        if Preferences.liveWeather { liveWeather.start() }
        snowWord.typed = { [weak self] in self?.screens.forEach { $0.extras.flurry() } }
        if Preferences.words { snowWord.start() }
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.watchTheClock() }
        if snowfallHeld {
            // A first run: the news of this version is all new anyway.
            Preferences.lastSeenVersion = Updater.version
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.showWelcome() }
        } else if Preferences.lastSeenVersion != Updater.version {
            // Just updated: say what changed, once.
            Preferences.lastSeenVersion = Updater.version
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.whatsNew.show() }
        }
    }

    // MARK: - Displays

    /// One overlay per display: new displays get snow, removed ones lose theirs, the rest follow resolution changes.
    private func syncScreens() {
        let current = NSScreen.screens
        let ids = Set(current.compactMap(\.displayID))
        for gone in screens where !ids.contains(gone.displayID) { gone.close() }
        screens.removeAll { !ids.contains($0.displayID) }

        for screen in current {
            if let existing = screens.first(where: { $0.displayID == screen.displayID }) {
                existing.fit(to: screen)
            } else if let snow = ScreenSnow(screen: screen, device: device, snowOnWindows: { [unowned self] in snowOnWindows }) {
                snow.simulation.snowfallHeld = snowfallHeld
                snow.simulation.snowfallReleased = { [weak self] in self?.releaseSnowfall() }
                snow.apply(power.budget)
                snow.visibilityChanged = { [weak self] in self?.updateActivity() }
                snow.hushed = hushed
                snow.cues = { [weak self] cues in self?.heard(cues) }
                screens.append(snow)
                if statusItem != nil { applyWeather(switching: false, only: snow) }
            }
        }
        updateActivity()
    }

    private func releaseSnowfall() {
        snowfallHeld = false
        for snow in screens { snow.simulation.snowfallHeld = false }
    }

    private func showWelcome() {
        let welcome = WelcomeController()
        welcome.scatter = { [weak self] pieces in
            guard let self, let first = pieces.first else { return }
            let point = CGPoint(x: CGFloat(first.position.x), y: CGFloat(first.position.y))
            guard let snow = screens.first(where: { $0.window.frame.contains(point) }) ?? screens.first else { return }
            let origin = SIMD2(Float(snow.window.frame.minX), Float(snow.window.frame.minY))
            snow.simulation.scatter(pieces.map { piece in
                var local = piece
                local.position -= origin
                return local
            })
        }
        welcome.skipped = { [weak self] in self?.releaseSnowfall() }
        welcome.finished = { [weak self] in
            Preferences.welcomed = true
            self?.welcome = nil
        }
        self.welcome = welcome
        welcome.show()
    }

    /// Snow that only falls when remembered isn't much of a mood: on the first run Snowpuff adds itself to the
    /// login items; the menu turns that off.
    private func openAtLoginOnFirstRun() {
        guard !UserDefaults.standard.bool(forKey: "addedToLoginItems") else { return }
        UserDefaults.standard.set(true, forKey: "addedToLoginItems")
        guard SMAppService.mainApp.status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            NSLog("Snowpuff: could not add a login item: \(error)")
        }
    }

    // MARK: - Weather

    /// What falls now: the weather outside when that is on, the mode picked otherwise.
    private var weather: Weather { liveWeather.now?.weather ?? Preferences.weather }
    private var intensity: Snowfall { liveWeather.now?.snowfall ?? snowfall }

    /// Sets every display to the weather: what falls, how hard, how the leaves look, the icicles and the extras.
    /// `switching` clears what lies on the way, as a change of mode does.
    private func applyWeather(switching: Bool, only: ScreenSnow? = nil) {
        let weather = weather
        let intensity = intensity
        let direction = screens.first?.simulation.breezeDirection ?? -1
        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let rains = weather == .rain || (Preferences.mixRain && weather.piles)
        for snow in only.map({ [$0] }) ?? screens {
            let leafy = weather.isLeafy
            if switching && leafy != snow.simulation.autumn {
                snow.simulation.switchMode(autumn: leafy, direction: direction, calm: calm)
            } else if switching && !weather.piles && snow.simulation.hasSnow {
                // Rain and hail don't lie: what snow or leaves there are blow away as they start.
                snow.simulation.blowAway(direction: direction, calm: calm)
            } else if !switching {
                snow.autumn = leafy
            }
            snow.simulation.snowfall = weather.piles ? intensity : .off
            snow.petals = weather == .petals
            snow.rain.intensity = Rain.intensity(intensity) * (weather == .rain ? 1 : 0.6)
            snow.rain.on = rains && intensity != .off
            let icicles = Preferences.icicles && weather == .snow
            if switching && !icicles { if calm { snow.icicles.melt() } else { snow.icicles.dropAll() } }
            snow.icicles.enabled = icicles
            snow.opacity = Preferences.opacity
            snow.extras.apply(SPSettings(
                weather: weather.core,
                blizzard: Preferences.blizzard ? 1 : 0,
                fog: Preferences.fog || (liveWeather.now?.fog ?? false) ? 1 : 0,
                stars: Preferences.stars ? 1 : 0,
                garland: Preferences.garland ? 1 : 0,
                frost: Preferences.frost ? 1 : 0,
                creatures: Preferences.creatures ? 1 : 0,
                padding: 0,
                intensity: Rain.intensity(intensity)
            ))
        }
        ambience.rainLevel = rains ? Rain.intensity(intensity) : 0
        ambience.hailLevel = weather == .hail ? Rain.intensity(intensity) : 0
        ambience.windiness = windiness
        updateStatusIcon()
    }

    // MARK: - Sound, breath and calls

    private func setUpSound() {
        ambience.volume = Preferences.ambienceVolume
        ambience.windiness = windiness
        ambience.mode = Preferences.ambience
        ambience.effects = Preferences.soundEffects
        breath.puffed = { [weak self] strength in
            guard let self, !hushed else { return }
            for snow in screens { snow.simulation.breathe(strength) }
        }
        if Preferences.puff {
            // Access taken away in System Settings since: the menu shouldn't claim it is on.
            breath.start { started in if !started { Preferences.puff = false } }
        }
        calls.listeningItself = { [weak self] in self?.breath.isListening ?? false }
        calls.changed = { [weak self] inCall in self?.setHushed(inCall) }
        if Preferences.quietOnCalls { calls.start() }
    }

    private var windiness: Float {
        switch intensity {
        case .off: 0.15
        case .light: 0.3
        case .steady, .variable: 0.55
        case .heavy: 1
        }
    }

    /// Sounds the extras asked for, and a click on an icicle knocking it off with a ring.
    private func heard(_ cues: [SPCue]) {
        for cue in cues { ambience.play(cue) }
    }

    private func setHushed(_ on: Bool) {
        guard hushed != on else { return }
        hushed = on
        if on {
            if breath.isListening { breath.stop() }
        } else if Preferences.puff {
            breath.start()
        }
        for snow in screens { snow.hushed = on }
        updateActivity()
        updateStatusIcon()
    }

    // MARK: - The clock: icicle clicks, New Year

    private var wasPressed = false
    private var fireworksYear = 0

    private func watchTheClock() {
        // A surprise nobody is told about: fireworks at midnight on New Year, for three minutes.
        let now = Date()
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        if parts.month == 1, parts.day == 1, parts.hour == 0, parts.minute == 0, fireworksYear != parts.year {
            fireworksYear = parts.year ?? 0
            screens.forEach { $0.extras.fireworks(seconds: 180) }
        }
    }

    /// Checks the mouse for a click on an icicle: polled while the menu is closed, from the screens' frames.
    private func knockIcicles() {
        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        defer { wasPressed = pressed }
        guard pressed, !wasPressed else { return }
        let mouse = NSEvent.mouseLocation
        for snow in screens {
            guard let point = snow.local(mouse), let pitch = snow.icicles.knock(at: point) else { continue }
            ambience.play(SPCue(kind: 1, value: pitch))
        }
    }

    private var newYearCountdown: String {
        let calendar = Calendar.current
        let now = Date()
        let year = calendar.component(.year, from: now)
        guard let newYear = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else { return "" }
        let left = calendar.dateComponents([.day, .hour, .minute], from: now, to: newYear)
        let days = left.day ?? 0, hours = left.hour ?? 0, minutes = left.minute ?? 0
        if days == 0 {
            return tr("New Year in \(hours) h \(minutes) min", "До Нового года \(hours) ч \(minutes) мин")
        }
        return tr("New Year in \(days) d \(hours) h", "До Нового года \(days) дн \(hours) ч")
    }

    // MARK: - Menu

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        menu.addItem(.sectionHeader(title: tr("Intensity", "Интенсивность")))
        snowfallSlider.changed = { [unowned self] in select($0) }
        let sliderItem = NSMenuItem()
        sliderItem.view = snowfallSlider
        menu.addItem(sliderItem)
        menu.addItem(.separator())

        let modes = NSMenu()
        modes.autoenablesItems = false
        for weather in Weather.allCases {
            let item = add(weather.title, #selector(chooseWeather(_:)), to: modes)
            item.tag = weather.rawValue
            weatherItems.append(item)
        }
        modes.addItem(.separator())
        mixRainItem = add(tr("Add Rain", "Добавить дождь"), #selector(toggleMixRain), to: modes)
        liveWeatherItem = add(tr("Weather Outside", "Погода за окном"), #selector(toggleLiveWeather), to: modes)
        menu.addItem(withTitle: tr("Mode", "Режим"), action: nil, keyEquivalent: "").submenu = modes
        clearItem = add(tr("Clear Snow", "Смести весь снег"), #selector(clearSnow), to: menu)
        menu.addItem(.separator())
        countdownItem = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        countdownItem.isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("Settings", "Настройки"), action: nil, keyEquivalent: "").submenu = makeSettingsMenu()
        menu.addItem(.separator())
        updatesItem = add(tr("Check for Updates…", "Проверить обновления…"), #selector(checkForUpdates), to: menu)
        add(tr("What's New", "Что нового"), #selector(showWhatsNew), to: menu)
        add(tr("Report a Problem…", "Сообщить о проблеме…"), #selector(reportProblem), to: menu)
        add(tr("Snowpuff \(Updater.version) on GitHub", "Snowpuff \(Updater.version) на GitHub"), #selector(openGitHub), to: menu)
        menu.addItem(.separator())
        add(tr("Support the Author ♥", "Поддержать автора ♥"), #selector(openDonation), to: menu)
        add(tr("More Apps — ehroz.pro", "Другие приложения — ehroz.pro"), #selector(openSite), to: menu)
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("Quit Snowpuff", "Выйти из Snowpuff"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        return item
    }

    private func makeSettingsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(.sectionHeader(title: tr("Behavior", "Поведение")))
        let surfaces = NSMenu()
        surfaces.autoenablesItems = false
        groundItem = add(tr("On the Ground", "На земле"), #selector(toggleAccumulate), to: surfaces)
        dockItem = add(tr("On the Dock", "На Dock"), #selector(toggleDock), to: surfaces)
        windowsItem = add(tr("On Windows", "На окнах"), #selector(toggleSnowOnWindows), to: surfaces)
        accumulateItem = menu.addItem(withTitle: tr("Accumulate", "Сугробы"), action: nil, keyEquivalent: "")
        accumulateItem.submenu = surfaces
        meltItem = add(tr("Melt Snow", "Таяние"), #selector(toggleMeltSnow), to: menu)
        toggle(tr("Icicles", "Сосульки"), in: menu, get: { Preferences.icicles }, enabled: { [unowned self] in snowOnWindows && !behindWindows && weather == .snow }) { [unowned self] in
            Preferences.icicles.toggle()
            applyWeather(switching: false)
        }
        toggle(tr("Warm Window Light", "Тёплый свет окна"), in: menu, get: { Preferences.warmGlow }, enabled: { [unowned self] in snowOnWindows && !behindWindows }) {
            Preferences.warmGlow.toggle()
        }
        toggle(tr("Snow on Selection", "Снег на рамке выделения"), in: menu, get: { Preferences.deepInteraction }, enabled: { [unowned self] in snowOnWindows }) {
            Preferences.deepInteraction.toggle()
        }
        toggle(tr("Blow on the Snow (Microphone)", "Подуть на снег (микрофон)"), in: menu, get: { Preferences.puff }) { [unowned self] in togglePuff() }
        toggle(tr("Hide During Calls", "Прятать на созвонах"), in: menu, get: { Preferences.quietOnCalls }) { [unowned self] in
            Preferences.quietOnCalls.toggle()
            if Preferences.quietOnCalls { calls.start() } else { calls.stop() }
        }
        toggle(tr("Typing \"snow\" Brings a Flurry", "Слово «снег» вызывает снегопад"), in: menu, get: { Preferences.words }) { [unowned self] in
            Preferences.words.toggle()
            if Preferences.words { snowWord.start() } else { snowWord.stop() }
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: tr("Magic", "Волшебство")))
        let extras: [(String, String, ReferenceWritableKeyPath<PreferencesBox, Bool>)] = [
            ("Swirl Behind the Cursor", "Метель за курсором", \.blizzard),
            ("Frost and Misted Glass", "Иней и запотевшее стекло", \.frost),
            ("Fog", "Туман", \.fog),
            ("Starry Sky", "Звёздное небо", \.stars),
            ("Garland on Windows", "Гирлянда на окнах", \.garland),
            ("Cat and Bullfinch", "Кот и снегирь", \.creatures),
        ]
        for (english, russian, key) in extras {
            toggle(tr(english, russian), in: menu, get: { PreferencesBox.shared[keyPath: key] }) { [unowned self] in
                PreferencesBox.shared[keyPath: key].toggle()
                applyWeather(switching: false)
            }
        }
        let hint = menu.addItem(withTitle: tr(
            "⌥ + move: draw on frost · hold on a drift: snowman · ⌥-click: snowball",
            "⌥ + курсор: рисовать по инею · держать на сугробе: снеговик · ⌥-клик: снежок"
        ), action: nil, keyEquivalent: "")
        hint.isEnabled = false

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: tr("Display", "Отображение")))
        toggle(tr("Behind Windows", "За окнами"), in: menu, get: { [unowned self] in behindWindows }) { [unowned self] in toggleBehindWindows() }
        toggle(tr("Show over Full Screen", "Поверх полноэкранных приложений"), in: menu, get: { Preferences.overFullScreen }, enabled: { [unowned self] in !behindWindows }) { [unowned self] in
            Preferences.overFullScreen.toggle()
            for snow in screens { snow.overFullScreen = Preferences.overFullScreen }
        }
        toggle(tr("Show in Screenshots", "Показывать на скриншотах"), in: menu, get: { Preferences.showInScreenshots }) { [unowned self] in
            Preferences.showInScreenshots.toggle()
            for snow in screens {
                snow.window.showsInScreenshots = Preferences.showInScreenshots
                snow.dock.window.showsInScreenshots = Preferences.showInScreenshots
            }
        }
        toggle(tr("Max Performance", "Максимальная плавность"), in: menu, get: { Preferences.maxPerformance }) {
            Preferences.maxPerformance.toggle()
        }
        toggle(tr("Battery Saver", "Экономить батарею"), in: menu, get: { Preferences.batterySaver }) { [unowned self] in
            Preferences.batterySaver.toggle()
            power.update()
        }
        menu.addItem(.sectionHeader(title: tr("Opacity", "Прозрачность падающего")))
        opacitySlider = slider(value: Preferences.opacity, min: 0.15, action: #selector(changeOpacity(_:)), in: menu)

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: tr("General", "Общие")))
        menu.addItem(withTitle: tr("Sound", "Звук"), action: nil, keyEquivalent: "").submenu = makeSoundMenu()
        loginItem = add(tr("Open at Login", "Открывать при входе"), #selector(toggleOpenAtLogin), to: menu)
        toggle(tr("Update Automatically", "Обновлять автоматически"), in: menu, get: { Preferences.autoUpdate }) {
            Preferences.autoUpdate.toggle()
        }
        return menu
    }

    private func makeSoundMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for mode in Ambience.Mode.allCases {
            let item = add(mode.title, #selector(selectSound(_:)), to: menu)
            item.tag = mode.rawValue
            soundItems.append(item)
        }
        menu.addItem(.separator())
        toggle(tr("Sound Effects", "Звуки эффектов"), in: menu, get: { Preferences.soundEffects }) { [unowned self] in
            Preferences.soundEffects.toggle()
            ambience.effects = Preferences.soundEffects
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: tr("Volume", "Громкость")))
        volumeSlider = slider(value: Preferences.ambienceVolume, min: 0.05, action: #selector(changeVolume(_:)), in: menu)
        return menu
    }

    private func slider(value: Float, min: Double, action: Selector, in menu: NSMenu) -> NSSlider {
        let slider = NSSlider(value: Double(value), minValue: min, maxValue: 1, target: self, action: action)
        slider.isContinuous = true
        slider.frame = NSRect(x: 20, y: 4, width: 180, height: 22)
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 30))
        holder.addSubview(slider)
        let item = NSMenuItem()
        item.view = holder
        menu.addItem(item)
        return slider
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// A menu switch: its tick follows `get`, and choosing it runs `flip`.
    private func toggle(_ title: String, in menu: NSMenu, get: @escaping () -> Bool, enabled: @escaping () -> Bool = { true }, flip: @escaping () -> Void) {
        let item = add(title, #selector(flipSwitch(_:)), to: menu)
        item.representedObject = Flip(flip)
        switches.append((item, get, enabled))
    }

    private final class Flip {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    @objc private func flipSwitch(_ sender: NSMenuItem) {
        (sender.representedObject as? Flip)?.run()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let weather = weather
        let live = liveWeather.now != nil
        snowfallSlider.snowfall = snowfall
        for item in weatherItems {
            item.state = item.tag == Preferences.weather.rawValue ? .on : .off
            item.isEnabled = !live
        }
        mixRainItem.state = Preferences.mixRain ? .on : .off
        mixRainItem.isEnabled = Preferences.weather.piles && !live
        liveWeatherItem.state = Preferences.liveWeather ? .on : .off
        liveWeatherItem.title = liveWeather.summary.map { tr("Weather Outside: \($0)", "Погода за окном: \($0)") } ?? tr("Weather Outside", "Погода за окном")
        clearItem.title = weather.isLeafy ? tr("Clear Leaves", "Смести все листья") : tr("Clear Snow", "Смести весь снег")
        clearItem.isEnabled = screens.contains { $0.simulation.hasSnow || $0.simulation.spriteCount > 0 }
        countdownItem.title = newYearCountdown
        groundItem.state = accumulates ? .on : .off
        dockItem.state = Preferences.snowOnDock ? .on : .off
        dockItem.isEnabled = snowOnWindows && !behindWindows
        windowsItem.state = snowOnWindows ? .on : .off
        windowsItem.isEnabled = !behindWindows
        accumulateItem.isEnabled = weather.piles
        meltItem.title = weather == .petals ? tr("Wilt Petals", "Лепестки вянут") : weather == .leaves ? tr("Wither Leaves", "Листья вянут") : tr("Melt Snow", "Таяние")
        meltItem.state = thaws ? .on : .off
        meltItem.isEnabled = accumulates && weather.piles
        for (item, get, enabled) in switches {
            item.state = get() ? .on : .off
            item.isEnabled = enabled()
        }
        for item in soundItems { item.state = item.tag == Preferences.ambience.rawValue ? .on : .off }
        volumeSlider.doubleValue = Double(Preferences.ambienceVolume)
        opacitySlider.doubleValue = Double(Preferences.opacity)
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        updatesItem.isEnabled = !updater.isBusy
        updatesItem.title = updater.isBusy ? tr("Updating…", "Обновление…")
            : updater.available.map { tr("Update to \($0.version)", "Обновить до \($0.version)") }
            ?? tr("Check for Updates…", "Проверить обновления…")
    }

    private func select(_ snowfall: Snowfall) {
        self.snowfall = snowfall
        Preferences.snowfall = snowfall
        applyWeather(switching: false)
    }

    @objc private func chooseWeather(_ sender: NSMenuItem) {
        guard let picked = Weather(rawValue: sender.tag), picked != Preferences.weather else { return }
        Preferences.weather = picked
        applyWeather(switching: true)
    }

    @objc private func toggleMixRain() {
        Preferences.mixRain.toggle()
        applyWeather(switching: false)
    }

    @objc private func toggleLiveWeather() {
        Preferences.liveWeather.toggle()
        if Preferences.liveWeather { liveWeather.start() } else { liveWeather.stop() }
    }

    @objc private func toggleAccumulate() {
        accumulates.toggle()
        Preferences.accumulate = accumulates
        for snow in screens { snow.simulation.accumulates = accumulates }
    }

    @objc private func toggleDock() {
        Preferences.snowOnDock.toggle()
        if !Preferences.snowOnDock { screens.forEach { $0.watchWindows() } }
    }

    @objc private func toggleMeltSnow() {
        thaws.toggle()
        Preferences.meltSnow = thaws
        for snow in screens { snow.simulation.thaws = thaws }
    }

    @objc private func toggleSnowOnWindows() {
        snowOnWindows.toggle()
        Preferences.snowOnWindows = snowOnWindows
        if !snowOnWindows { screens.forEach { $0.dropWindowSnow() } }
    }

    @objc private func clearSnow() {
        let direction = screens.first?.simulation.breezeDirection ?? -1
        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for snow in screens {
            snow.simulation.blowAway(direction: direction, calm: calm)
            snow.rain.clear()
            snow.extras.clear()
            if calm { snow.icicles.melt() } else { snow.icicles.dropAll() }
        }
    }

    private func togglePuff() {
        if Preferences.puff {
            Preferences.puff = false
            breath.stop()
            return
        }
        breath.start { [weak self] started in
            if started {
                Preferences.puff = true
            } else {
                self?.explainMicrophone()
            }
        }
    }

    private func explainMicrophone() {
        let alert = NSAlert()
        alert.messageText = tr("Snowpuff can't hear you", "Snowpuff не слышит микрофон")
        alert.informativeText = tr(
            "To blow on the snow, allow Snowpuff to use the microphone in System Settings → Privacy & Security → Microphone. Sound is only listened to for a puff of breath, never recorded or sent anywhere.",
            "Чтобы дуть на снег, разреши Snowpuff доступ к микрофону: Системные настройки → Конфиденциальность и безопасность → Микрофон. Звук только проверяется на «дуновение», он не записывается и никуда не отправляется."
        )
        alert.addButton(withTitle: tr("Open Settings", "Открыть настройки"))
        alert.addButton(withTitle: tr("Cancel", "Отмена"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func tell(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Snowpuff"
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func selectSound(_ sender: NSMenuItem) {
        let mode = Ambience.Mode(rawValue: sender.tag) ?? .off
        Preferences.ambience = mode
        ambience.mode = mode
    }

    @objc private func changeVolume(_ sender: NSSlider) {
        Preferences.ambienceVolume = sender.floatValue
        ambience.volume = sender.floatValue
    }

    @objc private func changeOpacity(_ sender: NSSlider) {
        Preferences.opacity = sender.floatValue
        for snow in screens { snow.opacity = sender.floatValue }
    }

    private func toggleBehindWindows() {
        behindWindows.toggle()
        Preferences.behindWindows = behindWindows
        for snow in screens {
            snow.window.behindWindows = behindWindows
            snow.checkFullScreen()
        }
    }

    @objc private func toggleOpenAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Snowpuff: login item change failed: \(error)")
        }
    }

    @objc private func checkForUpdates() {
        updater.check(asked: true)
    }

    @objc private func showWhatsNew() {
        whatsNew.show()
    }

    /// Opens a new issue on GitHub with the version and the system filled in; nothing is sent until it is submitted.
    @objc private func reportProblem() {
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        let body = """
        \(tr("What happened, and what did you expect?", "Что случилось и чего ты ждал?"))


        —
        Snowpuff \(Updater.version), macOS \(system)
        """
        var parts = URLComponents(string: "https://github.com/\(Updater.repository)/issues/new")!
        parts.queryItems = [URLQueryItem(name: "body", value: body)]
        if let url = parts.url { NSWorkspace.shared.open(url) }
    }

    @objc private func openGitHub() {
        open("https://github.com/\(Updater.repository)")
    }

    @objc private func openDonation() {
        open("https://t.me/hhrrzz1")
    }

    @objc private func openSite() {
        open("https://ehroz.pro")
    }

    private func open(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    private static let trayIcon = trayImage("TrayIconTemplate")
    private static let pausedTrayIcon = trayImage("TrayIconPausedTemplate")

    private static func trayImage(_ name: String) -> NSImage? {
        guard let image = Bundle.main.image(forResource: name) else { return NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Snowpuff") }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "Snowpuff"
        return image
    }

    private func updateStatusIcon() {
        guard let statusItem else { return }
        let paused = intensity == .off || hushed
        statusItem.button?.image = paused ? Self.pausedTrayIcon : Self.trayIcon
    }

    // MARK: - System

    private func observeSystem() {
        power.changed = { [unowned self] in screens.forEach { $0.apply(power.budget) } }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()

        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false }
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.screenLocked = true }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.screenLocked = false }
        observe(.default, NSWindow.didChangeOcclusionStateNotification) { _ in }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.syncScreens() }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { $0.screens.forEach { $0.spaceChanged() } }
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { $0.screens.forEach { $0.watchWindows() } }
        // A click on an icicle is looked for a few dozen times a second: cheap, and no event tap needed.
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.knockIcicles() }
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        object: AnyObject? = nil,
        _ change: @escaping (AppDelegate) -> Void
    ) {
        observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            guard let self else { return }
            change(self)
            self.updateActivity()
        })
    }

    private func updateActivity() {
        let present = !screensAsleep && !screenLocked && !sessionInactive
        // Nobody to hear it while the Mac sleeps, is locked or another user is on it.
        // A film or game in full screen everywhere gets the quiet too.
        let allCovered = !screens.isEmpty && screens.allSatisfy(\.covered)
        ambience.muted = hushed || !present || allCovered
        for snow in screens {
            // Drawing goes on while the snow fades out, and pauses once it's gone.
            snow.setActive(present && snow.showing && snow.window.occlusionState.contains(.visible))
        }
    }
}

/// Key paths to the extras' switches, for the menu to list them in one go.
final class PreferencesBox {
    static let shared = PreferencesBox()
    var blizzard: Bool { get { Preferences.blizzard } set { Preferences.blizzard = newValue } }
    var frost: Bool { get { Preferences.frost } set { Preferences.frost = newValue } }
    var fog: Bool { get { Preferences.fog } set { Preferences.fog = newValue } }
    var stars: Bool { get { Preferences.stars } set { Preferences.stars = newValue } }
    var garland: Bool { get { Preferences.garland } set { Preferences.garland = newValue } }
    var creatures: Bool { get { Preferences.creatures } set { Preferences.creatures = newValue } }
}
