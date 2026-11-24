//
//  MatrixRain.metal
//  Shader
//
//  Digital rain: streams of glyphs falling down the screen, each with a white head and
//  a green trail that fades out behind it.
//
//  The rain is drawn per pixel on one grid of glyph cells. Every column rains at its
//  own pace, and some columns are far away: dimmer, softer and slower. Glyphs are
//  mirrored katakana, Latin capitals, digits and a few symbols, mixed at random, and
//  they flip to new ones as the rain falls.
//
//  Everything is worked out in display values (as the screen shows them), like the
//  reference, whose glow was measured as a single Gaussian added in that space. The
//  glow is the rain drawn again at low resolution, blurred horizontally and then
//  vertically, and added to the sharp rain.
//

#include <metal_stdlib>
using namespace metal;

/// Mirrors `MatrixRainUniforms` in MatrixRainRenderer.swift; keep the field order in sync.
/// Lengths are in points.
struct RainUniforms {
    float4 trailColor;      // display RGB at full strength
    float4 headColor;
    float2 viewport;        // target size, pixels
    float2 cell;            // column and row pitch; a glyph fills its cell
    float2 atlasCell;       // texels per glyph cell in the atlas
    float pointScale;       // pixels per point in the target
    float time;             // seconds
    float speed;            // rows per second of the fastest near columns
    float density;          // share of columns that rain
    float brightness;       // a near trail's strength just behind its head
    float farShare;         // share of rain columns that are far away
    float softness;         // extra mip levels for every glyph
    float farBlur;          // more for far columns
    float glowAmount;
    uint atlasColumns;
    uint scriptCount;       // entries in the script table
    uint mirrored;
};

/// Mirrors `MatrixBlurStep` in MatrixRainRenderer.swift.
struct BlurStep {
    int2 direction;         // one texel along the blur
    int radius;             // taps each side of the centre
};

struct RainVertexOut {
    float4 position [[position]];
};

namespace {

constexpr sampler linearClamp(filter::linear, mip_filter::linear, address::clamp_to_edge);

uint hash(uint x) {
    x ^= x >> 16;
    x *= 0x7feb352dU;
    x ^= x >> 15;
    x *= 0x846ca68bU;
    x ^= x >> 16;
    return x;
}

uint hash(int a, int b, int c, uint seed) {
    return hash(as_type<uint>(a) ^ hash(as_type<uint>(b) ^ hash(as_type<uint>(c) ^ hash(seed))));
}

/// Uniform in [0, 1), the same every time for the same arguments.
float random(int a, int b, int c, uint seed) {
    return float(hash(a, b, c, seed) >> 8) * (1.0 / 16777216.0);
}

/// The rain's light at `pixel`, before the glow. Values above 1 are clipped later.
float3 rain(float2 pixel,
            constant RainUniforms &u,
            constant uint2 *scripts,
            texture2d<float> atlas,
            float extraBlur)
{
    float2 p = pixel / u.pointScale;
    float2 cell = floor(p / u.cell);
    int column = int(cell.x);
    int row = int(cell.y);

    // Each column rains on its own: some not at all, the rest at their own pace, with
    // drops a column-specific number of rows apart. Far columns are dimmer, softer and
    // slower.
    if (random(column, 0, 0, 0) >= u.density) return 0.0;
    bool far = random(column, 1, 0, 0) < u.farShare;
    float depth = random(column, 2, 0, 0);
    float strength = u.brightness * (far ? mix(0.15, 0.45, depth) : mix(0.75, 1.0, depth));
    float speed = u.speed * mix(0.55, 1.0, random(column, 3, 0, 0)) * (far ? 0.6 : 1.0);
    float spacing = mix(28.0, 72.0, random(column, 4, 0, 0));
    float phase = random(column, 5, 0, 0) * 1000.0;

    // Heads move down a row at a time. `behind` is how many rows ago the latest one
    // passed this cell; each drop's trail takes its own share of the spacing.
    float fall = (u.time * speed + phase - cell.y) / spacing;
    int drop = int(floor(fall));
    float behind = fract(fall) * spacing;
    float trail = spacing * mix(0.5, 0.9, random(column, drop, 6, 0));
    if (behind >= trail) return 0.0;
    // Some drops are bright enough that their trails clip to full green for a while.
    strength *= mix(0.8, 1.4, random(column, drop, 9, 0));

    // Fades evenly from the head to the end of the trail. The head is white for about
    // a row, then turns to the trail colour.
    float fade = 1.0 - behind / trail;
    float head = 1.0 - smoothstep(0.6, 1.3, behind);

    // Cells flip to a new glyph now and then, a few of them often; heads flicker.
    float flipRate = mix(0.15, 2.5, pow(random(column, row, 7, 0), 3.0));
    flipRate = mix(flipRate, 12.0, head);
    int flip = int(floor(u.time * flipRate + 10.0 * random(column, row, 8, 0)));
    uint2 range = scripts[min(uint(random(column, row, flip, 1) * float(u.scriptCount)), u.scriptCount - 1)];
    uint glyph = range.x + hash(column, row, flip, 2) % range.y;

    float2 uv = p / u.cell - cell;
    if (u.mirrored) uv.x = 1.0 - uv.x;

    // Sample at the mip level matching the glyph's size on screen, plus any blur.
    float2 atlasSize = float2(atlas.get_width(), atlas.get_height());
    float2 origin = float2(glyph % u.atlasColumns, glyph / u.atlasColumns) * u.atlasCell;
    float lod = max(log2(u.atlasCell.y / (u.cell.y * u.pointScale)), 0.0) + extraBlur + (far ? u.farBlur : 0.0);
    float ink = atlas.sample(linearClamp, (origin + uv * u.atlasCell) / atlasSize, level(lod)).r;
    // Blurred glyphs spill past their cell; fade them out before its edge.
    float2 edge = smoothstep(0.0, 0.06, min(uv, 1.0 - uv));
    ink *= edge.x * edge.y;

    float flicker = mix(0.8, 1.0, random(column, row, flip, 3));
    float3 tint = mix(u.trailColor.rgb * fade, u.headColor.rgb, head);
    return ink * strength * flicker * tint;
}

}

