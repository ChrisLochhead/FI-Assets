// Nebula gas, faint haze and space dust for NebulaLayer (2026-11-18 shader pass): the galaxy map
// and the space battle backdrop.
//
// One screen quad per technique. TexCoord is the LAYER coordinate (layer units, one unit = one
// screen pixel at zoom 1), computed per corner on the CPU so depth parallax and zoom are just
// what the four corners say. NoiseMap is Shaders/TilingNoise (R, G, B = three fractal fields,
// each ~N(0.5, 0.2)), the same texture the ground clouds use.
//
// Nebula (5 reads): a very low-frequency read gives the haze and picks between the two tints;
// a low-frequency read warps the coordinates; two reads of the warped coordinate give the gas
// body and frayed detail; one read toward the sun shades the far side. Designed against an
// offline numpy port over the real backdrops (AI_Game/__tmp/shaderpass/nebula/port.py).
//
// Dust (3 reads): motes on a jittered grid. Each grid cell reads one random triple from the
// noise (offset, size, keep) and draws a round, screen-pixel-sized dot; a coarse read thins
// and thickens the motes so they gather in drifts. Two grids at different sizes.
//
// Wisps (4 reads): a sparse smattering of small soft nebula puffs on a coarse jittered grid (the
// main menu's replacement for its floating nebula sprites, 2026-11-19). Each kept cell holds one
// stretched, rotated blob whose edge is frayed by noise, tinted between the gas tints and slowly
// drifting and breathing. Blob size is kept well inside its cell so no puff is ever clipped.
//
// Output is premultiplied for BlendState.AlphaBlend; alpha is small, so both read as light.
// Tuning constants are marked TUNE.

#if OPENGL
    #define SV_POSITION POSITION
    #define VS_SHADERMODEL vs_3_0
    #define PS_SHADERMODEL ps_3_0
#else
    #define VS_SHADERMODEL vs_4_0_level_9_3
    #define PS_SHADERMODEL ps_4_0_level_9_3
#endif

float4x4 MatrixTransform;
float Time;            // seconds
float Opacity;         // master fade, 0..1

// Nebula
float NoisePerUnit;    // noise tiles per layer unit
float2 Wind;           // drift, noise units per second
float Warp;            // domain warp strength, noise units
float Detail;          // weight of the fraying field
float Cut;             // density threshold (higher = less gas)
float Body;            // brightness of the thickest gas
float Haze;            // brightness of the wide haze
float Occlusion;       // how much the gas dims what is behind it
float2 SunOffset;      // toward the light, noise units (zero = flat)
float3 TintA;
float3 TintB;
float3 TintRim;

// Dust
float DustCell;        // layer units per grid cell
float DustCellPixels;  // screen pixels per grid cell (DustCell x layer scale)
float DustKeep;        // share of cells with a mote: higher keeps fewer
float DustBrightness;
float3 DustTint;

// Wisps
float WispCell;        // layer units per wisp cell
float WispCellPixels;  // screen pixels per wisp cell (WispCell x layer scale)
float WispKeep;        // share of cells with a wisp: higher keeps fewer
float WispBrightness;
float WispRadius;      // largest puff radius, screen pixels (smallest is half); stays under ~1/7 of the cell

Texture2D NoiseMap;
sampler2D NoiseSampler = sampler_state
{
    Texture = <NoiseMap>;
    MinFilter = Linear;
    MagFilter = Linear;
    MipFilter = Linear;
    AddressU = Wrap;
    AddressV = Wrap;
};

struct VSInput
{
    float4 Position : POSITION0;
    float2 TexCoord : TEXCOORD0;
};

struct VSOutput
{
    float4 Position : SV_POSITION;
    float2 TexCoord : TEXCOORD0;
};

VSOutput MainVS(VSInput input)
{
    VSOutput o;
    o.Position = mul(input.Position, MatrixTransform);
    o.TexCoord = input.TexCoord;
    return o;
}

float4 NebulaPS(VSOutput input) : COLOR0
{
    float2 p = input.TexCoord * NoisePerUnit;
    // Keep drifts small so float precision holds however long the game runs.
    float2 drift = frac(Wind * Time);
    float2 driftWarp = frac(Wind * 0.6 * Time);
    float2 driftDetail = frac(Wind * 1.4 * Time);
    float2 driftHaze = frac(Wind * 0.013 * Time);

    float3 hz = tex2D(NoiseSampler, p * 0.35 + driftHaze).rgb;                      // TUNE: haze scale
    float2 w = tex2D(NoiseSampler, p * 0.33 + float2(0.31, 0.17) + driftWarp).rg;     // TUNE: warp scale
    float2 q = p + (w - 0.5) * Warp;

    float a = tex2D(NoiseSampler, q + drift).r;
    float b = tex2D(NoiseSampler, q * 2.3 + float2(0.37, 0.61) - driftDetail).g;    // TUNE: detail scale
    float d = a + Detail * (b - 0.5);
    float dens = smoothstep(Cut - 0.12, Cut + 0.30, d);                              // TUNE: soft ramp

    // Thicker toward the light means this pixel is on the gas's shaded side.
    float s = tex2D(NoiseSampler, q + SunOffset + drift).r;
    float shade = clamp(0.75 + (s - a) * 2.0, 0.35, 1.25);                           // TUNE

    float3 col = lerp(TintA, TintB, saturate((hz.b - 0.5) * 3.0 + 0.5));
    float rim = saturate(dens * (1.0 - dens) * 4.0);
    col = lerp(col, TintRim, rim * 0.6);                                             // TUNE: rim colour share

    float haze = smoothstep(0.35, 0.8, hz.b) * Haze;
    float inten = dens * Body * shade;
    return float4(col * (inten + haze), inten * Occlusion) * Opacity;
}

