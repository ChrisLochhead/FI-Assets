// Hex-grid ripple across a ship's shield sprite after a hit (2026-11-18 shader pass,
// GameStates/SpaceBattleState/SpaceBattleState.ShieldRipples.cs + Rendering/Vfx/ShieldRippleSet.cs).
//
// One SpriteBatch quad per ripple, drawn over the ship with BlendState.Additive. The shield texture
// only supplies the bubble's SHAPE (its alpha); the colour is Tint, the same blue (or reflector gold,
// or buff colour) the old windowed flash used. In shield-height units (Aspect keeps the ring round on
// a wide hull) a ring expands from HitUv to Reach over Progress 0..1. Inside the ring's band the hex
// cell edges light brightly and the cell faces faintly; a short wake of edges trails behind the
// front, and a hot flash sits on the impact point for the first third. Everything fades with
// (1 - Progress)^2. One texture read per pixel. Tuning marked TUNE.

#if OPENGL
    #define SV_POSITION POSITION
    #define VS_SHADERMODEL vs_3_0
    #define PS_SHADERMODEL ps_3_0
#else
    #define VS_SHADERMODEL vs_4_0_level_9_3
    #define PS_SHADERMODEL ps_4_0_level_9_3
#endif

float4x4 MatrixTransform;
float2 HitUv;       // impact point in the shield texture's UV
float2 Aspect;      // (width / height, 1) of the drawn shield
float Progress;     // 0..1 over the ripple's life
float Reach;        // ring radius at Progress 1, shield heights
float3 Tint;        // shield colour, 0..1
float Intensity;    // overall strength

Texture2D SpriteTexture;
sampler2D SpriteTextureSampler = sampler_state
{
    Texture = <SpriteTexture>;
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

static const float HexScale = 7.0;     // TUNE: hex cells across the shield's height
static const float RingWidth = 0.11;   // TUNE: ring band half-width, shield heights
static const float WakeLength = 0.35;  // TUNE: how far the lit edges trail behind the front
static const float2 HexS = float2(1.0, 1.7320508);

// Distance from p to the nearest hex cell edge: 0 on an edge, 0.5 at a cell centre.
float HexEdge(float2 p)
{
    float2 a = p - HexS * floor(p / HexS) - HexS * 0.5;
    float2 pb = p - HexS * 0.5;
    float2 b = pb - HexS * floor(pb / HexS) - HexS * 0.5;
    float2 q = dot(a, a) < dot(b, b) ? a : b;
    q = abs(q);
    return 0.5 - max(dot(q, float2(0.5, 0.8660254)), q.x);
}

float4 MainPS(VSOutput input) : COLOR0
{
    float2 uv = input.TexCoord;
    float shape = tex2D(SpriteTextureSampler, uv).a * input.Color.a;

    float2 p = (uv - HitUv) * Aspect;
    float d = length(p);
    float radius = Progress * Reach;

    float edgeLine = 1.0 - smoothstep(0.02, 0.09, HexEdge(uv * Aspect * HexScale));   // TUNE: edge sharpness
    float k = (d - radius) / RingWidth;
    float ring = exp(-k * k);
    float behind = step(d, radius) * saturate(1.0 - (radius - d) / WakeLength);
    float fade = (1.0 - Progress) * (1.0 - Progress);

    float front = ring * (0.28 + 0.72 * edgeLine);         // TUNE: cell face vs edge in the band
    float wake = behind * edgeLine * 0.22;                 // TUNE: wake brightness
    float flash = exp(-d * d / 0.012) * pow(saturate(1.0 - Progress * 3.0), 2.0) * 0.9;

    float v = ((front + wake) * fade + flash) * shape * Intensity;
    return float4(Tint * v, 1.0);
}

technique ShieldRipple
{
    pass P0
    {
        VertexShader = compile VS_SHADERMODEL MainVS();
        PixelShader = compile PS_SHADERMODEL MainPS();
    }
}
