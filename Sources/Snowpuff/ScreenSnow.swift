import AppKit
import CSnowpuffCore
import MetalKit

/// The snow on one display: its overlay window, simulation and renderer, the windows tracked on it and its light.
final class ScreenSnow {
    let displayID: CGDirectDisplayID
    let window: OverlayWindow
    let dock: DockOverlay
    let simulation: SnowSimulation
    private let view: MTKView
    private let renderer: Renderer
    private let tracker = WindowTracker()
    private let light = SceneLight()
    private(set) var screen: NSScreen
    let icicles = Icicles()
    let rain: Rain
    let extras: SceneExtras
    /// The windows from the last poll, for a drag selection to join.
    private var lastSurfaces: [WindowSurface] = []
    /// A selection being dragged across the desktop: where it started, and whether one showed last frame.
    private var selectionStart: CGPoint?
    private var selectionShown = false
    private var lastSelectionAt: CFTimeInterval = 0
    private static let selectionID: CGWindowID = 0x5E1E_C7ED
    var autumn: Bool {
        get { simulation.autumn }
        set { simulation.autumn = newValue }
    }
    /// A call is on: the snow steps aside.
    var hushed = false {
        didSet { if hushed != oldValue { refreshVisibility() } }
    }
    /// The snow stays over full-screen apps instead of stepping out of their way.
    var overFullScreen = Preferences.overFullScreen {
        didSet { if overFullScreen != oldValue { checkFullScreen() } }
    }
    /// A full-screen app's Space shows on this display: the snow fades out and rests until it goes.
    private(set) var covered = false
    /// Showing, or still fading out: drawing goes on until the snow is out of sight.
    private(set) var showing = true
    /// Called once the snow has faded in or out, to pause or resume drawing.
    var visibilityChanged: () -> Void = {}
    private var lookout: Timer?

