import CoreGraphics
import Foundation
import simd

/// One icicle as the GPU draws it.
struct IcicleSprite {
    var root: SIMD2<Float>
    var length: Float
    var width: Float
    var angle: Float
    var seed: Float
    var alpha: Float
    var padding: Float = 0
}

/// A run of icicles that share the same windows in front of them.
struct IcicleGroup {
    var offset: Int
    var count: Int
    var occluders: [SIMD4<Float>]
}

/// Icicles along the bottom edges of windows that carry snow, like the ones under the window on the app icon.
/// They grow slowly, ride along when a window is moved gently, and snap off and shatter into snow when it is
/// jerked, shaken, closed or minimized.
final class Icicles {
    private struct Hanging {
        /// From the window's left edge.
        var x: Float
        var length: Float = 0
        var maxLength: Float
        var width: Float
        var seed: Float
        /// Points a second.
        var rate: Float
    }

    private struct Eave {
        var frame: CGRect
        var velocity = SIMD2<Float>(repeating: 0)
        var hanging: [Hanging]
        var occluders: [SIMD4<Float>]
    }

    private struct Falling {
        var position: SIMD2<Float>
        var velocity: SIMD2<Float>
        var length: Float
        var width: Float
        var angle: Float
        var spin: Float
        var seed: Float
    }

    var enabled = true {
        didSet { if !enabled { dropAll() } }
    }
    private var eaves: [CGWindowID: Eave] = [:]
    /// Eaves of windows on another Space, kept out of sight until they return.
    private var away: [CGWindowID: Eave] = [:]
    private var falling: [Falling] = []
    private var grown: Float = 0
    private var dirty = false
    private var random = SystemRandomNumberGenerator()

    var isEmpty: Bool { falling.isEmpty && eaves.values.allSatisfy { $0.hanging.allSatisfy { $0.length < 0.3 } } }
    /// Icicles in the air need a smooth frame rate.
    var isFalling: Bool { !falling.isEmpty }
    var count: Int { falling.count + eaves.values.reduce(0) { $0 + $1.hanging.count } }

    private func rand(_ lower: Float, _ upper: Float) -> Float {
        Float.random(in: lower..<upper, using: &random)
    }

    /// Follows the windows on screen. Windows that are gone drop their icicles; those on another Space keep them.
    /// `sliding` is a whole Space sliding past: the windows move without being moved, so nothing breaks.
    func update(_ surfaces: [WindowSurface], interval: Float, keep: Set<CGWindowID>, sliding: Bool) {
        guard enabled else { return }
        var seen = Set<CGWindowID>()
        for surface in surfaces where !surface.isDock {
            seen.insert(surface.id)
            let frame = surface.frame
            let occluders = surface.eaveBlockers.map { SIMD4(Float($0.minX), Float($0.minY), Float($0.maxX), Float($0.maxY)) }
            if var eave = eaves[surface.id] ?? away.removeValue(forKey: surface.id) {
                let old = eave.frame
                let resized = frame.width != old.width || frame.height != old.height
                if frame.width != old.width {
                    // Icicles keep to the edge that stays put: dragging the left edge slides them with the right one.
                    if abs(frame.maxX - old.maxX) < 0.5 {
                        let shift = Float(frame.minX - old.minX)
                        for i in eave.hanging.indices { eave.hanging[i].x -= shift }
                    }
                    let width = Float(frame.width)
                    let outside = eave.hanging.filter { $0.x < 14 || $0.x > width - 14 }
                    for icicle in outside { drop(icicle, at: frame, velocity: .zero) }
                    eave.hanging.removeAll { $0.x < 14 || $0.x > width - 14 }
                }
                // A poll after a long quiet spell means the window was at rest until now.
                let previous = interval > 0.12 ? SIMD2<Float>(repeating: 0) : eave.velocity
                let moved = SIMD2(Float(frame.minX - old.minX), Float(frame.minY - old.minY))
                let raw = moved / max(interval, 1.0 / 120)
                // The window list reports a dragged window unevenly; smoothing keeps a steady drag from reading as jolts.
                let velocity = previous + (raw - previous) * 0.4
                if !sliding && !resized {
                    let jolt = simd_length(velocity - previous) / max(interval, 1.0 / 120) * 0.016
                    let force = max(simd_length(velocity) * 0.7, jolt)
                    // Long ones snap first: a sharp jerk or a shake breaks them, a slow glide doesn't.
                    let snaps: (Hanging) -> Bool = { $0.length > 2 && force > 2400 - $0.length * 50 }
                    let snapped = eave.hanging.filter(snaps)
                    for icicle in snapped { drop(icicle, at: old, velocity: velocity) }
                    eave.hanging.removeAll(where: snaps)
                }
                eave.frame = frame
                eave.velocity = sliding ? .zero : velocity
                eave.occluders = occluders
                eaves[surface.id] = eave
            } else {
                eaves[surface.id] = Eave(frame: frame, hanging: makeHanging(width: Float(frame.width)), occluders: occluders)
            }
            dirty = true
        }
        for (id, eave) in eaves where !seen.contains(id) {
            if keep.contains(id) {
                away[id] = eave
            } else {
                for icicle in eave.hanging where icicle.length > 1.5 {
                    drop(icicle, at: eave.frame, velocity: SIMD2(0, -60))
                }
            }
            eaves.removeValue(forKey: id)
            dirty = true
        }
    }

