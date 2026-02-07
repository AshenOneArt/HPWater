#ifndef HPWATERCAUSTIC_INCLUDED
#define HPWATERCAUSTIC_INCLUDED

#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Color.hlsl"
#include "Packages/com.unity.render-pipelines.high-definition/Runtime/HanPiWater/HPWaterCommon.hlsl"
#include "Packages/com.unity.render-pipelines.high-definition/Runtime/HanPiWater/Caustic/HPWaterCausticPass.cs.hlsl"

#define SACTTER_DECODE_SCALE 0.1

// 根据图集 UV 坐标确定级联索引
int GetCascadeIndexFromAtlasUV(float2 atlasUV, float atlasSize)
{
    // 将 UV 坐标转换为像素坐标
    float2 pixelCoord = atlasUV * atlasSize;
    
    // 遍历级联，检查当前像素属于哪个级联
    for (int i = 0; i < (int)_CascadeCount; i++)
    {
        float4 offsetAndSize = _WaterCascadeAtlasOffsetsAndSizes[i];
        float2 cascadeMin = offsetAndSize.xy;
        float2 cascadeMax = offsetAndSize.xy + offsetAndSize.zw;
        
        // 检查像素是否在当前级联的边界内
        if (pixelCoord.x >= cascadeMin.x && pixelCoord.x < cascadeMax.x &&
            pixelCoord.y >= cascadeMin.y && pixelCoord.y < cascadeMax.y)
        {
            return i;
        }
    }
    
    // 如果没有找到，返回 0（默认第一个级联）
    return 0;
}

// 将归一化深度（0-1）转换为视图空间深度（米）
float NormalizedDepthToMeters(float normalizedDepth, int cascadeIndex)
{
    float4 depthRange = _WaterCascadeDepthRanges[cascadeIndex];
    float near = depthRange.x;
    float far = depthRange.y;
    
    #if UNITY_REVERSED_Z
        // Reversed-Z: 1.0 = near, 0.0 = far
        return lerp(far, near, normalizedDepth);
    #else
        // Standard: 0.0 = near, 1.0 = far
        return lerp(near, far, normalizedDepth);
    #endif
}


void EncodeHPWaterCausticGBuffer(float3 absorptionColor, float3 scatterColor, out float4 outGBuffer0)
{
    float absorptionValue = Luminance(absorptionColor);
    float scatterValue = Luminance(scatterColor);
    float2 dateEncode;
    dateEncode.r = FastLinearToSRGB(absorptionValue);
    dateEncode.g = FastLinearToSRGB(scatterValue);
    outGBuffer0 = float4(dateEncode, 0, 0);
}

void DecodeHPWaterCausticGBuffer(float2 gbuffer, out float absorptionValue, out float scatterValue)
{
    // R8G8B8A8_UNorm 格式，读取SRGB空间值
    float2 dateDecode = gbuffer.rg;
    dateDecode.r = FastSRGBToLinear(dateDecode.r);
    dateDecode.g = FastSRGBToLinear(dateDecode.g);
    absorptionValue = dateDecode.r;
    scatterValue = dateDecode.g * SACTTER_DECODE_SCALE;
}

void DecodeHPWaterCausticGBufferUpsampling(texture2D<float2> lowResGbuffer,texture2D<float> lowResDepthTex, sampler lowResTexSampler,
float2 uv,float depth,uint highResSize, out float absorptionValue, out float scatterValue)
{
    // ========================================
    // 双边上采样 (Joint Bilateral Upsampling)采样低分辨率水体GBuffer
    // ========================================
    uint lowResDepthSizeX;
    lowResGbuffer.GetDimensions(lowResDepthSizeX, lowResDepthSizeX);

    // 计算分辨率比例
    float scale = float(lowResDepthSizeX) * rcp(float(max(highResSize, 1)));

    // 当前高分辨率像素对应的低分辨率纹理中心位置
    float2 lowResCenter = uv * highResSize * scale - 0.5;

    // 低分辨率的基础像素坐标（向下取整）
    int2 lowResBase = int2(floor(lowResCenter));
    float2 lowResFrac = frac(lowResCenter);

    // 采样 2x2 区域
    float4 lowResDepths = HP_GATHER_TEXTURE2D(lowResDepthTex, lowResTexSampler, uv);

    // 查询与全分辨率深度最接近的低分辨率像素
    float4 depthDiffs = abs(lowResDepths - depth);

    //是否平坦面，如果不是，则使用深度差值作为权重
    depthDiffs = any(depthDiffs > 1e-2) ? rcp(depthDiffs + 1e-6) : 1;

    // 双线性插值权重
    float wb00 = (1.0 - lowResFrac.x) * (1.0 - lowResFrac.y);
    float wb10 = lowResFrac.x * (1.0 - lowResFrac.y);
    float wb01 = (1.0 - lowResFrac.x) * lowResFrac.y;
    float wb11 = lowResFrac.x * lowResFrac.y;

    depthDiffs.x *= wb00;
    depthDiffs.y *= wb10;
    depthDiffs.z *= wb11;
    depthDiffs.w *= wb01;
    float totalWeight = depthDiffs.x + depthDiffs.y + depthDiffs.z + depthDiffs.w;
    float2 dateDecode = float2(1, 0);

    float4 lowReswaterGbuffer_X = HP_GATHER_TEXTURE2D(lowResGbuffer, lowResTexSampler, uv);
    dateDecode.r = (
        lowReswaterGbuffer_X.x * depthDiffs.x + lowReswaterGbuffer_X.y * depthDiffs.y + 
        lowReswaterGbuffer_X.z * depthDiffs.z + lowReswaterGbuffer_X.w * depthDiffs.w) * rcp(totalWeight);

    float4 lowReswaterGbuffer_Y = HP_GATHER_GREEN_TEXTURE2D(lowResGbuffer, lowResTexSampler, uv);
    dateDecode.g = (
        lowReswaterGbuffer_Y.x * depthDiffs.x + lowReswaterGbuffer_Y.y * depthDiffs.y + 
        lowReswaterGbuffer_Y.z * depthDiffs.z + lowReswaterGbuffer_Y.w * depthDiffs.w) * rcp(totalWeight);

    // R8G8B8A8_UNorm 格式，读取SRGB空间值
    dateDecode.r = FastSRGBToLinear(dateDecode.r);
    dateDecode.g = FastSRGBToLinear(dateDecode.g);
    absorptionValue = dateDecode.r;
    scatterValue = dateDecode.g * SACTTER_DECODE_SCALE;
}

#endif // HPWATERCAUSTIC_INCLUDED