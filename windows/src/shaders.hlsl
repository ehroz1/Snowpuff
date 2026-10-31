cbuffer Uniforms : register(b0) {
    float2 viewSize;
    float scale;
    float time;
    float columnWidth;
    int columnCount;
    float pileTop;
    int occluderCount;
    float2 origin;
    float pileBottom;
    int heightOffset;
    float4 light;
    float4 shadowTint;
    float4 rim;
    // The cursor's glow: where it is, how far it reaches and how bright it is.
    float4 lantern;
    // How far everything is jolted: x and y.
    float4 shake;
    // The focused window's glow: its frame, left, bottom, right, top...
    float4 hearth;
    // ...how far it spills sideways, how bright it is and how far it reaches below the window.
    float4 hearthLight;
    float4 occluders[16];
};

Buffer<float> heights : register(t0);

// Cocoa palette: glow-300, the warm light from a window.
static const float3 candle = float3(1.0, 0.824, 0.494);

float hash(float2 p) {
    p = frac(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return frac(p.x * p.y);
}

float flicker(float seed) {
    return 0.86 + 0.08 * sin(time * 11.0 + seed * 2.1) + 0.06 * sin(time * 29.0 + 1.3 + seed * 4.3);
}

// How much warm light reaches a point: the cursor's lantern, and the focused window's glow, which spills a little
// around the window and reaches further below it, like light from a window onto a drift.
float candlelight(float2 at) {
    float2 d = at - lantern.xy;
    float glow = lantern.w * flicker(0.0) * exp(-dot(d, d) / (lantern.z * lantern.z));
    if (hearthLight.y > 0.0) {
        float2 center = (hearth.xy + hearth.zw) * 0.5;
        float2 halfSize = (hearth.zw - hearth.xy) * 0.5;
        float2 q = at - center;
        float2 outside = max(abs(q) - halfSize, float2(0.0, 0.0));
        float reachY = q.y < 0.0 ? hearthLight.z : hearthLight.x;
        float spill = exp(-outside.x * outside.x / (hearthLight.x * hearthLight.x) - outside.y * outside.y / (reachY * reachY));
        float inside = lerp(0.35, 1.0, saturate(length(outside) / 10.0));
        glow += hearthLight.y * spill * inside * (0.94 + 0.06 * sin(time * 0.7));
    }
    return min(glow, 1.0);
}

struct SpriteIn {
    float2 position : POSITION;
    float2 velocity : VELOCITY;
    float size : SIZE;
    float alpha : ALPHA;
    float soft : SOFT;
    float tintAmount : TINTAMOUNT;
    float3 tintColor : TINTCOLOR;
    float lump : LUMP;
    uint vid : SV_VertexID;
};

struct SpriteOut {
    float4 position : SV_Position;
    float2 coord : TEXCOORD0;
    float alpha : ALPHA;
    float soft : SOFT;
    float4 tint : TINT;
    float2 streak : STREAK;
    float radius : RADIUS;
    float lump : LUMP;
    float spin : SPIN;
    float warm : WARM;
};

SpriteOut spriteVertex(SpriteIn s) {
    float pixels = s.size * scale;
    // About a 1/55 s exposure, capped so even the fastest grain stays a short smear and never reads as rain.
    float2 travel = s.velocity * 0.018;
    float smear = min(length(travel), s.size * (s.lump > 0.0 ? 1.2 : 2.2));
    float2 streak = smear > 0.25 ? normalize(travel) * smear * scale : float2(0.0, 0.0);
    // A lump's ragged edge reaches past its nominal size.
    float reach = s.lump > 0.0 ? 1.3 : 1.0;
    float extent = max(pixels * reach + length(streak), 2.0);
    float2 corner = float2(float(s.vid & 1), float(s.vid >> 1));
    SpriteOut o;
    float2 center = (s.position + shake.xy) / viewSize * 2.0 - 1.0;
    o.position = float4(center + (corner - 0.5) * extent * 2.0 / (viewSize * scale), 0.0, 1.0);
    o.coord = float2(corner.x, 1.0 - corner.y);
    o.streak = streak / extent;
    o.radius = pixels / extent * 0.5;
    // A streak spreads the same flake over more pixels, so each is fainter.
    o.alpha = s.alpha * min(pixels / 2.0, 1.0) * pixels / max(pixels + length(streak) * 0.6, 0.001);
    o.soft = s.soft;
    o.tint = float4(s.tintColor, s.tintAmount);
    o.lump = s.lump;
    o.spin = s.lump > 0.0 ? time * (s.lump - 0.5) * 9.0 + s.lump * 40.0 : 0.0;
    o.warm = candlelight(s.position);
    return o;
}

float4 spriteFragment(SpriteOut i) : SV_Target {
    // Quad coordinates run down the screen; velocities run up.
    float2 p = float2(i.coord.x - 0.5, 0.5 - i.coord.y);
    float2 half_ = i.streak * 0.5;
    float span = dot(half_, half_);
    float t = span > 0.0 ? clamp(dot(p, half_) / span, -1.0, 1.0) : 0.0;
    float2 d = p - half_ * t;
    float r = length(d) / max(i.radius, 0.001);
    float shading = 0.0;
    if (i.lump > 0.0) {
        float angle = atan2(d.y, d.x) + i.spin;
        r /= 1.0 + 0.14 * sin(3.0 * angle) + 0.08 * sin(5.0 * angle + i.lump * 21.0) + 0.05 * sin(2.0 * angle + i.lump * 9.0);
        shading = saturate(dot(d / max(i.radius, 0.001), float2(0.45, -0.6))) * 0.4;
    }
    // Brighter at the head, where the flake is now, than at the tail, where it was.
    float head = span > 0.0 ? 0.15 + 0.85 * pow(t * 0.5 + 0.5, 1.5) : 1.0;
    float a = (1.0 - smoothstep(lerp(0.6, 0.0, i.soft), 1.0, r)) * i.alpha * head;
    if (a < 0.002) discard;
    float3 core = float3(1.0, 0.975, 0.94);
    float3 edge = float3(0.76, 0.69, 0.66);
    float3 color = lerp(core, edge, saturate(smoothstep(0.35, 1.0, r) * 0.65 + shading));
    color = lerp(color, i.tint.rgb, i.tint.a) * light.rgb;
    color = lerp(color, candle, i.warm * 0.7);
    a = min(1.0, a * (1.0 + i.warm * 0.8));
    return float4(color * a, a);
}

struct PileOut {
    float4 position : SV_Position;
    float2 local : TEXCOORD0;
};

PileOut pileVertex(uint vid : SV_VertexID) {
    float2 corner = float2(float(vid & 1), float(vid >> 1));
    float2 p = float2(corner.x * float(columnCount) * columnWidth, lerp(pileBottom, pileTop, corner.y));
    PileOut o;
    o.position = float4((p + origin + shake.xy) / viewSize * 2.0 - 1.0, 0.0, 1.0);
    o.local = p;
    return o;
}

float heightAt(int start, float x) {
    float f = x / columnWidth - 0.5;
    float base = floor(f);
    int i = clamp(int(base), 0, columnCount - 1);
    int j = min(i + 1, columnCount - 1);
    return lerp(heights[start + i], heights[start + j], saturate(f - base));
}

float4 pileFragment(PileOut i) : SV_Target {
    float2 world = i.local + origin;
    [loop]
    for (int k = 0; k < occluderCount; k++) {
        float4 o = occluders[k];
        if (world.x >= o.x && world.x < o.z && world.y >= o.y && world.y < o.w) discard;
    }

    float x = i.local.x;
    float level = heightAt(heightOffset, x);
    float bed = heightAt(heightOffset + columnCount, x);
    float depth = level - i.local.y;
    float coverage = saturate(depth * scale + 0.5)
        * saturate((i.local.y - bed) * scale + 0.5)
        * saturate((level - bed) / 0.75);
    if (coverage <= 0.0) discard;

    float slope = (heightAt(heightOffset, x + 2.0) - heightAt(heightOffset, x - 2.0)) * 0.25;
    float lit = dot(normalize(float2(-slope, 1.0)), normalize(float2(-0.5, 1.0)));

    float3 shadow = lerp(float3(0.82, 0.73, 0.70), shadowTint.rgb, shadowTint.a);
    float3 surface = lerp(float3(0.965, 0.94, 0.915), min(shadowTint.rgb * 1.18, float3(1.0, 1.0, 1.0)), shadowTint.a * 0.2);
    float shade = (1.0 - exp(-depth / 30.0)) * 0.32 + (1.0 - lit) * 0.6 * exp(-depth / 5.0);
    float3 color = lerp(surface, shadow, saturate(shade));
    color = lerp(color, float3(1.0, 0.98, 0.955), exp(-depth * 0.9) * 0.6);
    color += (hash(floor(i.position.xy)) - 0.5) * 0.02;

    float seed = hash(floor(i.position.xy * 0.5) + 31.7);
    if (seed > 0.992) {
        float twinkle = pow(saturate(sin(time * (0.6 + seed * 1.8) + seed * 90.0)), 28.0);
        color = lerp(color, float3(1.0, 1.0, 1.0), twinkle * exp(-depth / 7.0));
    }

    color *= light.rgb;
    color = lerp(color, rim.rgb, rim.a * exp(-depth / 2.5));
    color = lerp(color, candle, candlelight(world) * (0.35 + 0.65 * exp(-depth / 14.0)) * 0.55);
    return float4(color * coverage, coverage);
}

// Icicles along the bottom edges of windows, and those falling: one quad per icicle, hanging down from its root and
// turned by its angle while it tumbles.
struct IcicleIn {
    float2 root : ROOT;
    float length : LENGTH;
    float width : WIDTH;
    float angle : ANGLE;
    float seed : SEED;
    float alpha : ALPHA;
    uint vid : SV_VertexID;
};

struct IcicleOut {
    float4 position : SV_Position;
    float2 local : TEXCOORD0;
    float2 world : TEXCOORD1;
    nointerpolation float4 shape : SHAPE;
};

IcicleOut icicleVertex(IcicleIn c) {
    float2 corner = float2(float(c.vid & 1), float(c.vid >> 1));
    float x = (corner.x * 2.0 - 1.0) * (c.width + 1.5);
    float y = lerp(1.0, -c.length - 1.5, corner.y);
    float cs = cos(c.angle);
    float sn = sin(c.angle);
    float2 world = c.root + float2(x * cs - y * sn, x * sn + y * cs);
    IcicleOut o;
    o.position = float4(world / viewSize * 2.0 - 1.0, 0.0, 1.0);
    o.local = float2(x, -y);
    o.world = world;
    o.shape = float4(c.width, c.length, c.alpha, c.seed);
    return o;
}

float4 icicleFragment(IcicleOut i) : SV_Target {
    [loop]
    for (int k = 0; k < occluderCount; k++) {
        float4 o = occluders[k];
        if (i.world.x >= o.x && i.world.x < o.z && i.world.y >= o.y && i.world.y < o.w) discard;
    }
    float width = i.shape.x, len = i.shape.y, alpha = i.shape.z, seed = i.shape.w;
    float v = i.local.y / max(len, 0.001);
    if (v < -0.02 || v > 1.0) discard;
    // Tapers to a point, with a few ripples where meltwater froze on the way down.
    float taper = pow(saturate(1.0 - v), 0.9) * (1.0 + 0.12 * sin(v * 19.0 + seed * 7.0) * (1.0 - v));
    float halfWidth = width * taper;
    float a = saturate((halfWidth - abs(i.local.x)) * scale + 0.5) * alpha;
    if (a < 0.003) discard;
    float across = i.local.x / max(halfWidth, 0.3);
    // Clear ice: see-through in the middle, brighter at its edges, with a bright streak where light catches it.
    float body = 0.42 + 0.35 * smoothstep(0.3, 1.0, abs(across));
    float streak = exp(-pow((across + 0.35) / 0.18, 2.0)) * 0.9;
    float3 color = lerp(float3(0.86, 0.92, 0.98), float3(1.0, 1.0, 1.0), streak);
    float glint = pow(saturate(sin(time * 0.8 + seed * 40.0 + v * 3.0)), 30.0) * streak;
    color = lerp(color, float3(1.0, 1.0, 1.0), glint);
    color *= light.rgb;
    float warm = candlelight(i.world);
    color = lerp(color, candle, warm * 0.6);
    float opacity = a * saturate(body + streak * 0.5 + warm * 0.25);
    return float4(color * opacity, opacity);
}
