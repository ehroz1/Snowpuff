import CoreGraphics
import simd

/// Rain: streaks that beat down and splash where they land, and drops on the windows' glass that run down it in
/// lurches, leave a trail of beads, gather what they meet, hang under the bottom edge until they let go, smear under
/// the cursor and fly off a shaken window. Nothing piles up. The same as `core/src/rain.rs` on Windows.
///
/// Overlay points with y up. Drops on the glass keep their place on their window, from its left edge and down from
/// its top, so they ride along when it moves.
final class Rain {
    /// Sprite kinds, in a sprite's `leaf`, below zero so they never pass for a leaf.
    static let streak: Float = -1
    static let bead: Float = -2
    static let spray: Float = -3

    private static let gravity: Float = 1500
    /// Of the streaks that hit a window's top, how many leave a drop on its glass.
    private static let sticking: Float = 0.07
    private static let maxDrops = 700
    private static let maxBeads = 1600

    /// How hard it rains at each setting of the intensity slider; none while it is off.
    static func intensity(_ snowfall: Snowfall) -> Float {
        switch snowfall {
        case .off: 0
        case .light: 0.4
        case .heavy: 2.2
        case .steady, .variable: 1
        }
    }

    private struct Streak {
        var position: SIMD2<Float>
        var velocity: SIMD2<Float>
        /// 0.55 far away to 1 near: far streaks are thinner and fainter and pass behind the windows.
        var depth: Float
    }

    /// A droplet in the air: a splash's spray, or a drop that let go of a window.
    private struct Spray {
        var position: SIMD2<Float>
        var velocity: SIMD2<Float>
        var size: Float
        var age: Float = 0
        var life: Float
        /// A drop fallen off a window splashes again where it lands; spray just fades.
        var lands: Bool
    }

    private enum Motion: Equatable {
        /// Clinging to the glass for this much longer.
        case resting(Float)
        /// Running down at this speed for this much longer.
        case running(speed: Float, left: Float)
        /// Under the bottom edge, swelling until it lets go.
        case hanging
    }

    private struct Drop {
        let window: CGWindowID
        /// From the window's left edge, and down from its top.
        var x: Float
        var down: Float
        var size: Float
        var motion: Motion
        /// How far it has run since it last left a bead behind.
        var sinceBead: Float = 0
        var wobble: Float
    }

    /// A bead left behind on the glass: it stays put and dries.
    private struct Bead {
        let window: CGWindowID
        var x: Float
        var down: Float
        var size: Float
        var age: Float = 0
        var life: Float
    }

    private struct Pane {
        var frame: CGRect
        var fronts: [CGRect]
        var ledgeOnly: Bool
        var velocity: SIMD2<Float>
    }

    private(set) var width: Float
    private(set) var height: Float
    /// Raining, rather than letting the last of it run off.
    var on = false
    /// Light 0.4, steady 1, heavy 2.2.
    var intensity: Float = 1
    /// Leaning of the streaks: their sideways speed for each point a second they fall.
    var slant: Float = -0.12
    private var streaks: [Streak] = []
    private var spray: [Spray] = []
    private var drops: [Drop] = []
    private var beads: [Bead] = []
    private var panes: [CGWindowID: Pane] = [:]
    private var owed: Float = 0
    private var lastCursor: SIMD2<Float>?

    init(width: Float, height: Float) {
        self.width = width
        self.height = height
    }

    func resize(width: Float, height: Float) {
        self.width = width
        self.height = height
    }

    /// Anything left to draw or move.
    var isActive: Bool { on || !streaks.isEmpty || !spray.isEmpty || !drops.isEmpty || !beads.isEmpty }
    var spriteCount: Int { streaks.count + spray.count + drops.count + beads.count }

    /// Knocks everything off the glass, as clearing the screen does.
    func clear() {
        for drop in drops {
            if let at = place(drop.window, drop.x, drop.down) {
                spray.append(Spray(position: at, velocity: SIMD2(0, -60), size: drop.size * 0.8, life: 3, lands: true))
            }
        }
        drops.removeAll()
        beads.removeAll()
    }

