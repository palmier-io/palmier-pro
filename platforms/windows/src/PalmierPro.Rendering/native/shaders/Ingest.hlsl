// Decoded straight-alpha BGRA8 source -> premultiplied, gamma-encoded fp16 working texture.
// Mirrors the plan's "Render graph" ingest step exactly: YUV->RGB + range conversion already
// happened in MediaSource's CPU decode; this pass is a bit-depth widen + alpha premultiply
// ONLY — no gamma/EOTF transform (non-color-managed working space, matching
// CustomVideoCompositor's NSNull working color space on the Mac).
Texture2D<float4> SourceTex : register(t0);
SamplerState PointClamp : register(s0);

struct VSOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };

float4 PSMain(VSOut input) : SV_TARGET
{
    float4 straight = SourceTex.Sample(PointClamp, input.uv);
    return float4(straight.rgb * straight.a, straight.a);
}