// One jittered grid of motes. g is in cells; returns brightness 0..1.
float Motes(float2 g, float cellPixels, float2 salt, float thin)
{
    float2 c = floor(g);
    float3 r = tex2D(NoiseSampler, frac(c * float2(0.1373, 0.2171) + salt)).rgb;
    float2 o = 0.15 + 0.7 * saturate((r.rg - 0.2) / 0.6);
    float dist = length(g - c - o) * cellPixels;                                     // screen pixels
    // 2026-11-18 round 2 (Chris: motes "too big, very obvious drawn circles"): pin-pricks about
    // one screen pixel across with a short soft falloff, instead of 1-4 px discs.
    float size = 0.25 + 0.45 * saturate((r.b - 0.3) / 0.5);                          // TUNE: radius px
    float mote = 1.0 - smoothstep(size - 0.25, size + 0.55, dist);
    float keep = smoothstep(DustKeep, DustKeep + 0.04, r.b + thin);
    float twinkle = 0.65 + 0.35 * sin(Time * (0.6 + 2.0 * r.r) + r.g * 40.0);
    return mote * keep * twinkle;
}

float4 DustPS(VSOutput input) : COLOR0
{
    float2 g = input.TexCoord / DustCell;
    float m = tex2D(NoiseSampler, g / 14.0).g;                                       // TUNE: drift size
    float thin = (m - 0.5) * 0.5;
    float a = Motes(g, DustCellPixels, float2(0.0, 0.0), thin);
    float b = Motes(g / 0.61 + float2(3.3, 7.1), DustCellPixels * 0.61, float2(0.43, 0.731), thin);
    float br = (a + b * 0.6) * DustBrightness;
    return float4(DustTint * br, 0.0) * Opacity;
}

float4 WispsPS(VSOutput input) : COLOR0
{
    float2 g = input.TexCoord / WispCell;
    float2 c = floor(g);
    float3 r = tex2D(NoiseSampler, frac(c * float2(0.0917, 0.1531) + float2(0.21, 0.63))).rgb;
    float3 r2 = tex2D(NoiseSampler, frac(c * float2(0.2113, 0.0711) + float2(0.57, 0.12))).rgb;
    float keep = smoothstep(WispKeep, WispKeep + 0.05, r2.g);
    // Centre in the middle 40 % of the cell, with a slow wander, so the puff never reaches the cell edge.
    float2 o = 0.3 + 0.4 * saturate((r.rg - 0.2) / 0.6);
    o += 0.05 * float2(sin(Time * 0.11 + r2.r * 30.0), cos(Time * 0.09 + r2.b * 30.0));
    float2 d = (g - c - o) * WispCellPixels;
    float ang = r2.b * 6.2831853;
    float cs = cos(ang), sn = sin(ang);
    float2 rd = float2(d.x * cs + d.y * sn, -d.x * sn + d.y * cs);
    rd.x *= 0.6;                                                                     // TUNE: stretch
    float radius = WispRadius * (0.5 + 0.5 * saturate((r.b - 0.2) / 0.6));
    float dist = length(rd) / max(radius, 0.001);
    float blob = 1.0 - smoothstep(0.0, 1.0, dist);
    blob *= blob;
    // Fray the edge so it reads as gas, not a disc.
    float n = tex2D(NoiseSampler, (g - c) * 1.7 + r2.rg + frac(Wind * 3.0 * Time)).r;
    blob *= saturate(0.45 + (n - 0.5) * 2.2 + (1.0 - dist) * 0.6);
    float pulse = 0.7 + 0.3 * sin(Time * (0.25 + 0.4 * r.r) + r.g * 20.0);
    float3 col = lerp(TintA, TintB, r.r);
    col = lerp(col, TintRim, saturate((r2.r - 0.55) * 2.5) * 0.7);
    float br = blob * keep * pulse * WispBrightness;
    return float4(col * br, br * 0.25) * Opacity;
}

technique Nebula
{
    pass P0
    {
        VertexShader = compile VS_SHADERMODEL MainVS();
        PixelShader = compile PS_SHADERMODEL NebulaPS();
    }
}

technique Dust
{
    pass P0
    {
        VertexShader = compile VS_SHADERMODEL MainVS();
        PixelShader = compile PS_SHADERMODEL DustPS();
    }
}

technique Wisps
{
    pass P0
    {
        VertexShader = compile VS_SHADERMODEL MainVS();
        PixelShader = compile PS_SHADERMODEL WispsPS();
    }
}
