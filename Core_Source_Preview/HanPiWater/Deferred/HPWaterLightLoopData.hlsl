#ifndef WATER_LIGHT_LOOP_DATA_DEFINED
#define WATER_LIGHT_LOOP_DATA_DEFINED
struct WaterLightLoopData
{
    float3 RelativeStartPos;
    float3 RelativeStartPosNoMatOffset;
    float3 RelativeRefractedEndPos;
    float3 NoLinearRayDirection;
    float3 AbsorptionCoefficient;
    float3 ScatterCoefficient;
    float2 RefractWaterScreenCoord;    
    float NoLinearRayLength;
    float NoLinearAmbientDepth;
    float NoLinearSunDepth; 
    float Dither;
};
#endif