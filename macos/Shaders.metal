#include <metal_stdlib>
using namespace metal;

// ============================================================
// Shared structures (must match Swift-side layout exactly)
// ============================================================

struct CellInstance {
    packed_float2 position;   // pixel position (x, y) in points
    packed_float2 uvOrigin;   // atlas UV origin
    packed_float3 color;      // RGB (0..1)
};

struct GridUniforms {
    float2 viewSize;          // view bounds in points
    float2 cellSize;          // cell size in points
    float2 uvCellSize;        // UV size of one atlas cell
};

struct CompositeUniforms {
    float bloomIntensity;
    float scanlineIntensity;
    float distortionStrength;
    float vignetteStrength;
    float viewHeightPixels;
    float backgroundAlpha;
    float hasBackground;
    float backgroundDarkness;
};

// ============================================================
// Grid rendering — instanced textured quads
// ============================================================

struct GridVertexOut {
    float4 position [[position]];
    float2 uv;
    float3 color;
};

vertex GridVertexOut grid_vertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    constant CellInstance *instances [[buffer(0)]],
    constant GridUniforms &uniforms [[buffer(1)]]
) {
    const float2 corners[4] = {
        float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1)
    };
    float2 corner = corners[vid];

    CellInstance inst = instances[iid];
    float2 pos = float2(inst.position) + corner * uniforms.cellSize;

    // Points to NDC, top-left origin
    float2 ndc;
    ndc.x = pos.x / uniforms.viewSize.x * 2.0 - 1.0;
    ndc.y = 1.0 - pos.y / uniforms.viewSize.y * 2.0;

    GridVertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.uv = float2(inst.uvOrigin) + corner * uniforms.uvCellSize;
    out.color = float3(inst.color);
    return out;
}

fragment float4 grid_fragment(
    GridVertexOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float alpha = atlas.sample(s, in.uv).a;
    return float4(in.color * alpha, alpha);
}

// ============================================================
// Fullscreen quad — shared vertex shader for post-processing
// ============================================================

struct FullscreenOut {
    float4 position [[position]];
    float2 uv;
};

vertex FullscreenOut fullscreen_vertex(uint vid [[vertex_id]]) {
    const float2 positions[4] = {
        float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1)
    };
    const float2 uvs[4] = {
        float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0)
    };

    FullscreenOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
}

// ============================================================
// Phosphor persistence — smooth fading via temporal decay
// ============================================================

fragment float4 phosphor_fragment(
    FullscreenOut in [[stage_in]],
    texture2d<float> freshTex [[texture(0)]],
    texture2d<float> prevTex  [[texture(1)]],
    constant float &decay [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 fresh = freshTex.sample(s, in.uv);
    float4 prev  = prevTex.sample(s, in.uv) * decay;
    return max(fresh, prev);
}

// ============================================================
// Bloom — bright-pass extraction
// ============================================================

fragment float4 bloom_bright_fragment(
    FullscreenOut in [[stage_in]],
    texture2d<float> scene [[texture(0)]],
    constant float &threshold [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 color = scene.sample(s, in.uv);
    float brightness = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
    return brightness > threshold ? color : float4(0);
}

// ============================================================
// Gaussian blur — 9-tap, direction passed as uniform
// ============================================================

fragment float4 blur_fragment(
    FullscreenOut in [[stage_in]],
    texture2d<float> source [[texture(0)]],
    constant float2 &direction [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    const float weights[5] = {0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216};

    float4 result = source.sample(s, in.uv) * weights[0];
    for (int i = 1; i < 5; i++) {
        result += source.sample(s, in.uv + direction * float(i)) * weights[i];
        result += source.sample(s, in.uv - direction * float(i)) * weights[i];
    }
    return result;
}

// ============================================================
// CRT composite — bloom + barrel distortion + scanlines + vignette
// ============================================================

static float2 barrel_distort(float2 uv, float k) {
    float2 centered = uv - 0.5;
    float r2 = dot(centered, centered);
    return centered * (1.0 + k * r2) + 0.5;
}

fragment float4 composite_fragment(
    FullscreenOut in [[stage_in]],
    texture2d<float> scene [[texture(0)]],
    texture2d<float> bloom [[texture(1)]],
    texture2d<float> background [[texture(2)]],
    constant CompositeUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float2 uv = in.uv;

    // Barrel distortion
    if (uniforms.distortionStrength > 0) {
        uv = barrel_distort(uv, uniforms.distortionStrength);
        if (uv.x < 0 || uv.x > 1 || uv.y < 0 || uv.y > 1) {
            discard_fragment();
        }
    }

    // Scene + bloom
    float4 color = scene.sample(s, uv);
    if (uniforms.bloomIntensity > 0) {
        color.rgb += bloom.sample(s, uv).rgb * uniforms.bloomIntensity;
    }

    // Preserve alpha through CRT effects
    float alpha = color.a;

    // Scanlines
    if (uniforms.scanlineIntensity > 0) {
        float line = sin(uv.y * uniforms.viewHeightPixels * 3.14159);
        color.rgb *= 1.0 - uniforms.scanlineIntensity * (1.0 - line * line);
    }

    // Vignette
    if (uniforms.vignetteStrength > 0) {
        float2 vigUV = (uv - 0.5) * 2.0;
        color.rgb *= clamp(1.0 - uniforms.vignetteStrength * dot(vigUV, vigUV), 0.0f, 1.0f);
    }

    // Background compositing
    if (uniforms.hasBackground > 0.5) {
        float4 bg = background.sample(s, uv);
        bg.rgb *= (1.0 - uniforms.backgroundDarkness);
        color = float4(bg.rgb * (1.0 - color.a) + color.rgb, 1.0);
    } else {
        color.a = max(alpha, uniforms.backgroundAlpha);
    }
    return color;
}

// ============================================================
// Blit — passthrough for CoreText bitmap (Y-flipped)
// ============================================================

fragment float4 blit_fragment(
    FullscreenOut in [[stage_in]],
    texture2d<float> source [[texture(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return source.sample(s, float2(in.uv.x, 1.0 - in.uv.y));
}
