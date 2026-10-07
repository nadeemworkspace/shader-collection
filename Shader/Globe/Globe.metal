//
//  Globe.metal
//  Shader
//
//  A dotted globe, ray-cast per pixel. The sphere is covered by a lattice of dots laid
//  out in rows of latitude (each row holds as many dots as fit around it, so the poles
//  end in concentric rings). Each dot looks up the country under its centre in an
//  equirectangular country-ID map: land is brighter than sea, and countries can be
//  lit individually.
//
//  The selected country is drawn again on its own, much finer lattice, anchored on the
//  plane tangent to the globe at the country's centre, so it reads as a crisp square
//  grid once the camera has flown in. It is revealed by a soft disc growing out of its
//  centre, which dissolves into the country's shape.
//
//  Everything is worked out as an amount of ink (0 = paper), then blended between the
//  theme's paper and ink colours.
//

#include <metal_stdlib>
using namespace metal;

/// Mirrors `GlobeUniforms` in GlobeRenderer.swift; keep the field order in sync.
/// Lengths are in pixels unless noted; directions are in globe space (unit sphere).
struct GlobeUniforms {
    float3 eye;
    float3 right;
    float3 up;
    float3 back;                // from the globe's centre toward the camera
    float3 selectionCenter;
    float3 selectionEast;
    float3 selectionNorth;
    float3 paper;               // background colour
    float3 ink;                 // colour of full-strength dots
    float2 viewport;
    float2 focus;               // where the globe's centre projects
    float2 selectionScreen;     // where the selected country's centre projects
    float focal;
    float scale;                // pixels per point
    float globeRadius;          // projected radius of the sphere
    float rowStep;              // radians between dot rows
    float landLevel;
    float oceanLevel;
    float highlightLevel;
    float countryLevel;
    float boost;                // 0…1 while travelling: bigger, brighter dots
    float opacity;
    float selectionSpacing;     // fine lattice pitch, tangent-plane units
    float reveal;               // 0…1
    float revealRadius;         // size of the glowing disc, about the country's size
    float revealReach;          // how far the country's dots are uncovered (islands too)
    float markerRadius;         // ring around countries too small to see, 0 = none
    float dotGain;              // scales the ink of every dot
    float restLevel;            // ink the unpicked dots keep while a region is picked
    float highlightGrowth;      // how much bigger the picked region's dots get
    float regionFocus;          // 0…1, how lit the picked region is
    int selectedID;
};

struct GlobeVertexOut {
    float4 position [[position]];
};

namespace {

float3 sphereDirection(float latitude, float longitude) {
    return float3(cos(latitude) * sin(longitude), sin(latitude), cos(latitude) * cos(longitude));
}

uint countryAt(texture2d<uint> map, float3 p) {
    float longitude = atan2(p.x, p.z);
    float latitude = asin(clamp(p.y, -1.0, 1.0));
    float w = float(map.get_width());
    float h = float(map.get_height());
    uint x = uint(clamp((longitude + M_PI_F) / (2.0 * M_PI_F) * w, 0.0, w - 1.0));
    uint y = uint(clamp((M_PI_2_F - latitude) / M_PI_F * h, 0.0, h - 1.0));
    return map.read(uint2(x, y)).r;
}

/// Coverage of a disc of radius `r` at distance `d`, filtered over `aa`. Discs smaller
/// than the filter are drawn at the filter's size with proportionally less ink, so
/// distant dots fade instead of flickering.
float discCoverage(float d, float r, float aa) {
    float rr = max(r, aa);
    float c = 1.0 - smoothstep(rr - 0.5 * aa, rr + 0.5 * aa, d);
    return c * (r * r) / (rr * rr);
}

}

