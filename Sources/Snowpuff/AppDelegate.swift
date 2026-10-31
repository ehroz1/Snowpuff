import AppKit
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
    private var accumulateItem: NSMenuItem!
    private var meltItem: NSMenuItem!
    private var snowOnWindowsItem: NSMenuItem!
    private var iciclesItem: NSMenuItem!
    private var warmGlowItem: NSMenuItem!
    private var clearItem: NSMenuItem!
    private var puffItem: NSMenuItem!
    private var soundItems: [NSMenuItem] = []
    private var volumeSlider: NSSlider!
    private var quietItem: NSMenuItem!
    private var behindWindowsItem: NSMenuItem!
    private var screenshotsItem: NSMenuItem!
    private var loginItem: NSMenuItem!
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        if AppMover.moveIfNeeded() {
            NSApp.terminate(nil)
            return
        }
        Preferences.registerDefaults()
        guard let device = MTLCreateSystemDefaultDevice() else {
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

        statusItem = makeStatusItem()
        updateStatusIcon()
        setUpSound()
        observeSystem()
        if snowfallHeld {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.showWelcome() }
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
                snow.window.alphaValue = hushed ? 0 : 1
                screens.append(snow)
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

    // MARK: - Sound, breath and calls

    private func setUpSound() {
        ambience.volume = Preferences.ambienceVolume
        ambience.windiness = windiness
        ambience.mode = Preferences.ambience
        breath.puffed = { [weak self] strength in
            guard let self, !hushed else { return }
            for snow in screens { snow.simulation.breathe(strength) }
        }
        if Preferences.puff { breath.start() }
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
        ambience.muted = on
        if on {
            if breath.isListening { breath.stop() }
        } else if Preferences.puff {
            breath.start()
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.8
            for snow in screens {
                snow.window.animator().alphaValue = on ? 0 : 1
                snow.dock.window.animator().alphaValue = on ? 0 : 1
            }
        }, completionHandler: { [weak self] in self?.updateActivity() })
        if !on { updateActivity() }
        updateStatusIcon()
    }

    // MARK: - Menu

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        menu.addItem(.sectionHeader(title: tr("Snowfall", "Снегопад")))
        snowfallSlider.changed = { [unowned self] in select($0) }
        let sliderItem = NSMenuItem()
        sliderItem.view = snowfallSlider
        menu.addItem(sliderItem)
        menu.addItem(.separator())
        accumulateItem = add(tr("Accumulate", "Сугробы"), #selector(toggleAccumulate), to: menu)
        meltItem = add(tr("Melt Snow", "Таяние"), #selector(toggleMeltSnow), to: menu)
        snowOnWindowsItem = add(tr("Snow on Windows", "Снег на окнах"), #selector(toggleSnowOnWindows), to: menu)
        iciclesItem = add(tr("Icicles", "Сосульки"), #selector(toggleIcicles), to: menu)
        warmGlowItem = add(tr("Warm Window Light", "Тёплый свет окна"), #selector(toggleWarmGlow), to: menu)
        clearItem = add(tr("Clear Snow", "Смести весь снег"), #selector(clearSnow), to: menu)
        menu.addItem(.separator())
        puffItem = add(tr("Blow on the Snow (Microphone)", "Подуть на снег (микрофон)"), #selector(togglePuff), to: menu)
        let soundItem = menu.addItem(withTitle: tr("Sound", "Звук"), action: nil, keyEquivalent: "")
        soundItem.submenu = makeSoundMenu()
        quietItem = add(tr("Hide During Calls", "Прятать на созвонах"), #selector(toggleQuietOnCalls), to: menu)
        menu.addItem(.separator())
        behindWindowsItem = add(tr("Behind Windows", "За окнами"), #selector(toggleBehindWindows), to: menu)
        screenshotsItem = add(tr("Show in Screenshots", "Показывать на скриншотах"), #selector(toggleScreenshots), to: menu)
        loginItem = add(tr("Open at Login", "Открывать при входе"), #selector(toggleOpenAtLogin), to: menu)
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
        meltItem.state = thaws ? .on : .off
        meltItem.isEnabled = accumulates
        snowOnWindowsItem.state = snowOnWindows ? .on : .off
        snowOnWindowsItem.isEnabled = !behindWindows
        iciclesItem.state = Preferences.icicles ? .on : .off
        iciclesItem.isEnabled = snowOnWindows && !behindWindows
        warmGlowItem.state = Preferences.warmGlow ? .on : .off
        warmGlowItem.isEnabled = snowOnWindows && !behindWindows
        clearItem.isEnabled = screens.contains { $0.simulation.hasSnow || $0.simulation.spriteCount > 0 }
        puffItem.state = Preferences.puff ? .on : .off
        for item in soundItems { item.state = item.tag == Preferences.ambience.rawValue ? .on : .off }
        volumeSlider.doubleValue = Double(Preferences.ambienceVolume)
        quietItem.state = Preferences.quietOnCalls ? .on : .off
        behindWindowsItem.state = behindWindows ? .on : .off
        screenshotsItem.state = Preferences.showInScreenshots ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func select(_ snowfall: Snowfall) {
        self.snowfall = snowfall
        Preferences.snowfall = snowfall
        for snow in screens { snow.simulation.snowfall = snowfall }
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
        for snow in screens { snow.icicles.enabled = Preferences.icicles }
    }

    @objc private func toggleWarmGlow() {
        Preferences.warmGlow.toggle()
    }

    @objc private func clearSnow() {
        let direction = screens.first?.simulation.breezeDirection ?? -1
        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for snow in screens {
            snow.simulation.blowAway(direction: direction, calm: calm)
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
            if behindWindows { snow.dropWindowSnow() }
        }
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
        let awake = !screensAsleep && !screenLocked && !sessionInactive && !hushed
        for snow in screens {
            snow.setActive(awake && snow.window.occlusionState.contains(.visible))
        }
    }
}
