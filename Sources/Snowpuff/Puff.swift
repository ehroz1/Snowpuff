import AppKit
import CSnowpuffNet
import MetalKit
import simd

/// Snowpuff's own parts over the snow on one display, from the shared Rust core (core/src/puff): the extras (the
/// cursor's swirl, hail, fog, stars and meteors, the garland, the cat, the bullfinch, a flurry, frost to draw in)
/// and the icicles under snowy windows.
final class PuffScene {
    private let extras: OpaquePointer
    private let icicles: OpaquePointer
    private var raw: [SPSprite] = []
    private var windowIDs: [CGWindowID] = []
    /// The focused window, for its warm glow: the frontmost one carrying snow.
    private(set) var focused: CGRect?
    /// Sounds asked for: kind 0 crunch, 1 chime, 2 splat, 3 boom.
    var heard: ([SPCue]) -> Void = { _ in }
    var iciclesOn = true
    private var hearth = SIMD4<Float>(repeating: 0)
    private var hearthStrength: Float = 0
    var warmGlow = true

    init(width: Float, height: Float) {
        extras = sp_extras_new(width, height)
        icicles = sp_icicles_new()
    }

    deinit {
        sp_extras_free(extras)
        sp_icicles_free(icicles)
    }

    func resize(width: Float, height: Float) {
        sp_extras_resize(extras, width, height)
    }

    func apply(_ settings: SPSettings) {
        sp_extras_settings(extras, settings)
    }

    /// Icicles on or off; turned off, they fall, or melt away for those who'd rather nothing moved.
    func setIcicles(_ on: Bool, calm: Bool) {
        guard on != iciclesOn else { return }
        iciclesOn = on
        if !on { if calm { sp_icicles_melt(icicles) } else { sp_icicles_drop_all(icicles) } }
        sp_icicles_enable(icicles, on ? 1 : 0)
    }

    /// The windows from the tracker's latest poll, for the extras and the icicles.
    func update(_ update: WindowUpdate) {
        var windows: [SPWindow] = []
        var fronts: [SPRect] = []
        for surface in update.surfaces {
            let offset = UInt32(fronts.count)
            fronts.append(contentsOf: surface.blockers.prefix(16).map(Self.rect))
            windows.append(SPWindow(
                id: Int64(surface.id),
                frame: Self.rect(surface.frame),
                fronts_offset: offset,
                fronts_count: UInt32(fronts.count) - offset,
                ledge_only: surface.isDock || surface.sweeps ? 1 : 0
            ))
        }
        windowIDs = update.surfaces.filter { !$0.isDock && !$0.sweeps }.map(\.id)
        focused = update.surfaces.first { !$0.isDock && !$0.sweeps }?.frame
        sp_extras_windows(extras, windows, windows.count, fronts, fronts.count)
        let keep = update.elsewhere.union(update.parked).map { Int64($0) }
        sp_icicles_update(icicles, windows, windows.count, fronts, fronts.count, keep, keep.count, update.interval, update.sliding ? 1 : 0)
    }

    /// Every app window, left, bottom, right, top: stars don't show over them.
    func setCovers(_ covers: [SIMD4<Float>]) {
        var flat: [Float] = []
        flat.reserveCapacity(covers.count * 4)
        for cover in covers { flat.append(contentsOf: [cover.x, cover.y, cover.z, cover.w]) }
        sp_extras_covers(extras, flat, covers.count)
    }

