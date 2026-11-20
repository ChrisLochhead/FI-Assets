// Screen-space shockwave refraction for Rendering/ScenePost (shader pass, 2026-11-18).
//
// Up to MaxRings expanding rings (ScreenDistortion's pool, already aged on the CPU by
// DistortionRules): each ring is a soft band at its current radius that pushes the scene
// outward from its centre, so the background bends as the wave passes. Strong offsets split
// the colour channels slightly (a thin chromatic fringe on the wave front).
// Rings[i] = (centre x px, centre y px, radius px, amplitude px); amplitude 0 = unused slot.
// Drawn with SpriteBatch, MatrixTransform set by hand.

#if OPENGL
    #define SV_POSITION POSITION
    #define VS_SHADERMODEL vs_3_0
    #define PS_SHADERMODEL ps_3_0
#else
    #define VS_SHADERMODEL vs_4_0_level_9_3
    #define PS_SHADERMODEL ps_4_0_level_9_3
#endif

#define MaxRings 8

float4x4 MatrixTransform;
float2 SourceSize;            // scene size in pixels
float4 Rings[MaxRings];

static const float BandShare = 0.32;  // TUNE: band width as a share of the radius
static const float MinBand = 6.0;     // TUNE: px
static const float Fringe = 0.35;     // TUNE: chromatic split per px of offset

Texture2D SpriteTexture;
sampler2D SpriteTextureSampler = sampler_state
{
    Texture = <SpriteTexture>;
    MinFilter = Linear;
    MagFilter = Linear;
    MipFilter = None;
    AddressU = Clamp;
    AddressV = Clamp;
};

struct VSInput
{
    float4 Position : POSITION0;
    float4 Color    : COLOR0;
    float2 TexCoord : TEXCOORD0;
};

struct VSOutput
{
    float4 Position : SV_POSITION;
    float4 Color    : COLOR0;
    float2 TexCoord : TEXCOORD0;
};

VSOutput MainVS(VSInput input)
{
    VSOutput o;
    o.Position = mul(input.Position, MatrixTransform);
    o.Color = input.Color;
    o.TexCoord = input.TexCoord;
    return o;
}

float4 DistortPS(VSOutput input) : COLOR0
{
    float2 px = input.TexCoord * SourceSize;
    float2 offset = 0;

    [unroll]
    for (int i = 0; i < MaxRings; i++)
    {
        float4 r = Rings[i];
        float2 v = px - r.xy;
        float d = length(v);
        float w = max(r.z * BandShare, MinBand);
        float x = (d - r.z) / w;
        // Signed band: pulls in just inside the front, pushes out just behind it.
        float band = x * exp(-x * x * 2.0);
        offset += (v / max(d, 0.001)) * band * r.w;
    }

    float2 uvOff = offset / SourceSize;
    float split = length(offset) * Fringe / SourceSize.x;
    float2 dir = normalize(offset + 0.0001);
    float2 uv = input.TexCoord - uvOff;
    float4 c = tex2D(SpriteTextureSampler, uv);
    c.r = tex2D(SpriteTextureSampler, uv - dir * split).r;
    c.b = tex2D(SpriteTextureSampler, uv + dir * split).b;
    return c * input.Color;
}

technique Distort
{
    pass P0
    {
        VertexShader = compile VS_SHADERMODEL MainVS();
        PixelShader = compile PS_SHADERMODEL DistortPS();
    }
}
