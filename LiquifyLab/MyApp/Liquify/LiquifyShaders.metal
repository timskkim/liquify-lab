#include <metal_stdlib>
using namespace metal;

struct CanvasVertexOut {
    float4 position [[position]];
    float2 uv;
};

// Keep this layout synchronized with LiquifyBrushStamp in Swift
struct BrushStamp {
    float2 location;
    float2 delta;
    float radius;
    float strength;
    float timelineTime;
};

// MARK: - Canvas rendering

vertex CanvasVertexOut canvasVertex(
    uint vertexID [[vertex_id]],
    constant float2 &aspectScale [[buffer(0)]])
{
    constexpr float2 positions[] = {
        {-1.0, -1.0}, { 1.0, -1.0}, {-1.0,  1.0},
        {-1.0,  1.0}, { 1.0, -1.0}, { 1.0,  1.0}
    };
    constexpr float2 uvs[] = {
        {0.0, 1.0}, {1.0, 1.0}, {0.0, 0.0},
        {0.0, 0.0}, {1.0, 1.0}, {1.0, 0.0}
    };

    CanvasVertexOut out;
    out.position = float4(positions[vertexID] * aspectScale, 0.0, 1.0);
    out.uv = uvs[vertexID];
    return out;
}

fragment float4 liquifyFragmentTier2(
    CanvasVertexOut in [[stage_in]],
    texture2d<float> source [[texture(0)]],
    texture2d<half> displacement [[texture(1)]],
    constant float &deformationMix [[buffer(0)]])
{
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 offset = float2(displacement.sample(linearSampler, in.uv).rg);
    return source.sample(linearSampler, clamp(in.uv - offset * deformationMix, 0.0, 1.0));
}

fragment float4 liquifyFragmentTier1(
    CanvasVertexOut in [[stage_in]],
    texture2d<float> source [[texture(0)]],
    texture2d<float> displacementX [[texture(1)]],
    texture2d<float> displacementY [[texture(2)]],
    constant float &deformationMix [[buffer(0)]])
{
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 offset = float2(
        displacementX.sample(linearSampler, in.uv).r,
        displacementY.sample(linearSampler, in.uv).r
    );
    return source.sample(linearSampler, clamp(in.uv - offset * deformationMix, 0.0, 1.0));
}

// MARK: - Brush compute

kernel void applyLiquifyBrushTier2(
    texture2d<half, access::read_write> displacement [[texture(0)]],
    device const BrushStamp *stamps [[buffer(0)]],
    constant uint &stampCount [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= displacement.get_width() || gid.y >= displacement.get_height()) {
        return;
    }

    float2 size = float2(displacement.get_width(), displacement.get_height());
    float2 uv = (float2(gid) + 0.5) / size;
    float2 updated = float2(displacement.read(gid).rg);

    for (uint index = 0; index < stampCount; ++index) {
        BrushStamp stamp = stamps[index];
        float distanceFromBrush = distance(uv, stamp.location);
        float falloff = 1.0 - smoothstep(0.0, stamp.radius, distanceFromBrush);
        // Apply smoothstep again to flatten the falloff near the brush center and edge
        falloff = falloff * falloff * (3.0 - 2.0 * falloff);
        updated += stamp.delta * falloff * stamp.strength;
    }

    displacement.write(half4(half2(updated), 0.0h, 1.0h), gid);
}

kernel void applyLiquifyBrushTier1(
    texture2d<float, access::read_write> displacementX [[texture(0)]],
    texture2d<float, access::read_write> displacementY [[texture(1)]],
    device const BrushStamp *stamps [[buffer(0)]],
    constant uint &stampCount [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= displacementX.get_width() || gid.y >= displacementX.get_height()) {
        return;
    }

    float2 size = float2(displacementX.get_width(), displacementX.get_height());
    float2 uv = (float2(gid) + 0.5) / size;
    float2 updated = float2(displacementX.read(gid).r, displacementY.read(gid).r);

    for (uint index = 0; index < stampCount; ++index) {
        BrushStamp stamp = stamps[index];
        float distanceFromBrush = distance(uv, stamp.location);
        float falloff = 1.0 - smoothstep(0.0, stamp.radius, distanceFromBrush);
        // Apply smoothstep again to flatten the falloff near the brush center and edge
        falloff = falloff * falloff * (3.0 - 2.0 * falloff);
        updated += stamp.delta * falloff * stamp.strength;
    }

    displacementX.write(float4(updated.x, 0.0, 0.0, 1.0), gid);
    displacementY.write(float4(updated.y, 0.0, 0.0, 1.0), gid);
}

// MARK: - Field clearing

kernel void clearDisplacementTier2(
    texture2d<half, access::write> displacement [[texture(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x < displacement.get_width() && gid.y < displacement.get_height()) {
        displacement.write(half4(0.0h), gid);
    }
}

kernel void clearDisplacementTier1(
    texture2d<float, access::write> displacementX [[texture(0)]],
    texture2d<float, access::write> displacementY [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x < displacementX.get_width() && gid.y < displacementX.get_height()) {
        displacementX.write(float4(0.0), gid);
        displacementY.write(float4(0.0), gid);
    }
}
