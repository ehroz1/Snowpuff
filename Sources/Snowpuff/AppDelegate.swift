import AppKit
import CSnowpuffNet
import MetalKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var device: MTLDevice!
    private var screens: [ScreenSnow] = []
    private let displays = Displays()
    private var surfaces: Surfaces = []
    private var thaws = true
    private var behindWindows = false
    private var snowfallHeld = false
    private var halloween = false
    private var newYear = false
    private var statusItem: NSStatusItem!
    private let intensitySlider = MenuSlider(range: 0...1)
    private let opacitySlider = MenuSlider(range: Preferences.opacityRange, captioned: false)
    private var opacityItem: NSMenuItem!
    private let opacityRow = MenuDisclosure()
    private var opacitySliderItem: NSMenuItem!
    private var accumulateItem: NSMenuItem!
    private let accumulateRow = MenuDisclosure()
    private var surfacesItem: NSMenuItem!
    private let surfacePicker = SurfacePicker()
    private var meltItem: NSMenuItem!
    private var clearItem: NSMenuItem!
    private var halloweenItem: NSMenuItem!
    private var newYearItem: NSMenuItem!
    private var fightItem: NSMenuItem?
    private var shimmerTimer: Timer?
    /// Max Performance as it was before this player came into a snowball fight's room, to go back to on leaving it.
    private var performanceBeforeFight: Bool?
    private var fightStatusItem: NSMenuItem?
    private var fightInviteItem: NSMenuItem?
    private var fightJoinItem: NSMenuItem?
    /// A word on what was just done, shown in place of the room's state for a moment.
    private var fightNotice: String?
    private var fightNoticeTimer: Timer?
    private var fightLeaveItem: NSMenuItem?
    private var mixedItem: NSMenuItem!
    private var modeItems: [(item: NSMenuItem, mode: Mode)] = []
    private var maxPerformanceItem: NSMenuItem!
    private var behindWindowsItem: NSMenuItem!
    private var fullScreenItem: NSMenuItem!
    private var screenshotsItem: NSMenuItem!
    private var deepInteractionItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var updatesItem: NSMenuItem!
    private var observers: [NSObjectProtocol] = []
    private var screensAsleep = false
    private let screenshots = ScreenshotWatch()
    private var screenLocked = false
    private var sessionInactive = false
    let updater = Updater()
    private var welcome: WelcomeController?
    private let power = PowerMonitor()
    private var halloweenTimer: Timer?
    /// Snowpuff's own parts: sound, breath, calls, the weather outside, shortcuts and the rest.
    private let parts = SnowpuffParts()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if AppMover.moveIfNeeded() {
            NSApp.terminate(nil)
            return
        }
        CrashGuard.start()
        SettingsFile.restoreIfNeeded()
        Preferences.registerSnowpuffDefaults()
        Preferences.registerDefaults()
        guard let device = Self.lowPowerDevice() ?? MTLCreateSystemDefaultDevice() else {
            NSApp.terminate(nil)
            return
        }
        self.device = device
        surfaces = Preferences.surfaces
        thaws = Preferences.meltSnow
        behindWindows = Preferences.behindWindows
        snowfallHeld = !Preferences.welcomed
        syncScreens()
        // With no display attached yet, the snow comes once one is.
        guard !screens.isEmpty || NSScreen.screens.isEmpty else {
            NSApp.terminate(nil)
            return
        }

        updater.start()
        statusItem = makeStatusItem()
        updateStatusIcon()
        refreshHalloween()
        halloweenTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refreshHalloween() }
        observeSystem()
        Marquee.enabled = Preferences.surfaces.contains(.selection)
        // What the room comes to shows in the open menu at once.
        observers.append(NotificationCenter.default.addObserver(forName: SnowballRoom.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            boostForFight()
            updateFightItems()
            fightStatusItem?.menu?.items.forEach { $0.view?.needsDisplay = true }
        })
        screenshots.stepAside = { [weak self] aside in self?.screens.forEach { $0.stepAside(aside) } }
        screenshots.start()
        setUpSnowpuff()
        if snowfallHeld {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.showWelcome() }
        }
    }

    // MARK: - Displays

    /// One overlay per display: new displays get snow, removed ones lose theirs, the rest follow resolution changes.
    private func syncScreens() {
        let current = NSScreen.screens
        displays.update(screens: current)
        let ids = Set(current.compactMap(\.displayID))
        for gone in screens where !ids.contains(gone.displayID) { gone.close() }
        screens.removeAll { !ids.contains($0.displayID) }

        for screen in current {
            if let existing = screens.first(where: { $0.displayID == screen.displayID }) {
                existing.fit(to: screen)
            } else if let snow = ScreenSnow(screen: screen, device: device, displays: displays, surfaces: { [unowned self] in
                // The wallpaper's depth needs the windows too: a flake over one is in front of it, not in the picture.
                surfaces.union(Preferences.depth ? .wallpaper : [])
            }) {
                snow.simulation.snowfallHeld = snowfallHeld
                snow.simulation.snowfallReleased = { [weak self] in self?.releaseSnowfall() }
                snow.halloween = halloween
                snow.newYear = newYear
                snow.modes = modesNow
                snow.maxFrameRate = Preferences.maxPerformance
                snow.activityChanged = { [weak self] in self?.updateActivity() }
                snow.apply(power.budget)
                screens.append(snow)
                preparePuff(snow)
            }
        }
        displays.snows = screens
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

    // MARK: - Menu

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        menu.addItem(.sectionHeader(title: tr("intensity")))
        intensitySlider.changed = { [unowned self] in select(intensity: $0) }
        let intensityItem = NSMenuItem()
        intensityItem.view = intensitySlider
        menu.addItem(intensityItem)
        // Opacity is set once and left, so it folds away like Accumulate, its value on the row.
        opacityItem = menu.addItem(withTitle: tr("opacity"), action: nil, keyEquivalent: "")
        opacityItem.view = opacityRow
        opacityRow.summaryWhileOpen = true
        opacityRow.toggled = { [unowned self] in
            opacityRow.open.toggle()
            opacitySliderItem.isHidden = !opacityRow.open
        }
        opacitySlider.changed = { [unowned self] opacity in
            Preferences.fallingOpacity = opacity
            for snow in screens { snow.simulation.fallingOpacity = Float(opacity) }
            opacityRow.summary = MenuSlider.percent(opacity)
        }
        opacitySliderItem = NSMenuItem()
        opacitySliderItem.view = opacitySlider
        opacitySliderItem.isHidden = true
        menu.addItem(opacitySliderItem)
        accumulateItem = menu.addItem(withTitle: tr("accumulate"), action: nil, keyEquivalent: "")
        accumulateItem.view = accumulateRow
        accumulateRow.toggled = { [unowned self] in
            accumulateRow.open.toggle()
            surfacesItem.isHidden = !accumulateRow.open
            if !accumulateRow.open { accumulateRow.fit(accumulateItem.title, least: surfacePicker.frame.width) }
        }
        surfacesItem = NSMenuItem()
        surfacesItem.view = surfacePicker
        surfacesItem.isHidden = true
        surfacePicker.toggled = { [unowned self] surface in toggle(surface) }
        menu.addItem(surfacesItem)
        let modes = NSMenu()
        modes.autoenablesItems = false
        mixedItem = toggle(tr("mixed"), #selector(toggleMixed), to: modes)
        modes.addItem(.separator())
        modeItems = Mode.allCases.map { mode in
            let item = toggle(tr(mode.key), #selector(chooseMode), to: modes)
            (item.view as? MenuToggle)?.staysOpen = { Preferences.mixed }
            return (item, mode)
        }
        modes.addItem(.separator())
        halloweenItem = add(tr("halloween"), #selector(toggleHalloween), to: modes)
        newYearItem = add(tr("newyear"), #selector(toggleNewYear), to: modes)
        menu.addItem(withTitle: tr("mode"), action: nil, keyEquivalent: "").submenu = modes
        let fight = NSMenu()
        fight.autoenablesItems = false
        let status = fight.addItem(withTitle: "", action: nil, keyEquivalent: "")
        status.isEnabled = false
        fightStatusItem = status
        // They leave the menu open, to see the room open and who comes into it.
        fightInviteItem = action(tr("fight.invite"), #selector(inviteToFight), to: fight)
        fightJoinItem = action(tr("fight.join"), #selector(joinFight), to: fight)
        fightLeaveItem = action(tr("fight.leave"), #selector(leaveFight), to: fight)
        let fightRow = menu.addItem(withTitle: tr("fight"), action: nil, keyEquivalent: "")
        fightRow.submenu = fight
        fightRow.attributedTitle = Shimmer.title(tr("fight"), phase: 0)
        fightItem = fightRow
        clearItem = add(tr("clear.snow"), #selector(clearSnow), to: menu)
        menu.addItem(.separator())
        let settings = NSMenu()
        settings.autoenablesItems = false
        settings.addItem(.sectionHeader(title: tr("behavior")))
        meltItem = toggle(tr("melt.snow"), #selector(toggleMeltSnow), to: settings)
        deepInteractionItem = toggle(tr("deep"), #selector(toggleDeepInteraction), to: settings)
        settings.addItem(.separator())
        settings.addItem(.sectionHeader(title: tr("display")))
        behindWindowsItem = toggle(tr("behind"), #selector(toggleBehindWindows), to: settings)
        fullScreenItem = toggle(tr("full_screen"), #selector(toggleFullScreen), to: settings)
        screenshotsItem = toggle(tr("screenshots"), #selector(toggleScreenshots), to: settings)
        maxPerformanceItem = toggle(tr("performance"), #selector(toggleMaxPerformance), to: settings)
        settings.addItem(.separator())
        settings.addItem(.sectionHeader(title: tr("general")))
        loginItem = toggle(tr("login"), #selector(toggleOpenAtLogin), to: settings)
        updatesItem = add(tr("updates"), #selector(checkForUpdates), to: settings)
        menu.addItem(withTitle: tr("settings"), action: nil, keyEquivalent: "").submenu = settings
        addSnowpuffItems(modes: modes, settings: settings, menu: menu)
        add(tr("support"), #selector(openSponsors), to: menu).attributedTitle = Self.supportTitle
        menu.addItem(withTitle: tr("quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        item.menu = menu
        return item
    }

    /// The site's sponsor heart, in its colour, ahead of the title: set as the item's image, the status menu doesn't
    /// show it.
    private static let supportTitle: NSAttributedString = {
        let font = NSFont.menuFont(ofSize: 0)
        let title = NSMutableAttributedString(string: tr("support"), attributes: [.font: font])
        guard let heart = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: font.pointSize * 0.85, weight: .regular).applying(.init(paletteColors: [NSColor(srgbRed: 0.92, green: 0.51, blue: 0.51, alpha: 1)])))
        else { return title }
        heart.isTemplate = false
        let attachment = NSTextAttachment()
        attachment.image = heart
        attachment.bounds = CGRect(x: 0, y: (font.capHeight - heart.size.height) / 2, width: heart.size.width, height: heart.size.height)
        title.insert(NSAttributedString(string: "  ", attributes: [.font: font]), at: 0)
        title.insert(NSAttributedString(attachment: attachment), at: 0)
        return title
    }()

    @discardableResult
    private func add(_ title: String, _ action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// A row that does something and keeps the menu open.
    private func action(_ title: String, _ action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let row = MenuToggle(action: action, target: self)
        row.plain = true
        row.fit(title)
        item.view = row
        return item
    }

    private func toggle(_ title: String, _ action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let toggle = MenuToggle(action: action, target: self)
        toggle.fit(title)
        item.view = toggle
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        intensitySlider.value = Preferences.intensity
        opacitySlider.value = Preferences.fallingOpacity
        opacityRow.summary = MenuSlider.percent(Preferences.fallingOpacity)
        opacityRow.fit(opacityItem.title, least: 0)
        let modes = Mode.allCases.filter(Preferences.modes.contains)
        mixedItem.state = Preferences.mixed ? .on : .off
        for (item, mode) in modeItems { item.state = modes.contains(mode) ? .on : .off }
        // Rain neither heaps up nor lies about to clear away.
        let heaps = modes.filter { $0 != .rain }
        meltItem.isHidden = heaps.isEmpty
        clearItem.isHidden = heaps.isEmpty
        meltItem.title = tr(heaps.contains(.snow) ? "melt.snow" : heaps == [.blossom] ? "melt.blossom" : "melt.autumn")
        clearItem.title = tr("clear", heaps)
        (meltItem.view as? MenuToggle)?.fit(meltItem.title)
        // Top to bottom, as they lie on the screen, the wallpaper behind them all first. Rain splashes on the ground
        // whatever it says.
        let choices: [Surfaces] = [.wallpaper, .selection, .widgets, .windows, .dock] + (heaps.isEmpty ? [] : [.ground])
        if surfacePicker.choices != choices { surfacePicker.choices = choices }
        surfacePicker.on = surfaces
        let lit = choices.filter(surfaces.contains)
        let every = lit.count == choices.count
        accumulateRow.summary = every ? tr("all") : lit.isEmpty ? tr("off") : ""
        accumulateRow.summaryIcons = every || lit.isEmpty ? [] : lit
        // Unfolded, the summary isn't shown: the menu keeps its width while the icons are switched.
        if !accumulateRow.open { accumulateRow.fit(accumulateItem.title, least: surfacePicker.frame.width) }
        meltItem.state = thaws ? .on : .off
        meltItem.isEnabled = !surfaces.isEmpty
        deepInteractionItem.state = Preferences.depth ? .on : .off
        clearItem.isEnabled = screens.contains { $0.simulation.hasSnow || $0.simulation.spriteCount > 0 }
        halloweenItem.state = Halloween.isWanted ? .on : .off
        halloweenItem.isEnabled = modes == [.snow]
        newYearItem.state = NewYear.isWanted ? .on : .off
        newYearItem.isEnabled = modes == [.snow]
        updateFightItems()
        updateSnowpuffItems()
        maxPerformanceItem.state = Preferences.maxPerformance ? .on : .off
        behindWindowsItem.state = behindWindows ? .on : .off
        fullScreenItem.state = Preferences.showOverFullScreen ? .on : .off
        fullScreenItem.isEnabled = !behindWindows
        screenshotsItem.state = Preferences.showInScreenshots ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        updatesItem.isEnabled = !updater.isBusy
        updatesItem.title = updater.isBusy ? tr("Updating…", "Обновление…")
            : updater.available.map { tr("Update to \($0.version)", "Обновить до \($0.version)") } ?? tr("updates")
    }

    @objc private func checkForUpdates() {
        updater.check(asked: true)
    }

    private func select(intensity: Double) {
        Preferences.intensity = intensity
        applyWeather()
        updateStatusIcon()
    }

    private func toggle(_ surface: Surfaces) {
        surfaces.formSymmetricDifference(surface)
        Preferences.surfaces = surfaces
        for snow in screens {
            snow.simulation.accumulates = !surfaces.isEmpty
            snow.simulation.groundSettles = surfaces.contains(.ground)
            snow.picture?.frost = surfaces.contains(.wallpaper)
            snow.picture?.wanted = surfaces.contains(.wallpaper) || Preferences.depth
        }
        Marquee.enabled = surfaces.contains(.selection)
        if surfaces.isDisjoint(with: .tracked) { screens.forEach { $0.dropWindowSnow() } }
        if let menu = statusItem.menu {
            menuNeedsUpdate(menu)
            menu.items.forEach { $0.view?.needsDisplay = true }
        }
    }

    @objc private func toggleMeltSnow() {
        thaws.toggle()
        Preferences.meltSnow = thaws
        for snow in screens { snow.simulation.thaws = thaws }
    }

    @objc private func toggleDeepInteraction() {
        Preferences.depth.toggle()
        for snow in screens {
            snow.picture?.depth = Preferences.depth
            snow.picture?.wanted = surfaces.contains(.wallpaper) || Preferences.depth
        }
    }

    @objc private func clearSnow() {
        let direction = screens.first?.simulation.breezeDirection ?? -1
        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for snow in screens {
            snow.simulation.blowAway(direction: direction, calm: calm)
            snow.puff.clear(calm: calm)
            snow.stir()
        }
    }

    @objc private func toggleBehindWindows() {
        behindWindows.toggle()
        Preferences.behindWindows = behindWindows
        for snow in screens { snow.window.behindWindows = behindWindows }
    }

    @objc private func toggleFullScreen() {
        Preferences.showOverFullScreen.toggle()
        for snow in screens { snow.overFullScreen = Preferences.showOverFullScreen }
    }

    @objc private func toggleScreenshots() {
        Preferences.showInScreenshots.toggle()
        for snow in screens {
            snow.window.showsInScreenshots = Preferences.showInScreenshots
            snow.dock.window.showsInScreenshots = Preferences.showInScreenshots
            snow.picture?.showsInScreenshots = Preferences.showInScreenshots
        }
    }

    @objc private func openSponsors() {
        NSWorkspace.shared.open(URL(string: "https://t.me/hhrrzz1")!)
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

    /// Mixed, a third mode picked takes the place of the one picked before the other.
    @objc private func chooseMode(_ sender: NSMenuItem) {
        guard let mode = modeItems.first(where: { $0.item === sender })?.mode else { return }
        if Preferences.mixed {
            let mix = Preferences.mix
            guard !mix.contains(mode) else { return }
            Preferences.mix = [mix[1], mode]
        } else {
            guard mode != Preferences.mode else { return }
        }
        Preferences.mode = mode
        switchModes()
    }

    /// Mixed, the mode picked last falls along with the one picked before it; unmixed, it falls alone.
    @objc private func toggleMixed() {
        Preferences.mixed.toggle()
        let mode = Preferences.mode
        if Preferences.mixed, !Preferences.mix.contains(mode) {
            Preferences.mix = [Preferences.mix[1], mode]
        } else if Preferences.mixed {
            Preferences.mix = [Preferences.mix.first { $0 != mode } ?? .snow, mode]
        }
        switchModes()
    }

    private func switchModes() {
        refreshHalloween()
        updateStatusIcon()
        let direction = screens.first?.simulation.breezeDirection ?? -1
        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for snow in screens { snow.simulation.switchMode(to: modesNow, direction: direction, calm: calm) }
        applyWeather()
    }

    @objc private func toggleMaxPerformance() {
        setMaxPerformance(!Preferences.maxPerformance)
    }

    private func setMaxPerformance(_ on: Bool) {
        Preferences.maxPerformance = on
        for snow in screens { snow.maxFrameRate = on }
    }

    /// In a snowball fight's room the snow runs at full frame rate, snowballs flying smooth; leaving it, Max Performance
    /// goes back to what it was.
    private func boostForFight() {
        let inRoom = SnowballRoom.shared.me != nil
        if inRoom, performanceBeforeFight == nil {
            performanceBeforeFight = Preferences.maxPerformance
            setMaxPerformance(true)
        } else if !inRoom, let before = performanceBeforeFight {
            performanceBeforeFight = nil
            setMaxPerformance(before)
        }
    }

    @objc private func toggleHalloween() {
        Halloween.toggle()
        refreshHalloween()
    }

    /// The snowball fight's name shimmers while the menu is open, and only then.
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem.menu, let item = fightItem, shimmerTimer == nil else { return }
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in
            item.attributedTitle = Shimmer.title(tr("fight"), phase: CGFloat((CACurrentMediaTime() - start) / 2.5))
        }
        RunLoop.main.add(timer, forMode: .common)
        shimmerTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        shimmerTimer?.invalidate()
        shimmerTimer = nil
    }

    /// The snowball fight's room as it is now: what is going on, and what can be done.
    private func updateFightItems() {
        guard let status = fightStatusItem else { return }
        let room = SnowballRoom.shared
        let invite = room.invite != nil ? tr("fight.copy") : tr("fight.invite")
        fightInviteItem?.title = invite
        (fightInviteItem?.view as? MenuToggle)?.fit(invite)
        fightLeaveItem?.isHidden = room.state == .none
        if let notice = fightNotice {
            status.isHidden = false
            status.title = notice
            return
        }
        switch room.state {
        case .none:
            status.isHidden = true
        case .opening:
            status.isHidden = false
            status.title = tr("fight.opening")
        case .joining:
            status.isHidden = false
            status.title = tr("fight.joining")
        case .open:
            status.isHidden = false
            // The round: what is left of each snowman, this player's first; once it is won, who won it.
            let everyone = (room.me.map { [$0] } ?? []) + room.players.map(\.id)
            if let winner = room.winner {
                status.title = winner == room.me ? tr("fight.youwon") : String(format: tr("fight.won"), room.name(of: winner))
            } else if room.players.isEmpty {
                status.title = tr("fight.waiting")
            } else {
                status.title = everyone.map { "\(room.name(of: $0)) ♥\(room.hearts(of: $0))" }.joined(separator: " · ")
            }
        case let .failed(reason):
            status.isHidden = false
            status.title = reason
        }
    }

    /// Opens a room, its invite link going to the clipboard; in one already, copies its link again.
    @objc private func inviteToFight() {
        let room = SnowballRoom.shared
        if let invite = room.invite {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(SnowballRoom.link(for: invite), forType: .string)
            noteFight(tr("fight.copied"))
        } else {
            room.host()
        }
    }

    /// Joins the room of the link on the clipboard; says so when there is none.
    @objc private func joinFight() {
        guard let text = NSPasteboard.general.string(forType: .string), SnowballRoom.holdsInvite(text) else {
            noteFight(tr("fight.nolink"))
            return
        }
        SnowballRoom.shared.join(text)
    }

    private func noteFight(_ notice: String) {
        fightNotice = notice
        fightNoticeTimer?.invalidate()
        let timer = Timer(timeInterval: 2.5, repeats: false) { [weak self] _ in
            self?.fightNotice = nil
            self?.updateFightItems()
        }
        RunLoop.main.add(timer, forMode: .common)
        fightNoticeTimer = timer
        updateFightItems()
    }

    @objc private func leaveFight() {
        SnowballRoom.shared.leave()
    }

    func applicationWillTerminate(_ notification: Notification) {
        SnowballRoom.shared.leaveNow()
        SettingsFile.save()
        if let before = performanceBeforeFight { Preferences.maxPerformance = before }
    }

    /// An invite link clicked anywhere opens the app and brings it into the room.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.scheme == "snowpuff" && $0.host == "join" }) else { return }
        SnowballRoom.shared.join(url.absoluteString)
    }

    @objc private func toggleNewYear() {
        NewYear.toggle()
        refreshHalloween()
    }

    private func updateStatusIcon() {
        statusItem.button?.image = Self.icon(halloween: halloween, newYear: newYear, dimmed: Preferences.intensity <= 0)
    }

    private static let symbol: [Mode: String] = [.snow: "snowflake", .autumn: "leaf", .rain: "cloud.rain"]

    /// The integrated GPU on a Mac with two: asking for the default device would wake the discrete one and hold it
    /// awake for as long as the snow falls. The devices left unused are let go before the discrete GPU powers up.
    private static func lowPowerDevice() -> MTLDevice? {
        autoreleasepool { MTLCopyAllDevices().first { $0.isLowPower } }
    }

    private static func icon(halloween: Bool, newYear: Bool, dimmed: Bool) -> NSImage? {
        let image = halloween ? Halloween.icon : newYear ? NewYear.icon : Preferences.mode == .blossom ? Blossom.icon
            : NSImage(systemSymbolName: Self.symbol[Preferences.mode] ?? "snowflake", accessibilityDescription: "Snowpuff")
        guard dimmed, let image else { return image }
        // Dimmed by hand: the button's appearsDisabled also disables the slider in its menu, so Off could not be left.
        let faded = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.4)
            return true
        }
        faded.isTemplate = image.isTemplate
        faded.accessibilityDescription = image.accessibilityDescription
        return faded
    }

    /// Halloween or the New Year, whichever the snow keeps now. A season that comes round puts away the other
    /// holiday turned on for every day, so only one of them is ticked.
    private func refreshHalloween() {
        if NewYear.isSeason(), NewYear.isWanted, Preferences.halloween { Preferences.halloween = false }
        if Halloween.isSeason(), Halloween.isWanted, Preferences.newYear { Preferences.newYear = false }
        let holiday = Holiday.current
        let spooky = holiday == .halloween, festive = holiday == .newYear
        guard spooky != halloween || festive != newYear else { return }
        halloween = spooky
        newYear = festive
        updateStatusIcon()
        for snow in screens {
            snow.halloween = halloween
            snow.newYear = newYear
        }
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
        observe(.default, NSApplication.didChangeScreenParametersNotification) {
            Spaces.invalidate()
            $0.syncScreens()
        }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) {
            Spaces.invalidate()
            $0.screens.forEach { $0.spaceChanged() }
        }
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
        let awake = !screensAsleep && !screenLocked && !sessionInactive
        for snow in screens {
            snow.occlusionChanged()
            snow.setActive(awake && !snow.givesWay && (snow.window.occlusionState.contains(.visible) || snow.fading), asleep: !awake)
        }
    }
}

/// What Snowpuff keeps for its own parts over the Snowhush snow.
final class SnowpuffParts {
    let ambience = Ambience()
    let breath = Breath()
    let calls = CallMonitor()
    let liveWeather = LiveWeather()
    let snowWord = SnowWord()
    let whatsNew = WhatsNewController()
    var hotKeys: HotKeys?
    /// A call is on: the snow and its sound step aside.
    var hushed = false
    /// The intensity before ⌃⌥S turned the snow off.
    var intensityBefore: Double?
    var clickMonitors: [Any] = []
    var items: [(item: NSMenuItem, isOn: () -> Bool)] = []
    var soundItems: [(item: NSMenuItem, mode: Ambience.Mode)] = []
    var hailItem: NSMenuItem?
    var liveWeatherItem: NSMenuItem?
    let volumeSlider = MenuSlider(range: 0.05...1)
    var countdownItem: NSMenuItem?
}

// MARK: - Snowpuff

extension AppDelegate {
    /// What falls now: the weather outside while that is on, else what Mode says.
    var modesNow: [Mode] {
        guard Preferences.liveWeather, let now = parts.liveWeather.now else { return Preferences.modes }
        switch now.weather {
        case .rain: return [.rain]
        case .leaves: return [.autumn]
        case .petals: return [.blossom]
        default: return [.snow]
        }
    }

    /// Hail beats down instead of what Mode says.
    private var hailing: Bool {
        if Preferences.liveWeather, let now = parts.liveWeather.now { return now.weather == .hail }
        return Preferences.hail
    }

    private var intensityNow: Double {
        if Preferences.liveWeather, let now = parts.liveWeather.now { return now.snowfall.intensity }
        return Preferences.intensity
    }

    fileprivate func setUpSnowpuff() {
        let ambience = parts.ambience
        ambience.volume = Preferences.ambienceVolume
        ambience.mode = Ambience.Mode(rawValue: Preferences.ambience) ?? .off
        ambience.effects = Preferences.soundEffects
        parts.breath.puffed = { [weak self] strength in
            guard let self, !parts.hushed else { return }
            for snow in screens {
                snow.simulation.breathe(strength)
            }
        }
        if Preferences.puff { parts.breath.start { started in if !started { Preferences.puff = false } } }
        parts.calls.listeningItself = { [weak self] in self?.parts.breath.isListening ?? false }
        parts.calls.changed = { [weak self] inCall in self?.setHushed(inCall) }
        if Preferences.quietOnCalls { parts.calls.start() }
        parts.snowWord.typed = { [weak self] in
            self?.screens.forEach {
                $0.puff.flurry()
                $0.stir()
            }
        }
        if Preferences.words { parts.snowWord.start() }
        parts.hotKeys = HotKeys { [weak self] action in self?.hotKey(action) }
        if Preferences.hotkeys { parts.hotKeys?.start() }
        parts.liveWeather.changed = { [weak self] in self?.weatherOutsideChanged() }
        parts.liveWeather.failed = { [weak self] message in
            Preferences.liveWeather = false
            self?.weatherOutsideChanged()
            self?.tell(message)
        }
        if Preferences.liveWeather { parts.liveWeather.start() }
        updater.mayInstallQuietly = { [weak self] in !(self?.parts.hushed ?? false) }
        // A click on an icicle knocks it down with a ring.
        let knock: (NSEvent) -> Void = { [weak self] _ in self?.knockIcicles() }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: knock) { parts.clickMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { event in knock(event); return event }) {
            parts.clickMonitors.append(local)
        }
        SettingsFile.startSaving()
        // What's New, once after an update; a first run gets the welcome instead.
        if !Preferences.welcomed {
            Preferences.lastSeenVersion = Updater.version
        } else if Preferences.lastSeenVersion != Updater.version {
            Preferences.lastSeenVersion = Updater.version
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.parts.whatsNew.show() }
        }
        applyWeather()
    }

    /// A new display's Snowpuff parts: what it hears, its glow, and the weather.
    fileprivate func preparePuff(_ snow: ScreenSnow) {
        snow.puff.heard = { [weak self] cues in
            guard let self, !parts.hushed else { return }
            for cue in cues { parts.ambience.play(cue) }
        }
        applyWeather(only: snow)
    }

    /// Sets every display to the weather: how much falls, hail, the icicles and the extras, and the sounds of rain.
    fileprivate func applyWeather(only: ScreenSnow? = nil) {
        let modes = modesNow
        let hail = hailing
        let intensity = intensityNow
        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let weather: Weather = hail ? .hail : modes.count == 1 ? [Weather.snow, .leaves, .rain, .petals][modes[0].rawValue] : modes.contains(.snow) ? .snow : .leaves
        let fog = Preferences.fog || (Preferences.liveWeather && parts.liveWeather.now?.fog == true)
        let settings = SPSettings(
            weather: weather.core,
            blizzard: Preferences.blizzard ? 1 : 0,
            fog: fog ? 1 : 0,
            stars: Preferences.stars ? 1 : 0,
            garland: Preferences.garland ? 1 : 0,
            frost: Preferences.frost ? 1 : 0,
            creatures: Preferences.creatures ? 1 : 0,
            padding: 0,
            intensity: Float(intensity) * 2
        )
        for snow in only.map({ [$0] }) ?? screens {
            // Hail falls alone: the snow, leaves or rain stop while it beats down.
            snow.simulation.intensity = hail ? 0 : Float(intensity)
            snow.puff.apply(settings)
            snow.puff.warmGlow = Preferences.warmGlow
            snow.puff.setIcicles(Preferences.icicles && modes.contains(.snow) && !hail, calm: calm)
            snow.stir()
        }
        let ambience = parts.ambience
        ambience.rainLevel = modes.contains(.rain) && !hail ? Float(intensity) * 2 : 0
        ambience.hailLevel = hail ? Float(intensity) * 2 : 0
        ambience.windiness = Float(min(max(intensity * 1.2, 0.15), 1))
    }

    private func weatherOutsideChanged() {
        let direction = screens.first?.simulation.breezeDirection ?? -1
        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for snow in screens where snow.simulation.modes != modesNow {
            snow.simulation.switchMode(to: modesNow, direction: direction, calm: calm)
        }
        applyWeather()
        updateStatusIcon()
    }

    private func setHushed(_ on: Bool) {
        guard parts.hushed != on else { return }
        parts.hushed = on
        if on {
            if parts.breath.isListening { parts.breath.stop() }
        } else if Preferences.puff {
            parts.breath.start()
        }
        parts.ambience.muted = on
        NSAnimationContext.runAnimationGroup { context in
            context.duration = on ? 0.6 : 1.2
            for snow in screens {
                snow.window.contentView?.animator().alphaValue = on ? 0 : 1
                snow.dock.window.contentView?.animator().alphaValue = on ? 0 : 1
            }
        }
    }

    private func knockIcicles() {
        let mouse = NSEvent.mouseLocation
        for snow in screens where snow.window.frame.contains(mouse) {
            let point = SIMD2(Float(mouse.x - snow.window.frame.minX), Float(mouse.y - snow.window.frame.minY))
            guard let pitch = snow.puff.knock(at: point) else { continue }
            if !parts.hushed { parts.ambience.play(SPCue(kind: 1, value: pitch)) }
            snow.stir()
        }
    }

    private func hotKey(_ action: HotKeys.Action) {
        switch action {
        case .snow:
            if Preferences.intensity > 0 {
                parts.intensityBefore = Preferences.intensity
                select(intensity: 0)
            } else {
                select(intensity: parts.intensityBefore ?? 0.5)
            }
        case .mode:
            let next = Mode.allCases[(Preferences.mode.rawValue + 1) % Mode.allCases.count]
            Preferences.mode = next
            if Preferences.mixed { Preferences.mix = [Preferences.mix[1], next] }
            switchModes()
        case .clear:
            clearSnow()
        case .frost:
            Preferences.frost.toggle()
            applyWeather()
        case .garland:
            Preferences.garland.toggle()
            applyWeather()
        case .help:
            parts.whatsNew.showHelp()
        case .snowman, .snowball:
            // Snowmen and snowballs are the snowball fight's now, in the menu.
            break
        }
    }

    private func tell(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Snowpuff"
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: Menu

    fileprivate func addSnowpuffItems(modes: NSMenu, settings: NSMenu, menu: NSMenu) {
        modes.addItem(.separator())
        parts.hailItem = snowpuffToggle(tr("Hail", "Град"), modes, { Preferences.hail }) { [unowned self] in
            Preferences.hail.toggle()
            applyWeather()
            updateStatusIcon()
        }
        parts.liveWeatherItem = snowpuffToggle(tr("Weather Outside", "Погода за окном"), modes, { Preferences.liveWeather }) { [unowned self] in
            Preferences.liveWeather.toggle()
            if Preferences.liveWeather { parts.liveWeather.start() } else { parts.liveWeather.stop() }
            weatherOutsideChanged()
        }

        settings.addItem(.separator())
        settings.addItem(.sectionHeader(title: tr("Magic", "Волшебство")))
        snowpuffToggle(tr("Icicles", "Сосульки"), settings, { Preferences.icicles }) { [unowned self] in
            Preferences.icicles.toggle()
            applyWeather()
        }
        snowpuffToggle(tr("Warm Window Glow", "Тёплый свет окна"), settings, { Preferences.warmGlow }) { [unowned self] in
            Preferences.warmGlow.toggle()
            applyWeather()
        }
        snowpuffToggle(tr("Frost on the Glass", "Морозные узоры"), settings, { Preferences.frost }) { [unowned self] in
            Preferences.frost.toggle()
            applyWeather()
        }
        snowpuffToggle(tr("Garland on Windows", "Гирлянда на окнах"), settings, { Preferences.garland }) { [unowned self] in
            Preferences.garland.toggle()
            applyWeather()
        }
        snowpuffToggle(tr("Stars at Night", "Звёзды ночью"), settings, { Preferences.stars }) { [unowned self] in
            Preferences.stars.toggle()
            applyWeather()
        }
        snowpuffToggle(tr("Fog", "Туман"), settings, { Preferences.fog }) { [unowned self] in
            Preferences.fog.toggle()
            applyWeather()
        }
        snowpuffToggle(tr("Swirl Behind the Cursor", "Вихрь за курсором"), settings, { Preferences.blizzard }) { [unowned self] in
            Preferences.blizzard.toggle()
            applyWeather()
        }
        snowpuffToggle(tr("Cat and Bullfinch", "Кот и снегирь"), settings, { Preferences.creatures }) { [unowned self] in
            Preferences.creatures.toggle()
            applyWeather()
        }
        snowpuffToggle(tr("Blow on the Snow", "Подуть на снег"), settings, { Preferences.puff }) { [unowned self] in
            if Preferences.puff {
                Preferences.puff = false
                parts.breath.stop()
            } else {
                Preferences.puff = true
                parts.breath.start { started in
                    if !started {
                        Preferences.puff = false
                        self.tell(tr("Snowpuff needs the microphone to hear you blow: allow it in System Settings › Privacy & Security › Microphone.",
                                     "Чтобы услышать, как ты дуешь, Snowpuff нужен микрофон: разреши его в «Системных настройках → Конфиденциальность и безопасность → Микрофон»."))
                    }
                }
            }
        }
        snowpuffToggle(tr("Type “snow” for a Flurry", "Слово «снег» — снегопад"), settings, { Preferences.words }) { [unowned self] in
            Preferences.words.toggle()
            if Preferences.words { parts.snowWord.start() } else { parts.snowWord.stop() }
        }
        snowpuffToggle(tr("Shortcuts ⌃⌥", "Горячие клавиши ⌃⌥"), settings, { Preferences.hotkeys }) { [unowned self] in
            Preferences.hotkeys.toggle()
            if Preferences.hotkeys { parts.hotKeys?.start() } else { parts.hotKeys?.stop() }
        }
        snowpuffToggle(tr("Hide During Calls", "Прятать на созвонах"), settings, { Preferences.quietOnCalls }) { [unowned self] in
            Preferences.quietOnCalls.toggle()
            if Preferences.quietOnCalls {
                parts.calls.start()
            } else {
                parts.calls.stop()
                setHushed(false)
            }
        }

        settings.addItem(.separator())
        settings.addItem(.sectionHeader(title: tr("Sound", "Звук")))
        for mode in Ambience.Mode.allCases {
            let item = snowpuffToggle(mode.title, settings, { Preferences.ambience == mode.rawValue }) { [unowned self] in
                Preferences.ambience = mode.rawValue
                parts.ambience.mode = mode
            }
            parts.soundItems.append((item, mode))
        }
        parts.volumeSlider.changed = { [unowned self] volume in
            Preferences.ambienceVolume = Float(volume)
            parts.ambience.volume = Float(volume)
        }
        let volume = NSMenuItem()
        volume.view = parts.volumeSlider
        settings.addItem(volume)
        snowpuffToggle(tr("Sound Effects", "Звуковые эффекты"), settings, { Preferences.soundEffects }) { [unowned self] in
            Preferences.soundEffects.toggle()
            parts.ambience.effects = Preferences.soundEffects
        }
        settings.addItem(.separator())
        snowpuffToggle(tr("Install Updates Automatically", "Обновляться автоматически"), settings, { Preferences.autoUpdate }) {
            Preferences.autoUpdate.toggle()
        }
        snowpuffAction(tr("Show Settings File", "Показать файл настроек"), settings) {
            SettingsFile.save()
            NSWorkspace.shared.activateFileViewerSelecting([SettingsFile.url])
        }

        menu.addItem(.separator())
        let countdown = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        countdown.isEnabled = false
        parts.countdownItem = countdown
        snowpuffAction(tr("How to Use…", "Как пользоваться…"), menu) { [unowned self] in parts.whatsNew.showHelp() }
        snowpuffAction(tr("What's New", "Что нового"), menu) { [unowned self] in parts.whatsNew.show() }
        snowpuffAction(tr("Report a Problem…", "Сообщить о проблеме…"), menu) { Self.reportProblem() }
    }

    fileprivate func updateSnowpuffItems() {
        for (item, isOn) in parts.items { item.state = isOn() ? .on : .off }
        parts.hailItem?.isEnabled = !Preferences.liveWeather
        parts.volumeSlider.value = Double(Preferences.ambienceVolume)
        parts.countdownItem?.title = Self.newYearCountdown
        if Preferences.liveWeather, let summary = parts.liveWeather.summary {
            parts.liveWeatherItem?.title = tr("Weather Outside", "Погода за окном") + " · " + summary
            (parts.liveWeatherItem?.view as? MenuToggle)?.fit(parts.liveWeatherItem?.title ?? "")
        }
    }

    @discardableResult
    private func snowpuffToggle(_ title: String, _ menu: NSMenu, _ isOn: @escaping () -> Bool, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = toggle(title, #selector(snowpuffItemChosen(_:)), to: menu)
        item.representedObject = SnowpuffAction(action)
        parts.items.append((item, isOn))
        return item
    }

    private func snowpuffAction(_ title: String, _ menu: NSMenu, _ action: @escaping () -> Void) {
        let item = menu.addItem(withTitle: title, action: #selector(snowpuffItemChosen(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = SnowpuffAction(action)
    }

    @objc fileprivate func snowpuffItemChosen(_ sender: Any?) {
        let item = (sender as? NSMenuItem) ?? parts.items.first { $0.item.view === (sender as? NSView) }?.item
        (item?.representedObject as? SnowpuffAction)?.run()
        if let menu = statusItem.menu {
            menuNeedsUpdate(menu)
            menu.items.forEach { $0.view?.needsDisplay = true }
            menu.items.compactMap(\.submenu).forEach { $0.items.forEach { $0.view?.needsDisplay = true } }
        }
    }

    private static var newYearCountdown: String {
        let calendar = Calendar.current
        let now = Date()
        let year = calendar.component(.year, from: now)
        guard let newYear = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else { return "" }
        let left = calendar.dateComponents([.day, .hour, .minute], from: now, to: newYear)
        let days = left.day ?? 0, hours = left.hour ?? 0, minutes = left.minute ?? 0
        if days == 0 { return tr("New Year in \(hours) h \(minutes) min", "До Нового года \(hours) ч \(minutes) мин") }
        return tr("New Year in \(days) d \(hours) h", "До Нового года \(days) дн \(hours) ч")
    }

    /// A new issue on GitHub with the version and the system filled in; nothing is sent until it is submitted.
    private static func reportProblem() {
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
}

/// A menu row's action, carried by the row.
final class SnowpuffAction: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    func run() { action() }
}
