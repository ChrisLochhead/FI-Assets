// Planet and moon lighting for sprite batches (2026-11-18 shader pass, Rendering/PlanetLighting.cs).
//
// Pixel-shader only: SpriteBatch's own vertex shader positions the quad (with the batch's
// transform matrix), so these techniques drop into any SpriteBatch.Begin.
//
// Overlay  - drawn over a planet that is already on screen (the 3D sphere or the sprite). The
//            quad is QuadScale x the planet disc; the batch texture is TilingNoise (LinearWrap).
//            Each pixel treats the disc as a sphere (normal from the disc position) and adds:
//            a soft night-side darkening, a slowly turning cloud layer cut from the noise the
//            same way Clouds.fx does it (no city lights since 2026-11-18), and a
//            thin atmosphere rim on the lit limb with a halo just outside the disc.
//            Per-planet data rides in the vertex colour so one batch draws every planet:
//              R = city lights 0..1, G = cloud coverage 0..1,
//              B = (biome * 36 + seed) / 255, A = alpha.
//            Biomes: 0 normal, 1 ice, 2 sand, 3 fire, 4 water, 5 swamp, 6 moon (no air, faint rim).
// Surface  - draws a sprite (the space battle's moons) lit as a sphere: terminator plus a rim
//            light. The light direction in the sprite's own axes rides in the vertex colour
//            (R, G = x, y mapped from -1..1), so rotated sprites stay lit from the battle sun.
//
// Designed against an offline numpy port over the real sprites (AI_Game/__tmp/shaderpass/planets).
// Output is premultiplied for BlendState.AlphaBlend. Tuning constants are marked TUNE.

#if OPENGL
    #define SV_POSITION POSITION
    #define VS_SHADERMODEL vs_3_0
    #define PS_SHADERMODEL ps_3_0
#else
    #define VS_SHADERMODEL vs_4_0_level_9_3
    #define PS_SHADERMODEL ps_4_0_level_9_3
#endif

float Time;            // seconds
float3 LightDir;       // Overlay: toward the sun, screen space (x right, y down, z toward viewer), normalised
float QuadScale;       // Overlay: quad half-size / disc radius
float2 DiscCenter;     // Surface: disc centre in the sprite's UV
float2 DiscRadius;     // Surface: disc radius in the sprite's UV (x, y)
float3 SurfaceTint;    // Surface: albedo tint

Texture2D SpriteTexture;
// Clamp, and every read stays inside 0..1 (see OverlayPS): the clouds no longer rely on wrapping.
sampler2D SpriteTextureSampler = sampler_state
{
    Texture = <SpriteTexture>;
    MinFilter = Linear;
    MagFilter = Linear;
    MipFilter = Linear;
    AddressU = Clamp;
    AddressV = Clamp;
};

struct PSInput
{
    float4 Position : SV_POSITION;
    float4 Color    : COLOR0;
    float2 TexCoord : TEXCOORD0;
};

static const float PI2 = 6.2831853;
static const float NightDarken = 0.45;     // TUNE: black alpha on the night side
static const float CloudOpacity = 0.55;    // TUNE: alpha of the thickest cloud
static const float CloudSpin = 0.012;      // TUNE: turns of the cloud layer per second... x2 tiles
static const float Spread = 0.2193;        // as Clouds.fx
static const float Halo = 0.45;            // as Clouds.fx: share of alpha in the fringe
static const float RimInner = 0.6;         // TUNE: fresnel rim inside the disc
static const float RimOuter = 0.9;         // TUNE: halo just outside the disc
static const float RimWidth = 0.14;        // TUNE: halo width, in disc radii

float3 RimTint(float biome)
{
    // Unrolled table (level_9_3 has no dynamic constant indexing).
    float3 t = float3(0.45, 0.70, 1.00);                       // 0 normal
    t = lerp(t, float3(0.72, 0.88, 1.00), step(0.5, biome));   // 1 ice
    t = lerp(t, float3(1.00, 0.74, 0.45), step(1.5, biome));   // 2 sand
    t = lerp(t, float3(1.00, 0.45, 0.20), step(2.5, biome));   // 3 fire
    t = lerp(t, float3(0.40, 0.66, 1.00), step(3.5, biome));   // 4 water
    t = lerp(t, float3(0.55, 0.85, 0.50), step(4.5, biome));   // 5 swamp
    t = lerp(t, float3(0.70, 0.72, 0.76), step(5.5, biome));   // 6 moon
    return t;
}

