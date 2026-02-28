#ifndef WATER_LIGHT_LOOP_DATA_DEFINED
#define WATER_LIGHT_LOOP_DATA_DEFINED
struct WaterLightLoopData
{
    float3 RelativeStartPos;
    float3 RelativeStartPosNoMatOffset;
    float3 RelativeRefractedEndPos;
    float3 NoLinearRayDirection;
    float3 NoLinearDynamicRayDirection;  // 线性射线方向（与 LinearRayDirection 一致，用于阴影采样）
    float3 LinearRayDirection;
    float3 AbsorptionCoefficient;
    float3 ScatterCoefficient;
    float2 RefractWaterScreenCoord;    
    float NoLinearRayLength;
    float NoLinearAmbientDepth;
    float NoLinearSunDepth; 
    float Dither;
    // 预计算的 Fresnel 透射率：入射(环境光进水)、出射(散射光出水)
    float3 FresnelTransmissionEntry;  // 1 - F0，环境光入射近似
    float3 FresnelTransmissionExit;   // 1 - F(NdotV)，散射光出射
};
#endif