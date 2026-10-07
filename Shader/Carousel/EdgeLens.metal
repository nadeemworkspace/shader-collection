//
//  EdgeLens.metal
//  Shader
//
//  A screen-space "glass edge" for SwiftUI's `layerEffect`. Inside a band along the
//  left and right edges the layer is magnified toward the edge: vertically about a
//  centre line (the flare) and horizontally away from the band's inner border (the
//  streaks). Each pixel takes several taps whose strength varies with wavelength, so
//  hard edges split into a spectrum and content smears as it nears the edge.
//
//  The colour channels are averaged with different weights, which only yields a valid
//  premultiplied colour for an opaque layer, so apply it to a flattened, opaque view.
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

namespace {

/// Colour of one dispersion tap. Taps walk once around the hue wheel, starting just
/// short of red, so both the least and the most refracted taps are warm/magenta: that
/// puts a thin warm line against the card and a cooler band beyond it.
half3 spectralWeight(float s) {
    float hue = fract(0.92 + s);
    float3 w = saturate(0.5 + 0.5 * cos(2.0 * M_PI_F * (hue - float3(0.0, 1.0 / 3.0, 2.0 / 3.0))));
    return half3(w);
}

/// 0 at the band's inner border, 1 at the screen edge. Eases in quadratically and turns
/// linear past `knee`, which matches the flare measured from the reference recording.
float flareProfile(float t, float knee) {
    float ramp = t < knee ? t * t / (2.0 * knee) : t - 0.5 * knee;
    return ramp / (1.0 - 0.5 * knee);
}

}

/// - Parameters:
///   - bounds: the layer's bounding rect (`.boundingRect`).
///   - band: width of the refracting band on each side, in points.
///   - centerY: the line the vertical magnification is anchored to.
///   - verticalStrength: 0…1; 0.49 magnifies roughly 2× at the very edge.
///   - horizontalStrength: > 0; higher values pull more content into streaks.
///   - verticalDispersion / horizontalDispersion: how much the strength varies across
///     the spectrum on each axis. Vertical spread colours the flare's outline; keep the
///     horizontal one small so stretched content smears rather than splits.
[[ stitchable ]] half4 edgeLens(float2 position,
                                SwiftUI::Layer layer,
                                float4 bounds,
                                float band,
                                float centerY,
                                float verticalStrength,
                                float horizontalStrength,
                                float verticalDispersion,
                                float horizontalDispersion)
{
    float toLeft = position.x - bounds.x;
    float toRight = bounds.x + bounds.z - position.x;
    float distance = min(toLeft, toRight);
    if (distance >= band) {
        return layer.sample(position);
    }

    bool isLeft = toLeft < toRight;
    float innerX = isLeft ? bounds.x + band : bounds.x + bounds.z - band;
    float outward = isLeft ? -1.0 : 1.0;
    float t = 1.0 - distance / band;
    float flare = flareProfile(t, 0.3);

    constexpr int taps = 12;
    half3 color = 0.0h;
    half3 weight = 0.0h;
    half alpha = 0.0h;
    for (int i = 0; i < taps; i++) {
        float s = (float(i) + 0.5) / float(taps);
        float spread = s - 0.5;

        // band * (1 - e^(-a t)) / a: slope 1 at the border (no seam), ~0 at the edge.
        float a = horizontalStrength * (1.0 + horizontalDispersion * spread);
        float x = innerX + outward * band * (1.0 - exp(-a * t)) / a;
        float squeeze = verticalStrength * (1.0 + verticalDispersion * spread) * flare;
        float y = centerY + (position.y - centerY) * (1.0 - squeeze);

        half4 tap = layer.sample(float2(x, y));
        half3 w = spectralWeight(s);
        color += tap.rgb * w;
        weight += w;
        alpha += tap.a;
    }
    return half4(color / weight, alpha / half(taps));
}