    /// Moves everything on. Returns whether anything changed, and whether it moves enough to want a smooth rate.
    func step(dt: Float, cursor: SIMD2<Float>?, daylight: Float, topInset: Float, simulation: SnowSimulation) -> (changed: Bool, smooth: Bool) {
        let width = simulation.width
        let count = Int(width / 4) + 2
        var heights = [Float](repeating: 0, count: count)
        for i in 0..<count { heights[i] = simulation.groundLevel(at: Float(i) * 4) }
        sp_extras_ground(extras, heights, count)
        let flags = NSEvent.modifierFlags
        sp_extras_step(extras, SPInput(
            dt: dt,
            cursor_x: cursor?.x ?? 0,
            cursor_y: cursor?.y ?? 0,
            has_cursor: cursor == nil ? 0 : 1,
            button: NSEvent.pressedMouseButtons & 1 != 0 ? 1 : 0,
            magic: flags.contains(.option) && !flags.contains(.command) ? 1 : 0,
            padding: 0,
            daylight: daylight,
            top_inset: topInset
        ))
        var cues = [SPCue](repeating: SPCue(), count: 16)
        let n = cues.withUnsafeMutableBufferPointer { sp_extras_take_cues(extras, $0.baseAddress, 16) }
        if n > 0 { heard(Array(cues.prefix(n))) }

        var changed = sp_extras_active(extras) != 0
        let smooth = sp_extras_smooth(extras) != 0 || sp_icicles_falling(icicles) != 0
        if iciclesOn {
            var depths = windowIDs.map { SPDepth(id: Int64($0), depth: simulation.snowDepth(onWindow: $0)) }
            var shatters = [SPShatter](repeating: SPShatter(), count: 64)
            var shattered = 0
            let moved = depths.withUnsafeMutableBufferPointer { depthsPointer in
                shatters.withUnsafeMutableBufferPointer { out in
                    sp_icicles_step(icicles, dt, depthsPointer.baseAddress, depthsPointer.count, heights, count, out.baseAddress, out.count, &shattered)
                }
            }
            for shatter in shatters.prefix(shattered) {
                simulation.shatterIcicle(at: SIMD2(shatter.x, shatter.y), size: shatter.size)
            }
            if moved != 0 { changed = true }
        }
        if updateHearth(dt: dt) { changed = true }
        return (changed, smooth || hearthStrength > 0 && hearthStrength < 0.99)
    }

    /// Eases the glow toward the focused window, fading it in and out; returns whether it visibly changed.
    private func updateHearth(dt: Float) -> Bool {
        let target = warmGlow ? focused : nil
        let previous = (hearth, hearthStrength)
        if let target {
            let goal = SIMD4(Float(target.minX), Float(target.minY), Float(target.maxX), Float(target.maxY))
            hearth = hearthStrength < 0.01 ? goal : hearth + (goal - hearth) * min(1, dt * 9)
            hearthStrength += (1 - hearthStrength) * min(1, dt * 2.5)
        } else {
            hearthStrength += (0 - hearthStrength) * min(1, dt * 2.5)
            if hearthStrength < 0.005 { hearthStrength = 0 }
        }
        return simd_reduce_max(simd_abs(hearth - previous.0)) > 0.4 || abs(hearthStrength - previous.1) > 0.004
    }

    /// The focused window's warm glow, for the shaders: its frame, and how far and how brightly it spills.
    var glow: (frame: SIMD4<Float>, light: SIMD4<Float>) {
        (hearth, SIMD4(70, 0.42 * hearthStrength, 280, 0))
    }

    var hasIcicles: Bool { sp_icicles_count(icicles) > 0 }
    var isEmpty: Bool { sp_extras_active(extras) == 0 && sp_icicles_empty(icicles) != 0 && hearthStrength == 0 }
    var spriteCount: Int { sp_extras_sprite_count(extras) }

    /// A click on an icicle knocks it down: how high it rings, or nil where none hangs.
    func knock(at point: SIMD2<Float>) -> Float? {
        var pitch: Float = 0
        return sp_icicles_knock(icicles, point.x, point.y, &pitch) != 0 ? pitch : nil
    }

    func flurry() { sp_extras_flurry(extras) }

    func clear(calm: Bool) {
        sp_extras_clear(extras)
        if calm { sp_icicles_melt(icicles) } else { sp_icicles_drop_all(icicles) }
    }

    func writeSprites(into buffer: UnsafeMutablePointer<SPSprite>, capacity: Int) -> Int {
        sp_extras_write(extras, buffer, min(spriteCount, capacity))
    }