    /// The windows now and how long since the last time, to tell how fast each moves: a shaken window throws its drops off.
    func updateWindows(_ surfaces: [WindowSurface], interval: Double) {
        var fresh: [CGWindowID: Pane] = [:]
        for surface in surfaces {
            var velocity = SIMD2<Float>.zero
            if let old = panes[surface.id], interval > 0 {
                let moved = SIMD2(Float(surface.frame.minX - old.frame.minX), Float(surface.frame.maxY - old.frame.maxY))
                velocity = moved / Float(max(interval, 1.0 / 120))
            }
            fresh[surface.id] = Pane(frame: surface.frame, fronts: surface.fronts, ledgeOnly: surface.isDock, velocity: velocity)
        }
        // Drops on a window that went, or that was shaken hard, fall; beads on it are gone.
        var thrown: [(Drop, SIMD2<Float>)] = []
        drops.removeAll { drop in
            let pane = fresh[drop.window]
            let shaken = pane.map { simd_length($0.velocity) > 1400 } ?? false
            let resized = pane.map { CGFloat(drop.x) > $0.frame.width || CGFloat(drop.down) > $0.frame.height + 2 } ?? false
            guard pane == nil || shaken || resized else { return false }
            thrown.append((drop, pane?.velocity ?? .zero))
            return true
        }
        for (drop, velocity) in thrown {
            if let at = place(drop.window, drop.x, drop.down) {
                let push = velocity * 0.55 + SIMD2(Float.random(in: -40...40), Float.random(in: -20...60))
                spray.append(Spray(position: at, velocity: push, size: drop.size * 0.8, life: 3, lands: true))
            }
        }
        beads.removeAll { bead in
            guard let pane = fresh[bead.window] else { return true }
            return simd_length(pane.velocity) > 1400 || CGFloat(bead.x) > pane.frame.width || CGFloat(bead.down) > pane.frame.height
        }
        panes = fresh
    }

    /// Moves everything on by `dt` seconds. `ground` is where the bottom of the screen catches the rain at an x.
    /// Returns whether anything is left to draw.
    @discardableResult
    func step(dt: Float, cursor: SIMD2<Float>?, ground: (Float) -> Float) -> Bool {
        let dt = min(max(dt, 0), 0.05)
        spawn(dt)
        fall(dt, ground: ground)
        fly(dt, ground: ground)
        run(dt)
        if let cursor, let lastCursor { smear(from: lastCursor, to: cursor, dt: dt) }
        lastCursor = cursor
        for i in beads.indices { beads[i].age += dt }
        beads.removeAll { $0.age >= $0.life }
        return isActive
    }

    private func spawn(_ dt: Float) {
        guard on else { return }
        // About 165 streaks in the air over every 1000 points of width on a steady rain.
        owed += width / 1000 * 165 * intensity * dt
        // Leaning streaks drift sideways as they fall: they start upwind of where they will land.
        let drift = -slant * height
        while owed >= 1 {
            owed -= 1
            let depth = Float.random(in: 0.55...1)
            let speed = Float.random(in: 900...1250) * (0.75 + 0.25 * depth)
            let x = Float.random(in: (min(-drift, 0) - 20)...(width + max(-drift, 0) + 20))
            let y = height + Float.random(in: 10...160)
            streaks.append(Streak(position: SIMD2(x, y), velocity: SIMD2(-slant * speed, -speed), depth: depth))
        }
    }

    private func fall(_ dt: Float, ground: (Float) -> Float) {
        var hits: [(SIMD2<Float>, CGWindowID?, Float)] = []
        let panes = self.panes
        streaks = streaks.compactMap { streak in
            var streak = streak
            let from = streak.position
            streak.position += streak.velocity * dt
            let to = streak.position
            // Far streaks pass behind the windows and fade out somewhere low on the screen.
            if streak.depth < 0.72 {
                return to.y > max(ground(to.x), 0) + (1 - streak.depth) * 220 ? streak : nil
            }
            var landed: (y: Float, window: CGWindowID?)?
            for (id, pane) in panes {
                let top = Float(pane.frame.maxY)
                guard from.y >= top, to.y < top else { continue }
                let t = (from.y - top) / max(from.y - to.y, 1e-3)
                let x = from.x + (to.x - from.x) * t
                if x >= Float(pane.frame.minX), x <= Float(pane.frame.maxX), !Self.hidden(pane.fronts, SIMD2(x, top)), top > (landed?.y ?? -.infinity) {
                    landed = (top, id)
                }
            }
            let floor = max(ground(to.x), 0)
            if landed == nil, to.y <= floor { landed = (floor, nil) }
            guard let landed else { return to.y > -50 ? streak : nil }
            let t = (from.y - landed.y) / max(from.y - to.y, 1e-3)
            hits.append((SIMD2(from.x + (to.x - from.x) * t, landed.y), landed.window, streak.depth))
            return nil
        }
        for (at, window, depth) in hits {
            splash(at, strength: depth)
            if let window, drops.count < Self.maxDrops, Float.random(in: 0..<1) < Self.sticking,
               let pane = panes[window], !pane.ledgeOnly {
                drops.append(Drop(
                    window: window,
                    x: at.x - Float(pane.frame.minX),
                    down: Float.random(in: 1.5...5),
                    size: Float.random(in: 3...5.8),
                    motion: .resting(Float.random(in: 0.3...3.5)),
                    wobble: Float.random(in: 0...6.28)
                ))
            }
        }
    }

