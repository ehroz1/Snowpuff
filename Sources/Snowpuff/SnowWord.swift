import AppKit
import CoreGraphics

/// Typing "snow", or "снег" on a Russian layout, anywhere brings a flurry. Only the eight keys those words use are
/// looked at, a few times a second, and only the order they go down in is kept, for two seconds: nothing typed is
/// read, stored or sent.
final class SnowWord {
    var typed: () -> Void = {}
    private var timer: Timer?
    private var down: Set<CGKeyCode> = []
    private var recent: [(key: CGKeyCode, at: CFTimeInterval)] = []

    // US key codes: S N O W, and C Y T U where a Russian layout has С Н Е Г.
    private static let snow: [CGKeyCode] = [1, 45, 31, 13]
    private static let sneg: [CGKeyCode] = [8, 16, 17, 32]
    private static let watched = Set(snow + sneg)

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        recent.removeAll()
        down.removeAll()
    }

    private func poll() {
        let now = CACurrentMediaTime()
        for key in Self.watched {
            let pressed = CGEventSource.keyState(.combinedSessionState, key: key)
            if pressed && !down.contains(key) {
                recent.append((key, now))
            }
            if pressed { down.insert(key) } else { down.remove(key) }
        }
        recent.removeAll { now - $0.at > 2 }
        let keys = recent.suffix(4).map(\.key)
        if keys == Self.snow || keys == Self.sneg {
            recent.removeAll()
            typed()
        }
    }
}