    func frost() -> SPFrost { sp_extras_frost(extras) }

    /// Writes the icicles to draw; returns how many, and the runs that share the windows in front of them.
    func writeIcicles(into sprites: UnsafeMutablePointer<SPIcicle>, capacity: Int) -> (count: Int, groups: [(offset: Int, count: Int, occluders: [SIMD4<Float>])]) {
        var groups = [SPIcicleGroup](repeating: SPIcicleGroup(), count: 128)
        var occluders = [(Float, Float, Float, Float)](repeating: (0, 0, 0, 0), count: 1024)
        var counts = [Int](repeating: 0, count: 3)
        groups.withUnsafeMutableBufferPointer { g in
            occluders.withUnsafeMutableBufferPointer { o in
                o.baseAddress!.withMemoryRebound(to: (Float, Float, Float, Float).self, capacity: o.count) { pointer in
                    sp_icicles_write(icicles, sprites, capacity, g.baseAddress, g.count, pointer, o.count, &counts)
                }
            }
        }
        let result = groups.prefix(counts[1]).map { group in
            (offset: Int(group.offset), count: Int(group.count),
             occluders: occluders[Int(group.occluders_offset)..<Int(group.occluders_offset + group.occluders_count)].map { SIMD4($0.0, $0.1, $0.2, $0.3) })
        }
        return (counts[0], result)
    }

    private static func rect(_ r: CGRect) -> SPRect {
        SPRect(x: Float(r.minX), y: Float(r.minY), width: Float(r.width), height: Float(r.height))
    }
}

/// What Snowpuff's shaders are told each frame.
struct PuffUniforms {
    var viewSize: SIMD2<Float>
    var scale: Float
    var time: Float
    var light = SIMD4<Float>(1, 1, 1, 1)
    var lantern = SIMD4<Float>(0, 0, 0, 0)
    var hearth = SIMD4<Float>(0, 0, 0, 0)
    var hearthLight = SIMD4<Float>(0, 0, 0, 0)
    var opacity: Float = 1
    var occluderCount: Int32 = 0
    var shake = SIMD2<Float>(0, 0)
}

struct FrostUniforms {
    var viewSize: SIMD2<Float>
    var time: Float
    var cell: Float
    var reach: Float
    var mist: Float
    var columns: Int32
    var rows: Int32
    var light: SIMD4<Float>
}

/// Draws a display's PuffScene into the snow's own pass: icicles under the falling snow's sprites, the extras, and
/// frost on the glass in front of everything.
final class PuffRenderer {
    private struct Pipelines {
        let sprite, icicle, frost: MTLRenderPipelineState
    }