    private func splash(_ at: SIMD2<Float>, strength: Float) {
        let count = 2 + Int(Float.random(in: 0..<1) * 3 * strength)
        for _ in 0..<count {
            let velocity = SIMD2(Float.random(in: -150...150), Float.random(in: 60...230) * strength)
            spray.append(Spray(position: at + SIMD2(0, 1), velocity: velocity, size: Float.random(in: 0.9...1.8), life: Float.random(in: 0.22...0.42), lands: false))
        }
    }

    private func fly(_ dt: Float, ground: (Float) -> Float) {
        var landed: [SIMD2<Float>] = []
        let panes = Array(self.panes.values)
        spray = spray.compactMap { spray in
            var spray = spray
            spray.age += dt
            let from = spray.position
            spray.velocity.y -= Self.gravity * dt
            spray.position += spray.velocity * dt
            guard spray.lands else { return spray.age < spray.life ? spray : nil }
            let to = spray.position
            let onWindow = panes.contains { pane in
                let top = Float(pane.frame.maxY)
                return from.y >= top && to.y < top && to.x >= Float(pane.frame.minX) && to.x <= Float(pane.frame.maxX)
                    && !Self.hidden(pane.fronts, SIMD2(to.x, top))
            }
            if onWindow || to.y <= max(ground(to.x), 0) {
                landed.append(to)
                return nil
            }
            return spray.age < spray.life && to.y > -20 ? spray : nil
        }
        for at in landed { splash(at, strength: 0.6) }
    }

    /// Drops on the glass: they rest, run a little, rest again, leave beads, take in what they run into, and hang
    /// under the bottom edge until heavy enough to let go.
    private func run(_ dt: Float) {
        var released: [Drop] = []
        var leftBeads: [Bead] = []
        for i in drops.indices {
            guard let height = panes[drops[i].window].map({ Float($0.frame.height) }) else { continue }
            switch drops[i].motion {
            case .resting(let left):
                // Heavier drops give way sooner.
                let left = left - dt * (drops[i].size / 3)
                drops[i].motion = left <= 0
                    ? .running(speed: Float.random(in: 25...70) * drops[i].size / 3, left: Float.random(in: 0.15...1.1))
                    : .resting(left)
            case .running(let speed, let left):
                let moved = speed * dt
                drops[i].down += moved
                drops[i].wobble += dt * 3
                drops[i].x += sin(drops[i].wobble) * moved * 0.12
                drops[i].sinceBead += moved
                if drops[i].sinceBead > Float.random(in: 5...11), drops[i].size > 1.6 {
                    drops[i].sinceBead = 0
                    let size = drops[i].size * Float.random(in: 0.28...0.45)
                    leftBeads.append(Bead(window: drops[i].window, x: drops[i].x, down: drops[i].down - drops[i].size * 0.4, size: size, life: Float.random(in: 5...11)))
                    drops[i].size = sqrt(max(drops[i].size * drops[i].size - size * size * 0.5, 1))
                }
                let remaining = left - dt
                drops[i].motion = remaining <= 0 ? .resting(Float.random(in: 0.1...1.6)) : .running(speed: speed, left: remaining)
                if drops[i].down >= height - drops[i].size * 0.3 {
                    drops[i].down = height
                    drops[i].motion = .hanging
                }
            case .hanging:
                drops[i].size += dt * 0.9
                if drops[i].size > 7.4 {
                    released.append(drops[i])
                    drops[i].size = 0
                }
            }
        }
        drops.removeAll { $0.size <= 0 }
        // A running drop takes in the beads it runs over.
        for i in drops.indices {
            guard case .running = drops[i].motion else { continue }
            let drop = drops[i]
            var gathered = drop.size * drop.size
            beads.removeAll { bead in
                let near = bead.window == drop.window && abs(bead.x - drop.x) < drop.size * 0.6 + bead.size
                    && bead.down > drop.down - drop.size && bead.down < drop.down + drop.size * 0.5
                if near { gathered += bead.size * bead.size }
                return near
            }
            drops[i].size = min(sqrt(gathered), 8)
        }
        beads.append(contentsOf: leftBeads)
        if beads.count > Self.maxBeads { beads.removeFirst(beads.count - Self.maxBeads) }
        for drop in released {
            if let at = place(drop.window, drop.x, drop.down + drop.size * 0.5) {
                spray.append(Spray(position: at, velocity: SIMD2(0, -40), size: drop.size * 0.75, life: 3, lands: true))
            }
        }
    }

