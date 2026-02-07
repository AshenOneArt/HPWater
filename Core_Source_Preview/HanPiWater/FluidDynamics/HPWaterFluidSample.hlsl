#ifndef WAVE_HEIGHT_SAMPLE_INCLUDED
#define WAVE_HEIGHT_SAMPLE_INCLUDED

#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
#include "Packages/com.unity.render-pipelines.high-definition/Runtime/HanPiWater/HPWaterCommon.hlsl"
#define mySampler s_linear_clamp_sampler

TEXTURE2D(_HPWaterWaveHeightTexture);
float3 _HPWaterFluidDynamicsBoxCenter;
float3 _HPWaterFluidDynamicsBoxSize;

// 世界坐标转UV
float2 WorldPosToFluidUV(float3 worldPos)
{
    // 计算相对于Box中心的偏移
    float offsetX = worldPos.x - _HPWaterFluidDynamicsBoxCenter.x;
    float offsetZ = worldPos.z - _HPWaterFluidDynamicsBoxCenter.z;
    
    // 归一化到[0, 1]范围
    float u = (offsetX * rcp(_HPWaterFluidDynamicsBoxSize.x)) + 0.5;
    float v = (offsetZ * rcp(_HPWaterFluidDynamicsBoxSize.z)) + 0.5;
    
    return float2(u, v);
}

// 使用世界坐标采样波高
void HPWaterFluidHeight_float(float3 worldPos, out float waveHeight)
{
    float2 uv = WorldPosToFluidUV(worldPos);
    waveHeight = SAMPLE_TEXTURE2D_LOD(_HPWaterWaveHeightTexture, mySampler, uv, 0).r;
}

// 高度转法线
void HPWaterFluidHeightToNormal_float(float3 worldPosition, out float3 OutNormal)
{
    uint width, height;
    _HPWaterWaveHeightTexture.GetDimensions(width, height);

    float2 uv = WorldPosToFluidUV(worldPosition);
    // 偏移向量
    float2 offsetU = float2(rcp(width), 0.0);
    float2 offsetV = float2(0.0, rcp(height));

    // 采样周围 4 个点的高度 (中心差分)
    float hLeft  = SAMPLE_TEXTURE2D(_HPWaterWaveHeightTexture, mySampler, uv - offsetU).r;
    float hRight = SAMPLE_TEXTURE2D(_HPWaterWaveHeightTexture, mySampler, uv + offsetU).r;
    float hDown  = SAMPLE_TEXTURE2D(_HPWaterWaveHeightTexture, mySampler, uv - offsetV).r;
    float hUp    = SAMPLE_TEXTURE2D(_HPWaterWaveHeightTexture, mySampler, uv + offsetV).r;

    // 世界尺寸
    float2 worldSize = _HPWaterFluidDynamicsBoxSize.xz * rcp(width);
    // 法线强度 : 1 / Δx
    float2 normalStrength = 1.0 * rcp(worldSize * 2);

    // 计算梯度 (斜率)
    float dX = (hLeft - hRight) * normalStrength.x;
    float dY = (hDown - hUp) * normalStrength.y;

    OutNormal = safeNormalize(float3(dX, 1.0, dY));
}

// 混合世界法线
void HPWaterFluidWorldNormalBlend_float(float3 normalInput1,float3 normalInput2, out float3 OutNormal)
{
    float2 xz = normalInput1.xz + normalInput2.xz;
    float y = normalInput1.y * normalInput2.y;
    OutNormal = safeNormalize(float3(xz.x, y, xz.y));
}



#endif