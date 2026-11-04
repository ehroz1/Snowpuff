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
    // One while leaves fall instead of snow.
    float autumn;
};

Buffer<float> heights : register(t0);

// Cocoa palette: glow-300, the warm light from a window.
static const float3 candle = float3(1.0, 0.824, 0.494);

float hash(float2 p) {
    p = frac(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return frac(p.x * p.y);
}

float smoothNoise(float x) {
    float i = floor(x);
    float f = frac(x);
    return lerp(hash(float2(i, 0.0)), hash(float2(i + 1.0, 0.0)), f * f * (3.0 - 2.0 * f));
}

// Golden, amber, orange, rust or brown, a little lighter or darker.
float3 leafColor(float seed) {
    float k = frac(seed * 7.13);
    float3 c = k < 0.3 ? float3(0.97, 0.78, 0.22)
        : (k < 0.55 ? float3(0.95, 0.56, 0.13)
        : (k < 0.75 ? float3(0.86, 0.36, 0.11)
        : (k < 0.9 ? float3(0.72, 0.2, 0.09)
        : float3(0.58, 0.38, 0.17))));
    return c * (0.86 + 0.24 * frac(seed * 31.7));
}

// Fallen leaves lying every which way: the topmost at each point shows, the gaps between them in shadow.
float3 litter(float2 at) {
    float2 cell = floor(at / 6.5);
    float top = -1.0;
    float margin = 0.0;
    float3 color = float3(0.34, 0.19, 0.08);
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            for (int k = 0; k < 3; k++) {
                float2 c = cell + float2(i, j) + float(k) * 0.37;
                float2 d = at - (cell + float2(i, j) + float2(hash(c + 7.1), hash(c + 3.3))) * 6.5;
                float angle = hash(c + 11.7) * 6.2832;
                float2 q = float2(cos(angle) * d.x + sin(angle) * d.y, -sin(angle) * d.x + cos(angle) * d.y);
                float size = 3.8 + 2.4 * hash(c + 2.9);
                float t = q.x / size;
                float inside = (1.0 - t * t) * size * 0.45 - abs(q.y);
                float z = hash(c + 5.9);
                if (inside > 0.0 && z > top) {
                    top = z;
                    margin = inside;
                    color = leafColor(hash(c + 0.5));
                }
            }
        }
    }
    return color * (0.7 + 0.3 * smoothstep(0.0, 0.7, margin));
}

// A leaf's outline at one moment, `p` running across it from -0.5 to 0.5: how far inside it a point is. Gives back how
// far inside its blade alone, and the point in the leaf's own frame, stretched across by how much of its face shows.
float leafShape(float2 p, float seed, float turn, float flip, out float blade, out float2 r) {
    float across = max(abs(flip), 0.35);
    r = float2(cos(turn) * p.x + sin(turn) * p.y, -sin(turn) * p.x + cos(turn) * p.y) * 2.0;
    r.y /= across;
    if (frac(seed * 13.7) < 0.4) {
        // A maple leaf: five pointed lobes around the stem.
        float2 m = r - float2(0.08, 0.0);
        float a = atan2(m.y, m.x);
        float reach = (0.5 + 0.44 * pow(abs(cos(a * 2.5)), 1.3)) * (0.82 + 0.18 * cos(a));
        blade = reach - length(m);
    } else {
        // An oval leaf, widest toward the stem and pointed at the tip.
        float t = (r.x + 0.88) / 1.82;
        float halfWidth = 2.1 * pow(saturate(t), 0.7) * pow(saturate(1.0 - t), 1.1) * (0.8 + 0.4 * frac(seed * 5.3));
        blade = min(halfWidth - abs(r.y), min(t, 1.0 - t) * 0.6);
    }
    float stem = 0.05 - max(abs(r.y) * across, max(-0.98 - r.x, r.x + 0.55));
    return max(blade, stem);
}

