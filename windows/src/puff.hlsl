// Snowpuff's own parts over the snow, drawn by puff.rs: the extras (shaders/extras.shader, shared with the Mac),
// icicles and frost. Sprites and icicles come as plain float buffers, so no input layout is needed.

cbuffer PuffUniforms : register(b0) {
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
    float4 occluders[16];
};

Buffer<float> sprites : register(t0);
Buffer<float> icicles : register(t1);
Buffer<float> frostGrid : register(t2);

// The warm light from a window.
static const float3 candle = float3(1.0, 0.824, 0.494);

float puffFlicker() {
    return 0.86 + 0.08 * sin(time * 11.0) + 0.06 * sin(time * 29.0 + 1.3);
}

// How much warm light reaches a point: the cursor's lantern, and the focused window's glow, which spills a little
// around the window and reaches further below it, like light from a window onto a drift.
float puffCandlelight(float2 at) {
    float2 d = at - lantern.xy;
    float glow = lantern.w * puffFlicker() * exp(-dot(d, d) / max(lantern.z * lantern.z, 1.0));
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

struct PuffOut {
    float4 position : SV_Position;
    float2 coord : TEXCOORD0;
    float alpha : ALPHA;
    float4 tint : TINT;
    float2 streak : STREAK;
    float radius : RADIUS;
    float warm : WARM;
    // The kind, its two values and how many pixels the sprite spans.
    nointerpolation float4 leaf : LEAF;
    nointerpolation float4 smear : SMEAR;
};

float spriteValue(uint sprite, uint k) {
    return sprites.Load(sprite * 17 + k);
}

// A glow (-4), snowman (-5), cat (-6), bird (-7), fog puff (-8), hailstone (-9), snowball (-10), bulb (-11) or a piece
// of the garland's cord (-12); one quad per sprite, four vertices each.
PuffOut puffVertex(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
    float2 corner = float2(float(vid & 1), float(vid >> 1));
    float2 position = float2(spriteValue(iid, 0), spriteValue(iid, 1));
    float2 velocity = float2(spriteValue(iid, 2), spriteValue(iid, 3));
    float size = spriteValue(iid, 4);
    float alpha = spriteValue(iid, 5);
    float4 tint = float4(spriteValue(iid, 8), spriteValue(iid, 9), spriteValue(iid, 10), spriteValue(iid, 7));
    float3 leaf = float3(spriteValue(iid, 12), spriteValue(iid, 13), spriteValue(iid, 14));
    float2 spin = float2(spriteValue(iid, 15), spriteValue(iid, 16));
    int kind = (int)round(-leaf.x);
    float2 travel = kind == 4 ? velocity * 0.03 : (kind == 9 ? velocity * 0.012 : float2(0.0, 0.0));
    float extent = kind == 4 ? size * 2.4 + length(travel) : (kind == 9 ? size * 1.4 + length(travel) : size);
    if (kind == 11) extent = size * 3.4;
    if (kind == 12) {
        extent = length(velocity) + size * 2.0 + 1.0;
        travel = float2(0.0, 0.0);
    }
    extent = max(extent, 2.0 / scale);
    float2 middle = (position - travel * 0.5 + shake) / viewSize * 2.0 - 1.0;
    PuffOut o = (PuffOut)0;
    o.position = float4(middle + (corner - 0.5) * extent * 2.0 / viewSize, 0.0, 1.0);
    o.coord = float2(corner.x, 1.0 - corner.y);
    o.streak = kind == 12 ? velocity / extent : travel / extent;
    o.radius = size * 0.5 / extent;
    o.alpha = kind == 9 ? alpha * opacity : alpha;
    o.warm = puffCandlelight(position);
    o.tint = tint;
    o.leaf = float4(leaf, extent * scale);
    o.smear = float4(spin, 0.0, 0.0);
    return o;
}

float4 puffFragment(PuffOut i) : SV_Target {
    // Quad coordinates run down the screen; the shapes' run up.
    float2 p = float2(i.coord.x - 0.5, 0.5 - i.coord.y);
    int kind = (int)round(-i.leaf.x);
    float3 lit = lerp(light.rgb, candle, i.warm * 0.4);
    float4 color;
    if (kind == 4) {
        color = spGlow(p, i.streak, i.radius, i.tint.rgb, i.alpha);
    } else if (kind == 5) {
        color = spSnowman(p, i.leaf.y, i.leaf.z, i.smear.x, i.smear.y, i.leaf.w, lit) * i.alpha;
    } else if (kind == 6) {
        color = spCat(p, i.leaf.y, i.leaf.z, i.smear.x, i.smear.y, i.leaf.w, lit) * i.alpha;
    } else if (kind == 7) {
        color = spBird(p, i.leaf.y, i.leaf.z, i.smear.x, i.smear.y, i.leaf.w, lit) * i.alpha;
    } else if (kind == 8) {
        color = spFog(p, i.leaf.y, i.alpha, light.rgb);
    } else if (kind == 9) {
        color = spHail(p, i.streak, i.radius, i.alpha, lit, i.leaf.w);
    } else if (kind == 11) {
        color = spBulb(p, i.tint.rgb, i.leaf.y, i.leaf.z, i.leaf.w, light.rgb) * i.alpha;
    } else if (kind == 12) {
        color = spWire(p, i.streak, i.radius, light.rgb, i.leaf.w) * i.alpha;
    } else {
        color = spSnowball(p, i.leaf.y, i.leaf.z, i.alpha, lit, i.leaf.w);
    }
    if (color.a < 0.002) discard;
    return color;
}

struct IcicleOut {
    float4 position : SV_Position;
    float2 local : TEXCOORD0;
    float2 world : TEXCOORD1;
    nointerpolation float4 shape : SHAPE;
};

IcicleOut icicleVertex(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
    float2 corner = float2(float(vid & 1), float(vid >> 1));
    uint at = iid * 8;
    float2 root = float2(icicles.Load(at), icicles.Load(at + 1));
    float len = icicles.Load(at + 2);
    float width = icicles.Load(at + 3);
    float angle = icicles.Load(at + 4);
    float seed = icicles.Load(at + 5);
    float alpha = icicles.Load(at + 6);
    float x = (corner.x * 2.0 - 1.0) * (width + 1.5);
    float y = lerp(1.0, -len - 1.5, corner.y);
    float cs = cos(angle);
    float sn = sin(angle);
    float2 world = root + float2(x * cs - y * sn, x * sn + y * cs);
    IcicleOut o;
    o.position = float4((world + shake) / viewSize * 2.0 - 1.0, 0.0, 1.0);
    o.local = float2(x, -y);
    o.world = world;
    o.shape = float4(width, len, alpha, seed);
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
    float warm = puffCandlelight(i.world);
    color = lerp(color, candle, warm * 0.6);
    float shown = a * saturate(body + streak * 0.5 + warm * 0.25);
    return float4(color * shown, shown);
}

// Frost and mist on the glass, drawn as four bands along the screen's edges, as deep as they reach.
cbuffer FrostUniforms : register(b1) {
    float2 frostView;
    float frostTime;
    float frostCell;
    float frostReach;
    float frostMist;
    int frostColumns;
    int frostRows;
    float4 frostLight;
};

struct FrostOut {
    float4 position : SV_Position;
    float2 world : TEXCOORD0;
};

FrostOut frostVertex(uint vid : SV_VertexID, uint band : SV_InstanceID) {
    float2 corner = float2(float(vid & 1), float(vid >> 1));
    float2 size = frostView;
    float r = min(frostReach, min(size.x, size.y) * 0.5);
    float4 box = band == 0 ? float4(0.0, 0.0, size.x, r)
        : (band == 1 ? float4(0.0, size.y - r, size.x, size.y)
        : (band == 2 ? float4(0.0, r, r, size.y - r)
        : float4(size.x - r, r, size.x, size.y - r)));
    float2 world = lerp(box.xy, box.zw, corner);
    FrostOut o;
    o.position = float4(world / size * 2.0 - 1.0, 0.0, 1.0);
    o.world = world;
    return o;
}

float frostAt(int2 c) {
    c = clamp(c, int2(0, 0), int2(frostColumns - 1, frostRows - 1));
    return frostGrid.Load(c.y * frostColumns + c.x);
}

float4 frostFragment(FrostOut i) : SV_Target {
    float2 g = i.world / frostCell;
    int2 c = int2(floor(g));
    float2 t = g - floor(g);
    float v = lerp(lerp(frostAt(c), frostAt(c + int2(1, 0)), t.x), lerp(frostAt(c + int2(0, 1)), frostAt(c + int2(1, 1)), t.x), t.y);
    float4 color = spFrost(i.world, v, frostMist, frostTime, frostLight.rgb, frostView);
    if (color.a < 0.002) discard;
    return color;
}
