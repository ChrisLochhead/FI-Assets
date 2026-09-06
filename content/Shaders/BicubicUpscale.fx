// Catmull-Rom bicubic upscale + screen grade for the final letterbox blit.
//
// Used by Rendering/Presentation.cs to composite the 1280x720 virtual back-buffer
// onto the actual window at native resolution. Replaces raw bilinear filtering
// (which produces a soft, smeared look when the window is maximized) with a
// bicubic reconstruction that keeps edges crisp — text especially benefits.
//
// This is a well-known optimization from "Fast Third-Order Texture Filtering"
// (Sigg & Hadwiger, GPU Gems 2): nine bilinear taps combined with Catmull-Rom
// weights yield the same result as sixteen point samples, at ~1/2 the cost.
//
// The grade stage (vignette, shadow/highlight tint, dither noise) replaces the
// flat full-screen black rectangles the map states used to draw. All parameters
// default to neutral (Presentation resets them every frame) so menu screens are
// untouched; map states opt in from their Draw.
//
// Must be called with a Linear-filtered sampler; the bilinear taps do the
// weighted texel blending for us.

#if OPENGL
    #define SV_POSITION POSITION
    #define VS_SHADERMODEL vs_3_0
    #define PS_SHADERMODEL ps_3_0
#else
    #define VS_SHADERMODEL vs_4_0_level_9_1
    #define PS_SHADERMODEL ps_4_0_level_9_1
#endif

// Set by Presentation before every Begin. Combined ortho projection *
// SpriteBatch transform matrix (identity for the blit).
float4x4 MatrixTransform;

// Size of the source (virtual) render target in pixels — e.g. (1280, 720).
// Set once at load time by Presentation.
float2 SourceSize;

// ── Grade ─────────────────────────────────────────────────────────────────
// Vignette: darkening starts at VignetteRadius (0 = centre, ~0.7 = corners) and
// ramps over VignetteSoftness; VignetteStrength is the max darkening (0 = off).
float VignetteStrength;
float VignetteRadius;
float VignetteSoftness;
// Multiplied into dark pixels (ShadowTint) and bright pixels (HighlightTint),
// blended by luminance. (1,1,1) = no change.
float3 ShadowTint;
float3 HighlightTint;
// Signed dither amplitude (0 = off, ~0.02 hides DXT banding in dark gradients).
float NoiseAmount;
float Time;

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
    VSOutput output;
    output.Position = mul(input.Position, MatrixTransform);
    output.Color    = input.Color;
    output.TexCoord = input.TexCoord;
    return output;
}

float Hash21(float2 p)
{
    p = frac(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return frac(p.x * p.y);
}

float4 MainPS(VSOutput input) : COLOR0
{
    // Convert UV into source-texel space and split into "center texel + fraction".
    float2 samplePos = input.TexCoord * SourceSize;
    float2 texPos1   = floor(samplePos - 0.5) + 0.5;
    float2 f         = samplePos - texPos1;

    // Catmull-Rom weights for each of the four neighboring rows/columns.
    float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    float2 w3 = f * f * (-0.5 + 0.5 * f);

    // Fuse the middle two taps into a single bilinear fetch that lands between them.
    float2 w12      = w1 + w2;
    float2 offset12 = w2 / w12;

    float2 invSize  = 1.0 / SourceSize;
    float2 texPos0  = (texPos1 - 1.0)     * invSize;
    float2 texPos3  = (texPos1 + 2.0)     * invSize;
    float2 texPos12 = (texPos1 + offset12) * invSize;

    float4 result = 0.0;
    result += tex2D(SpriteTextureSampler, float2(texPos0.x,  texPos0.y))  * w0.x  * w0.y;
    result += tex2D(SpriteTextureSampler, float2(texPos12.x, texPos0.y))  * w12.x * w0.y;
    result += tex2D(SpriteTextureSampler, float2(texPos3.x,  texPos0.y))  * w3.x  * w0.y;

    result += tex2D(SpriteTextureSampler, float2(texPos0.x,  texPos12.y)) * w0.x  * w12.y;
    result += tex2D(SpriteTextureSampler, float2(texPos12.x, texPos12.y)) * w12.x * w12.y;
    result += tex2D(SpriteTextureSampler, float2(texPos3.x,  texPos12.y)) * w3.x  * w12.y;

    result += tex2D(SpriteTextureSampler, float2(texPos0.x,  texPos3.y))  * w0.x  * w3.y;
    result += tex2D(SpriteTextureSampler, float2(texPos12.x, texPos3.y))  * w12.x * w3.y;
    result += tex2D(SpriteTextureSampler, float2(texPos3.x,  texPos3.y))  * w3.x  * w3.y;

    // Catmull-Rom weights sum to 1 by construction; no divide needed.
    result *= input.Color;

    // ── Grade ──
    // Luminance-weighted shadow/highlight tint. Source is premultiplied; scaling
    // rgb only keeps it valid.
    float lum = dot(result.rgb, float3(0.299, 0.587, 0.114));
    float3 tint = lerp(ShadowTint, HighlightTint, saturate(lum * 1.4));
    result.rgb *= tint;

    // Elliptical vignette in UV space (follows the screen shape).
    float2 centred = input.TexCoord - 0.5;
    float dist = length(centred) * 1.4142;
    float vig = smoothstep(VignetteRadius, VignetteRadius + max(VignetteSoftness, 0.001), dist);
    result.rgb *= 1.0 - vig * VignetteStrength;

    // Dither: breaks the banding compressed backgrounds show under the vignette.
    float n = Hash21(input.TexCoord * SourceSize + Time) - 0.5;
    result.rgb += n * NoiseAmount * result.a;

    return result;
}

technique BicubicUpscale
{
    pass P0
    {
        VertexShader = compile VS_SHADERMODEL MainVS();
        PixelShader  = compile PS_SHADERMODEL MainPS();
    }
};