// A leaf at one moment, its outline smoothed over `edge`: its colour, premultiplied.
float4 leafAt(float2 p, float seed, float turn, float flip, float alpha, float warm, float edge) {
    float inside;
    float2 r;
    float shape = leafShape(p, seed, turn, flip, inside, r);
    float across = max(abs(flip), 0.35);
    float a = smoothstep(-edge, edge, shape) * alpha;
    float3 color = leafColor(seed);
    color *= 0.76 + 0.24 * smoothstep(0.0, 0.22, inside);
    float vein = (1.0 - smoothstep(0.0, 0.045, abs(r.y) * across)) * step(-0.9, r.x) * step(r.x, 0.7);
    color = lerp(color, color * 0.6, vein * 0.55);
    if (flip < 0.0) {
        color = lerp(color, float3(0.86, 0.74, 0.52), 0.28) * 0.9;
    }
    // Night dims the leaves without draining their colour.
    color *= (0.8 + 0.2 * abs(flip)) * lerp(float3(1.0, 1.0, 1.0), light.rgb, 0.4);
    color = lerp(color, candle, warm * 0.45);
    return float4(color * a, a);
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
    float3 leaf : LEAF;
    float2 spin : SPIN;
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
    // A leaf's seed, which way it points and how much of its face shows, then how many moments of the exposure it is
    // drawn at; how much wider the sprite is than the leaf, and how far the leaf turns and tumbles over the exposure.
    nointerpolation float4 leaf : LEAF;
    nointerpolation float4 smear : SMEAR;
};

// A leaf's sprite, this corner of it. About a 1/40 s exposure: at 30 frames a second a falling leaf smears most of the
// way to where the next frame shows it, so it glides instead of hopping. The sprite sits midway along the smear.
SpriteOut leafVertex(SpriteIn s, float2 corner) {
    float exposure = 0.024;
    float pixels = max(s.size * scale, 2.0);
    float2 travel = s.velocity * exposure;
    float extent = pixels + length(travel) * scale;
    float2 middle = (s.position - travel * 0.5 + shake.xy) / viewSize * 2.0 - 1.0;
    SpriteOut o = (SpriteOut)0;
    o.position = float4(middle + (corner - 0.5) * extent * 2.0 / (viewSize * scale), 0.0, 1.0);
    o.coord = float2(corner.x, 1.0 - corner.y);
    o.streak = travel / max(s.size, 0.001);
    float turnSmear = s.spin.x * exposure;
    float flipSmear = s.spin.y * exposure;
    // Enough moments along the smear that no copy of the leaf stands apart from the next.
    float motion = length(travel) * scale + (abs(turnSmear) + abs(flipSmear)) * pixels * 0.5;
    o.leaf = float4(s.leaf, clamp(ceil(motion / 1.2), 1.0, 8.0));
    o.smear = float4(extent / pixels, turnSmear, flipSmear, 0.0);
    o.alpha = s.alpha;
    o.warm = candlelight(s.position);
    return o;
}

// Rain, drawn by Snowpuff: a sprite whose leaf seed is below zero is a streak (-1), a drop on the glass (-2) or a
// droplet of spray (-3). A drop's leaf.y is how far it stretches along its run.
SpriteOut rainVertex(SpriteIn s, float2 corner) {
    float kind = s.leaf.x;
    // Streaks smear over about a 1/33 s exposure, as long as they fall in a frame; spray over less.
    float2 travel = kind < -1.5 ? (kind < -2.5 ? s.velocity * 0.012 : float2(0.0, 0.0)) : s.velocity * 0.03;
    float stretch = kind < -1.5 && kind > -2.5 ? max(s.leaf.y, 1.0) : 1.0;
    float extent = max(s.size * 1.3 * stretch + length(travel), 2.0 / scale) + 2.0 / scale;
    float2 middle = (s.position - travel * 0.5 + shake.xy) / viewSize * 2.0 - 1.0;
    SpriteOut o = (SpriteOut)0;
    o.position = float4(middle + (corner - 0.5) * extent * 2.0 / viewSize, 0.0, 1.0);
    o.coord = float2(corner.x, 1.0 - corner.y);
    o.streak = travel / extent;
    o.radius = s.size * 0.5 / extent;
    o.alpha = s.alpha;
    o.warm = candlelight(s.position);
    // Its kind, its stretch and its radius in pixels, for edges a pixel soft at any size.
    o.leaf = float4(kind, stretch, max(s.size * 0.5 * scale, 0.5), 0.0);
    return o;
}

