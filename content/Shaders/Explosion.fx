// Procedural ship-explosion fireball (2026-11-18 shader pass round 2, Rendering/Vfx/ShipExplosionFx.cs).
//
// Replaces the Ships/Accessories/Explosion flipbook. Pixel-shader only: SpriteBatch's own vertex
// shader positions the quad, so this drops into any SpriteBatch.Begin. The batch texture is
// TilingNoise drawn with LinearWrap; the quad's UV runs 0..1 across the fireball.
//
// Per-explosion data rides in the vertex colour so one batch draws every fireball:
//   R = age 0..1, G = seed 0..1, B = style (0 ship death, 1 hull hit: faster, no smoke), A = alpha.
//
// The look, by age: a white flash at the centre for the first ~12%; a ball that expands on an
// ease-out curve, its edge pushed around by two noise reads through a warped position so it
// billows instead of growing as a disc; a temperature that falls with age and toward the edge,
// mapped white -> yellow -> orange -> deep red; the fire dissolving from its cool edge inward; and
// a lumpy grey smoke cloud that thickens as the fire dies (death style only).
// Four texture reads per pixel.
//
// Designed against an offline numpy port over the battle backdrop
// (AI_Game/__tmp/shaderpass/explosion/port.py). Output is premultiplied for BlendState.AlphaBlend:
// fire is mostly additive (low alpha), smoke darkens. Tuning constants are marked TUNE.

#if OPENGL
    #define SV_POSITION POSITION
    #define VS_SHADERMODEL vs_3_0
    #define PS_SHADERMODEL ps_3_0
#else
    #define VS_SHADERMODEL vs_4_0_level_9_3
    #define PS_SHADERMODEL ps_4_0_level_9_3
#endif

Texture2D SpriteTexture;
sampler2D NoiseSampler = sampler_state
{
    Texture = <SpriteTexture>;
};

struct PSInput
{
    float4 Position : SV_POSITION;
    float4 Color    : COLOR0;
    float2 TexCoord : TEXCOORD0;
};

static const float Grow0 = 0.30;      // TUNE: ball radius at birth (quad half-sizes)
static const float Grow1 = 0.95;      // TUNE: ball radius at the end
static const float Warp = 0.18;       // TUNE: how far the noise pushes the ball's outline
static const float Turb = 0.75;       // TUNE: noise weight in the density
static const float Dissolve = 0.95;   // TUNE: how fast the fire burns away from the edge
static const float SmokeAmount = 0.9; // TUNE: alpha of the thickest smoke
static const float FlashLife = 0.12;  // TUNE: share of the life the white core flash lasts
static const float FireAlpha = 0.2;   // TUNE: how much the fire occludes (rest is additive glow)

static const float3 Red = float3(0.55, 0.08, 0.02);
static const float3 Orange = float3(1.0, 0.42, 0.08);
static const float3 Yellow = float3(1.0, 0.80, 0.32);
static const float3 White = float3(1.0, 0.97, 0.88);
static const float3 SmokeRgb = float3(0.24, 0.22, 0.22);

float3 Ramp(float h)
{
    float3 lo = lerp(Red, Orange, saturate(h / 0.35));
    float3 mid = lerp(Orange, Yellow, saturate((h - 0.35) / 0.35));
    float3 hi = lerp(Yellow, White, saturate((h - 0.7) / 0.3));
    return h < 0.35 ? lo : (h < 0.7 ? mid : hi);
}

float4 FireballPS(PSInput input) : COLOR0
{
    float2 uv = input.TexCoord;
    float age = input.Color.r;
    float seed = input.Color.g;
    float hit = step(0.5, input.Color.b);
    float alpha = input.Color.a;

    float2 p = (uv - 0.5) * 2.0;
    float d = length(p);
    float2 so = float2(seed * 7.31, seed * 3.17);

    float inv = 1.0 - age;
    float grow = 1.0 - inv * inv * inv;
    float radius = lerp(Grow0, Grow1, grow);

    float2 w = tex2D(NoiseSampler, uv * 0.22 + so + float2(0.0, age * 0.05)).rg;
    float2 pw = p + (w - 0.5) * (Warp * 2.0);
    float n1 = tex2D(NoiseSampler, pw * 0.20 + so.yx - float2(0.0, age * 0.06)).b;
    float n2 = tex2D(NoiseSampler, pw * 0.5 + so * float2(1.7, 1.3)).r;
    float n = n1 * 0.65 + n2 * 0.35;

    float dw = length(pw) / radius;
    float body = 1.0 - dw + (n - 0.5) * Turb;
    float th = age * Dissolve;
    float fire = smoothstep(th - 0.05, th + 0.25, body);
    float heat = saturate(body * 1.25 - age * 1.2);
    float emit = fire * smoothstep(0.0, 0.3, heat) * pow(max(inv, 0.0001), 0.8);

    float sb = 1.0 - dw * 1.15 + (n - 0.5) * 1.6;
    float smoke = smoothstep(0.0, 0.4, sb) * smoothstep(0.12, 0.45, age) * pow(max(inv, 0.0001), 1.2) * SmokeAmount * (1.0 - hit);

    float flash = saturate(1.0 - age / FlashLife) * exp(-d * d * 10.0);
    float edge = 1.0 - smoothstep(0.82, 1.0, d);

    float e = min(emit * 1.25 + flash, 1.5) * edge;
    float sA = smoke * edge * (1.0 - saturate(e));
    float3 rgb = Ramp(heat) * e + flash * edge * 0.6 + SmokeRgb * sA;
    float a = saturate(sA + saturate(e) * FireAlpha);
    return float4(rgb, a) * alpha;
}

