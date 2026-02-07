#ifndef BASE_DEFERRED_CAUSTIC_SAMPLING_INCLUDED
#define BASE_DEFERRED_CAUSTIC_SAMPLING_INCLUDED

#include "Packages/com.unity.render-pipelines.high-definition/Runtime/HanPiWater/HPWaterGlobalShaderVariable.cs.hlsl"
#include "Packages/com.unity.render-pipelines.high-definition/Runtime/HanPiWater/Caustic/HPWaterCausticPass.cs.hlsl"

// 焦散纹理（uint 格式）
Texture2D<uint> _CausticCascadeAtlas_R; // RGB 模式：三张 R32_SInt
Texture2D<uint> _CausticCascadeAtlas_G;
Texture2D<uint> _CausticCascadeAtlas_B;
Texture2D<float> _CausticCascadeAtlas_Float; // 单通道模式：一张 R32_SInt

TEXTURE2D(_WaterCascadeAtlas);//水面深度级联纹理
TEXTURE2D(_WaterNormalAtlas);//水面法线纹理
Texture2D<float2> _WaterGbuffer1Atlas;//吸收/散射纹理，低分辨率
Texture2D<float> _WaterCascadeDepth1Atlas;//低分辨率深度，用于 Decode 双边上采样



#include "Packages/com.unity.render-pipelines.high-definition/Runtime/HanPiWater/Caustic/HPWaterCaustic.hlsl"
#include "Packages/com.unity.render-pipelines.high-definition/Runtime/HanPiWater/Caustic/HPWaterCausticSampleFunction.hlsl"

#endif
