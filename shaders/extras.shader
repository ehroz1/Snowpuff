// Snowpuff's extras, drawn the same on the Mac (Metal) and Windows (HLSL). The file is plain shader code both
// languages accept once each defines FN, lerp and frac before including it:
//   Metal: #define FN static inline / #define lerp mix / #define frac fract
//   HLSL:  #define FN
// A sprite's point p runs over its box from -0.5 to 0.5, y up. `px` is how many pixels the box spans, for edges a
// pixel soft at any size. Colors come back premultiplied.

FN float spHash(float2 p) {
    p = frac(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return frac(p.x * p.y);
}

FN float spNoise(float2 p) {
    float2 i = floor(p);
    float2 f = frac(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = spHash(i);
    float b = spHash(i + float2(1.0, 0.0));
    float c = spHash(i + float2(0.0, 1.0));
    float d = spHash(i + float2(1.0, 1.0));
    return lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);
}

FN float spFbm(float2 p) {
    float sum = 0.0;
    float amplitude = 0.5;
    for (int k = 0; k < 4; k++) {
        sum += spNoise(p) * amplitude;
        p = float2(p.x * 1.6 - p.y * 1.2, p.x * 1.2 + p.y * 1.6);
        amplitude *= 0.5;
    }
    return sum;
}

// Inside a circle, softened over one pixel: 1 inside, 0 outside.
FN float spDisc(float2 p, float2 center, float radius, float px) {
    return saturate((radius - length(p - center)) * px + 0.5);
}

FN float spEllipse(float2 p, float2 center, float2 radii, float px) {
    float2 q = (p - center) / radii;
    float d = (length(q) - 1.0) * min(radii.x, radii.y);
    return saturate(-d * px + 0.5);
}

// Along a segment from a to b, `width` wide.
FN float spLine(float2 p, float2 a, float2 b, float width, float px) {
    float2 ab = b - a;
    float t = saturate(dot(p - a, ab) / max(dot(ab, ab), 1e-6));
    return saturate((width * 0.5 - length(p - a - ab * t)) * px + 0.5);
}

// Paints `color` over what is there with coverage `a`.
FN float4 spOver(float4 under, float3 color, float a) {
    return float4(color * a + under.rgb * (1.0 - a), a + under.a * (1.0 - a));
}

// A soft light: fairy lights, stars, sparks and meteors. `streak` smears it along its motion.
FN float4 spGlow(float2 p, float2 streak, float radius, float3 color, float alpha) {
    float2 h = streak * 0.5;
    float span = dot(h, h);
    float t = span > 0.0 ? clamp(dot(p, h) / span, -1.0, 1.0) : 0.0;
    float r = length(p - h * t) / max(radius, 1e-4);
    float head = span > 0.0 ? 0.25 + 0.75 * (t * 0.5 + 0.5) : 1.0;
    float core = saturate(1.0 - r * 1.25);
    float halo = exp(-r * r * 1.4) * 0.6;
    float a = saturate(core + halo) * alpha * head;
    float3 c = lerp(color, float3(1.0, 1.0, 1.0), core * core * 0.7);
    return float4(c * a, a * 0.85);
}

FN float4 spFog(float2 p, float seed, float alpha, float3 light) {
    float r = length(p) * 2.0;
    float body = exp(-r * r * 2.2) * smoothstep(1.0, 0.55, r);
    float grain = 0.65 + 0.35 * spFbm(p * 3.0 + seed * 17.0);
    float a = body * grain * alpha;
    float3 c = float3(0.9, 0.91, 0.93) * lerp(float3(1.0, 1.0, 1.0), light, 0.7);
    return float4(c * a, a);
}

FN float4 spHail(float2 p, float2 streak, float radius, float alpha, float3 light, float px) {
    float2 h = streak * 0.5;
    float span = dot(h, h);
    float t = span > 0.0 ? clamp(dot(p, h) / span, -1.0, 1.0) : 0.0;
    float2 q = p - h * t;
    float body = saturate((radius - length(q)) * px + 0.5);
    float lit = saturate(dot(q / max(radius, 1e-4), float2(-0.5, 0.6)));
    float3 c = lerp(float3(0.78, 0.84, 0.9), float3(1.0, 1.0, 1.0), lit) * light;
    float a = body * alpha * (span > 0.0 ? 0.4 + 0.6 * (t * 0.5 + 0.5) : 1.0);
    return float4(c * a, a);
}

// A snowball in flight, or the splat it leaves.
FN float4 spSnowball(float2 p, float splat, float seed, float alpha, float3 light, float px) {
    float4 o = float4(0.0, 0.0, 0.0, 0.0);
    if (splat < 0.5) {
        float body = spDisc(p, float2(0.0, 0.0), 0.42, px);
        float lit = saturate(dot(p / 0.42, float2(-0.55, 0.65)) * 0.5 + 0.5);
        float lumps = spFbm(p * 9.0) * 0.12;
        float3 c = lerp(float3(0.76, 0.78, 0.84), float3(1.0, 0.99, 0.97), saturate(lit + lumps)) * light;
        return float4(c * body * alpha, body * alpha);
    }
    float angle = atan2(p.y, p.x);
    float edge = 0.27 + 0.07 * sin(angle * 5.0 + seed * 20.0) + 0.04 * sin(angle * 9.0 + seed * 7.0);
    float blob = saturate((edge - length(p)) * px + 0.5);
    float drip = spLine(p, float2(0.03, 0.0), float2(0.05, -0.38), 0.07, px);
    float specks = 0.0;
    for (int k = 0; k < 6; k++) {
        float a = seed * 40.0 + float(k) * 1.7;
        float2 c = float2(cos(a), sin(a)) * (0.33 + 0.1 * frac(a));
        specks = max(specks, spDisc(p, c, 0.025 + 0.015 * frac(a * 3.1), px));
    }
    float cover = max(max(blob, drip), specks);
    float3 c = lerp(float3(0.82, 0.84, 0.9), float3(1.0, 0.99, 0.97), saturate(0.6 + p.y)) * light;
    return float4(c * cover * alpha, cover * alpha);
}

// A snowman sitting in the drift, built from the bottom up: `built` 0 to 1. He looks toward the cursor.
FN float4 spSnowman(float2 p, float built, float seed, float look, float time, float px, float3 light) {
    float4 o = float4(0.0, 0.0, 0.0, 0.0);
    float bottom = saturate(built / 0.4);
    float middle = saturate((built - 0.4) / 0.3);
    float head = saturate((built - 0.7) / 0.3);
    float3 snow = float3(0.98, 0.96, 0.93) * light;
    float3 shade = float3(0.74, 0.72, 0.78) * light;
    float3 coal = float3(0.1, 0.09, 0.1);
    float2 lightDir = normalize(float2(-0.5, 0.7));
    // Twig arms behind the body.
    if (middle > 0.9) {
        float3 twig = float3(0.36, 0.24, 0.15) * light;
        float wave = sin(time * 1.3 + seed * 9.0) * 0.03;
        o = spOver(o, twig, spLine(p, float2(-0.1, 0.0), float2(-0.33, 0.13 + wave), 0.022, px));
        o = spOver(o, twig, spLine(p, float2(-0.27, 0.1 + wave * 0.8), float2(-0.33, 0.2 + wave), 0.016, px));
        o = spOver(o, twig, spLine(p, float2(0.1, 0.0), float2(0.33, 0.12 - wave), 0.022, px));
        o = spOver(o, twig, spLine(p, float2(0.27, 0.09 - wave * 0.8), float2(0.36, 0.17 - wave), 0.016, px));
    }
    float2 centers[3] = { float2(0.0, -0.3), float2(0.0, -0.03), float2(0.0, 0.17) };
    float radii[3] = { 0.18 * bottom, 0.13 * middle, 0.095 * head };
    for (int k = 0; k < 3; k++) {
        if (radii[k] <= 0.001) continue;
        float2 c = centers[k];
        if (k == 0) c.y = -0.5 + radii[0] * 1.1;
        float cover = spDisc(p, c, radii[k], px);
        float lit = saturate(dot((p - c) / radii[k], lightDir) * 0.5 + 0.55);
        float lumps = (spFbm((p - c) * 14.0 + seed * 9.0) - 0.5) * 0.18;
        o = spOver(o, lerp(shade, snow, saturate(lit + lumps)), cover);
    }
    if (middle > 0.95) {
        // Coal buttons.
        for (int k = 0; k < 3; k++) {
            o = spOver(o, coal, spDisc(p, float2(look * 0.01, 0.05 - float(k) * 0.05), 0.012, px));
        }
        // A knitted scarf, its colour from the seed, with a tail hanging down.
        float3 wool = seed < 0.33 ? float3(0.78, 0.18, 0.16) : (seed < 0.66 ? float3(0.2, 0.45, 0.3) : float3(0.25, 0.35, 0.65));
        wool = lerp(wool, wool * 0.7, step(0.5, frac((p.x + p.y) * 30.0))) * light;
        float band = spEllipse(p, float2(0.0, 0.085), float2(0.11, 0.025), px);
        float tail = spLine(p, float2(0.05, 0.08), float2(0.08 + sin(time * 1.7) * 0.01, -0.03), 0.04, px);
        o = spOver(o, wool, max(band * head, tail * head));
    }
    if (head > 0.95) {
        float2 eyes = float2(look * 0.025, 0.0);
        o = spOver(o, coal, spDisc(p, float2(-0.033, 0.195) + eyes, 0.012, px));
        o = spOver(o, coal, spDisc(p, float2(0.033, 0.195) + eyes, 0.012, px));
        // A carrot nose pointing where he looks.
        float side = look >= 0.0 ? 1.0 : -1.0;
        float reach = 0.04 + 0.04 * abs(look);
        float2 tip = float2(look * 0.02 + side * reach + 0.005, 0.165);
        float2 root = float2(look * 0.02, 0.17);
        float along = saturate(dot(p - root, tip - root) / max(dot(tip - root, tip - root), 1e-5));
        float carrot = spLine(p, root, tip, 0.026 * (1.0 - along * 0.75), px);
        o = spOver(o, float3(0.95, 0.5, 0.15) * light, carrot);
        for (int k = 0; k < 5; k++) {
            float x = (float(k) - 2.0) * 0.022 + look * 0.02;
            o = spOver(o, coal, spDisc(p, float2(x, 0.135 - 0.012 * (1.0 - abs(float(k) - 2.0) * 0.5)), 0.007, px));
        }
        // Some wear a hat.
        if (seed > 0.5) {
            float3 felt = float3(0.12, 0.11, 0.13) * light;
            float brim = spEllipse(p, float2(0.0, 0.255), float2(0.085, 0.014), px);
            float crown = spLine(p, float2(0.0, 0.26), float2(0.0, 0.33), 0.11, px);
            o = spOver(o, felt, max(brim, crown));
            o = spOver(o, float3(0.7, 0.15, 0.15) * light, spLine(p, float2(-0.05, 0.275), float2(0.05, 0.275), 0.014, px) * crown);
        }
    }
    return o;
}

// A cat peeking out of the drift: `rise` 0 under the snow to 1 its head and paws out. It looks left and right.
FN float4 spCat(float2 p, float rise, float seed, float look, float blink, float px, float3 light) {
    float4 o = float4(0.0, 0.0, 0.0, 0.0);
    float ground = -0.5 + 6.0 / 44.0;
    float3 fur = seed < 0.3 ? float3(0.86, 0.5, 0.24) : (seed < 0.55 ? float3(0.42, 0.42, 0.46) : (seed < 0.8 ? float3(0.13, 0.12, 0.14) : float3(0.93, 0.9, 0.86)));
    float3 dark = fur * 0.65;
    float2 c = float2(look * 0.04, ground + 0.13 - (1.0 - rise) * 0.42);
    float stripes = seed < 0.3 ? step(0.55, frac((p.y - c.y) * 22.0 + abs(p.x - c.x) * 6.0)) * 0.25 : 0.0;
    float3 coat = lerp(fur, dark, stripes) * light;
    // Ears, then the head.
    for (float side = -1.0; side <= 1.0; side += 2.0) {
        float2 base = c + float2(side * 0.13, 0.12);
        float2 tip = c + float2(side * 0.19, 0.29);
        float ear = spLine(p, base, tip, 0.13 * saturate(1.0 - length(p - base) / 0.22), px);
        o = spOver(o, coat, ear);
        o = spOver(o, float3(0.92, 0.6, 0.62) * light, spLine(p, base + float2(-side * 0.01, 0.02), tip - float2(side * 0.015, 0.04), 0.05 * saturate(1.0 - length(p - base) / 0.2), px) * 0.8);
    }
    o = spOver(o, coat, spEllipse(p, c, float2(0.22, 0.18), px));
    // Eyes: amber or green, slit pupils glancing where it looks, shut now and then for a blink.
    float shut = step(frac(blink * 0.23 + seed * 3.0), 0.035);
    float3 iris = seed > 0.5 ? float3(0.55, 0.78, 0.3) : float3(0.95, 0.68, 0.2);
    for (float side = -1.0; side <= 1.0; side += 2.0) {
        float2 e = c + float2(side * 0.085, 0.03);
        if (shut > 0.5) {
            o = spOver(o, float3(0.1, 0.08, 0.08), spLine(p, e - float2(0.035, 0.0), e + float2(0.035, 0.0), 0.012, px));
        } else {
            o = spOver(o, iris * light, spEllipse(p, e, float2(0.042, 0.038), px));
            o = spOver(o, float3(0.05, 0.04, 0.04), spEllipse(p, e + float2(look * 0.018, 0.0), float2(0.011, 0.032), px));
            o = spOver(o, float3(1.0, 1.0, 1.0), spDisc(p, e + float2(-0.012, 0.014), 0.008, px) * 0.8);
        }
    }
    // Nose, mouth, whiskers.
    float2 nose = c + float2(look * 0.015, -0.04);
    o = spOver(o, float3(0.85, 0.45, 0.5) * light, spEllipse(p, nose, float2(0.022, 0.014), px));
    o = spOver(o, float3(0.2, 0.15, 0.15), spLine(p, nose, nose + float2(-0.02, -0.03), 0.008, px));
    o = spOver(o, float3(0.2, 0.15, 0.15), spLine(p, nose, nose + float2(0.02, -0.03), 0.008, px));
    for (float side = -1.0; side <= 1.0; side += 2.0) {
        for (int k = 0; k < 2; k++) {
            float2 from = nose + float2(side * 0.05, -0.015 - float(k) * 0.015);
            o = spOver(o, float3(0.95, 0.95, 0.95) * light, spLine(p, from, from + float2(side * 0.14, 0.02 - float(k) * 0.04), 0.005, px) * 0.8);
        }
    }
    // Paws on the snow once it is all the way up.
    if (rise > 0.8) {
        float paws = saturate((rise - 0.8) / 0.2);
        o = spOver(o, coat, spEllipse(p, float2(c.x - 0.1, ground + 0.02), float2(0.06, 0.035), px) * paws);
        o = spOver(o, coat, spEllipse(p, float2(c.x + 0.1, ground + 0.02), float2(0.06, 0.035), px) * paws);
    }
    // The drift hides whatever is below its surface, its edge ragged with snow.
    float surface = ground + 0.015 * sin(p.x * 40.0 + seed * 10.0);
    float hidden = saturate((surface - p.y) * px + 0.5);
    o *= 1.0 - hidden;
    float rim = spLine(p, float2(c.x - 0.3, surface), float2(c.x + 0.3, surface), 0.035, px) * saturate(rise * 3.0);
    o = spOver(o, float3(0.97, 0.96, 0.94) * light, rim);
    return o;
}

// A bullfinch: perched (flying 0) on a window's edge, pecking and hopping, or flying (1) with its wings beating.
FN float4 spBird(float2 p, float flying, float facing, float wing, float peck, float px, float3 light) {
    float4 o = float4(0.0, 0.0, 0.0, 0.0);
    p.x *= facing;
    float3 grey = float3(0.47, 0.49, 0.55) * light;
    float3 black = float3(0.08, 0.08, 0.1);
    float3 rose = float3(0.93, 0.36, 0.28) * light;
    float bob = flying > 0.5 ? sin(wing) * 0.02 : 0.0;
    float2 body = float2(0.0, -0.15 + bob);
    // Tail, then legs.
    o = spOver(o, black, spLine(p, body + float2(-0.15, 0.02), body + float2(-0.36, 0.08 - flying * 0.05), 0.08, px));
    if (flying < 0.5) {
        o = spOver(o, float3(0.3, 0.25, 0.22), spLine(p, body + float2(-0.03, -0.12), body + float2(-0.04, -0.32), 0.02, px));
        o = spOver(o, float3(0.3, 0.25, 0.22), spLine(p, body + float2(0.05, -0.12), body + float2(0.06, -0.32), 0.02, px));
    }
    // A round body: grey back, rose-red breast.
    float round = spEllipse(p, body, float2(0.21, 0.165), px);
    float breast = saturate((p.x - body.x + 0.02 - (p.y - body.y) * 0.4) * px * 0.2 + 0.5) * saturate((body.y + 0.05 - p.y) * px * 0.1 + 0.5);
    o = spOver(o, lerp(grey, rose, saturate(breast * 1.4)), round);
    // The head dips forward to peck.
    float2 head = body + float2(0.15 + peck * 0.05, 0.13 - peck * 0.1);
    o = spOver(o, rose, spDisc(p, head, 0.115, px));
    o = spOver(o, black, spDisc(p, head + float2(-0.01, 0.035), 0.1, px) * saturate((p.y - head.y + 0.005) * px * 0.15 + 0.5));
    o = spOver(o, black, spLine(p, head + float2(0.09, -0.01), head + float2(0.17, -0.03), 0.06, px));
    o = spOver(o, float3(1.0, 1.0, 1.0), spDisc(p, head + float2(0.045, 0.015), 0.012, px) * 0.85);
    // A wing: folded on its side while perched, beating while it flies.
    float beat = flying * sin(wing);
    float2 shoulder = body + float2(-0.02, 0.06);
    float2 tip = shoulder + float2(-0.2, beat * 0.28 - (1.0 - flying) * 0.06);
    o = spOver(o, black, spLine(p, shoulder, tip, 0.13 - 0.05 * flying, px));
    o = spOver(o, float3(0.9, 0.9, 0.92) * light, spLine(p, shoulder + (tip - shoulder) * 0.35, shoulder + (tip - shoulder) * 0.75, 0.025, px) * 0.9);
    return o;
}

// A piece of the garland's cord: a twisted dark green cord along `segment` (in box units), `radius` thick.
FN float4 spWire(float2 p, float2 segment, float radius, float3 light, float px) {
    float2 h = segment * 0.5;
    float span = max(dot(h, h), 1e-6);
    float t = clamp(dot(p, h) / span, -1.0, 1.0);
    float d = length(p - h * t);
    float cover = saturate((radius - d) * px + 0.5);
    float twist = 0.5 + 0.5 * sin((t * length(segment) * px * 0.9) + d / max(radius, 1e-4) * 3.0);
    float3 c = lerp(float3(0.05, 0.11, 0.07), float3(0.2, 0.36, 0.22), twist * 0.6 + 0.2) * lerp(float3(1.0, 1.0, 1.0), light, 0.6);
    return float4(c * cover, cover);
}

// A glass bulb of a fairy light hanging from its socket, `on` 0 dark to 1 lit, tilted by `angle`, with its glow
// spilling around it. `color` is the glass. `px` is pixels per box unit.
FN float4 spBulb(float2 p, float3 color, float on, float angle, float px, float3 light) {
    float bulb = 1.0 / 3.4;
    float c = cos(angle), s = sin(angle);
    float2 q = float2(c * p.x + s * p.y, -s * p.x + c * p.y) / bulb;
    float upx = px * bulb;
    float4 o = float4(0.0, 0.0, 0.0, 0.0);
    // The light it throws around itself, under everything else.
    float r = length(p - float2(-s, -c) * bulb * 0.1);
    float halo = exp(-r * r * 26.0) * on * 0.55 + exp(-r * r * 110.0) * on * 0.35;
    o = float4(color * halo, halo * 0.75);
    // The glass: a rounded drop, its tip pointing down.
    float2 g = q - float2(0.0, -0.1);
    float taper = 1.0 - 0.28 * saturate(-g.y / 0.4);
    float glass = spEllipse(float2(g.x / taper, g.y), float2(0.0, 0.0), float2(0.25, 0.4), upx);
    float core = exp(-dot(g * float2(1.6, 1.0), g * float2(1.6, 1.0)) * 9.0);
    float3 lit = lerp(color * (0.28 + 0.1 * light), lerp(color, float3(1.0, 0.97, 0.9), core * 0.65), on);
    float rim = smoothstep(0.12, 0.28, abs(g.x / taper)) * 0.35;
    lit = lit * (1.0 - rim * (1.0 - on * 0.5));
    o = spOver(o, lit, glass * (0.82 + 0.18 * on));
    // A glint on the glass.
    o = spOver(o, float3(1.0, 1.0, 1.0), spEllipse(q, float2(-0.09, 0.04), float2(0.045, 0.11), upx) * 0.75);
    // The socket it hangs from, with its ridges.
    float socket = saturate((0.17 - abs(q.x)) * upx + 0.5) * saturate((q.y - 0.24) * upx + 0.5) * saturate((0.52 - q.y) * upx + 0.5);
    float ridges = 0.5 + 0.5 * step(0.5, frac(q.y * 14.0));
    float3 green = lerp(float3(0.06, 0.15, 0.09), float3(0.16, 0.32, 0.2), ridges) * lerp(float3(1.0, 1.0, 1.0), light, 0.6);
    o = spOver(o, green, socket);
    return o;
}

// One feathered frond in its own frame: `t` along its stem from the root, `d` across it. Barbs leave the stem at an
// angle toward its tip, of uneven lengths, longest near the root, and fine needles leave each barb the same way.
// Gives back how much ice covers the point (x) and a soft icy glow around the lines (y).
FN float2 spFrond(float t, float d, float length_, float grown, float seed, float px) {
    float reachOut = length_ * grown;
    if (t < -6.0 || t > reachOut + 6.0) return float2(0.0, 0.0);
    float reach = saturate(1.0 - t / max(length_, 1.0));
    float a = abs(d);
    // The stem, thinning toward its tip and ending where it has grown to.
    float stemWidth = 0.5 + 0.9 * reach;
    float inStem = step(0.0, t) * step(t, reachOut);
    float stemDist = a + (1.0 - inStem) * 100.0;
    // Barbs, swept toward the tip, every few points on both sides, uneven in length.
    float spacing = 6.0 + 3.5 * seed;
    float cotangent = 0.95;
    float k = floor((t - a * cotangent) / spacing + 0.5);
    float from = k * spacing;
    float along = (t - from) - a * cotangent;
    float jitter = spHash(float2(k, seed * 31.0 + sign(d)));
    float barbLength = length_ * 0.36 * saturate(1.0 - from / max(reachOut, 1.0)) * (0.45 + 0.55 * jitter);
    float out_ = a * 1.38;
    float inBarb = step(out_, barbLength) * step(0.0, from) * step(from, reachOut);
    float barbDist = abs(along) * 0.69 + (1.0 - inBarb) * 100.0;
    float barbWidth = 0.35 + 0.55 * saturate(1.0 - out_ / max(barbLength, 0.1));
    // Fine needles off each barb, short and faint.
    float va = abs(along);
    float nk = floor((out_ - va * cotangent) / 3.0 + 0.5);
    float nAlong = (out_ - nk * 3.0) - va * cotangent;
    float needleLength = barbLength * 0.22 * saturate(1.0 - out_ / max(barbLength, 0.1));
    float inNeedle = step(va * 1.38, needleLength) * inBarb;
    float needleDist = abs(nAlong) * 0.69 + (1.0 - inNeedle) * 100.0;
    float ice = max(saturate((stemWidth * 0.5 - stemDist) * px + 0.5),
                max(saturate((barbWidth * 0.5 - barbDist) * px + 0.5), saturate((0.22 - needleDist) * px + 0.5) * 0.55));
    float nearest = min(stemDist, min(barbDist, needleDist + 0.6));
    float glow = exp(-nearest * nearest * 0.18) * (0.5 + 0.5 * reach);
    return float2(ice, glow);
}

// Frost or mist on the glass at a point of the screen, `value` 0 clear to 1 thick. `view` is the screen's size.
FN float4 spFrost(float2 world, float value, float mist, float time, float3 light, float2 view) {
    if (value < 0.003) return float4(0.0, 0.0, 0.0, 0.0);
    if (mist > 0.5) {
        // Mist: a soft grey film with beads gathered in it.
        float film = value * (0.42 + 0.12 * spFbm(world * 0.02));
        float2 cell = floor(world / 7.0);
        float2 inside = frac(world / 7.0) - 0.5;
        float bead = spHash(cell) > 0.82 ? saturate(1.0 - length(inside) / (0.18 + 0.2 * spHash(cell + 3.1))) : 0.0;
        bead *= saturate(value * 1.6 - 0.3);
        float a = saturate(film + bead * 0.35);
        float3 c = lerp(float3(0.86, 0.88, 0.9), float3(0.55, 0.58, 0.62), bead) * lerp(float3(1.0, 1.0, 1.0), light, 0.6);
        return float4(c * a, a);
    }
    // Frost: feathered fronds growing in from the edges, each from a root in a cell of the glass, turned inward with
    // a wander and a curve of its own. Where the frost is thin only their roots show; as it thickens they reach in.
    float size = 52.0;
    float2 cellOf = floor(world / size);
    float ice = 0.0;
    float glow = 0.0;
    float sparkle = 0.0;
    float px = 1.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float2 cell = cellOf + float2(float(i), float(j));
            float seed = spHash(cell + 17.3);
            if (seed < 0.14) continue;
            float2 root = (cell + float2(spHash(cell + 3.7), spHash(cell + 9.1))) * size;
            // Inward: away from the nearest edge and a little toward the middle, wandering.
            float2 toMiddle = normalize(view * 0.5 - root + float2(0.001, 0.0));
            float2 edge = root.x < view.x - root.x ? float2(1.0, 0.0) : float2(-1.0, 0.0);
            if (min(root.y, view.y - root.y) < min(root.x, view.x - root.x)) edge = root.y < view.y - root.y ? float2(0.0, 1.0) : float2(0.0, -1.0);
            float wander = (spHash(cell + 5.5) - 0.5) * 2.0;
            float2 base = normalize(lerp(edge, toMiddle, 0.3));
            float c = cos(wander), s = sin(wander);
            float2 dir = float2(base.x * c - base.y * s, base.x * s + base.y * c);
            float2 rel = world - root;
            float t = dot(rel, dir);
            float d = dot(rel, float2(-dir.y, dir.x));
            // Each frond bends its own way.
            d -= (spHash(cell + 2.2) - 0.5) * 0.022 * t * t / (1.0 + t * 0.01);
            float length_ = 45.0 + 100.0 * spHash(cell + 1.3) * spHash(cell + 7.7) + 30.0 * seed;
            float grown = saturate(value * 1.3 + (seed - 0.6) * 0.25);
            float2 frond = spFrond(t, d, length_, grown, seed, px);
            ice = max(ice, frond.x * (0.6 + 0.4 * saturate(1.0 - t / length_)));
            glow = max(glow, frond.y);
            sparkle = max(sparkle, frond.x * step(0.982, spHash(floor(world * 0.6) + seed)));
        }
    }
    // A faint hoar between the fronds where the frost is thickest, in the corners.
    float hoar = saturate(value * 1.5 - 0.7) * (0.2 + 0.3 * spFbm(world * 0.07));
    float a = saturate(ice * 0.68 + glow * 0.16 + hoar * 0.35) * smoothstep(0.0, 0.25, value);
    float glint = sparkle * pow(saturate(sin(time * 1.7 + spHash(floor(world * 0.6)) * 40.0)), 8.0);
    float3 c = lerp(float3(0.78, 0.87, 0.98), float3(1.0, 1.0, 1.0), ice) * lerp(float3(1.0, 1.0, 1.0), light, 0.45);
    return float4(c * a + glint * 0.9, saturate(a + glint * 0.9));
}