technique Fireball
{
    pass P0
    {
        PixelShader = compile PS_SHADERMODEL FireballPS();
    }
}

// ── Ground-battle shots (2026-11-18 shader pass round 3, Rendering/Vfx/GroundShotFx.cs) ──────────
// Appended techniques; Fireball above is unchanged. Same pixel-shader-only contract: the quad's UV
// runs 0..1, per-quad data rides in the vertex colour, output is premultiplied for AlphaBlend.

static const float MuzzleOrigin = 0.2;   // TUNE: share of the quad behind the muzzle (back-glow)
static const float MuzzleCore = 38.0;    // TUNE: tightness of the white core
static const float MuzzleCone = 0.55;    // TUNE: how wide the forward plume opens

// Muzzle flash. Quad x runs along the barrel (muzzle at MuzzleOrigin), y across it.
// R = age 0..1, G = seed, B = kind (0 rifle, 1 heavy gun: wider plume + side blast), A = alpha.
float4 MuzzlePS(PSInput input) : COLOR0
{
    float age = input.Color.r;
    float seed = input.Color.g;
    float heavy = step(0.5, input.Color.b);
    float alpha = input.Color.a;
    float x = (input.TexCoord.x - MuzzleOrigin) / (1.0 - MuzzleOrigin);
    float y = (input.TexCoord.y - 0.5) * 2.0;

    float inv = 1.0 - age;
    float reach = lerp(0.55, 1.0, smoothstep(0.0, 0.35, age));
    float xs = x / reach;

    float core = exp(-(x * x * MuzzleCore + y * y * MuzzleCore * 0.8));
    float w = 0.10 + MuzzleCone * (0.75 + 0.45 * heavy) * saturate(xs);
    float plume = exp(-(y / w) * (y / w) * 2.0) * pow(saturate(1.0 - xs), 1.4) * step(0.0, x);
    float n = tex2D(NoiseSampler, float2(xs * 0.9 + seed, y * 0.35 + seed * 3.1)).r;
    float n2 = tex2D(NoiseSampler, float2(xs * 2.3 - seed * 1.7, y * 0.9 + 0.37)).g;
    plume *= 0.45 + 1.1 * n * (0.7 + 0.6 * n2);
    // Muzzle-brake side blast on heavy guns: two short lobes either side of the barrel.
    float side = heavy * exp(-x * x * 70.0) * exp(-abs(y) * 2.2) * smoothstep(0.05, 0.35, abs(y)) * 0.55;

    float e = (core * 1.6 + plume + side) * inv * inv;
    float edge = (1.0 - smoothstep(0.85, 1.0, abs(y))) * (1.0 - smoothstep(0.92, 1.0, input.TexCoord.x));
    e *= edge;
    float3 rgb = Ramp(saturate(e * 0.9 + core * 0.4)) * e;
    return float4(rgb, saturate(e) * 0.12) * alpha;
}

static const float TracerCoreW = 0.16;   // TUNE: bright core, share of the quad's half-width
static const float TracerGlowW = 0.62;   // TUNE: soft glow, share of the quad's half-width
static const float TracerHead = 0.90;    // TUNE: where along the quad the hot head sits

// Tracer / shell streak. Quad x runs tail (0) -> head (1), y across. Vertex RGB = tint, A = intensity.
// Purely additive (alpha out = 0).
float4 TracerPS(PSInput input) : COLOR0
{
    float u = input.TexCoord.x;
    float y = (input.TexCoord.y - 0.5) * 2.0;
    float core = exp(-(y / TracerCoreW) * (y / TracerCoreW));
    float glow = exp(-(y / TracerGlowW) * (y / TracerGlowW) * 2.0) * 0.4;
    float along = pow(saturate(u / TracerHead), 1.7);
    float hd = (u - TracerHead) / 0.07;
    float head = exp(-hd * hd);
    float tip = 1.0 - smoothstep(TracerHead, 1.0, u);
    float body = (core + glow) * along * tip;
    float hot = head * (core * 1.4 + glow * 1.6);
    float3 tint = input.Color.rgb;
    float3 rgb = tint * body + lerp(tint, float3(1.0, 0.98, 0.92), 0.65) * hot;
    return float4(rgb * 1.25, 0.0) * input.Color.a;
}