    private static var built: [UInt64: Pipelines] = [:]
    private let pipelines: Pipelines
    private let device: MTLDevice
    private let framesInFlight = 3
    private var spriteBuffers: [MTLBuffer] = []
    private var spriteCapacity = 0
    private var icicleBuffers: [MTLBuffer] = []
    private let icicleCapacity = 4096
    private var frostBuffer: MTLBuffer?
    private var slot = 0

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        self.device = device
        if let pipelines = Self.built[device.registryID] {
            self.pipelines = pipelines
        } else {
            do {
                let library = try device.makeLibrary(source: puffShaderSource(), options: nil)
                func pipeline(_ vertex: String, _ fragment: String) throws -> MTLRenderPipelineState {
                    let descriptor = MTLRenderPipelineDescriptor()
                    descriptor.vertexFunction = library.makeFunction(name: vertex)
                    descriptor.fragmentFunction = library.makeFunction(name: fragment)
                    let attachment = descriptor.colorAttachments[0]!
                    attachment.pixelFormat = pixelFormat
                    attachment.isBlendingEnabled = true
                    attachment.sourceRGBBlendFactor = .one
                    attachment.sourceAlphaBlendFactor = .one
                    attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                    return try device.makeRenderPipelineState(descriptor: descriptor)
                }
                pipelines = try Pipelines(
                    sprite: pipeline("puffSpriteVertex", "puffSpriteFragment"),
                    icicle: pipeline("icicleVertex", "icicleFragment"),
                    frost: pipeline("frostVertex", "frostFragment")
                )
                Self.built[device.registryID] = pipelines
            } catch {
                NSLog("Snowpuff: the extras' shaders failed: \(error)")
                return nil
            }
        }
        icicleBuffers = (0..<framesInFlight).compactMap { _ in
            device.makeBuffer(length: icicleCapacity * MemoryLayout<SPIcicle>.stride, options: [.storageModeShared, .cpuCacheModeWriteCombined])
        }
    }

    /// Icicles hang under the windows, behind what falls.
    func encodeIcicles(_ scene: PuffScene, with encoder: MTLRenderCommandEncoder, uniforms: PuffUniforms) {
        guard scene.hasIcicles, icicleBuffers.count == framesInFlight else { return }
        let buffer = icicleBuffers[slot % framesInFlight]
        let (count, groups) = scene.writeIcicles(into: buffer.contents().bindMemory(to: SPIcicle.self, capacity: icicleCapacity), capacity: icicleCapacity)
        guard count > 0 else { return }
        encoder.setRenderPipelineState(pipelines.icicle)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        for group in groups where group.count > 0 {
            var u = uniforms
            u.occluderCount = Int32(group.occluders.count)
            var occluders = group.occluders.isEmpty ? [SIMD4<Float>(0, 0, 0, 0)] : group.occluders
            encoder.setVertexBytes(&u, length: MemoryLayout<PuffUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<PuffUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&occluders, length: occluders.count * MemoryLayout<SIMD4<Float>>.stride, index: 2)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: group.count, baseInstance: group.offset)
        }
    }

    /// The extras in front of the snow, and the frost on the glass in front of everything.
    func encodeExtras(_ scene: PuffScene, with encoder: MTLRenderCommandEncoder, uniforms: PuffUniforms) {
        var u = uniforms
        let wanted = scene.spriteCount
        if wanted > 0 {
            if wanted > spriteCapacity || spriteBuffers.count != framesInFlight {
                spriteCapacity = max(wanted * 2, 1024)
                spriteBuffers = (0..<framesInFlight).compactMap { _ in
                    device.makeBuffer(length: spriteCapacity * MemoryLayout<SPSprite>.stride, options: [.storageModeShared, .cpuCacheModeWriteCombined])
                }
            }
            if spriteBuffers.count == framesInFlight {
                let buffer = spriteBuffers[slot % framesInFlight]
                let n = scene.writeSprites(into: buffer.contents().bindMemory(to: SPSprite.self, capacity: spriteCapacity), capacity: spriteCapacity)
                if n > 0 {
                    encoder.setRenderPipelineState(pipelines.sprite)
                    encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                    encoder.setVertexBytes(&u, length: MemoryLayout<PuffUniforms>.stride, index: 1)
                    encoder.setFragmentBytes(&u, length: MemoryLayout<PuffUniforms>.stride, index: 1)
                    encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: n)
                }
            }
        }
        let frost = scene.frost()
        if frost.reach > 0, frost.columns > 0, frost.rows > 0, let values = frost.values {
            let length = Int(frost.columns * frost.rows) * MemoryLayout<Float>.stride
            if frost.changed != 0 || frostBuffer == nil || frostBuffer!.length != length {
                if frostBuffer == nil || frostBuffer!.length != length {
                    frostBuffer = device.makeBuffer(length: length, options: .storageModeShared)
                }
                frostBuffer?.contents().copyMemory(from: values, byteCount: length)
            }
            if let frostBuffer {
                var f = FrostUniforms(viewSize: u.viewSize, time: u.time, cell: frost.cell, reach: frost.reach, mist: Float(frost.mist),
                                      columns: Int32(frost.columns), rows: Int32(frost.rows), light: u.light)
                encoder.setRenderPipelineState(pipelines.frost)
                encoder.setVertexBytes(&f, length: MemoryLayout<FrostUniforms>.stride, index: 1)
                encoder.setFragmentBuffer(frostBuffer, offset: 0, index: 0)
                encoder.setFragmentBytes(&f, length: MemoryLayout<FrostUniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 4)
            }
        }
        slot += 1
    }
}

