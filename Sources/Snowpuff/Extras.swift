import CSnowpuffCore
import CoreGraphics
import simd

/// The extras over the weather on one display, from the shared Rust core (core/src/extras.rs): the cursor's swirl,
/// hail, fog, stars, the garland, fireworks, snowballs, snowmen, the cat, the bullfinch, a flurry, and frost.
final class SceneExtras {
    private let handle: OpaquePointer
    private var raw: [SPSprite] = []

    init(width: Float, height: Float) {
        handle = sp_extras_new(width, height)
    }

    deinit {
        sp_extras_free(handle)
    }

    func resize(width: Float, height: Float) {
        sp_extras_resize(handle, width, height)
    }

    func apply(_ settings: SPSettings) {
        sp_extras_settings(handle, settings)
    }

    func setWindows(_ surfaces: [WindowSurface]) {
        var windows: [SPWindow] = []
        var fronts: [SPRect] = []
        for surface in surfaces {
            let offset = UInt32(fronts.count)
            fronts.append(contentsOf: surface.fronts.map(Self.rect))
            windows.append(SPWindow(
                id: Int64(surface.id),
                frame: Self.rect(surface.frame),
                fronts_offset: offset,
                fronts_count: UInt32(surface.fronts.count),
                ledge_only: surface.isDock ? 1 : 0
            ))
        }
        sp_extras_windows(handle, windows, windows.count, fronts, fronts.count)
    }

    /// Every app window, left, bottom, right, top: stars don't show over them.
    func setCovers(_ covers: [SIMD4<Float>]) {
        var flat: [Float] = []
        flat.reserveCapacity(covers.count * 4)
        for cover in covers { flat.append(contentsOf: [cover.x, cover.y, cover.z, cover.w]) }
        sp_extras_covers(handle, flat, covers.count)
    }

    /// Moves everything on; `ground` is the top of the drift along the bottom at an x.
    func step(dt: Float, cursor: SIMD2<Float>?, button: Bool, magic: Bool, daylight: Float, topInset: Float, width: Float, ground: (Float) -> Float) {
        let count = Int(width / 4) + 2
        var heights = [Float](repeating: 0, count: count)
        for i in 0..<count { heights[i] = ground(Float(i) * 4) }
        sp_extras_ground(handle, heights, count)
        sp_extras_step(handle, SPInput(
            dt: dt,
            cursor_x: cursor?.x ?? 0,
            cursor_y: cursor?.y ?? 0,
            has_cursor: cursor == nil ? 0 : 1,
            button: button ? 1 : 0,
            magic: magic ? 1 : 0,
            padding: 0,
            daylight: daylight,
            top_inset: topInset
        ))
    }

    var isActive: Bool { sp_extras_active(handle) != 0 }
    var needsSmooth: Bool { sp_extras_smooth(handle) != 0 }
    var spriteCount: Int { sp_extras_sprite_count(handle) }

    /// Writes the extras' sprites in the Mac's layout, returning how many.
    func write(into buffer: UnsafeMutablePointer<Sprite>, capacity: Int) -> Int {
        let wanted = min(spriteCount, capacity)
        guard wanted > 0 else { return 0 }
        if raw.count < wanted { raw = [SPSprite](repeating: SPSprite(), count: wanted) }
        let n = raw.withUnsafeMutableBufferPointer { sp_extras_write(handle, $0.baseAddress, wanted) }
        for i in 0..<n {
            let r = raw[i]
            var sprite = Sprite(position: SIMD2(r.position.0, r.position.1), size: r.size, alpha: r.alpha, soft: r.soft)
            sprite.velocity = SIMD2(r.velocity.0, r.velocity.1)
            sprite.tintAmount = r.tint_amount
            sprite.tintRed = r.tint.0
            sprite.tintGreen = r.tint.1
            sprite.tintBlue = r.tint.2
            sprite.lump = r.lump
            sprite.leaf = r.leaf.0
            sprite.turn = r.leaf.1
            sprite.flip = r.leaf.2
            sprite.turnSpeed = r.spin.0
            sprite.flipSpeed = r.spin.1
            buffer[i] = sprite
        }
        return n
    }

    func frost() -> SPFrost { sp_extras_frost(handle) }

    /// The sounds asked for since the last call: kind 0 crunch, 1 chime, 2 splat, 3 boom.
    func takeCues() -> [SPCue] {
        var cues = [SPCue](repeating: SPCue(), count: 16)
        let n = cues.withUnsafeMutableBufferPointer { sp_extras_take_cues(handle, $0.baseAddress, 16) }
        return Array(cues.prefix(n))
    }

    func flurry() { sp_extras_flurry(handle) }
    func fireworks(seconds: Float) { sp_extras_fireworks(handle, seconds) }
    func clear() { sp_extras_clear(handle) }
    func buildSnowman(at x: Float) { sp_extras_build_snowman(handle, x) }
    func throwSnowball(at point: SIMD2<Float>) { sp_extras_throw(handle, point.x, point.y) }

    private static func rect(_ r: CGRect) -> SPRect {
        SPRect(x: Float(r.minX), y: Float(r.minY), width: Float(r.width), height: Float(r.height))
    }
}
