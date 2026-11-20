// Outlines and work glows for ground-map sprites (Rendering/InkOutline.cs).
//
// Round 3 (2026-11-18, Chris): the round-2 black cartoon border was "too thick and too black";
// buildings should carry "the outline we've got now for connections". So the outline is the
// roads' outline band: InkColor (GroundSpriteDrawer.RoadOutlineColor) about 1.5 world units wide,
// soft-edged, and there are no interior ink lines any more.
//
// Pixel-shader only: SpriteBatch's own vertex shader positions the quad, so this drops into a
// SpriteBatch.Begin. The sprite is drawn into a quad inflated by Pad on every side (room for
// the outline outside the art); the shader maps the quad UV back to sprite UV and treats
// anything outside the sprite as clear (a Clamp sampler would smear the border texels).
//
//   Ink   - the art over its outline: the sprite's alpha dilated by Step, smoothstepped, laid in
//           InkColor behind the art. Round 5 (2026-11-18, Chris: "outlines dont look very
//           smooth"): the round-3 two rings of 8 max-taps on the sharp alpha gave a lumpy edge
//           (the 8 shifted copies show as bumps) with a sub-pixel hard ramp (stair-steps). Now 12
//           taps at Step plus 6 rotated at 0.55 Step read the alpha one mip level softer
//           (TapBias), and the ramp is wide: a rounded, anti-aliased edge about a pixel soft.
//           Designed against an offline numpy port (AI_Game/__tmp/shaderpass/ink2/port3.py).
//   Glow  - the outline only, as a soft halo: the mean of the same taps instead of the max, so
//           it fades out over Step. Used for the blue "being built or upgraded" glow, which the
//           old CPU silhouette could not draw for the compressed building textures.
//
// Output is premultiplied (sprites are premultiplied) for BlendState.AlphaBlend. The vertex
// colour tints the art and scales the whole result's alpha (a ghosted building's outline ebbs
// with it). Ink: 23 texture reads; Glow: 17. Tuning constants are marked TUNE.
//
// Round 6 (2026-11-18, Chris: the map's pieces looked "very disjointed" from the terrain, partly
// "block colours ... vs the variety of the ground maps"): with Grounded = 1 the Ink art is lit by
// the terrain's sun (a gentle gradient across the sprite plus a lit rim on the sun side and a
// shaded rim on the far side), leans BiomeTint toward the biome colour, and with Grime > 0 (empty
// platforms, landing pads) picks up low-frequency brightness variation and dirt from the tiling
// noise. The Road technique does the same for the road mesh in world space, plus a worn verge,
// a contact shadow and a slightly broken outline. Numpy port: AI_Game/__tmp/shaderpass/grounded/.

#if OPENGL
    #define SV_POSITION POSITION
    #define VS_SHADERMODEL vs_3_0
    #define PS_SHADERMODEL ps_3_0
#else
    #define VS_SHADERMODEL vs_4_0_level_9_3
    #define PS_SHADERMODEL ps_4_0_level_9_3
#endif

float2 Pad;        // inflation per side, as a share of the quad (x, y)
float2 Step;       // outline / glow radius, in sprite UV (x, y)
float3 InkColor;   // outline or glow colour (0..1 rgb)
float InkAlpha;    // opacity of the outline or glow, 0..1
float Grounded;    // 1 = light, tint and grime the art (round 6); 0 = the plain round-5 look
float3 Biome;      // the biome's ground colour (GroundingMath.BiomeColor)
float3 Dirt;       // the biome's worn-ground colour (GroundingMath.DirtColor)
float BiomeTint;   // share of the way toward the biome colour
float Grime;       // 0..1 brightness variation and dirt on the art (platforms, pads)
float2 SunDir;     // toward the sun on screen (normalised)
float2 RimStep;    // the lit / shaded rim probe, sprite UV
float2 Seed;       // per-sprite noise offset

// Explicit registers (2026-11-18 fix): with two samplers the compiler put the noise in s0 and the
// sprite in s1, but SpriteBatch binds the sprite to slot 0, so the art read an empty slot (opaque
// black on GL) and every building drew as a black square. The sprite is always s0, the noise s1.
Texture2D NoiseMap;
sampler2D NoiseSampler : register(s1) = sampler_state
{
    Texture = <NoiseMap>;
    MinFilter = Linear;
    MagFilter = Linear;
    MipFilter = Linear;
    AddressU = Wrap;
    AddressV = Wrap;
};