    func dropAll() {
        for eave in eaves.values {
            for icicle in eave.hanging where icicle.length > 1.5 { drop(icicle, at: eave.frame, velocity: .zero) }
        }
        eaves.removeAll()
        away.removeAll()
        dirty = true
    }

    /// Lets every icicle melt away at once, as when all the snow is cleared.
    func melt() {
        eaves.removeAll()
        away.removeAll()
        falling.removeAll()
        dirty = true
    }

    /// Returns whether anything visible changed.
    func step(dt: Float, snowOn: (CGWindowID) -> Float, ground: (Float) -> Float, shatter: (SIMD2<Float>, Float) -> Void) -> Bool {
        var changed = dirty || !falling.isEmpty
        dirty = false
        for (id, var eave) in eaves {
            // They only grow under a window with snow on it, and only so long.
            guard snowOn(id) > 1.5 else { continue }
            for i in eave.hanging.indices where eave.hanging[i].length < eave.hanging[i].maxLength {
                let step = eave.hanging[i].rate * dt
                eave.hanging[i].length = min(eave.hanging[i].maxLength, eave.hanging[i].length + step)
                grown += step
            }
            eaves[id] = eave
        }
        if grown > 0.25 {
            grown = 0
            changed = true
        }
        var i = falling.count - 1
        while i >= 0 {
            var piece = falling[i]
            piece.velocity.y -= 2200 * dt
            piece.velocity.x *= 1 - min(1, dt * 0.6)
            piece.position += piece.velocity * dt
            piece.angle += piece.spin * dt
            let tip = piece.position.y - piece.length * cos(piece.angle)
            let floor = ground(piece.position.x)
            if tip <= floor || piece.position.y < -80 {
                if piece.position.y > -40 {
                    shatter(SIMD2(piece.position.x, max(floor, 0) + 2), piece.length * piece.width)
                }
                falling.swapAt(i, falling.count - 1)
                falling.removeLast()
            } else {
                falling[i] = piece
            }
            i -= 1
        }
        return changed
    }

    func write(into buffer: UnsafeMutablePointer<IcicleSprite>, capacity: Int) -> [IcicleGroup] {
        var groups: [IcicleGroup] = []
        var offset = 0
        for eave in eaves.values {
            let start = offset
            let left = Float(eave.frame.minX), bottom = Float(eave.frame.minY)
            guard bottom > 4 else { continue }
            for icicle in eave.hanging where icicle.length >= 0.6 && offset < capacity {
                buffer[offset] = IcicleSprite(
                    root: SIMD2(left + icicle.x, bottom + 0.5),
                    length: icicle.length,
                    width: icicle.width * min(1, 0.45 + icicle.length / 10),
                    angle: 0,
                    seed: icicle.seed,
                    alpha: min(1, icicle.length / 3)
                )
                offset += 1
            }
            if offset > start { groups.append(IcicleGroup(offset: start, count: offset - start, occluders: eave.occluders)) }
        }
        let start = offset
        for piece in falling where offset < capacity {
            buffer[offset] = IcicleSprite(root: piece.position, length: piece.length, width: piece.width, angle: piece.angle, seed: piece.seed, alpha: 1)
            offset += 1
        }
        if offset > start { groups.append(IcicleGroup(offset: start, count: offset - start, occluders: [])) }
        return groups
    }

    private func drop(_ icicle: Hanging, at frame: CGRect, velocity: SIMD2<Float>) {
        guard icicle.length > 1, falling.count < 400 else { return }
        falling.append(Falling(
            position: SIMD2(Float(frame.minX) + icicle.x, Float(frame.minY)),
            velocity: velocity * 0.6 + SIMD2(rand(-40, 40), rand(-20, 30)),
            length: icicle.length,
            width: icicle.width,
            angle: 0,
            spin: rand(-3, 3) + velocity.x * 0.002,
            seed: icicle.seed
        ))
        dirty = true
    }

    /// Irregularly spaced, mostly short, with a few long ones, and none near the rounded corners.
    private func makeHanging(width: Float) -> [Hanging] {
        var result: [Hanging] = []
        let inset: Float = 16
        var x = inset + rand(0, 14)
        while x < width - inset {
            let r = rand(0, 1)
            let maxLength = 3 + pow(r, 2.4) * 30
            result.append(Hanging(
                x: x,
                maxLength: maxLength,
                width: 1.1 + maxLength * 0.07 + rand(0, 0.7),
                seed: rand(0, 1),
                rate: maxLength / rand(50, 140)
            ))
            x += rand(7, 34)
        }
        return result
    }
}
