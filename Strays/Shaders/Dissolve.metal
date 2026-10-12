// The card dissolve shown when something is stopped.
//
// A SwiftUI layer effect: SwiftUI hands us the rasterised card as `layer`
// and asks for the colour of each pixel. Pixels are discarded in an order
// set by a noise field, so the card breaks up rather than fading evenly,
// and the pixels about to go glow briefly like embers.
//
// Compiled by scripts/compile-shaders.sh into Strays.metallib. When the
// Metal toolchain is not installed the app falls back to a plain
// transition; see DissolveEffect.swift.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

// Smooth value noise in 0...1.
static float valueNoise(float2 p) {
    float2 cell = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(cell);
    float b = hash21(cell + float2(1.0, 0.0));
    float c = hash21(cell + float2(0.0, 1.0));
    float d = hash21(cell + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Two octaves: large blobs with a fine grain on top.
static float grain(float2 p) {
    return valueNoise(p) * 0.68 + valueNoise(p * 3.1 + 17.0) * 0.32;
}

// position: the pixel, in the layer's coordinate space (points).
// size:     the layer's size, in points.
// progress: 0 is the untouched card, 1 is nothing left.
[[ stitchable ]] half4 dissolve(float2 position, SwiftUI::Layer layer, float2 size, float progress) {
    half4 color = layer.sample(position);
    if (progress <= 0.0) {
        return color;
    }

    float2 uv = position / max(size, float2(1.0));

    // The dissolve travels from the top-right corner, where the Stop
    // button is, across the card.
    float sweep = (1.0 - uv.x) * 0.42 + uv.y * 0.22;
    float field = grain(position / 11.0) * 0.6 + sweep;

    // `remaining` is positive for pixels that are still there.
    float remaining = field - progress * 1.34;
    if (remaining < 0.0) {
        return half4(0.0);
    }

    // The band just ahead of the front glows warm, then is gone.
    float ember = 1.0 - smoothstep(0.0, 0.07, remaining);
    half3 glow = half3(1.0h, 0.58h, 0.26h) * half(ember) * color.a * half(1.0 - progress * 0.4);

    // Colours are premultiplied; adding light does not change coverage.
    return half4(color.rgb + glow, color.a);
}