vertex GlobeVertexOut globeVertex(uint vid [[vertex_id]]) {
    // One triangle that covers the screen.
    float2 p = float2((vid << 1) & 2, vid & 2);
    GlobeVertexOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

fragment half4 globeFragment(GlobeVertexOut in [[stage_in]],
                             constant GlobeUniforms &u [[buffer(0)]],
                             constant float *highlight [[buffer(1)]],
                             texture2d<uint> map [[texture(0)]])
{
    float2 pixel = in.position.xy;
    float2 offset = pixel - u.focus;
    float limb = u.globeRadius - length(offset);     // > 0 inside the disc

    float3 dir = normalize(-u.back + (u.right * offset.x - u.up * offset.y) / u.focal);
    float b = dot(u.eye, dir);
    float h = b * b - (dot(u.eye, u.eye) - 1.0);

    if (h <= 0.0 || b >= 0.0) {
        // Off the globe: a wide soft halo and a tight glow hugging the edge.
        float outside = max(-limb, 0.0);
        float halo = 0.075 * exp(-outside / (30.0 * u.scale)) + 0.06 * exp(-outside / (3.0 * u.scale));
        return half4(half3(mix(u.paper, u.ink, halo * u.opacity)), 1.0h);
    }

    float t = -b - sqrt(h);
    float3 p = u.eye + t * dir;
    float facing = saturate(-dot(dir, p));
    float unitsPerPixel = t / u.focal;
    float aa = unitsPerPixel * (0.5 + 0.5 / max(facing, 0.15));

    // Body: barely inked, with a faint atmosphere and a thin rim at the edge.
    float fresnel = (1.0 - facing) * (1.0 - facing);
    float amount = 0.016 + 0.05 * fresnel * fresnel;
    amount += 0.22 * exp(-max(limb, 0.0) / (1.3 * u.scale));

    // Light from above and slightly in front, plus a lift toward the edge.
    float3 light = normalize(u.up * 0.6 + u.back * 0.8 - u.right * 0.15);
    float shade = (0.42 + 0.58 * saturate(dot(p, light))) * (1.0 + 0.6 * fresnel);

    // MARK: Base lattice

    float latitude = asin(clamp(p.y, -1.0, 1.0));
    float longitude = atan2(p.x, p.z);
    float row = round((latitude + M_PI_2_F) / u.rowStep);
    float rowLatitude = row * u.rowStep - M_PI_2_F;
    float count = max(1.0, round(2.0 * M_PI_F * cos(rowLatitude) / u.rowStep));
    float longitudeStep = 2.0 * M_PI_F / count;
    float3 dotCenter = sphereDirection(rowLatitude, round(longitude / longitudeStep) * longitudeStep);
    uint id = countryAt(map, dotCenter);

    // Dots fill about half the pitch but never grow past ~2 pt across on screen. While a
    // region is picked its dots take extra ink (and may grow) and the rest fade back.
    float lit = highlight[id];
    float maxRadius = (1.0 + 1.1 * u.boost) * u.scale * unitsPerPixel;
    float radius = min(0.26 * u.rowStep, maxRadius) * (1.0 + u.highlightGrowth * lit);
    float coverage = discCoverage(length(p - dotCenter), radius, aa);
    float rest = mix(1.0, u.restLevel, u.regionFocus * (1.0 - lit));
    float level = (id != 0 ? u.landLevel : u.oceanLevel) * rest + lit * u.highlightLevel;
    level *= shade * (1.0 + 1.2 * u.boost);

    // MARK: Selected country

    float selection = 0.0;
    if (u.selectedID > 0 && u.reveal > 0.0) {
        float distance = length(pixel - u.selectionScreen);

        // A soft disc grows from the centre; past ~40% the country's own dots take over
        // inside it while the disc and its bright rim fade.
        float grow = 1.0 - pow(1.0 - saturate(u.reveal / 0.6), 3.0);
        float radiusNow = grow * u.revealRadius;
        float soft = 0.28 * radiusNow + 2.0 * u.scale;
        float disc = 1.0 - smoothstep(radiusNow - soft, radiusNow, distance);
        float form = smoothstep(0.3, 0.85, u.reveal);
        float rimOffset = (distance - radiusNow + 0.5 * soft) / (0.35 * soft + u.scale);
        float rim = exp(-rimOffset * rimOffset);
        float fade = (1.0 - form) * smoothstep(0.0, 0.1, u.reveal);
        selection += (0.17 * disc + 0.24 * rim) * fade;

        float reachNow = grow * u.revealReach;
        float uncovered = 1.0 - smoothstep(0.75 * reachNow, reachNow, distance);

        float denominator = dot(p, u.selectionCenter);
        if (denominator > 0.1) {
            float3 g = p / denominator - u.selectionCenter;
            float2 uv = float2(dot(g, u.selectionEast), dot(g, u.selectionNorth));
            float2 cell = round(uv / u.selectionSpacing) * u.selectionSpacing;
            float3 cellCenter = normalize(u.selectionCenter + u.selectionEast * cell.x + u.selectionNorth * cell.y);
            if (countryAt(map, cellCenter) == uint(u.selectedID)) {
                float planeAA = aa / (denominator * denominator);
                float fine = discCoverage(length(uv - cell), 0.34 * u.selectionSpacing, planeAA);
                selection += fine * u.countryLevel * uncovered * form;
            }
        }

        // The coarse dots give way to the fine ones inside the country.
        if (countryAt(map, p) == uint(u.selectedID)) {
            coverage *= 1.0 - uncovered * form;
        }

        if (u.markerRadius > 0.0) {
            float ring = 1.0 - smoothstep(0.6 * u.scale, 1.5 * u.scale, abs(distance - u.markerRadius));
            selection += 0.55 * ring * form;
        }
    }

    amount += (coverage * level + selection) * u.dotGain;
    return half4(half3(mix(u.paper, u.ink, saturate(amount) * u.opacity)), 1.0h);
}
