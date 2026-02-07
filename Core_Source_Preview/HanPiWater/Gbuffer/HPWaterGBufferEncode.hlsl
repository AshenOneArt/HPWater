#ifndef HP_WATER_GBUFFER_INCLUDED
#define HP_WATER_GBUFFER_INCLUDED

#include "Packages/com.unity.render-pipelines.high-definition/Runtime/Material/NormalBuffer.hlsl"
// ============================================================================
// HPWater GBuffer 数据结构 (全部全分辨率，一次 3 MRT 绘制)
// ============================================================================
// GBuffer0: normalWS + roughness           - R8G8B8A8_UNorm
// GBuffer1: scatterColor (直接存储)        - R8G8B8A8_UNorm
// GBuffer2: absorptionColor (exp) + foam   - R8G8B8A8_UNorm (alpha = foam)
// ============================================================================

// 用于 GBuffer Pass 的表面数据 (编码前)
struct HPWaterSurfaceData
{
    float3 normalWS;
    float  perceptualRoughness;
    float  foam;
    float3 absorptionColor;     // 吸收系数 (原始值，将被 exp 编码)
    float3 scatterColor;        // 散射系数 (原始值，直接存储到 HDR 纹理)
};

// ============================================================================
// 编码函数 (GBuffer Pass 使用)
// ============================================================================

// 编码 GBuffer0: normalWS + roughness
void EncodeHPWaterGBuffer0(float3 normalWS, float perceptualRoughness, out float4 outGBuffer0)
{
    NormalData normalData;
    normalData.normalWS = normalWS;
    normalData.perceptualRoughness = perceptualRoughness;
    EncodeIntoNormalBuffer(normalData, outGBuffer0);
}

// 编码 GBuffer1: scatterColor (R8G8B8A8_SRGB格式)
void EncodeHPWaterGBuffer1(float3 scatterColor, out float4 outGBuffer1)
{
    outGBuffer1 = float4(scatterColor, 1.0);
}

// 编码 GBuffer2: absorptionColor + foam (alpha 通道) (R8G8B8A8_SRGB格式)
void EncodeHPWaterGBuffer2(float3 absorptionColor, float foam, out float4 outGBuffer2)
{
    // exp(-x) 编码，确保值在 [0,1] 范围内，alpha 存储 foam
    outGBuffer2 = float4(absorptionColor, saturate(foam));
}

// 一次性编码所有 GBuffer
void EncodeHPWaterGBuffer(
    HPWaterSurfaceData surfaceData,
    out float4 outGBuffer0,
    out float4 outGBuffer1,
    out float4 outGBuffer2)
{
    EncodeHPWaterGBuffer0(surfaceData.normalWS, surfaceData.perceptualRoughness, outGBuffer0);
    EncodeHPWaterGBuffer1(surfaceData.scatterColor, outGBuffer1);
    EncodeHPWaterGBuffer2(surfaceData.absorptionColor, surfaceData.foam, outGBuffer2);
}

#endif // HP_WATER_GBUFFER_INCLUDED

