//
//  DrumWrap.metal
//  Shader
//
//  Wraps a flat strip of cards around the front of a vertical cylinder (the "drum"),
//  seen by a perspective camera. For each destination pixel we cast a ray at the
//  cylinder, turn the hit point into arc length and height on the surface, and sample
//  the flat strip there. Cards therefore bend with the drum instead of staying flat
//  panels, and the whole drum is a single pass.
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

/// - Parameters:
///   - center: the centre of the flat strip in the layer; also the screen point that
///     faces the camera head-on.
///   - radius: drum radius, in points.
///   - camera: distance from the camera to the front of the drum, in points.
///   - arcOffset: arc length from the front of the drum to the strip's centre
///     (positive turns the strip to the right).
///   - haze: colour cards fade toward as they turn away from the camera.
///   - hazeStrength: haze at 90° (0 disables it).
///   - blur: horizontal blur radius at 90°, in points; cards soften as they turn away,
///     like a shallow depth of field.
[[ stitchable ]] half4 drumWrap(float2 position,
                                SwiftUI::Layer layer,
                                float2 center,
                                float radius,
                                float camera,
                                float arcOffset,
                                half4 haze,
                                float hazeStrength,
                                float blur)
{
    // Work in units of the radius: eye at (0, 0, d), drum axis at z = -1, front at z = 0.
    float2 p = (position - center) / radius;
    float d = camera / radius;

    // Ray (t·p.x, t·p.y, d·(1 - t)) against x² + (z + 1)² = 1; nearest root.
    float discriminant = d * d - p.x * p.x * d * (d + 2.0);
    if (discriminant < 0.0) {
        return half4(0.0h);
    }
    float t = (d * (d + 1.0) - sqrt(discriminant)) / (p.x * p.x + d * d);

    float x = t * p.x;
    float z = d * (1.0 - t);
    float angle = atan2(x, z + 1.0);

    float2 local = float2(angle * radius - arcOffset, t * (position.y - center.y));
    float turn = 1.0 - cos(angle);

    // 5-tap tent filter along the card; collapses to one sample at the front.
    float spread = blur * turn * 0.5;
    half4 color = layer.sample(center + local) * 0.375h;
    color += layer.sample(center + local + float2(spread, 0.0)) * 0.25h;
    color += layer.sample(center + local - float2(spread, 0.0)) * 0.25h;
    color += layer.sample(center + local + float2(2.0 * spread, 0.0)) * 0.0625h;
    color += layer.sample(center + local - float2(2.0 * spread, 0.0)) * 0.0625h;

    half amount = half(hazeStrength * turn);
    return mix(color, half4(haze.rgb * color.a, color.a), amount);
}
