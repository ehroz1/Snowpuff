let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 viewSize;
    float scale;
    float time;
    float columnWidth;
    int columnCount;
    float pileTop;
    int occluderCount;
    float2 origin;
    float pileBottom;
    float autumn;
    float4 light;
    float4 shadowTint;
    float4 rim;
    float4 lantern;
    float4 shake;
    float4 hearth;
    float4 hearthLight;
};

struct Sprite {
    float2 position;
    float2 velocity;
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

struct SpriteOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float alpha;
    float soft;
    float4 tint;
    float3 light;
    float2 streak;
    float radius;
    float lump;
    float spin;
    float warm;
    float leaf;
    float turn;
    float flip;
    float reach;
    float turnSmear;
    float flipSmear;
    float samples;
};

/// Cocoa palette: glow-300, the warm light from a window.
constant float3 candle = float3(1.0, 0.824, 0.494);

static float hash(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float noise(float x) {
    float i = floor(x);
    float f = fract(x);
    return mix(hash(float2(i, 0.0)), hash(float2(i + 1.0, 0.0)), f * f * (3.0 - 2.0 * f));
}

/// Golden, amber, orange, rust or brown, a little lighter or darker.
static float3 leafColor(float seed) {
    float k = fract(seed * 7.13);
    float3 c = k < 0.3 ? float3(0.97, 0.78, 0.22)
        : k < 0.55 ? float3(0.95, 0.56, 0.13)
        : k < 0.75 ? float3(0.86, 0.36, 0.11)
        : k < 0.9 ? float3(0.72, 0.2, 0.09)
        : float3(0.58, 0.38, 0.17);
    return c * (0.86 + 0.24 * fract(seed * 31.7));
}

/// Fallen leaves lying every which way: the topmost at each point shows, the gaps between them in shadow.
static float3 litter(float2 point) {
    float2 cell = floor(point / 6.5);
    float top = -1.0;
    float rim = 0.0;
    float3 color = float3(0.34, 0.19, 0.08);
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            for (int k = 0; k < 3; k++) {
                float2 c = cell + float2(i, j) + float(k) * 0.37;
                float2 d = point - (cell + float2(i, j) + float2(hash(c + 7.1), hash(c + 3.3))) * 6.5;
                float angle = hash(c + 11.7) * 6.2832;
                float2 q = float2(cos(angle) * d.x + sin(angle) * d.y, -sin(angle) * d.x + cos(angle) * d.y);
                float size = 3.8 + 2.4 * hash(c + 2.9);
                float t = q.x / size;
                float inside = (1.0 - t * t) * size * 0.45 - abs(q.y);
                float z = hash(c + 5.9);
                if (inside > 0.0 && z > top) {
                    top = z;
                    rim = inside;
                    color = leafColor(hash(c + 0.5));
                }
            }
        }
    }
    return color * (0.7 + 0.3 * smoothstep(0.0, 0.7, rim));
}

/// A leaf at one moment, `p` running across it from -0.5 to 0.5: its colour, premultiplied.
static float4 leafAt(float2 p, float seed, float turn, float flip, float alpha, float3 light, float warm) {
    float across = max(abs(flip), 0.35);
    float2 r = float2(cos(turn) * p.x + sin(turn) * p.y, -sin(turn) * p.x + cos(turn) * p.y) * 2.0;
    r.y /= across;
    float inside;
    if (fract(seed * 13.7) < 0.4) {
        // A maple leaf: five pointed lobes around the stem.
        float2 m = r - float2(0.08, 0.0);
        float a = atan2(m.y, m.x);
        float reach = (0.5 + 0.44 * pow(abs(cos(a * 2.5)), 1.3)) * (0.82 + 0.18 * cos(a));
        inside = reach - length(m);
    } else {
        // An oval leaf, widest toward the stem and pointed at the tip.
        float t = (r.x + 0.88) / 1.82;
        float halfWidth = 2.1 * pow(saturate(t), 0.7) * pow(saturate(1.0 - t), 1.1) * (0.8 + 0.4 * fract(seed * 5.3));
        inside = min(halfWidth - abs(r.y), min(t, 1.0 - t) * 0.6);
    }
    float stem = 0.05 - max(abs(r.y) * across, max(-0.98 - r.x, r.x + 0.55));
    float shape = max(inside, stem);
    float edge = max(fwidth(shape), 1e-4);
    float a = smoothstep(-edge, edge, shape) * alpha;
    float3 color = leafColor(seed);
    color *= 0.76 + 0.24 * smoothstep(0.0, 0.22, inside);
    float vein = (1.0 - smoothstep(0.0, 0.045, abs(r.y) * across)) * step(-0.9, r.x) * step(r.x, 0.7);
    color = mix(color, color * 0.6, vein * 0.55);
    if (flip < 0.0) color = mix(color, float3(0.86, 0.74, 0.52), 0.28) * 0.9;
    // Night dims the leaves without draining their colour.
    color *= (0.8 + 0.2 * abs(flip)) * mix(float3(1.0), light, 0.4);
    color = mix(color, candle, warm * 0.45);
    return float4(color * a, a);
}