vertex RainVertexOut matrixVertex(uint vid [[vertex_id]]) {
    // One triangle that covers the target.
    float2 p = float2((vid << 1) & 2, vid & 2);
    RainVertexOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

/// The rain on its own at the glow's low resolution: what gets blurred into the glow.
fragment half4 matrixGlowSource(RainVertexOut in [[stage_in]],
                                constant RainUniforms &u [[buffer(0)]],
                                constant uint2 *scripts [[buffer(1)]],
                                texture2d<float> atlas [[texture(0)]])
{
    return half4(half3(rain(in.position.xy, u, scripts, atlas, 0.0)), 1.0h);
}

/// One direction of a Gaussian blur. `weights[i]` is the weight `i` texels from the
/// centre; they add up to 1 over both sides.
fragment half4 matrixGlowBlur(RainVertexOut in [[stage_in]],
                              constant BlurStep &step [[buffer(0)]],
                              constant float *weights [[buffer(1)]],
                              texture2d<half> source [[texture(0)]])
{
    int2 p = int2(in.position.xy);
    int2 last = int2(source.get_width(), source.get_height()) - 1;
    half4 sum = 0.0h;
    for (int i = -step.radius; i <= step.radius; i++) {
        int2 q = clamp(p + step.direction * i, int2(0), last);
        sum += source.read(uint2(q)) * half(weights[abs(i)]);
    }
    return sum;
}

/// The sharp rain plus its glow, into the drawable.
fragment half4 matrixComposite(RainVertexOut in [[stage_in]],
                               constant RainUniforms &u [[buffer(0)]],
                               constant uint2 *scripts [[buffer(1)]],
                               texture2d<float> atlas [[texture(0)]],
                               texture2d<float> glow [[texture(1)]])
{
    float2 pixel = in.position.xy;
    float3 color = rain(pixel, u, scripts, atlas, u.softness)
                 + glow.sample(linearClamp, pixel / u.viewport).rgb * u.glowAmount;

    // Dither so the dark ends of the glow don't band.
    int2 ip = int2(pixel);
    color = saturate(color) + (random(ip.x, ip.y, 0, 9) - 0.5) / 255.0;
    return half4(half3(color), 1.0h);
}