technique Muzzle
{
    pass P0
    {
        PixelShader = compile PS_SHADERMODEL MuzzlePS();
    }
}

technique Tracer
{
    pass P0
    {
        PixelShader = compile PS_SHADERMODEL TracerPS();
    }
}

// ── Galaxy-map fleet implosion (2026-11-18 round 4, Rendering/Vfx/FleetImplosionFx.cs) ───────────
// Appended technique; the ones above are unchanged. Same contract: pixel shader only, quad UV 0..1,
// R = age 0..1, G = seed, A = alpha; premultiplied for AlphaBlend, almost purely additive.
// Beats by age: a ring of cold light contracts from ImpRingStart to the centre while radial streaks
// are pulled in behind it and the core heats up (0..ImpCollapse); a brief white collapse flash; then
// a crisp shock ring races out to ImpShockEnd and fades, over a dim ember afterglow.
// Three texture reads. Designed against AI_Game/__tmp/shaderpass/implosion/port.py.

static const float ImpCollapse = 0.34;   // TUNE: share of the life spent contracting
static const float ImpRingStart = 0.62;  // TUNE: contracting ring's start radius (quad half-sizes)
static const float ImpShockEnd = 0.95;   // TUNE: shock ring's end radius
static const float3 ImpIce = float3(0.70, 0.84, 1.0);
static const float3 ImpHot = float3(1.0, 0.97, 0.90);
static const float3 ImpEmber = float3(1.0, 0.50, 0.18);

float4 ImplosionPS(PSInput input) : COLOR0
{
    float age = input.Color.r;
    float seed = input.Color.g;
    float alpha = input.Color.a;
    float2 p = (input.TexCoord - 0.5) * 2.0;
    float d = length(p) + 1e-5;
    float ang = atan2(p.y, p.x) * 0.15915494 + 0.5;

    // Contraction.
    float pre = 1.0 - step(ImpCollapse, age);
    float t = saturate(age / ImpCollapse);
    float r = lerp(ImpRingStart, 0.015, t * t);
    float wr = 0.025 + 0.045 * (1.0 - t);
    float rr = (d - r) / wr;
    float ring = exp(-rr * rr) * (0.35 + 0.9 * t) * pre;
    float s1 = tex2D(NoiseSampler, float2(ang * 11.0 + seed, d * 0.22 + t * 0.35)).r;
    float s2 = tex2D(NoiseSampler, float2(ang * 23.0 - seed * 1.3, d * 0.15 + t * 0.25 + 0.37)).g;
    float streak = smoothstep(0.58, 0.80, s1 * 0.55 + s2 * 0.55);
    float band = smoothstep(r, r + 0.06, d) * (1.0 - smoothstep(r + 0.12, ImpRingStart * 1.35, d));
    float streaks = streak * band * (0.25 + 0.9 * t) * pre;
    float core = exp(-d * d / (0.004 + 0.03 * (1.0 - t))) * t * t * 1.4 * pre;

    // Collapse flash.
    float k = (age - ImpCollapse) / 0.045;
    float flash = exp(-k * k) * exp(-d * d * 22.0) * 1.6;

    // Shockwave and afterglow.
    float post = step(ImpCollapse, age);
    float u = saturate((age - ImpCollapse) / (1.0 - ImpCollapse));
    float iu = 1.0 - u;
    float sr = lerp(0.02, ImpShockEnd, 1.0 - iu * iu * iu);
    float sw = 0.022 + 0.06 * u;
    float sn = tex2D(NoiseSampler, float2(ang * 4.0 + seed * 2.1, 0.5 + u * 0.3)).b;
    float sk = (d - sr) / sw;
    float shock = exp(-sk * sk) * pow(iu, 1.6) * (0.85 + 0.3 * sn) * post;
    float glow = exp(-d * d * 14.0) * pow(iu, 2.2) * 0.55 * post;

    float edge = 1.0 - smoothstep(0.9, 1.0, d);
    float iceE = (ring + streaks * 0.8 + shock * 1.1) * edge;
    float hotE = (core + flash) * edge;
    float3 rgb = ImpIce * iceE + ImpHot * (hotE + shock * edge * 0.35) + ImpEmber * glow * edge;
    float a = saturate((iceE + hotE + glow) * 0.08);
    return float4(rgb, a) * alpha;
}

technique Implosion
{
    pass P0
    {
        PixelShader = compile PS_SHADERMODEL ImplosionPS();
    }
}