Texture2D SpriteTexture;
sampler2D SpriteTextureSampler : register(s0) = sampler_state
{
    Texture = <SpriteTexture>;
};

struct PSInput
{
    float4 Position : SV_POSITION;
    float4 Color    : COLOR0;
    float2 TexCoord : TEXCOORD0;
};

static const float D = 0.7071068;
static const float CoverLo = 0.03;      // TUNE: dilated (softened) alpha where the outline starts
static const float CoverHi = 0.55;      // TUNE: ... and where it is solid
static const float TapBias = 1.0;       // TUNE: mip levels softer than the art for the outline taps
static const float LightBase = 0.94;    // TUNE: sprite shade on flat ground (the terrain sits at ~0.79 under its own light)
static const float LightGrad = 0.07;    // TUNE: brighter toward the sun, darker away, across the sprite
static const float RimGain = 0.10;      // TUNE: lit rim on the sun side, shaded rim on the far side
static const float GrimeVar = 0.24;     // TUNE: brightness variation span under Grime
static const float GrimeDirt = 0.40;    // TUNE: strongest dirt cover under Grime


// Sprite alpha at sprite UV p, clear outside the sprite.
float ArtA(float2 p)
{
    float2 inside = step(0.0, p) * step(p, 1.0);
    return tex2D(SpriteTextureSampler, p).a * (inside.x * inside.y);
}

// Eight taps round a circle of radius r (sprite UV): x = max, y = sum.
float2 Ring(float2 p, float2 r)
{
    float a0 = ArtA(p + float2( r.x, 0.0));
    float a1 = ArtA(p + float2(-r.x, 0.0));
    float a2 = ArtA(p + float2(0.0,  r.y));
    float a3 = ArtA(p + float2(0.0, -r.y));
    float a4 = ArtA(p + float2( r.x,  r.y) * D);
    float a5 = ArtA(p + float2(-r.x,  r.y) * D);
    float a6 = ArtA(p + float2( r.x, -r.y) * D);
    float a7 = ArtA(p + float2(-r.x, -r.y) * D);
    float m = max(max(max(a0, a1), max(a2, a3)), max(max(a4, a5), max(a6, a7)));
    return float2(m, a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7);
}

// Softened sprite alpha at sprite UV p (one mip level blurrier), clear outside the sprite.
float SoftA(float2 p)
{
    float2 inside = step(0.0, p) * step(p, 1.0);
    return tex2Dbias(SpriteTextureSampler, float4(p, 0.0, TapBias)).a * (inside.x * inside.y);
}

// Max of the softened alpha over 12 taps round a circle of radius r plus 6 rotated taps at 0.55 r.
float SoftDilate(float2 p, float2 r)
{
    float m = SoftA(p);
    [unroll] for (int i = 0; i < 12; i++)
    {
        float a = i * 0.5235988;                       // 30 degrees
        m = max(m, SoftA(p + float2(cos(a), sin(a)) * r));
    }
    [unroll] for (int j = 0; j < 6; j++)
    {
        float b = j * 1.0471976 + 0.5235988;           // 60 degrees, offset 30
        m = max(m, SoftA(p + float2(cos(b), sin(b)) * r * 0.55));
    }
    return m;
}

// The round-6 grounding of a premultiplied art colour at sprite UV p.
float3 GroundArt(float3 rgb, float a, float2 p)
{
    float g = dot(p - 0.5, SunDir) * 2.0;
    float lit = saturate(a - ArtA(p + SunDir * RimStep));
    float far = saturate(a - ArtA(p - SunDir * RimStep));
    float shade = LightBase + LightGrad * g + RimGain * (lit - far);
    float lum = dot(rgb, float3(0.3333, 0.3333, 0.3333));
    rgb = lerp(rgb, saturate(lum * Biome * 1.6), BiomeTint);
    float3 n = tex2D(NoiseSampler, p * 0.9 + Seed).rgb;
    rgb *= 1.0 + Grime * GrimeVar * (n.r - 0.5) * 2.0;
    float dirt = smoothstep(0.62, 0.80, n.g) * GrimeDirt * Grime;
    rgb = lerp(rgb, Dirt * 0.8 * a, dirt);
    return rgb * shade;
}

float2 SpriteUV(float2 t)
{
    return (t - Pad) / (1.0 - 2.0 * Pad);
}