static float flicker(float time, float seed) {
    return 0.86 + 0.08 * sin(time * 11.0 + seed * 2.1) + 0.06 * sin(time * 29.0 + 1.3 + seed * 4.3);
}

/// How much warm light reaches a point: the cursor's lantern, and the focused window's glow, which spills
/// a little around the window and reaches further below it, like light from a window onto a drift.
static float candlelight(constant Uniforms &u, float2 point) {
    float2 d = point - u.lantern.xy;
    float glow = u.lantern.w * flicker(u.time, 0.0) * exp(-dot(d, d) / (u.lantern.z * u.lantern.z));
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


/// Rain, drawn by Snowpuff: a sprite whose leaf is below zero is a streak (-1), a drop on the glass (-2) or a
/// droplet of spray (-3). A drop's turn is how far it stretches along its run.
static SpriteOut rainVertex(Sprite s, constant Uniforms &u) {
    SpriteOut out;
    float kind = s.leaf;
    // Streaks smear over about a 1/33 s exposure, as long as they fall in a frame; spray over less.
    float2 travel = kind < -1.5 ? (kind < -2.5 ? s.velocity * 0.012 : float2(0.0)) : s.velocity * 0.03;
    float stretch = (kind < -1.5 && kind > -2.5) ? max(s.turn, 1.0) : 1.0;
    float extent = max(s.size * 1.3 * stretch + length(travel), 2.0 / u.scale) + 2.0 / u.scale;
    out.position = float4((s.position - travel * 0.5 + u.shake.xy) / u.viewSize * 2.0 - 1.0, 0.0, 1.0);
    out.pointSize = extent * u.scale;
    out.streak = travel / extent;
    out.radius = s.size * 0.5 / extent;
    out.alpha = s.alpha;
    out.light = u.light.rgb;
    out.warm = candlelight(u, s.position);
    out.leaf = kind;
    out.turn = stretch;
    // Its radius in pixels, for edges a pixel soft at any size.
    out.reach = max(s.size * 0.5 * u.scale, 0.5);
    return out;
}

static float4 rainFragment(SpriteOut in, float2 p) {
    float kind = in.leaf;
    float soft = 1.0 / in.reach;
    float3 lit = mix(in.light, candle, in.warm * 0.5);
    if (kind > -1.5 || kind < -2.5) {
        // A streak or a droplet: a thin line along its fall, brightest at its head.
        float2 h = in.streak * 0.5;
        float span = dot(h, h);
        float t = span > 0.0 ? clamp(dot(p, h) / span, -1.0, 1.0) : 0.0;
        float d = length(p - h * t) / max(in.radius, 1e-4);
        float head = span > 0.0 ? 0.3 + 0.7 * (t * 0.5 + 0.5) : 1.0;
        float a = (1.0 - smoothstep(1.0 - soft * 2.0, 1.0 + soft, d)) * in.alpha * head;
        if (a < 0.003) discard_fragment();
        // Grey enough to show over a light window as well as against a dark desktop.
        float3 color = float3(0.72, 0.76, 0.82) * lit;
        return float4(color * a, a);
    }
    // A drop on the glass: a little lens. Mostly clear, with the dark rim and the bright crescent that light bent
    // through water shows, and a glint near its top. Running or hanging drops swell toward their foot.
    float2 q = p / max(in.radius, 1e-4);
    q.y = q.y > 0.0 ? q.y / in.turn : q.y / (1.0 + (in.turn - 1.0) * 0.25);
    float r = length(q);
    float body = 1.0 - smoothstep(1.0 - soft, 1.0 + soft, r);
    if (body < 0.003) discard_fragment();
    float rim = smoothstep(0.6, 1.0, r) * (0.3 + 0.7 * saturate(0.55 - q.y * 0.7));
    // Water bends what is behind it: darker along its lower half, with a bright crescent inside its foot.
    float shade = saturate(-q.y * 0.6 + 0.1) * (1.0 - smoothstep(0.0, 0.9, r)) * 0.18;
    float glint = pow(saturate(1.0 - length(q - float2(-0.3, 0.42)) / 0.3), 1.5);
    float crescent = pow(saturate(1.0 - length((q - float2(0.05, -0.55)) * float2(0.7, 1.8)) / 0.55), 2.0) * 0.8;
    float bright = saturate(glint + crescent);
    float dark = saturate(rim * 0.75 + shade);
    float a = saturate(0.1 + dark + bright * 0.85) * body * in.alpha;
    float3 color = mix(float3(0.04, 0.05, 0.07), float3(1.0) * lit, bright / max(bright + dark, 1e-3));
    return float4(color * a, a);
}

vertex SpriteOut spriteVertex(uint vid [[vertex_id]],
                              const device Sprite *sprites [[buffer(0)]],
                              constant Uniforms &u [[buffer(1)]]) {
    Sprite s = sprites[vid];
    if (s.leaf < 0.0) return rainVertex(s, u);
    if (s.leaf != 0.0) {
        SpriteOut out;
        // About a 1/40 s exposure: at 30 frames a second a falling leaf smears most of the way to where the next
        // frame shows it, so it glides instead of hopping. The sprite sits midway along the smear.
        float exposure = 0.024;
        float pixels = max(s.size * u.scale, 2.0);
        float2 travel = s.velocity * exposure;
        float extent = pixels + length(travel) * u.scale;
        out.position = float4((s.position - travel * 0.5 + u.shake.xy) / u.viewSize * 2.0 - 1.0, 0.0, 1.0);
        out.pointSize = extent;
        out.reach = extent / pixels;
        out.streak = travel / max(s.size, 0.001);
        out.turnSmear = s.turnSpeed * exposure;
        out.flipSmear = s.flipSpeed * exposure;
        // Enough moments along the smear that no copy of the leaf stands apart from the next.
        float motion = length(travel) * u.scale + (abs(out.turnSmear) + abs(out.flipSmear)) * pixels * 0.5;
        out.samples = clamp(ceil(motion / 1.2), 1.0, 8.0);
        out.alpha = s.alpha;
        out.light = u.light.rgb;
        out.warm = candlelight(u, s.position);
        out.leaf = s.leaf;
        out.turn = s.turn;
        out.flip = s.flip;
        return out;
    }
    float pixels = s.size * u.scale;
    // About a 1/55 s exposure, capped so even the fastest grain stays a short smear and never reads as rain.
    float2 travel = s.velocity * 0.018;
    float smear = min(length(travel), s.size * (s.lump > 0.0 ? 1.2 : 2.2));
    float2 streak = smear > 0.25 ? normalize(travel) * smear * u.scale : float2(0.0);
    // A lump's ragged edge reaches past its nominal size.
    float reach = s.lump > 0.0 ? 1.3 : 1.0;
    float extent = max(pixels * reach + length(streak), 2.0);
    SpriteOut out;
    out.position = float4((s.position + u.shake.xy) / u.viewSize * 2.0 - 1.0, 0.0, 1.0);
    out.pointSize = extent;
    out.streak = streak / extent;
    out.radius = pixels / extent * 0.5;
    // A streak spreads the same flake over more pixels, so each is fainter.
    out.alpha = s.alpha * min(pixels / 2.0, 1.0) * pixels / max(pixels + length(streak) * 0.6, 0.001);
    out.soft = s.soft;
    out.tint = float4(s.tintRed, s.tintGreen, s.tintBlue, s.tintAmount);
    out.light = u.light.rgb;
    out.lump = s.lump;
    out.spin = s.lump > 0.0 ? u.time * (s.lump - 0.5) * 9.0 + s.lump * 40.0 : 0.0;
    out.warm = candlelight(u, s.position);
    out.leaf = 0.0;
    return out;
}

fragment float4 spriteFragment(SpriteOut in [[stage_in]], float2 coord [[point_coord]], constant Uniforms &u [[buffer(1)]]) {
    // Point coordinates run down the screen; velocities run up.
    float2 p = float2(coord.x - 0.5, 0.5 - coord.y);
    if (in.leaf < 0.0) return rainFragment(in, p);
    if (in.leaf != 0.0) {
        // The leaf over the exposure, from where it was to where it is now, turning and tumbling on the way.
        int n = int(in.samples);
        float4 sum = float4(0.0);
        for (int k = 0; k < n; k++) {
            float along = (float(k) + 0.5) / float(n) - 0.5;
            float back = along - 0.5;
            sum += leafAt(p * in.reach - in.streak * along, in.leaf, in.turn + in.turnSmear * back,
                          clamp(in.flip + in.flipSmear * back, -1.0, 1.0), in.alpha, in.light, in.warm);
        }
        sum /= float(n);
        if (sum.a < 0.002) discard_fragment();
        return sum;
    }
    float2 half_ = in.streak * 0.5;
    float span = dot(half_, half_);
    float t = span > 0.0 ? clamp(dot(p, half_) / span, -1.0, 1.0) : 0.0;
    float2 d = p - half_ * t;
    float r = length(d) / max(in.radius, 0.001);
    float shading = 0.0;
    if (in.lump > 0.0) {
        float angle = atan2(d.y, d.x) + in.spin;
        r /= 1.0 + 0.14 * sin(3.0 * angle) + 0.08 * sin(5.0 * angle + in.lump * 21.0) + 0.05 * sin(2.0 * angle + in.lump * 9.0);
        shading = saturate(dot(d / max(in.radius, 0.001), float2(0.45, -0.6))) * 0.4;
    }
    // Brighter at the head, where the flake is now, than at the tail, where it was.
    float head = span > 0.0 ? 0.15 + 0.85 * pow(t * 0.5 + 0.5, 1.5) : 1.0;
    float a = (1.0 - smoothstep(mix(0.6, 0.0, in.soft), 1.0, r)) * in.alpha * head;
    if (a < 0.002) discard_fragment();
    float3 core = float3(1.0, 0.975, 0.94);
    float3 rim = float3(0.76, 0.69, 0.66);
    float3 color = mix(core, rim, saturate(smoothstep(0.35, 1.0, r) * 0.65 + shading));
    color = mix(color, in.tint.rgb, in.tint.a) * in.light;
    color = mix(color, candle, in.warm * 0.7);
    a = min(1.0, a * (1.0 + in.warm * 0.8));
    return float4(color * a, a);
}

struct PileOut {
    float4 position [[position]];
    float2 point;
};

vertex PileOut pileVertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
    float2 corner = float2(float(vid & 1), float(vid >> 1));
    float2 p = float2(corner.x * float(u.columnCount) * u.columnWidth, mix(u.pileBottom, u.pileTop, corner.y));
    PileOut out;
    out.position = float4((p + u.origin + u.shake.xy) / u.viewSize * 2.0 - 1.0, 0.0, 1.0);
    out.point = p;
    return out;
}