float4 rainFragment(SpriteOut i, float2 p) {
    float kind = i.leaf.x;
    float soft = 1.0 / i.leaf.z;
    float3 lit = lerp(light.rgb, candle, i.warm * 0.5);
    [branch] if (kind > -1.5 || kind < -2.5) {
        // A streak or a droplet: a thin line along its fall, brightest at its head.
        float2 h = i.streak * 0.5;
        float span = dot(h, h);
        float t = span > 0.0 ? clamp(dot(p, h) / span, -1.0, 1.0) : 0.0;
        float d = length(p - h * t) / max(i.radius, 1e-4);
        float head = span > 0.0 ? 0.3 + 0.7 * (t * 0.5 + 0.5) : 1.0;
        float a = (1.0 - smoothstep(1.0 - soft * 2.0, 1.0 + soft, d)) * i.alpha * head;
        if (a < 0.003) discard;
        float3 color = float3(0.86, 0.9, 0.96) * lit;
        return float4(color * a, a);
    }
    // A drop on the glass: a little lens. Mostly clear, with the dark rim and the bright crescent that light bent
    // through water shows, and a glint near its top. Running or hanging drops swell toward their foot.
    float2 q = p / max(i.radius, 1e-4);
    q.y = q.y > 0.0 ? q.y * i.leaf.y : q.y * (1.0 + (i.leaf.y - 1.0) * 0.25);
    float r = length(q);
    float body = 1.0 - smoothstep(1.0 - soft, 1.0 + soft, r);
    if (body < 0.003) discard;
    float rim = smoothstep(0.55, 1.0, r) * (0.55 + 0.45 * saturate(-q.y * 0.8 + 0.3));
    float glint = pow(saturate(1.0 - length(q - float2(-0.32, 0.38)) / 0.32), 2.0);
    float crescent = pow(saturate(1.0 - length((q - float2(0.08, -0.52)) * float2(0.8, 1.6)) / 0.5), 2.0) * 0.6;
    float bright = saturate(glint + crescent);
    float a = saturate(0.07 + rim * 0.5 + bright * 0.85) * body * i.alpha;
    float3 color = lerp(float3(0.05, 0.06, 0.08), float3(1.0, 1.0, 1.0) * lit, bright / max(bright + rim * 0.6, 1e-3));
    return float4(color * a, a);
}

SpriteOut spriteVertex(SpriteIn s) {
    float2 corner = float2(float(s.vid & 1), float(s.vid >> 1));
    [branch] if (s.leaf.x < 0.0) {
        return rainVertex(s, corner);
    }
    [branch] if (s.leaf.x != 0.0) {
        return leafVertex(s, corner);
    }
    float pixels = s.size * scale;
    // About a 1/55 s exposure, capped so even the fastest grain stays a short smear and never reads as rain.
    float2 travel = s.velocity * 0.018;
    float smear = min(length(travel), s.size * (s.lump > 0.0 ? 1.2 : 2.2));
    float2 streak = smear > 0.25 ? normalize(travel) * smear * scale : float2(0.0, 0.0);
    // A lump's ragged edge reaches past its nominal size.
    float reach = s.lump > 0.0 ? 1.3 : 1.0;
    float extent = max(pixels * reach + length(streak), 2.0);
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
    o.leaf = float4(0.0, 0.0, 0.0, 0.0);
    o.smear = float4(0.0, 0.0, 0.0, 0.0);
    return o;
}

// The leaf over the exposure, from where it was to where it is now, turning and tumbling on the way, its outline
// smoothed over `edge`.
float4 leafSmear(SpriteOut i, float2 p, float edge) {
    int n = int(i.leaf.w);
    float4 sum = float4(0.0, 0.0, 0.0, 0.0);
    [loop]
    for (int k = 0; k < n; k++) {
        float along = (float(k) + 0.5) / float(n) - 0.5;
        float back = along - 0.5;
        sum += leafAt(p * i.smear.x - i.streak * along, i.leaf.x, i.leaf.y + i.smear.y * back,
                      clamp(i.leaf.z + i.smear.z * back, -1.0, 1.0), i.alpha, i.warm, edge);
    }
    sum /= float(n);
    if (sum.a < 0.002) discard;
    return sum;
}

