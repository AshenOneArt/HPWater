#ifndef SHADERPASS_HPWATER_GBUFFER
#define SHADERPASS_HPWATER_GBUFFER
#endif

#include "Packages/com.unity.render-pipelines.high-definition/Runtime/RenderPipeline/ShaderPass/VertMesh.hlsl"
#include "Packages/com.unity.render-pipelines.high-definition/Runtime/HanPiWater/Gbuffer/HPWaterGBufferEncode.hlsl"

PackedVaryingsType Vert(AttributesMesh inputMesh)
{
    VaryingsType varyingsType;

#if defined(HAVE_RECURSIVE_RENDERING)
    // If we have a recursive raytrace object, we will not render it.
    // As we don't want to rely on renderqueue to exclude the object from the list,
    // we cull it by settings position to NaN value.
    // TODO: provide a solution to filter dyanmically recursive raytrace object in the DrawRenderer
    if (_EnableRecursiveRayTracing && _RayTracing > 0.0)
    {
        ZERO_INITIALIZE(VaryingsType, varyingsType); // Divide by 0 should produce a NaN and thus cull the primitive.
    }
    else
#endif
    {
        varyingsType.vmesh = VertMesh(inputMesh);
    }

    return PackVaryingsType(varyingsType);
}

#ifdef TESSELLATION_ON

PackedVaryingsToPS VertTesselation(VaryingsToDS input)
{
    VaryingsToPS output;
    output.vmesh = VertMeshTesselation(input.vmesh);
    return PackVaryingsToPS(output);
}

#include "Packages/com.unity.render-pipelines.high-definition/Runtime/RenderPipeline/ShaderPass/TessellationShare.hlsl"

#endif // TESSELLATION_ON

// HPWater GBuffer 输出结构 (3 MRT)
struct HPWaterGBufferOutput
{
    float4 gbuffer0 : SV_Target0;   // normalWS + roughness
    float4 gbuffer1 : SV_Target1;   // scatterColor
    float4 gbuffer2 : SV_Target2;   // absorptionColor + foam (alpha)
};

HPWaterGBufferOutput Frag(PackedVaryingsToPS packedInput
    #ifdef _DEPTHOFFSET_ON
    , out float outputDepth : DEPTH_OFFSET_SEMANTIC
    #endif
    )
{
    UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(packedInput);
    FragInputs input = UnpackVaryingsToFragInputs(packedInput);

    // input.positionSS is SV_Position
    PositionInputs posInput = GetPositionInput(input.positionSS.xy, _ScreenSize.zw, input.positionSS.z, input.positionSS.w, input.positionRWS);

#ifdef VARYINGS_NEED_POSITION_WS
    float3 V = GetWorldSpaceNormalizeViewDir(input.positionRWS);
#else
    // Unused
    float3 V = float3(1.0, 1.0, 1.0); // Avoid the division by 0
#endif

    SurfaceData surfaceData;
    BuiltinData builtinData;
    GetSurfaceAndBuiltinData(input, V, posInput, surfaceData, builtinData);

    // 填充 HPWaterSurfaceData
    HPWaterSurfaceData waterSurfaceData;
    waterSurfaceData.normalWS = surfaceData.normalWS;
    waterSurfaceData.perceptualRoughness = PerceptualSmoothnessToPerceptualRoughness(surfaceData.perceptualSmoothness);
    waterSurfaceData.foam = surfaceData.metallic;  // foam 存储在 metallic 中
    waterSurfaceData.scatterColor = surfaceData.transmittanceColor;  // scatter 系数
    waterSurfaceData.absorptionColor = surfaceData.baseColor;  // absorption 系数

    // 编码到 GBuffer (3 个)
    HPWaterGBufferOutput output;
    EncodeHPWaterGBuffer(waterSurfaceData, output.gbuffer0, output.gbuffer1, output.gbuffer2);

#ifdef _DEPTHOFFSET_ON
    outputDepth = posInput.deviceDepth;
#endif

    return output;
}