float4 OverlayPS(PSInput input) : COLOR0
{
    float coverage = input.Color.g;
    float code = floor(input.Color.b * 255.0 + 0.5);
    float biome = floor(code / 36.0);
    float seed = code - biome * 36.0;
    float alpha = input.Color.a;
    float moon = step(5.5, biome);

    float2 p = (input.TexCoord * 2.0 - 1.0) * QuadScale;
    float r2 = dot(p, p);
    float r = sqrt(r2);
    float inside = step(r2, 1.0);
    float nz = sqrt(saturate(1.0 - r2));
    float ndl = dot(float3(p, nz), LightDir);

    // Night side.
    float night = smoothstep(0.10, -0.30, ndl) * NightDarken * inside;

    // Clouds: longitude/latitude on the sphere, drifting slowly. Every read stays inside 0..1, so the
    // look never depends on the sampler wrapping (2026-11-18: on DesktopGL the overlay batch sampled
    // clamped, and coordinates outside 0..1 smeared into straight bands, vertical then horizontal).
    // The drift is two layers half a cycle apart, each faded out at the moment its offset jumps back
    // (the usual flow-map cross-fade), so the clouds move steadily with no jump.
    float lon = atan2(p.x, max(nz, 0.0001)) / PI2;                  // -0.25..0.25 on the visible face
    float v = 0.5 + p.y * 0.42 + (frac(seed * 0.31) - 0.5) * 0.12;  // 0.02..0.98
    float t = Time * CloudSpin * 4.0 + seed * 0.137;
    float tA = frac(t);
    float tB = frac(t + 0.5);
    float wA = 1.0 - abs(tA * 2.0 - 1.0);                           // 0 when layer A's offset jumps
    float4 nA = tex2D(SpriteTextureSampler, float2(lon + 0.25 + tA * 0.5, v));
    float4 nB = tex2D(SpriteTextureSampler, float2(lon + 0.25 + tB * 0.5, 1.0 - v));
    // Base field plus a detail field from an independent channel at the same point.
    float dA = nA.r + 0.45 * (nA.g - 0.5);
    float dB = nB.r + 0.45 * (nB.g - 0.5);
    float d = lerp(dB, dA, wA);
    float x = clamp(1.0 - coverage, 0.02, 0.98);
    float cutoff = 0.5 + Spread * (log(x / (1.0 - x)) / 1.702);
    float dens = Halo * smoothstep(cutoff - 0.8 * Spread, cutoff + 0.8 * Spread, d)
               + (1.0 - Halo) * smoothstep(cutoff + 0.2 * Spread, cutoff + 1.6 * Spread, d);
    float limb = smoothstep(0.0, 0.25, nz);
    float pole = smoothstep(0.0, 0.45, sqrt(saturate(1.0 - p.y * p.y)));
    float ca = dens * CloudOpacity * limb * pole * inside * (1.0 - moon) * step(0.005, coverage);
    float clit = clamp(ndl * 0.9 + 0.30, 0.08, 1.0);
    float3 cloud = float3(0.95, 0.97, 1.0) * clit;

    // No night-side city lights (Chris, 2026-11-18: "remove the light glow from planets on their dark
    // side"). R (city) is still packed by PlanetLighting.EncodeOverlay but unused here.

    // Atmosphere: a fresnel rim inside the disc, a halo just outside it, both on the lit side.
    float2 pe = p / max(r, 0.0001);
    float litRim = saturate(dot(pe, LightDir.xy) * 0.7 + 0.45);
    float inner = pow(1.0 - nz, 3.0) * inside * saturate(ndl + 0.35);
    float outer = (1.0 - smoothstep(1.0, 1.0 + RimWidth, r)) * (1.0 - inside) * litRim;
    float rim = (inner * RimInner + outer * outer * RimOuter) * lerp(1.0, 0.35, moon);

    float3 rgb = cloud * ca + RimTint(biome) * rim;
    float outA = ca + (1.0 - ca) * night;
    return float4(rgb, outA) * alpha;
}

static const float SurfaceAmbient = 0.10;  // TUNE
static const float SurfaceDiffuse = 1.10;  // TUNE
static const float SurfaceRim = 0.60;      // TUNE: warm rim light on the lit limb
static const float SurfaceLightZ = 0.42;   // TUNE: how far the sun is in front (lower = thinner crescent)

float4 SurfacePS(PSInput input) : COLOR0
{
    float4 tex = tex2D(SpriteTextureSampler, input.TexCoord);
    float2 p = (input.TexCoord - DiscCenter) / DiscRadius;
    float nz = sqrt(saturate(1.0 - dot(p, p)));
    float2 l2 = (input.Color.rg * 2.0 - 1.0) * 0.9;
    float3 l = normalize(float3(l2, SurfaceLightZ));
    float ndl = dot(float3(p, nz), l);
    float lit = SurfaceAmbient + SurfaceDiffuse * saturate(ndl);
    float rim = pow(saturate(1.0 - nz), 2.5) * saturate(ndl + 0.2) * SurfaceRim;
    // The texture is premultiplied, so tex.a scales the rim the same way.
    float3 rgb = tex.rgb * SurfaceTint * lit + float3(1.0, 0.95, 0.88) * rim * tex.a;
    return float4(rgb, tex.a) * input.Color.a;
}

technique Overlay
{
    pass P0
    {
        PixelShader = compile PS_SHADERMODEL OverlayPS();
    }
}

technique Surface
{
    pass P0
    {
        PixelShader = compile PS_SHADERMODEL SurfacePS();
    }
}
