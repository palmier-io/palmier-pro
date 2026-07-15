// Full-screen-triangle vertex shader shared by every pixel-shader pass (ingest, all 11
// kernels, composite) — identical technique to D3D11Presenter.cpp's swap-chain blit VS. No
// vertex/index buffer: three vertices synthesized from SV_VertexID. UV is [0,1]^2 with (0,0)
// at the top-left, matching D3D11's texture-space convention directly.
struct VSOut
{
    float4 pos : SV_POSITION;
    float2 uv : TEXCOORD0;
};

VSOut VSMain(uint id : SV_VertexID)
{
    VSOut o;
    float2 uv = float2((id << 1) & 2, id & 2);
    o.uv = uv;
    o.pos = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
    return o;
}