float4 InkPS(PSInput input) : COLOR0
{
    float2 p = SpriteUV(input.TexCoord);
    float2 inside = step(0.0, p) * step(p, 1.0);
    float4 art = tex2D(SpriteTextureSampler, p) * (inside.x * inside.y) * input.Color;
    art.rgb = lerp(art.rgb, GroundArt(art.rgb, art.a, p), Grounded);

    float m = max(art.a, SoftDilate(p, Step));
    float o = smoothstep(CoverLo, CoverHi, m) * InkAlpha * input.Color.a;

    // Premultiplied: art over the outline.
    float under = o * (1.0 - art.a);
    return float4(art.rgb + InkColor * under, art.a + under);
}

float4 GlowPS(PSInput input) : COLOR0
{
    float2 p = SpriteUV(input.TexCoord);
    float2 outer = Ring(p, Step);
    float2 inner = Ring(p, Step * 0.5);
    float g = saturate((inner.y + outer.y * 0.6) / (8.0 * 1.6) * 1.4);   // TUNE: halo gain
    float a = g * g * InkAlpha * input.Color.a;
    return float4(InkColor * a, a);
}

technique Ink
{
    pass P0
    {
        PixelShader = compile PS_SHADERMODEL InkPS();
    }
}

technique Glow
{
    pass P0
    {
        PixelShader = compile PS_SHADERMODEL GlowPS();
    }
}

// ── Road: the ground map's road mesh (Rendering/RoadMesh.cs) ───────────────────────────────
// Built once per road layout in world units. The feather columns carry their push direction in
// TEXCOORD0; the vertex shader moves them out by FeatherWorld (one screen pixel in world units),
// so the soft edge stays one pixel wide at any zoom without rebuilding the mesh.
float4x4 RoadMatrix;   // world -> clip
float FeatherWorld;    // world units per screen pixel (capped)
float RoadHalf;        // half the road's painted width (the outline's outer edge), world units

struct RoadVSInput
{
    float4 Position : POSITION0;
    float4 Color    : COLOR0;
    float2 Extrude  : TEXCOORD0;
};

struct RoadVSOutput
{
    float4 Position : SV_POSITION;
    float4 Color    : COLOR0;
    float3 World    : TEXCOORD1;   // world xy, and the signed offset across the road (from Position.z)
};

RoadVSOutput RoadVS(RoadVSInput input)
{
    RoadVSOutput o;
    float4 p = input.Position;
    p.xy += input.Extrude * FeatherWorld;
    float across = p.z;
    p.z = 0.0;
    o.Position = mul(p, RoadMatrix);
    o.Color = input.Color;
    o.World = float3(p.xy, across);
    return o;
}

static const float RoadVarScale = 720.0;   // TUNE: world units per noise tile for the slow brightness drift
static const float RoadDirtScale = 320.0;  // TUNE: ... for the dirt patches

float4 RoadPS(RoadVSOutput input) : COLOR0
{
    float4 c = input.Color;
    float a = c.a;
    float3 rgb = c.rgb / max(a, 0.0001);   // un-premultiply
    float2 w = input.World.xy;
    float across = abs(input.World.z);
    float n1 = tex2D(NoiseSampler, w / RoadVarScale).r;
    float n2 = tex2D(NoiseSampler, w / RoadDirtScale + float2(0.37, 0.61)).g;
    // Soft masks, never step(): a hard threshold across the road drew stair-stepped edges.
    float body = 1.0 - smoothstep(RoadHalf, RoadHalf + 0.5, across);   // 1 on the painted bands, 0 on the verge and shadow

    float lum = dot(rgb, float3(0.3333, 0.3333, 0.3333));
    rgb = lerp(rgb, saturate(lum * Biome * 1.6), BiomeTint * body);
    rgb *= 0.86 + 0.28 * n1;
    float dirt = smoothstep(0.62, 0.80, n2) * GrimeDirt * body;
    rgb = lerp(rgb, Dirt * 0.8, dirt);
    // No worn cutaways in the outline (Chris, 2026-11-18: "looks fine without it, the dirt texture is good enough").
    a *= lerp(1.0, 0.6 + 0.8 * n2, 1.0 - body);                         // a patchy worn verge
    float4 grounded = float4(rgb * a, a);
    return lerp(c, grounded, Grounded);
}

technique Road
{
    pass P0
    {
        VertexShader = compile VS_SHADERMODEL RoadVS();
        PixelShader = compile PS_SHADERMODEL RoadPS();
    }
}
