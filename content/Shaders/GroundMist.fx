// Low ground mist for GroundMistLayer (2026-11-18 shader pass): the ground map, the mission
// editor's ground canvas and the ground battle.
//
// One quad over the terrain, one pass, three texture reads. Like Clouds.fx the mist is cut out
// of TilingNoise (B channel for the banks, R for the frayed detail, so it never lines up with
// the clouds above), but the field is stretched sideways into banks and slides slowly.
// PoolMap is a small, pre-blurred grid made on the CPU (GroundMistMath) whose R channel is
// "how low is this ground", 1 in the hollows and 0 on the ridges; it lowers the cut-off there
// so mist gathers in valleys and rivers and thins on high ground. PoolWeight 0 means no map:
// every pixel pools at 0.5.
// Designed against an offline numpy port over real battlefield art and heights
// (AI_Game/__tmp/shaderpass/mist/mist.py).
//
// Output is premultiplied for BlendState.AlphaBlend. Tuning constants are marked TUNE.

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
float Coverage;       // share of the ground under mist before pooling, 0..1
float Density;        // alpha of the thickest mist
float2 Scale;         // noise tiles across the quad (x, y)
float2 Wind;          // drift in noise units per second
float3 Tint;          // mist colour
float PoolWeight;     // 1 = PoolMap shapes the mist, 0 = no map (flat 0.5)
float RimFade;        // share of the quad faded in at each edge

Texture2D NoiseMap;
sampler2D NoiseSampler : register(s0) = sampler_state
{
    Texture = <NoiseMap>;
    MinFilter = Linear;
    MagFilter = Linear;
    MipFilter = Linear;
    AddressU = Wrap;
    AddressV = Wrap;
};

Texture2D PoolMap;
sampler2D PoolSampler : register(s1) = sampler_state
{
    Texture = <PoolMap>;
    MinFilter = Linear;
    MagFilter = Linear;
    MipFilter = Point;
    AddressU = Clamp;
    AddressV = Clamp;
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

static const float2 BankStretch = float2(0.55, 1.25);   // TUNE: banks are wider than tall
static const float2 DetailStretch = float2(1.7, 3.1);   // TUNE: finer fraying field
static const float DetailSpeed = 1.9;                   // TUNE: the detail slides faster
static const float Detail = 0.5;                        // TUNE: weight of the detail field
// Spread of bank + Detail * (detail - 0.5): 0.2 * sqrt(1 + Detail^2).
static const float Spread = 0.2236;
static const float PoolBias = 0.30;                     // TUNE: how far low ground lowers the cut-off
static const float PoolFloor = 0.25;                    // TUNE: share of density kept on high ground

float4 MainPS(VSOutput input) : COLOR0
{
    float2 uv = input.TexCoord;
    float2 p = uv * Scale;

    float2 drift1 = frac(Wind * Time);
    float2 drift2 = frac(Wind * DetailSpeed * Time);

    float bank = tex2D(NoiseSampler, p * BankStretch + drift1).b;
    float detail = tex2D(NoiseSampler, p * DetailStretch + drift2 + float2(0.53, 0.29)).r;
    float m = bank + Detail * (detail - 0.5);

    float pool = lerp(0.5, tex2D(PoolSampler, uv).r, PoolWeight);

    // Cut-off for the wanted coverage (as Clouds.fx), lowered in the hollows.
    float x = clamp(1.0 - Coverage, 0.02, 0.98);
    float cutoff = 0.5 + Spread * (log(x / (1.0 - x)) / 1.702);
    float mask = smoothstep(cutoff - 1.2 * Spread, cutoff + 1.6 * Spread, m + (pool - 0.5) * PoolBias);  // TUNE: soft ramp

    float2 rim = smoothstep(0.0, RimFade, uv) * smoothstep(0.0, RimFade, 1.0 - uv);
    float a = Density * mask * (PoolFloor + (1.0 - PoolFloor) * pool) * rim.x * rim.y;
    return float4(Tint * a, a);
}

technique GroundMist
{
    pass P0
    {
        VertexShader = compile VS_SHADERMODEL MainVS();
        PixelShader = compile PS_SHADERMODEL MainPS();
    }
}
