//
//  Spotlight.metal
//  Shader
//
//  Two `colorEffect` shaders for the offer spotlight:
//
//  - spotlightBackdrop: everything behind the card in one pass. A dimming scrim, a
//    sunburst of light wedges turning around the card, and a warm glow that hugs the
//    card's rounded outline. The rays and glow add light on top of the scrim.
//  - shimmerSweep: a glint that crosses a shape, a soft diagonal band with a bright
//    core line.
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

namespace {

/// Signed distance from `p` to a rounded rectangle centred on the origin.
float roundedRectDistance(float2 p, float2 halfSize, float radius) {
    float2 q = abs(p) - halfSize + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

}

/// Apply to a shape that fills the screen. The result is premultiplied, with the rays
/// and glow added on top of the scrim, so they brighten whatever is underneath.
///
/// - Parameters:
///   - card: the card's frame (x, y, width, height) in the shape's coordinates. Rays
///     radiate from its centre and the glow follows its outline.
///   - cornerRadius: the card's corner radius.
///   - rays: number of light wedges. They take up half of the circle.
///   - rotation: how far the sunburst has turned clockwise, in radians.
///   - scrim: the dimming colour (straight alpha).
///   - rayStrength: light added inside a wedge.
///   - glow: light added at the card's edge.
///   - glowLength: how far the glow reaches, in points.
[[ stitchable ]] half4 spotlightBackdrop(float2 position,
                                         half4 color,
                                         float4 card,
                                         float cornerRadius,
                                         float rays,
                                         float rotation,
                                         half4 scrim,
                                         float rayStrength,
                                         half4 glow,
                                         float glowLength)
{
    float2 halfSize = card.zw * 0.5;
    float2 d = position - (card.xy + halfSize);
    float r = length(d);

    // y points down, so angles grow clockwise. Light wedges are where `wedge` > 0 and
    // it is 0 on their edges; one point at this radius spans `pixel` of it.
    float turns = (atan2(d.y, d.x) - rotation) * rays / (2.0 * M_PI_F);
    float wedge = 0.25 - abs(fract(turns + 0.25) - 0.5);
    float pixel = rays / (2.0 * M_PI_F * max(r, 1.0));
    float light = smoothstep(-pixel, pixel, wedge);
    // The wedges converge under the card; fade them there so they never alias.
    light *= saturate(r / 40.0);

    float edge = max(roundedRectDistance(d, halfSize, cornerRadius), 0.0);
    float falloff = exp(-pow(edge / glowLength, 1.5));

    half3 rgb = scrim.rgb * scrim.a
              + half(rayStrength * light)
              + glow.rgb * half(falloff);
    return half4(rgb, scrim.a);
}

/// Apply to a shape filled with white. Returns premultiplied white, inside the shape
/// only, along a band leaning like "/".
///
/// - Parameters:
///   - bounds: the shape's bounding rect (`.boundingRect`).
///   - progress: 0 puts the band just left of the shape, 1 just right of it.
///   - slant: horizontal lean of the band per point of height.
///   - bandWidth: width of the soft band, in points.
///   - intensity: peak opacity of the glint.
[[ stitchable ]] half4 shimmerSweep(float2 position,
                                    half4 color,
                                    float4 bounds,
                                    float progress,
                                    float slant,
                                    float bandWidth,
                                    float intensity)
{
    // Horizontal distance from the band's centre line.
    float2 p = position - bounds.xy;
    float2 size = bounds.zw;
    float lean = slant * size.y * 0.5;
    float start = -lean - 2.0 * bandWidth;
    float travel = size.x + 2.0 * lean + 4.0 * bandWidth;
    float x = p.x + slant * (p.y - size.y * 0.5) - (start + progress * travel);

    float sigma = bandWidth * 0.3;
    float band = exp(-x * x / (2.0 * sigma * sigma));
    float coreX = x - bandWidth * 0.15;
    float coreSigma = bandWidth * 0.08;
    float core = exp(-coreX * coreX / (2.0 * coreSigma * coreSigma));

    half amount = half(saturate(intensity * (0.8 * band + 0.4 * core)));
    return half4(amount) * color.a;
}
