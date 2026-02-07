#if (SHADERPASS != SHADERPASS_DEPTH_ONLY && SHADERPASS != SHADERPASS_SHADOWS && SHADERPASS != SHADERPASS_TRANSPARENT_DEPTH_PREPASS && SHADERPASS != SHADERPASS_TRANSPARENT_DEPTH_POSTPASS)
#error SHADERPASS_is_not_correctly_define
#endif
#include "Packages/com.unity.render-pipelines.high-definition/Runtime/Material/NormalBuffer.hlsl"
#include "Packages/com.unity.render-pipelines.high-definition/Runtime/HanPiWater/Caustic/HPWaterCaustic.hlsl"
#include "Packages/com.unity.render-pipelines.high-definition/Runtime/RenderPipeline/ShaderPass/VertMesh.hlsl"
#if defined(WRITE_DECAL_BUFFER) && !defined(_DISABLE_DECALS)
#include "Packages/com.unity.render-pipelines.high-definition/Runtime/Material/Decal/DecalPrepassBuffer.hlsl"
#endif

PackedVaryingsType Vert(AttributesMesh inputMesh)
{
    VaryingsType varyingsType;

#if (SHADERPASS == SHADERPASS_DEPTH_ONLY) && defined(HAVE_RECURSIVE_RENDERING) && !defined(SCENESELECTIONPASS) && !defined(SCENEPICKINGPASS)
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

// 全局变量控制渲染模式：0=渲染gbuffer0（法线），1=渲染gbuffer1（吸收/散射）
int _RenderGbuffer1Only;

void Frag(PackedVaryingsToPS packedInput, out float4 gbuffer0 : SV_Target0)        
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

#if defined(_DEPTHOFFSET_ON) && !defined(SCENEPICKINGPASS)
    outputDepth = posInput.deviceDepth;


    #if SHADERPASS == SHADERPASS_SHADOWS
        // If we are using the depth offset and manually outputting depth, the slope-scale depth bias is not properly applied
        // we need to manually apply.
        float bias = max(abs(ddx(posInput.deviceDepth)), abs(ddy(posInput.deviceDepth))) * _SlopeScaleDepthBias;
        outputDepth += bias;
    #endif

#endif

    // Depth and Alpha to coverage
    #ifdef WRITE_MSAA_DEPTH
    // In case we are rendering in MSAA, reading the an MSAA depth buffer is way too expensive. To avoid that, we export the depth to a color buffer
    depthColor = packedInput.vmesh.positionCS.z;

    // Alpha channel is used for alpha to coverage
    depthColor.a = SharpenAlpha(builtinData.opacity, builtinData.alphaClipTreshold);
    #endif

    #if defined(WRITE_NORMAL_BUFFER)
    EncodeIntoNormalBuffer(ConvertSurfaceDataToNormalData(surfaceData), outNormalBuffer);
    #endif

    #if defined(WRITE_DECAL_BUFFER) && !defined(_DISABLE_DECALS)
    DecalPrepassData decalPrepassData;
    // We don't have the right to access SurfaceData in a shaderpass.
    // However it would be painful to have to add a function like ConvertSurfaceDataToDecalPrepassData() to every Material to return geomNormalWS anyway
    // Here we will put the constrain that any Material requiring to support Decal, will need to have geomNormalWS as member of surfaceData (and we already require normalWS anyway)
    decalPrepassData.geomNormalWS = surfaceData.geomNormalWS;
    decalPrepassData.decalLayerMask = GetMeshRenderingDecalLayer();
    EncodeIntoDecalPrepassBuffer(decalPrepassData, outDecalBuffer);
    #endif

    
    // 根据全局变量动态输出
    gbuffer0 = 0;
    
    if (_RenderGbuffer1Only == 0)
    {
        // 模式1：只渲染 gbuffer0（法线）
        NormalData normalData;
        normalData.normalWS = surfaceData.normalWS;
        normalData.perceptualRoughness = 1;//留着待用，现在暂时用1
        EncodeIntoNormalBuffer(normalData, gbuffer0);
    }
    else
    {
        // 模式2：只渲染 gbuffer1（吸收/散射）
        float3 absorptionColor = surfaceData.baseColor.rgb;
        float3 scatterColor = surfaceData.transmittanceColor.rgb;
        EncodeHPWaterCausticGBuffer(absorptionColor, scatterColor, gbuffer0);
    }
}
