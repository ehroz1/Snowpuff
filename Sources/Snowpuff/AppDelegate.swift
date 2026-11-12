import AppKit
import MetalKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var device: MTLDevice?
    private var screens: [ScreenSnow] = []
    private var snowfall = Snowfall.steady
    private var accumulates = true
    private var thaws = true
    private var snowOnWindows = true
    private var behindWindows = false
    private var snowfallHeld = false
    private var statusItem: NSStatusItem!
    private let snowfallSlider = SnowfallSlider()
    private var accumulateItem: NSMenuItem!
    private var snowOnWindowsItem: NSMenuItem!
    private var iciclesItem: NSMenuItem!
    private var clearItem: NSMenuItem!
    private var puffItem: NSMenuItem!
    private var soundItems: [NSMenuItem] = []
    private var volumeSlider: NSSlider!
    private var snowItem: NSMenuItem!
    private var autumnItem: NSMenuItem!
    private var rainItem: NSMenuItem!
    private var updatesItem: NSMenuItem!
    private let updater = Updater()
    private var observers: [NSObjectProtocol] = []
    private var screensAsleep = false
    private var screenLocked = false
    private var sessionInactive = false
    private var onboarding: OnboardingController?
    private lazy var settingsModel = SettingsModel(controls: self)
    private lazy var settingsWindow = SettingsWindowController(model: settingsModel)
    private let power = PowerMonitor()
    private let ambience = Ambience()
    private let breath = Breath()
    private let calls = CallMonitor()
    /// A call or recording is on: the snow and its sounds step aside.
    private var hushed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if AppMover.moveIfNeeded() {
            NSApp.terminate(nil)
            return
        }
        CrashGuard.start()
        SettingsFile.restoreIfNeeded()
        Preferences.registerDefaults()
        SettingsFile.startSaving()
        snowfall = Preferences.snowfall
        accumulates = Preferences.accumulate
        thaws = Preferences.meltSnow
        snowOnWindows = Preferences.snowOnWindows
        behindWindows = Preferences.behindWindows
        snowfallHeld = !Preferences.welcomed

        openAtLoginOnFirstRun()
        statusItem = makeStatusItem()
        updateStatusIcon()
        setUpSound()
        observeSystem()
        updater.mayInstallQuietly = { [weak self] in !(self?.hushed ?? false) }
        updater.start()
        startSnow()
        if snowfallHeld {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.showOnboarding() }
        }
    }

    /// Starts the snow, or keeps trying. Opened at login, Snowpuff can be ahead of the displays and the GPU; it used to
    /// quit then and stay gone until opened by hand. Now it waits for them, menu and all.
    private func startSnow() {
        if device == nil { device = MTLCreateSystemDefaultDevice() }
        if device != nil { syncScreens() }
        guard device == nil || screens.isEmpty else { return }
        NSLog("Snowpuff: nothing to draw on yet (GPU: \(device != nil), displays: \(NSScreen.screens.count)); trying again shortly")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.startSnow() }
    }

    // MARK: - Displays

    /// One overlay per display: new displays get snow, removed ones lose theirs, the rest follow resolution changes.
    private func syncScreens() {
        guard let device else { return }
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
                snow.autumn = Preferences.autumn
                snow.apply(power.budget)
                snow.visibilityChanged = { [weak self] in self?.updateActivity() }
                snow.hushed = hushed
                screens.append(snow)
            }
        }
        updateActivity()
    }

    private func releaseSnowfall() {
        snowfallHeld = false
        for snow in screens { snow.simulation.snowfallHeld = false }
    }

    private func showOnboarding() {
        let onboarding = OnboardingController()
        onboarding.finished = { [weak self] in
            Preferences.welcomed = true
            self?.releaseSnowfall()
            self?.onboarding = nil
            SettingsFile.save()
        }
        self.onboarding = onboarding
        onboarding.show(model: settingsModel)
    }

    @objc private func openSettings() {
        settingsWindow.show()
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

    // MARK: - Sound, breath and calls

    private func setUpSound() {
        ambience.volume = Preferences.ambienceVolume
        ambience.windiness = windiness
        ambience.mode = Preferences.ambience
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
        switch snowfall {
        case .off: 0.15
        case .light: 0.3
        case .steady, .variable: 0.55
        case .heavy: 1
        }
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
        snowItem = add(tr("Snow", "Снег"), #selector(chooseMode), to: modes)
        autumnItem = add(tr("Autumn Leaves", "Осенние листья"), #selector(chooseMode), to: modes)
        rainItem = add(tr("Rain", "Дождь"), #selector(chooseMode), to: modes)
        menu.addItem(withTitle: tr("Mode", "Режим"), action: nil, keyEquivalent: "").submenu = modes
        accumulateItem = add(tr("Accumulate", "Сугробы"), #selector(toggleAccumulate), to: menu)
        snowOnWindowsItem = add(tr("Snow on Windows", "Снег на окнах"), #selector(toggleSnowOnWindows), to: menu)
        iciclesItem = add(tr("Icicles", "Сосульки"), #selector(toggleIcicles), to: menu)
        clearItem = add(tr("Clear Snow", "Смести весь снег"), #selector(clearSnowFromMenu), to: menu)
        menu.addItem(.separator())
        let soundItem = menu.addItem(withTitle: tr("Sound", "Звук"), action: nil, keyEquivalent: "")
        soundItem.submenu = makeSoundMenu()
        puffItem = add(tr("Blow on the Snow (Microphone)", "Подуть на снег (микрофон)"), #selector(togglePuff), to: menu)
        menu.addItem(.separator())
        let settings = add(tr("Settings…", "Настройки…"), #selector(openSettings), to: menu)
        settings.keyEquivalent = ","
        updatesItem = add(tr("Check for Updates…", "Проверить обновления…"), #selector(checkForUpdatesFromMenu), to: menu)
        menu.addItem(.separator())
        add(tr("Support the Author ♥", "Поддержать автора ♥"), #selector(openDonation), to: menu)
        add(tr("More Apps — ehroz.pro", "Другие приложения — ehroz.pro"), #selector(openSite), to: menu)
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("Quit Snowpuff", "Выйти из Snowpuff"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        return item
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
        menu.addItem(.sectionHeader(title: tr("Volume", "Громкость")))
        let slider = NSSlider(value: Double(Preferences.ambienceVolume), minValue: 0.05, maxValue: 1, target: self, action: #selector(changeVolume(_:)))
        slider.isContinuous = true
        slider.frame = NSRect(x: 20, y: 4, width: 180, height: 22)
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 30))
        holder.addSubview(slider)
        volumeSlider = slider
        let sliderItem = NSMenuItem()
        sliderItem.view = holder
        menu.addItem(sliderItem)
        return menu
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        snowfallSlider.snowfall = snowfall
        accumulateItem.state = accumulates ? .on : .off
        let autumn = Preferences.autumn
        let raining = Preferences.rain
        snowItem.state = !autumn && !raining ? .on : .off
        autumnItem.state = autumn && !raining ? .on : .off
        rainItem.state = raining ? .on : .off
        // Rain doesn't pile up, so what is about piles steps aside.
        accumulateItem.isEnabled = !raining
        clearItem.isHidden = raining
        snowOnWindowsItem.title = raining ? tr("Rain on Windows", "Дождь на окнах")
            : autumn ? tr("Leaves on Windows", "Листья на окнах") : tr("Snow on Windows", "Снег на окнах")
        clearItem.title = autumn ? tr("Clear Leaves", "Смести все листья") : tr("Clear Snow", "Смести весь снег")
        snowOnWindowsItem.state = snowOnWindows ? .on : .off
        snowOnWindowsItem.isEnabled = !behindWindows
        iciclesItem.state = Preferences.icicles ? .on : .off
        iciclesItem.isEnabled = snowOnWindows && !behindWindows && !autumn && !raining
        clearItem.isEnabled = screens.contains { $0.simulation.hasSnow || $0.simulation.spriteCount > 0 }
        puffItem.state = Preferences.puff ? .on : .off
        for item in soundItems { item.state = item.tag == Preferences.ambience.rawValue ? .on : .off }
        volumeSlider.doubleValue = Double(Preferences.ambienceVolume)
        updatesItem.isEnabled = !updater.isBusy
        updatesItem.title = updater.isBusy ? tr("Updating…", "Обновление…")
            : updater.available.map { tr("Update to \($0.version)", "Обновить до \($0.version)") }
            ?? tr("Check for Updates…", "Проверить обновления…")
    }

    private func select(_ snowfall: Snowfall) {
        self.snowfall = snowfall
        Preferences.snowfall = snowfall
        for snow in screens {
            if Preferences.rain {
                snow.rain.intensity = Rain.intensity(snowfall)
                snow.rain.on = snowfall != .off
            } else {
                snow.simulation.snowfall = snowfall
            }
        }
        ambience.windiness = windiness
        updateStatusIcon()
    }

    @objc private func toggleAccumulate() {
        accumulates.toggle()
        Preferences.accumulate = accumulates
        for snow in screens { snow.simulation.accumulates = accumulates }
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

    @objc private func toggleIcicles() {
        Preferences.icicles.toggle()
        for snow in screens { snow.icicles.enabled = Preferences.icicles && !Preferences.autumn && !Preferences.rain }
    }

    @objc private func toggleWarmGlow() {
        Preferences.warmGlow.toggle()
    }

    @objc private func clearSnowFromMenu() {
        clearAll()
    }

    private func clearAll() {
        let direction = screens.first?.simulation.breezeDirection ?? -1
        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for snow in screens {
            snow.simulation.blowAway(direction: direction, calm: calm)
            snow.rain.clear()
            if calm { snow.icicles.melt() } else { snow.icicles.dropAll() }
        }
    }

    @objc private func togglePuff() {
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

    @objc private func selectSound(_ sender: NSMenuItem) {
        let mode = Ambience.Mode(rawValue: sender.tag) ?? .off
        Preferences.ambience = mode
        ambience.mode = mode
    }

    @objc private func changeVolume(_ sender: NSSlider) {
        Preferences.ambienceVolume = sender.floatValue
        ambience.volume = sender.floatValue
    }

    @objc private func toggleQuietOnCalls() {
        Preferences.quietOnCalls.toggle()
        if Preferences.quietOnCalls {
            calls.start()
        } else {
            calls.stop()
        }
    }

    @objc private func toggleBehindWindows() {
        behindWindows.toggle()
        Preferences.behindWindows = behindWindows
        for snow in screens {
            snow.window.behindWindows = behindWindows
            snow.checkFullScreen()
        }
    }

    @objc private func toggleOverFullScreen() {
        Preferences.overFullScreen.toggle()
        for snow in screens { snow.overFullScreen = Preferences.overFullScreen }
    }

    @objc private func toggleScreenshots() {
        Preferences.showInScreenshots.toggle()
        for snow in screens {
            snow.window.showsInScreenshots = Preferences.showInScreenshots
            snow.dock.window.showsInScreenshots = Preferences.showInScreenshots
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
        SettingsFile.scheduleSave()
    }

    @objc private func checkForUpdatesFromMenu() {
        updater.check(asked: true)
    }

    @objc private func chooseMode(_ sender: NSMenuItem) {
        applyMode(sender === rainItem ? .rain : sender === autumnItem ? .autumn : .snow)
    }

    private func applyMode(_ mode: SnowMode) {
        let autumn = mode == .autumn
        let raining = mode == .rain
        guard autumn != Preferences.autumn || raining != Preferences.rain else { return }
        let intoRain = raining && !Preferences.rain
        Preferences.autumn = autumn
        Preferences.rain = raining
        let direction = screens.first?.simulation.breezeDirection ?? -1
        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for snow in screens {
            // Rain doesn't lie: what snow or leaves there are blow away as it starts.
            if intoRain && autumn == snow.simulation.autumn { snow.simulation.blowAway(direction: direction, calm: calm) }
            snow.simulation.switchMode(autumn: autumn, direction: direction, calm: calm)
            snow.simulation.snowfall = raining ? .off : snowfall
            snow.rain.intensity = Rain.intensity(snowfall)
            snow.rain.on = raining && snowfall != .off
            // Icicles go with the snow.
            if calm { snow.icicles.melt() } else { snow.icicles.dropAll() }
            snow.icicles.enabled = Preferences.icicles && !autumn && !raining
        }
    }

    @objc private func toggleAutoUpdate() {
        Preferences.autoUpdate.toggle()
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
        let paused = snowfall == .off || hushed
        statusItem.button?.image = paused ? Self.pausedTrayIcon : Self.trayIcon
    }

    // MARK: - System

    private func observeSystem() {
        power.changed = { [unowned self] in screens.forEach { $0.apply(power.budget) } }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()

        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.updater.checkIfDue() }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false }
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.screenLocked = true }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.screenLocked = false }
        observe(.default, NSWindow.didChangeOcclusionStateNotification) { _ in }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.syncScreens() }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { $0.screens.forEach { $0.spaceChanged() } }
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { $0.screens.forEach { $0.watchWindows() } }
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

// MARK: - Settings window and onboarding

extension AppDelegate: SnowControls {
    func setSnowfall(_ snowfall: Snowfall) { select(snowfall) }
    func setMode(_ mode: SnowMode) { applyMode(mode) }
    func setAccumulate(_ on: Bool) { if on != accumulates { toggleAccumulate() } }
    func setMelt(_ on: Bool) { if on != thaws { toggleMeltSnow() } }
    func setSnowOnWindows(_ on: Bool) { if on != snowOnWindows { toggleSnowOnWindows() } }
    func setIcicles(_ on: Bool) { if on != Preferences.icicles { toggleIcicles() } }
    func setWarmGlow(_ on: Bool) { Preferences.warmGlow = on }

    func setPuff(_ on: Bool, done: @escaping (Bool) -> Void) {
        guard on != Preferences.puff else { return done(on) }
        if !on {
            Preferences.puff = false
            breath.stop()
            return done(false)
        }
        breath.start { [weak self] started in
            if started {
                Preferences.puff = true
            } else {
                self?.explainMicrophone()
            }
            done(started)
        }
    }

    func setSound(_ mode: Ambience.Mode) {
        Preferences.ambience = mode
        ambience.mode = mode
    }

    func setVolume(_ volume: Float) {
        Preferences.ambienceVolume = volume
        ambience.volume = volume
    }

    func setQuietOnCalls(_ on: Bool) { if on != Preferences.quietOnCalls { toggleQuietOnCalls() } }
    func setBehindWindows(_ on: Bool) { if on != behindWindows { toggleBehindWindows() } }
    func setOverFullScreen(_ on: Bool) { if on != Preferences.overFullScreen { toggleOverFullScreen() } }
    func setShowInScreenshots(_ on: Bool) { if on != Preferences.showInScreenshots { toggleScreenshots() } }
    func setMaxPerformance(_ on: Bool) { Preferences.maxPerformance = on }
    func setOpenAtLogin(_ on: Bool) { if on != (SMAppService.mainApp.status == .enabled) { toggleOpenAtLogin() } }
    func setAutoUpdate(_ on: Bool) { Preferences.autoUpdate = on }
    func clearSnow() { clearAll() }
    func checkForUpdates() { updater.check(asked: true) }
}
