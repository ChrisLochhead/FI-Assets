// Normal-mapped lighting for top-down terrain art (ground battle battlefields and the ground map).
//
// The diffuse battlefield is drawn through SpriteBatch with this effect; a quarter-resolution
// normal map generated from the art's luminance (tools: Content/Backgrounds/BattlefieldNormals)
// is bound on sampler 1 and shares the diffuse UVs. Light comes from LightDir (tangent space,
// screen X right / Y down / Z toward the viewer). Ambient is the floor of the shading term so
// slopes facing away from the sun darken but never go black.

#if OPENGL
    #define SV_POSITION POSITION
    #define VS_SHADERMODEL vs_3_0
    #define PS_SHADERMODEL ps_3_0
#else
    #define VS_SHADERMODEL vs_4_0_level_9_1
    #define PS_SHADERMODEL ps_4_0_level_9_1
#endif

float4x4 MatrixTransform;
float3 LightDir;      // normalised, pointing TOWARD the light
float Ambient;        // 0..1 floor of the shading term
float Strength;       // how far the normal tilts (1 = as authored)
float Specular;       // small glint on wet/ice surfaces, 0 = off

Texture2D SpriteTexture;
sampler2D SpriteTextureSampler = sampler_state
{
    Texture = <SpriteTexture>;
    MinFilter = Linear;
    MagFilter = Linear;
    MipFilter = Linear;
    AddressU = Clamp;
    AddressV = Clamp;
};

Texture2D NormalMap;
sampler2D NormalSampler : register(s1) = sampler_state
{
    Texture = <NormalMap>;
    MinFilter = Linear;
    MagFilter = Linear;
    MipFilter = Linear;
    AddressU = Clamp;
    AddressV = Clamp;
};

// Optional coarse height layer (ground map: the editor-painted 160x90 elevation, bilinear).
// ElevationStrength 0 disables it; the samples are still taken so no gradient op sits in a branch.
Texture2D ElevationMap;
sampler2D ElevationSampler : register(s2) = sampler_state
{
    Texture = <ElevationMap>;
    MinFilter = Linear;
    MagFilter = Linear;
    MipFilter = Linear;
    AddressU = Clamp;
    AddressV = Clamp;
};
float ElevationStrength;
float2 ElevationTexel;

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

float4 MainPS(VSOutput input) : COLOR0
{
    float4 diffuse = tex2D(SpriteTextureSampler, input.TexCoord);
    float3 n = tex2D(NormalSampler, input.TexCoord).xyz * 2.0 - 1.0;
    n.xy *= Strength;
    float eL = tex2D(ElevationSampler, input.TexCoord - float2(ElevationTexel.x, 0.0)).r;
    float eR = tex2D(ElevationSampler, input.TexCoord + float2(ElevationTexel.x, 0.0)).r;
    float eU = tex2D(ElevationSampler, input.TexCoord - float2(0.0, ElevationTexel.y)).r;
    float eD = tex2D(ElevationSampler, input.TexCoord + float2(0.0, ElevationTexel.y)).r;
    n.xy += float2(-(eR - eL), -(eD - eU)) * ElevationStrength;
    n = normalize(n);
    float3 l = normalize(LightDir);
    float ndl = saturate(dot(n, l));
    float shade = Ambient + (1.0 - Ambient) * ndl;
    // Cheap Blinn glint toward the viewer for water / ice biomes.
    float3 h = normalize(l + float3(0.0, 0.0, 1.0));
    float spec = pow(saturate(dot(n, h)), 24.0) * Specular;
    float3 rgb = diffuse.rgb * shade + spec * diffuse.a;
    return float4(rgb, diffuse.a) * input.Color;
}

technique TerrainLit
{
    pass P0
    {
        VertexShader = compile VS_SHADERMODEL MainVS();
        PixelShader  = compile PS_SHADERMODEL MainPS();
    }
};