    init?(screen: NSScreen, device: MTLDevice, snowOnWindows: @escaping () -> Bool) {
        guard let displayID = screen.displayID else { return nil }
        let simulation = SnowSimulation(
            width: Float(screen.frame.width),
            height: Float(screen.frame.height),
            snowfall: Preferences.rain ? .off : Preferences.snowfall
        )
        simulation.thaws = Preferences.meltSnow
        simulation.accumulates = Preferences.accumulate
        let renderer: Renderer
        do {
            renderer = try Renderer(device: device, pixelFormat: .bgra8Unorm, simulation: simulation)
        } catch {
            NSLog("Snowpuff: Metal setup failed: \(error)")
            return nil
        }
        self.displayID = displayID
        self.screen = screen
        rain = Rain(width: Float(screen.frame.width), height: Float(screen.frame.height))
        extras = SceneExtras(width: Float(screen.frame.width), height: Float(screen.frame.height))
        rain.intensity = Rain.intensity(Preferences.snowfall)
        rain.on = Preferences.rain && Preferences.snowfall != .off
        self.simulation = simulation
        self.renderer = renderer
        window = OverlayWindow(screen: screen)
        window.behindWindows = Preferences.behindWindows
        window.showsInScreenshots = Preferences.showInScreenshots
        dock = DockOverlay(screen: screen, device: device)
        dock.window.showsInScreenshots = Preferences.showInScreenshots
        renderer.dockOverlay = dock
        view = Self.makeView(device: device, size: screen.frame.size)

        renderer.cursorLocation = { [unowned window] in
            let mouse = NSEvent.mouseLocation
            return SIMD2(Float(mouse.x - window.frame.minX), Float(mouse.y - window.frame.minY))
        }
        renderer.windowSurfaces = { [unowned self] now in
            // Behind the windows the snow still settles on them: what lies on a window's top edge is above it, in
            // plain view.
            guard snowOnWindows() else { return nil }
            let polled = tracker.poll(now: now, eager: NSEvent.pressedMouseButtons != 0)
            let covers = tracker.covers.map { SIMD4(Float($0.minX), Float($0.minY), Float($0.maxX), Float($0.maxY)) }
            simulation.windowFrames = covers
            var update = polled.map { polled in
                // The Dock can be left bare from the Accumulate menu.
                Preferences.snowOnDock ? polled : WindowUpdate(
                    surfaces: polled.surfaces.filter { !$0.isDock }, interval: polled.interval, parked: polled.parked,
                    elsewhere: polled.elsewhere, sliding: polled.sliding, slideVelocity: polled.slideVelocity
                )
            }
            if let update { lastSurfaces = update.surfaces }
            // A selection dragged across the desktop catches the snow too, while it is held.
            let selection = selection(covers: covers)
            if selection != nil || selectionShown {
                let interval = Float(min(max(now - lastSelectionAt, 1.0 / 120), 0.25))
                lastSelectionAt = now
                let extra = selection.map { [WindowSurface(id: Self.selectionID, frame: $0, blockers: [], cornerRadius: 1, cornerExponent: 2, isDock: false)] } ?? []
                update = WindowUpdate(
                    surfaces: lastSurfaces + extra, interval: update?.interval ?? interval, parked: update?.parked ?? [],
                    elsewhere: update?.elsewhere ?? [], sliding: false, slideVelocity: 0
                )
                selectionShown = selection != nil
            }
            if polled != nil { extras.setCovers(covers) }
            if let update {
                icicles.update(update.surfaces, interval: update.interval, keep: update.parked.union(update.elsewhere), sliding: update.sliding)
                rain.updateWindows(update.surfaces, interval: Double(update.interval))
                extras.setWindows(update.surfaces)
            }
            return update
        }
        renderer.sceneLight = { [unowned self] now in
            light.update(screen: self.screen, now: now)
            return (light.light, light.shadowTint, light.rim, light.lantern)
        }
        icicles.enabled = Preferences.icicles && !Preferences.autumn && !Preferences.rain
        renderer.icicles = icicles
        renderer.rain = rain
        renderer.extras = extras
        renderer.daylight = { [unowned self] in light.day }
        renderer.topInset = Float(screen.frame.maxY - screen.visibleFrame.maxY)
        renderer.interaction = {
            (NSEvent.pressedMouseButtons & 1 != 0, NSEvent.modifierFlags.contains(.option))
        }
        renderer.opacity = Preferences.opacity
        renderer.warmGlow = { Preferences.warmGlow && snowOnWindows() }
        renderer.focusedWindow = { [unowned self] in window.behindWindows ? nil : tracker.focused }
        renderer.interactiveFrameRate = Self.interactiveFrameRate(of: screen)
        measure()
        view.delegate = renderer
        window.contentView = view
        window.orderFrontRegardless()
        covered = !overFullScreen && Spaces.fullScreenShowing(on: displayID)
        if covered {
            window.alphaValue = 0
            dock.window.alphaValue = 0
            showing = false
        }
        // A full-screen app can come and go without a Space change being announced, as a video going full screen.
        lookout = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.checkFullScreen() }
    }

    /// Fades the snow out of a full-screen app's way, or back once it goes.
    func checkFullScreen() {
        let now = !overFullScreen && !window.behindWindows && Spaces.fullScreenShowing(on: displayID)
        guard now != covered else { return }
        covered = now
        refreshVisibility()
    }

    /// Shows the snow unless a call or a full-screen app keeps it away; it keeps falling while it fades.
    private func refreshVisibility() {
        let shown = !hushed && !covered
        if shown {
            showing = true
            visibilityChanged()
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = shown ? 0.5 : 0.35
            window.animator().alphaValue = shown ? 1 : 0
            dock.window.animator().alphaValue = shown ? 1 : 0
        }, completionHandler: { [weak self] in
            guard let self, !shown, hushed || covered else { return }
            showing = false
            visibilityChanged()
        })
    }

    func fit(to screen: NSScreen) {
        self.screen = screen
        window.setFrame(screen.frame, display: true)
        dock.fit(to: screen)
        Renderer.fitDrawable(of: view)
        simulation.resize(width: Float(screen.frame.width), height: Float(screen.frame.height))
        rain.resize(width: Float(screen.frame.width), height: Float(screen.frame.height))
        extras.resize(width: Float(screen.frame.width), height: Float(screen.frame.height))
        renderer.topInset = Float(screen.frame.maxY - screen.visibleFrame.maxY)
        light.invalidate()
        renderer.interactiveFrameRate = Self.interactiveFrameRate(of: screen)
        measure()
    }

    private static func interactiveFrameRate(of screen: NSScreen) -> Int {
        min(max(screen.maximumFramesPerSecond, 60), 120)
    }

    func apply(_ budget: PowerBudget) {
        renderer.budget = budget
        simulation.density = budget == .saver ? 0.75 : 1
    }

    func setActive(_ active: Bool) {
        guard view.isPaused == active else { return }
        view.isPaused = !active
        if active { renderer.resetClock() }
    }

    /// Leaves are drawn as cherry petals.
    var petals: Bool {
        get { renderer.petals }
        set { renderer.petals = newValue }
    }

    var opacity: Float {
        get { renderer.opacity }
        set { renderer.opacity = newValue }
    }

    /// Sounds the extras ask for.
    var cues: ([SPCue]) -> Void {
        get { renderer.cues }
        set { renderer.cues = newValue }
    }

    /// The point on this screen in its overlay's coordinates, if it is on it.
    func local(_ point: NSPoint) -> SIMD2<Float>? {
        guard window.frame.contains(point) else { return nil }
        return SIMD2(Float(point.x - window.frame.minX), Float(point.y - window.frame.minY))
    }

    /// A rectangle being dragged out on the desktop, in overlay coordinates: started on no window, in Finder.
    private func selection(covers: [SIMD4<Float>]) -> CGRect? {
        guard Preferences.deepInteraction, NSEvent.pressedMouseButtons & 1 != 0, !NSEvent.modifierFlags.contains(.option),
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
        else {
            selectionStart = nil
            return nil
        }
        let mouse = NSEvent.mouseLocation
        let point = CGPoint(x: mouse.x - window.frame.minX, y: mouse.y - window.frame.minY)
        if selectionStart == nil {
            let onWindow = covers.contains { Float(point.x) >= $0.x && Float(point.x) <= $0.z && Float(point.y) >= $0.y && Float(point.y) <= $0.w }
            guard window.frame.contains(mouse), !onWindow else { return nil }
            selectionStart = point
        }
        guard let start = selectionStart else { return nil }
        let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
        return rect.width > 12 && rect.height > 12 ? rect : nil
    }

    func dropWindowSnow() {
        rain.updateWindows([], interval: 0.1)
        simulation.updateWindows([], interval: 0.1)
        simulation.windowFrames = []
        icicles.dropAll()
        tracker.reset()
    }

    func spaceChanged() {
        checkFullScreen()
        simulation.spaceChanged()
        light.invalidate()
        watchWindows()
        window.holdInPlace()
        dock.window.holdInPlace()
    }

    func watchWindows() {
        tracker.watchClosely(now: CACurrentMediaTime())
    }

    func close() {
        lookout?.invalidate()
        view.isPaused = true
        view.delegate = nil
        window.orderOut(nil)
        dock.close()
    }

    /// Window bounds come in global coordinates with the origin at the top left of the primary display.
    private func measure() {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let frame = screen.frame
        tracker.screen = CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
        tracker.menuBarHeight = frame.maxY - screen.visibleFrame.maxY
        tracker.reset()
        let others = NSScreen.screens.map(\.frame).filter { $0 != frame && $0.maxY > frame.minY && $0.minY < frame.maxY }
        simulation.walls = (
            left: !others.contains { abs($0.maxX - frame.minX) < 1 },
            right: !others.contains { abs($0.minX - frame.maxX) < 1 }
        )
    }

    private static func makeView(device: MTLDevice, size: CGSize) -> MTKView {
        let view = MTKView(frame: CGRect(origin: .zero, size: size), device: device)
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 30
        view.autoresizingMask = [.width, .height]
        view.autoResizeDrawable = false
        Renderer.fitDrawable(of: view)
        return view
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