float4 spriteFragment(SpriteOut i) : SV_Target {
    // Quad coordinates run down the screen; velocities run up.
    float2 p = float2(i.coord.x - 0.5, 0.5 - i.coord.y);
    float inside = 0.0;
    [branch] if (i.leaf.x > 0.0) {
        float blade;
        float2 frame;
        inside = leafShape(p * i.smear.x, i.leaf.x, i.leaf.y - i.smear.y * 0.5, clamp(i.leaf.z - i.smear.z * 0.5, -1.0, 1.0), blade, frame);
    }
    // Gradients are taken outside any branch, where every graphics card has them for all four pixels of a block.
    float2 slope = float2(ddx(inside), -ddy(inside));
    // Rain draws without gradients, so it branches off only once they are taken.
    [branch] if (i.leaf.x < 0.0) {
        return rainFragment(i, p);
    }
    [branch] if (i.leaf.x != 0.0) {
        // Gradients can't be taken in a loop of varying length, so every moment's outline is smoothed as wide as the
        // one midway through the exposure, the only moment drawn when the leaf hardly moves.
        return leafSmear(i, p, max(abs(slope.x) + abs(slope.y), 1e-4));
    }
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
    // Where along the heap itself: it stays put as the window's left edge is dragged under it. A pile's shake.z is
    // how far along its window the heap has drifted.
    float2 grain = float2(x - shake.z, i.local.y);
    float level = heightAt(heightOffset, x);
    float bed = heightAt(heightOffset + columnCount, x);
    // The leaves on top are drawn one by one, the heap under them as a mass with a ragged top; a leaf or two lie on their own.
    if (autumn > 0.5) {
        level -= 2.5;
        level += (smoothNoise(grain.x * 0.4) - 0.5) * 2.4 * saturate((level - bed) / 4.0);
    }
    float depth = level - i.local.y;
    float coverage = saturate(depth * scale + 0.5)
        * saturate((i.local.y - bed) * scale + 0.5)
        * saturate((level - bed) / 0.75);
    if (coverage <= 0.0) discard;

    float slope = (heightAt(heightOffset, x + 2.0) - heightAt(heightOffset, x - 2.0)) * 0.25;
    float lit = dot(normalize(float2(-slope, 1.0)), normalize(float2(-0.5, 1.0)));

    float3 color;
    [branch] if (autumn > 0.5) {
        // Deeper in the heap the leaves lie in shadow.
        color = litter(grain);
        color = lerp(color, color * float3(0.62, 0.54, 0.5), saturate(1.0 - exp(-depth / 18.0)) * 0.6);
        color *= 0.84 + 0.2 * lit;
    } else {
        float3 shadow = lerp(float3(0.82, 0.73, 0.70), shadowTint.rgb, shadowTint.a);
        float3 surface = lerp(float3(0.965, 0.94, 0.915), min(shadowTint.rgb * 1.18, float3(1.0, 1.0, 1.0)), shadowTint.a * 0.2);
        float shade = (1.0 - exp(-depth / 30.0)) * 0.32 + (1.0 - lit) * 0.6 * exp(-depth / 5.0);
        color = lerp(surface, shadow, saturate(shade));
        color = lerp(color, float3(1.0, 0.98, 0.955), exp(-depth * 0.9) * 0.6);
        color += (hash(floor(i.position.xy)) - 0.5) * 0.02;

        float seed = hash(floor(i.position.xy * 0.5) + 31.7);
        if (seed > 0.992) {
            float twinkle = pow(saturate(sin(time * (0.6 + seed * 1.8) + seed * 90.0)), 28.0);
            color = lerp(color, float3(1.0, 1.0, 1.0), twinkle * exp(-depth / 7.0));
        }
    }

    // Night dims fallen leaves without draining their colour.
    color *= autumn > 0.5 ? lerp(float3(1.0, 1.0, 1.0), light.rgb, 0.4) : light.rgb;
    color = lerp(color, rim.rgb, rim.a * exp(-depth / 2.5) * (1.0 - autumn));
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
