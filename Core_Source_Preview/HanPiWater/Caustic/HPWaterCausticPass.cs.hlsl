//
// This file was automatically generated. Please don't edit by hand. Execute Editor command [ Edit > Rendering > Generate Shader Includes ] instead
//

#ifndef HPWATERCAUSTICPASS_CS_HLSL
#define HPWATERCAUSTICPASS_CS_HLSL
// Generated from UnityEngine.Rendering.HighDefinition.HDRenderPipeline+CausticComputeParams
// PackingRules = Exact
CBUFFER_START(CausticComputeParams)
    uint _CascadeCount;
    float _ForwardRandomOffset;
    float _CrossDistance;
    float _CausticIntensity;
    float _DispersionStrength;
    float _unused1;
    float _unused2;
    float _unused3;
    float4 _MainLightDirection;
    float4 _WaterCascadeAtlasSize;
    float4 _WaterCascadeAtlasOffsetsAndSizes[4];
    float4x4 _WaterCascadeAtlasVPInverse[4];
    float4x4 _WaterCascadeAtlasVP[4];
    float4 _WaterCascadeDepthRanges[4];
CBUFFER_END


#endif
