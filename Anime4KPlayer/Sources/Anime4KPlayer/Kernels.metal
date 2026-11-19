#include <metal_stdlib>
using namespace metal;

// rgb = m * (float3(Y, Cb, Cr) - offset); range scaling is folded into m (see YCbCrParams.swift).
struct YCbCrParams {
    float3x3 m;
    float3 offset;
};

// Bi-planar 4:2:0 (NV12 / P010-style) -> RGB. Planes come straight from the decoder's
// IOSurface via CVMetalTextureCache (no CPU copy). 10-bit planes are r16/rg16Unorm.
kernel void IngestBiPlanar(texture2d<float, access::read>   lumaTex   [[texture(0)]],
                           texture2d<float, access::sample> chromaTex [[texture(1)]],
                           texture2d<float, access::write>  outTex    [[texture(2)]],
                           constant YCbCrParams &p                    [[buffer(0)]],
                           uint2 gid                                  [[thread_position_in_grid]])
{
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float y = lumaTex.read(gid).r;
    float2 uv = (float2(gid) + 0.5) / float2(outTex.get_width(), outTex.get_height());
    float2 cbcr = chromaTex.sample(s, uv).rg;
    float3 rgb = p.m * (float3(y, cbcr) - p.offset);
    outTex.write(float4(saturate(rgb), 1.0), gid);
}

// Resample the model output to exactly the output buffer size (the output buffer already has
// the on-screen aspect ratio, including non-square source pixels), bicubic.
kernel void ResizeFill(texture2d<float, access::sample> src [[texture(0)]],
                       texture2d<float, access::write>  dst [[texture(1)]],
                       uint2 gid                            [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::bicubic);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    dst.write(saturate(src.sample(s, uv)), gid);
}
