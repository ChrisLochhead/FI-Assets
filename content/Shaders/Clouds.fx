// Drifting clouds and their ground shadows for GroundCloudLayer (Ground Overhaul plan, 1.3).
//
// One quad, one pass. TilingNoise.png is already a cloudy fractal (R, G, B are three
// independent fields, each ~N(0.5, 0.2)), so cloud density is just two reads of it: the base
// field for the cloud bodies plus a finer, faster field that frays their edges. The density
// is cut off at a level chosen so that Coverage is the share of sky under cloud, then turned
// into alpha in two soft layers that blend into one falloff: a dense body and a wide, faint
// fringe that gives the wispy edge. Because the two fields slide at different speeds, clouds
// form, drift and dissolve instead of just sliding.
// The same density read a little toward the sun (SunOffset) shades the far side of each cloud;
// read further toward the sun (ShadowOffset) it gives the shadow this pixel's ground receives.
// Six texture reads per pixel.
//
// 2026-11-16 (second pass): the first rework stacked four octaves, curved the density toward
// thin and lit edges from a density derivative. That drew frost/lichen patches with contour
// lines (8-bit noise steps amplified by the derivative). Designed against an offline numpy
// render of this shader with the real noise texture (AI_Game/__tmp/clouds).
//
// Output is premultiplied for BlendState.AlphaBlend: white-ish cloud over a black shadow.
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
float Time;           // seconds
float Coverage;       // share of sky that is cloud, 0..1
float Opacity;        // alpha of the thickest cloud
float ShadowOpacity;  // ground darkening under the thickest cloud
float2 Scale;         // noise tiles across the quad (x, y)
float2 Wind;          // drift in noise units per second
float2 SunOffset;     // toward the sun, noise units: shading read
float2 ShadowOffset;  // toward the sun, noise units: shadow read

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

static const float Detail = 0.45;        // TUNE: weight of the edge-fraying field
static const float DetailScale = 2.3;    // TUNE: it is this many times finer than the base
static const float DetailSpeed = 1.7;    // TUNE: and slides this much faster
// Spread of base + Detail * (detail - 0.5): 0.2 * sqrt(1 + Detail^2).
static const float Spread = 0.2193;
static const float Halo = 0.45;          // TUNE: share of alpha in the wispy fringe (rest is the body)

// Cloud alpha factor at noise coordinate p, 0 (clear) .. 1 (thickest).
float Density(float2 p, float2 drift1, float2 drift2, float cutoff)
{
    float a = tex2D(NoiseSampler, p + drift1).r;
    float b = tex2D(NoiseSampler, p * DetailScale + drift2 + float2(0.37, 0.61)).g;
    float d = a + Detail * (b - 0.5);
    float body = smoothstep(cutoff + 0.2 * Spread, cutoff + 1.6 * Spread, d);    // TUNE: body ramp
    float fringe = smoothstep(cutoff - 0.8 * Spread, cutoff + 0.8 * Spread, d);  // TUNE: fringe ramp
    return Halo * fringe + (1.0 - Halo) * body;
}

float4 MainPS(VSOutput input) : COLOR0
{
    float2 uv = input.TexCoord;
    float2 p = uv * Scale;

    // Keep the drift small so float precision holds however long the game runs.
    float2 drift1 = frac(Wind * Time);
    float2 drift2 = frac(Wind * DetailSpeed * Time);

    // Cut-off for the wanted coverage: mean + spread * probit(1 - Coverage),
    // with probit(x) ~= ln(x / (1 - x)) / 1.702.
    float x = clamp(1.0 - Coverage, 0.02, 0.98);
    float cutoff = 0.5 + Spread * (log(x / (1.0 - x)) / 1.702);

    float d0 = Density(p, drift1, drift2, cutoff);
    float dSun = Density(p + SunOffset, drift1, drift2, cutoff);
    float dShadow = Density(p + ShadowOffset, drift1, drift2, cutoff);

    // Rim fade: the quad overhangs its area by 15% each side, so this stays off-screen.
    float2 rim = smoothstep(0.0, 0.1, uv) * smoothstep(0.0, 0.1, 1.0 - uv);
    float fade = rim.x * rim.y;

    // Thicker toward the sun means this pixel sits on the cloud's shaded side.
    float shade = saturate(0.75 + (d0 - dSun) * 0.8);
    float3 cloudRgb = lerp(float3(0.80, 0.83, 0.88), float3(1.0, 1.0, 1.0), shade); // TUNE: tint

    float cloudA = d0 * Opacity * fade;
    float shadowA = dShadow * ShadowOpacity * fade * (1.0 - cloudA);

    // Premultiplied: cloud colour over black shadow.
    return float4(cloudRgb * cloudA, cloudA + shadowA);
}

technique Clouds
{
    pass P0
    {
        VertexShader = compile VS_SHADERMODEL MainVS();
        PixelShader = compile PS_SHADERMODEL MainPS();
    }
}

// Round 6 (2026-11-18): the ground map draws the cloud bodies under its roads and buildings but
// their shadows over them, so the shadows fall on everything on the ground. ShadowOnly is MainPS's
// shadow term alone (the same maths, so the two passes add up to one Clouds pass).
float4 ShadowPS(VSOutput input) : COLOR0
{
    float2 uv = input.TexCoord;
    float2 p = uv * Scale;
    float2 drift1 = frac(Wind * Time);
    float2 drift2 = frac(Wind * DetailSpeed * Time);
    float x = clamp(1.0 - Coverage, 0.02, 0.98);
    float cutoff = 0.5 + Spread * (log(x / (1.0 - x)) / 1.702);
    float d0 = Density(p, drift1, drift2, cutoff);
    float dShadow = Density(p + ShadowOffset, drift1, drift2, cutoff);
    float2 rim = smoothstep(0.0, 0.1, uv) * smoothstep(0.0, 0.1, 1.0 - uv);
    float fade = rim.x * rim.y;
    float cloudA = d0 * Opacity * fade;
    float shadowA = dShadow * ShadowOpacity * fade * (1.0 - cloudA);
    return float4(0.0, 0.0, 0.0, shadowA);
}

technique ShadowOnly
{
    pass P0
    {
        VertexShader = compile VS_SHADERMODEL MainVS();
        PixelShader = compile PS_SHADERMODEL ShadowPS();
    }
}