    /// The cursor moving through drops knocks hanging ones off and drags the others along, smeared into beads.
    private func smear(from: SIMD2<Float>, to: SIMD2<Float>, dt: Float) {
        let moved = to - from
        guard simd_length(moved) >= 1.5, dt > 0 else { return }
        let velocity = moved / max(dt, 1e-3)
        for i in drops.indices {
            guard let pane = panes[drops[i].window] else { continue }
            let at = SIMD2(Float(pane.frame.minX) + drops[i].x, Float(pane.frame.maxY) - drops[i].down)
            guard !Self.hidden(pane.fronts, at), Self.distance(at, toSegment: from, to) <= 10 + drops[i].size else { continue }
            if drops[i].motion == .hanging {
                spray.append(Spray(position: at, velocity: velocity * 0.4, size: drops[i].size * 0.75, life: 3, lands: true))
                drops[i].size = 0
                continue
            }
            let push = SIMD2(moved.x, -moved.y) * 0.7
            let steps = Int(min(max((simd_length(push) / 4).rounded(.up), 1), 6))
            for k in 0..<steps {
                let along = Float(k) / Float(steps)
                beads.append(Bead(window: drops[i].window, x: drops[i].x + push.x * along, down: drops[i].down + push.y * along, size: drops[i].size * 0.35, life: Float.random(in: 3...7)))
            }
            drops[i].x = min(max(drops[i].x + push.x, 0), Float(pane.frame.width))
            drops[i].down = min(max(drops[i].down + push.y, 0), Float(pane.frame.height))
            drops[i].size = max(drops[i].size * 0.85, 1.2)
            drops[i].motion = .resting(0.6)
        }
        drops.removeAll { $0.size <= 0 }
    }

    private func place(_ window: CGWindowID, _ x: Float, _ down: Float) -> SIMD2<Float>? {
        panes[window].map { SIMD2(Float($0.frame.minX) + x, Float($0.frame.maxY) - down) }
    }

    /// Writes the rain's sprites, returning how many.
    func write(into buffer: UnsafeMutablePointer<Sprite>, capacity: Int) -> Int {
        var n = 0
        func put(_ sprite: Sprite) {
            guard n < capacity else { return }
            buffer[n] = sprite
            n += 1
        }
        func sprite(_ kind: Float, at position: SIMD2<Float>, velocity: SIMD2<Float> = .zero, size: Float, alpha: Float, stretch: Float = 0) -> Sprite {
            var sprite = Sprite(position: position, size: size, alpha: alpha, soft: 0)
            sprite.velocity = velocity
            sprite.leaf = kind
            sprite.turn = stretch
            return sprite
        }
        for streak in streaks {
            put(sprite(Self.streak, at: streak.position, velocity: streak.velocity, size: 0.9 + streak.depth * 0.7, alpha: 0.12 + streak.depth * 0.26))
        }
        for spray in spray {
            let fade = spray.lands ? 1 : 1 - spray.age / spray.life
            put(sprite(Self.spray, at: spray.position, velocity: spray.velocity, size: spray.size, alpha: 0.55 * fade))
        }
        for bead in beads {
            guard let pane = panes[bead.window] else { continue }
            let at = SIMD2(Float(pane.frame.minX) + bead.x, Float(pane.frame.maxY) - bead.down)
            guard !Self.hidden(pane.fronts, at) else { continue }
            let fade = 1 - pow(bead.age / bead.life, 3)
            put(sprite(Self.bead, at: at, size: bead.size, alpha: 0.9 * fade, stretch: 1))
        }
        for drop in drops {
            guard let pane = panes[drop.window] else { continue }
            let at = SIMD2(Float(pane.frame.minX) + drop.x, Float(pane.frame.maxY) - drop.down)
            guard !Self.hidden(pane.fronts, at) else { continue }
            // Running drops stretch along their run; hanging ones swell into a teardrop.
            let stretch: Float = switch drop.motion {
            case .running(let speed, _): 1 + min(speed / 120, 0.6)
            case .hanging: 1 + max(drop.size - 4, 0) * 0.12
            case .resting: 1
            }
            put(sprite(Self.bead, at: at, size: drop.size, alpha: 0.95, stretch: stretch))
        }
        return n
    }

    private static func hidden(_ fronts: [CGRect], _ at: SIMD2<Float>) -> Bool {
        fronts.contains { $0.contains(CGPoint(x: CGFloat(at.x), y: CGFloat(at.y))) }
    }

    private static func distance(_ p: SIMD2<Float>, toSegment a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let ab = b - a
        let t = min(max(simd_dot(p - a, ab) / max(simd_length_squared(ab), 1e-6), 0), 1)
        return simd_length(p - (a + ab * t))
    }
}