/// The extras' shapes are shared with Windows (shaders/extras.shader, in the app's resources); the rest is here.
private func puffShaderSource() -> String {
    let shared = Bundle.main.url(forResource: "extras", withExtension: "shader").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    return puffShaderHead + "#define FN static inline\n#define lerp mix\n#define frac fract\n" + shared + puffShaderBody
}

private let puffShaderHead = """
#include <metal_stdlib>
using namespace metal;

struct PuffUniforms {
    float2 viewSize;
    float scale;
    float time;
    float4 light;
    float4 lantern;
    float4 hearth;
    float4 hearthLight;
    float opacity;
    int occluderCount;
    float2 shake;
};

/// The core's sprite: 17 floats, packed.
struct PuffSprite {
    packed_float2 position;
    packed_float2 velocity;
    float size;
    float alpha;
    float soft;
    float tintAmount;
    float tintRed;
    float tintGreen;
    float tintBlue;
    float lump;
    float leaf;
    float turn;
    float flip;
    float turnSpeed;
    float flipSpeed;
};

/// The warm light from a window.
constant float3 candle = float3(1.0, 0.824, 0.494);

"""

private let puffShaderBody = """

static float puffFlicker(float time) {
    return 0.86 + 0.08 * sin(time * 11.0) + 0.06 * sin(time * 29.0 + 1.3);
}

/// How much warm light reaches a point: the cursor's lantern, and the focused window's glow, which spills a little
/// around the window and reaches further below it, like light from a window onto a drift.
static float puffCandlelight(constant PuffUniforms &u, float2 point) {
    float2 d = point - u.lantern.xy;
    float glow = u.lantern.w * puffFlicker(u.time) * exp(-dot(d, d) / max(u.lantern.z * u.lantern.z, 1.0));
    if (u.hearthLight.y > 0.0) {
        float2 center = (u.hearth.xy + u.hearth.zw) * 0.5;
        float2 half_ = (u.hearth.zw - u.hearth.xy) * 0.5;
        float2 q = point - center;
        float2 out_ = max(abs(q) - half_, float2(0.0));
        float reachY = q.y < 0.0 ? u.hearthLight.z : u.hearthLight.x;
        float spill = exp(-out_.x * out_.x / (u.hearthLight.x * u.hearthLight.x) - out_.y * out_.y / (reachY * reachY));
        float inside = mix(0.35, 1.0, saturate(length(out_) / 10.0));
        float breathe = 0.94 + 0.06 * sin(u.time * 0.7);
        glow += u.hearthLight.y * spill * inside * breathe;
    }
    return min(glow, 1.0);
}

struct PuffOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float alpha;
    float4 tint;
    float3 light;
    float2 streak;
    float radius;
    float warm;
    float leaf;
    float turn;
    float flip;
    float reach;
    float turnSmear;
    float flipSmear;
};

/// A glow (-4), snowman (-5), cat (-6), bird (-7), fog puff (-8), hailstone (-9), snowball (-10), bulb (-11) or a
/// piece of the garland's cord (-12).
vertex PuffOut puffSpriteVertex(uint vid [[vertex_id]], const device PuffSprite *sprites [[buffer(0)]], constant PuffUniforms &u [[buffer(1)]]) {
    PuffSprite s = sprites[vid];
    PuffOut out;
    int kind = int(round(-s.leaf));
    float2 velocity = float2(s.velocity);
    float2 position = float2(s.position);
    float2 travel = kind == 4 ? velocity * 0.03 : (kind == 9 ? velocity * 0.012 : float2(0.0));
    float extent = kind == 4 ? s.size * 2.4 + length(travel) : (kind == 9 ? s.size * 1.4 + length(travel) : s.size);
    if (kind == 11) extent = s.size * 3.4;
    if (kind == 12) {
        extent = length(velocity) + s.size * 2.0 + 1.0;
        travel = float2(0.0);
    }
    extent = min(max(extent, 2.0 / u.scale), 255.0);
    out.position = float4((position - travel * 0.5 + u.shake) / u.viewSize * 2.0 - 1.0, 0.0, 1.0);
    out.pointSize = extent * u.scale;
    out.streak = kind == 12 ? velocity / extent : travel / extent;
    out.radius = s.size * 0.5 / extent;
    out.alpha = kind == 9 ? s.alpha * u.opacity : s.alpha;
    out.light = u.light.rgb;
    out.warm = puffCandlelight(u, position);
    out.tint = float4(s.tintRed, s.tintGreen, s.tintBlue, s.tintAmount);
    out.leaf = s.leaf;
    out.turn = s.turn;
    out.flip = s.flip;
    out.turnSmear = s.turnSpeed;
    out.flipSmear = s.flipSpeed;
    out.reach = extent * u.scale;
    return out;
}

fragment float4 puffSpriteFragment(PuffOut in [[stage_in]], float2 coord [[point_coord]]) {
    // Point coordinates run down the screen; the shapes' run up.
    float2 p = float2(coord.x - 0.5, 0.5 - coord.y);
    int kind = int(round(-in.leaf));
    float3 lit = mix(in.light, candle, in.warm * 0.4);
    float4 color;
    switch (kind) {
    case 4: color = spGlow(p, in.streak, in.radius, in.tint.rgb, in.alpha); break;
    case 5: color = spSnowman(p, in.turn, in.flip, in.turnSmear, in.flipSmear, in.reach, lit) * in.alpha; break;
    case 6: color = spCat(p, in.turn, in.flip, in.turnSmear, in.flipSmear, in.reach, lit) * in.alpha; break;
    case 7: color = spBird(p, in.turn, in.flip, in.turnSmear, in.flipSmear, in.reach, lit) * in.alpha; break;
    case 8: color = spFog(p, in.turn, in.alpha, in.light); break;
    case 9: color = spHail(p, in.streak, in.radius, in.alpha, lit, in.reach); break;
    case 11: color = spBulb(p, in.tint.rgb, in.turn, in.flip, in.reach, in.light) * in.alpha; break;
    case 12: color = spWire(p, in.streak, in.radius, in.light, in.reach) * in.alpha; break;
    default: color = spSnowball(p, in.turn, in.flip, in.alpha, lit, in.reach); break;
    }
    if (color.a < 0.002) discard_fragment();
    return color;
}

struct FrostUniforms {
    float2 viewSize;
    float time;
    float cell;
    float reach;
    float mist;
    int columns;
    int rows;
    float4 light;
};

struct FrostOut {
    float4 position [[position]];
    float2 world;
};

/// Frost and mist are drawn as four bands along the screen's edges, as deep as they reach.
vertex FrostOut frostVertex(uint vid [[vertex_id]], uint band [[instance_id]], constant FrostUniforms &f [[buffer(1)]]) {
    float2 corner = float2(float(vid & 1), float(vid >> 1));
    float2 size = f.viewSize;
    float r = min(f.reach, min(size.x, size.y) * 0.5);
    float4 box = band == 0 ? float4(0.0, 0.0, size.x, r)
        : band == 1 ? float4(0.0, size.y - r, size.x, size.y)
        : band == 2 ? float4(0.0, r, r, size.y - r)
        : float4(size.x - r, r, size.x, size.y - r);
    float2 world = mix(box.xy, box.zw, corner);
    FrostOut out;
    out.position = float4(world / size * 2.0 - 1.0, 0.0, 1.0);
    out.world = world;
    return out;
}

fragment float4 frostFragment(FrostOut in [[stage_in]], const device float *grid [[buffer(0)]], constant FrostUniforms &f [[buffer(1)]]) {
    float2 g = in.world / f.cell;
    int2 i = int2(floor(g));
    float2 t = g - floor(g);
    int2 a = clamp(i, int2(0), int2(f.columns - 1, f.rows - 1));
    int2 b = clamp(i + 1, int2(0), int2(f.columns - 1, f.rows - 1));
    float v = mix(mix(grid[a.y * f.columns + a.x], grid[a.y * f.columns + b.x], t.x),
                  mix(grid[b.y * f.columns + a.x], grid[b.y * f.columns + b.x], t.x), t.y);
    float4 color = spFrost(in.world, v, f.mist, f.time, f.light.rgb, f.viewSize);
    if (color.a < 0.002) discard_fragment();
    return color;
}

struct Icicle {
    packed_float2 root;
    float length;
    float width;
    float angle;
    float seed;
    float alpha;
    float padding;
};

struct IcicleOut {
    float4 position [[position]];
    float2 local;
    float2 world;
    float width;
    float length;
    float alpha;
    float seed;
};

/// A quad hanging down from its root, turned by its angle while it tumbles.
vertex IcicleOut icicleVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                              const device Icicle *icicles [[buffer(0)]], constant PuffUniforms &u [[buffer(1)]]) {
    Icicle c = icicles[iid];
    float2 corner = float2(float(vid & 1), float(vid >> 1));
    float x = (corner.x * 2.0 - 1.0) * (c.width + 1.5);
    float y = mix(1.0, -c.length - 1.5, corner.y);
    float2 world = float2(c.root) + float2(x * cos(c.angle) - y * sin(c.angle), x * sin(c.angle) + y * cos(c.angle));
    IcicleOut out;
    out.position = float4((world + u.shake) / u.viewSize * 2.0 - 1.0, 0.0, 1.0);
    out.local = float2(x, -y);
    out.world = world;
    out.width = c.width;
    out.length = c.length;
    out.alpha = c.alpha;
    out.seed = c.seed;
    return out;
}

fragment float4 icicleFragment(IcicleOut in [[stage_in]], constant PuffUniforms &u [[buffer(1)]],
                               constant float4 *occluders [[buffer(2)]]) {
    for (int k = 0; k < u.occluderCount; k++) {
        float4 o = occluders[k];
        if (in.world.x >= o.x && in.world.x < o.z && in.world.y >= o.y && in.world.y < o.w) discard_fragment();
    }
    float v = in.local.y / max(in.length, 0.001);
    if (v < -0.02 || v > 1.0) discard_fragment();
    // Tapers to a point, with a few ripples where meltwater froze on the way down.
    float taper = pow(saturate(1.0 - v), 0.9) * (1.0 + 0.12 * sin(v * 19.0 + in.seed * 7.0) * (1.0 - v));
    float half_ = in.width * taper;
    float edge = half_ - abs(in.local.x);
    float a = saturate(edge * u.scale + 0.5) * in.alpha;
    if (a < 0.003) discard_fragment();
    float across = in.local.x / max(half_, 0.3);
    // Clear ice: see-through in the middle, brighter at its edges, with a bright streak where light catches it.
    float3 ice = float3(0.86, 0.92, 0.98);
    float body = 0.42 + 0.35 * smoothstep(0.3, 1.0, abs(across));
    float streak = exp(-pow((across + 0.35) / 0.18, 2.0)) * 0.9;
    float3 color = mix(ice, float3(1.0), streak);
    float glint = pow(saturate(sin(u.time * 0.8 + in.seed * 40.0 + v * 3.0)), 30.0) * streak;
    color = mix(color, float3(1.0), glint);
    color *= u.light.rgb;
    float warm = puffCandlelight(u, in.world);
    color = mix(color, candle, warm * 0.6);
    float alpha = a * saturate(body + streak * 0.5 + warm * 0.25);
    return float4(color * alpha, alpha);
}
"""