static float heightAt(const device float *h, constant Uniforms &u, float x) {
    float f = x / u.columnWidth - 0.5;
    float base = floor(f);
    int i = clamp(int(base), 0, u.columnCount - 1);
    int j = min(i + 1, u.columnCount - 1);
    return mix(h[i], h[j], saturate(f - base));
}

fragment float4 pileFragment(PileOut in [[stage_in]],
                             const device float *heights [[buffer(0)]],
                             constant Uniforms &u [[buffer(1)]],
                             constant float4 *occluders [[buffer(2)]]) {
    float2 world = in.point + u.origin;
    for (int k = 0; k < u.occluderCount; k++) {
        float4 o = occluders[k];
        if (world.x >= o.x && world.x < o.z && world.y >= o.y && world.y < o.w) discard_fragment();
    }

    float x = in.point.x;
    // Where along the heap itself: it stays put as the window's left edge is dragged under it.
    float2 grain = float2(x - u.shake.z, in.point.y);
    float level = heightAt(heights, u, x);
    float bed = heightAt(heights + u.columnCount, u, x);
    // The leaves on top are drawn one by one, the heap under them as a mass with a ragged top; a leaf or two lie on their own.
    if (u.autumn > 0.5) {
        level -= 2.5;
        level += (noise(grain.x * 0.4) - 0.5) * 2.4 * saturate((level - bed) / 4.0);
    }
    float depth = level - in.point.y;
    float coverage = saturate(depth * u.scale + 0.5)
        * saturate((in.point.y - bed) * u.scale + 0.5)
        * saturate((level - bed) / 0.75);
    if (coverage <= 0.0) discard_fragment();

    float slope = (heightAt(heights, u, x + 2.0) - heightAt(heights, u, x - 2.0)) * 0.25;
    float light = dot(normalize(float2(-slope, 1.0)), normalize(float2(-0.5, 1.0)));

    float3 color;
    if (u.autumn > 0.5) {
        // Deeper in the heap the leaves lie in shadow.
        color = litter(grain);
        color = mix(color, color * float3(0.62, 0.54, 0.5), saturate(1.0 - exp(-depth / 18.0)) * 0.6);
        color *= 0.84 + 0.2 * light;
    } else {
        float3 shadow = mix(float3(0.82, 0.73, 0.70), u.shadowTint.rgb, u.shadowTint.a);
        float3 surface = mix(float3(0.965, 0.94, 0.915), min(u.shadowTint.rgb * 1.18, float3(1.0)), u.shadowTint.a * 0.2);
        float shade = (1.0 - exp(-depth / 30.0)) * 0.32 + (1.0 - light) * 0.6 * exp(-depth / 5.0);
        color = mix(surface, shadow, saturate(shade));
        color = mix(color, float3(1.0, 0.98, 0.955), exp(-depth * 0.9) * 0.6);
        color += (hash(floor(in.position.xy)) - 0.5) * 0.02;

        float seed = hash(floor(in.position.xy * 0.5) + 31.7);
        if (seed > 0.992) {
            float twinkle = pow(saturate(sin(u.time * (0.6 + seed * 1.8) + seed * 90.0)), 28.0);
            color = mix(color, float3(1.0), twinkle * exp(-depth / 7.0));
        }
    }

    // Night dims fallen leaves without draining their colour.
    color *= u.autumn > 0.5 ? mix(float3(1.0), u.light.rgb, 0.4) : u.light.rgb;
    color = mix(color, u.rim.rgb, u.rim.a * exp(-depth / 2.5) * (1.0 - u.autumn));
    color = mix(color, candle, candlelight(u, world) * (0.35 + 0.65 * exp(-depth / 14.0)) * 0.55);
    return float4(color * coverage, coverage);
}

struct Icicle {
    float2 root;
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
                              const device Icicle *icicles [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
    Icicle c = icicles[iid];
    float2 corner = float2(float(vid & 1), float(vid >> 1));
    float x = (corner.x * 2.0 - 1.0) * (c.width + 1.5);
    float y = mix(1.0, -c.length - 1.5, corner.y);
    float2 world = c.root + float2(x * cos(c.angle) - y * sin(c.angle), x * sin(c.angle) + y * cos(c.angle));
    IcicleOut out;
    out.position = float4(world / u.viewSize * 2.0 - 1.0, 0.0, 1.0);
    out.local = float2(x, -y);
    out.world = world;
    out.width = c.width;
    out.length = c.length;
    out.alpha = c.alpha;
    out.seed = c.seed;
    return out;
}

fragment float4 icicleFragment(IcicleOut in [[stage_in]], constant Uniforms &u [[buffer(1)]],
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
    float warm = candlelight(u, in.world);
    color = mix(color, candle, warm * 0.6);
    float alpha = a * saturate(body + streak * 0.5 + warm * 0.25);
    return float4(color * alpha, alpha);
}
"""
