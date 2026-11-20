// World-layer bloom for Rendering/ScenePost (shader pass, 2026-11-18).
//
// Two techniques, both drawn through SpriteBatch with MatrixTransform set by hand:
//   BrightPass - downsamples the scene copy to quarter size (four bilinear taps cover a 4x4
//                block) and keeps only what is bright AND coloured. White counts for less than
//                a saturated colour of the same brightness (WhiteWeight), so hitsplat text and
//                planet labels do not smear while lasers, engines and fire glow.
//   Blur       - a separable 9-tap Gaussian folded into five bilinear taps along Direction.
//                ScenePost runs it horizontal then vertical, twice, at growing spread.
// The result is added back over the scene with BlendState.Additive by ScenePost.
// Tuning constants are marked TUNE; per-screen threshold and strength come from ScenePost.Look.

#if OPENGL
    #define SV_POSITION POSITION
    #define VS_SHADERMODEL vs_3_0
    #define PS_SHADERMODEL ps_3_0
#else
    #define VS_SHADERMODEL vs_4_0_level_9_1
    #define PS_SHADERMODEL ps_4_0_level_9_1
#endif

float4x4 MatrixTransform;
float2 SourceTexel;    // 1 / size of the texture being read
float Threshold;       // bloom starts at this weighted brightness
float Knee;            // and ramps in over this much more
float WhiteWeight;     // brightness multiplier for an unsaturated (white/grey) pixel, 0..1
float2 Direction;      // blur axis in texels of the read texture, times the spread

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

float4 BrightPS(VSOutput input) : COLOR0
{
    float2 uv = input.TexCoord;
    // Four bilinear taps one source texel off centre average a 4x4 block.
    float3 c = tex2D(SpriteTextureSampler, uv + SourceTexel * float2(-1, -1)).rgb;
    c += tex2D(SpriteTextureSampler, uv + SourceTexel * float2( 1, -1)).rgb;
    c += tex2D(SpriteTextureSampler, uv + SourceTexel * float2(-1,  1)).rgb;
    c += tex2D(SpriteTextureSampler, uv + SourceTexel * float2( 1,  1)).rgb;
    c *= 0.25;

    float hi = max(c.r, max(c.g, c.b));
    float lo = min(c.r, min(c.g, c.b));
    float sat = (hi - lo) / max(hi, 0.0001);
    float b = hi * lerp(WhiteWeight, 1.0, sat);
    float k = smoothstep(Threshold, Threshold + max(Knee, 0.0001), b);
    // Keep the colour, scaled by how far over the threshold it is.
    return float4(c * k, 1.0);
}

float4 BlurPS(VSOutput input) : COLOR0
{
    float2 uv = input.TexCoord;
    float2 d = Direction * SourceTexel;
    // 9-tap Gaussian (sigma ~2) as 5 linear taps: weights 0.2270, 0.3162, 0.0703.
    float3 c = tex2D(SpriteTextureSampler, uv).rgb * 0.2270270;
    c += tex2D(SpriteTextureSampler, uv + d * 1.3846154).rgb * 0.3162162;
    c += tex2D(SpriteTextureSampler, uv - d * 1.3846154).rgb * 0.3162162;
    c += tex2D(SpriteTextureSampler, uv + d * 3.2307692).rgb * 0.0702703;
    c += tex2D(SpriteTextureSampler, uv - d * 3.2307692).rgb * 0.0702703;
    return float4(c, 1.0);
}

technique BrightPass
{
    pass P0
    {
        VertexShader = compile VS_SHADERMODEL MainVS();
        PixelShader = compile PS_SHADERMODEL BrightPS();
    }
}

technique Blur
{
    pass P0
    {
        VertexShader = compile VS_SHADERMODEL MainVS();
        PixelShader = compile PS_SHADERMODEL BlurPS();
    }
}
