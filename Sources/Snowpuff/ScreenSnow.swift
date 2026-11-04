import AppKit
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
            let update = tracker.poll(now: now, eager: NSEvent.pressedMouseButtons != 0)
            simulation.windowFrames = tracker.covers.map { SIMD4(Float($0.minX), Float($0.minY), Float($0.maxX), Float($0.maxY)) }
            if let update {
                icicles.update(update.surfaces, interval: update.interval, keep: update.parked.union(update.elsewhere), sliding: update.sliding)
                rain.updateWindows(update.surfaces, interval: Double(update.interval))
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
        lookout = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.checkFullScreen() }
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
