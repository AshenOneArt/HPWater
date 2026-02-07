#if (SHADERPASS != SHADERPASS_HPWATER_FLUID_DYNAMICS)
#error SHADERPASS_is_not_correctly_define
#endif

#include "Packages/com.unity.render-pipelines.high-definition/Runtime/RenderPipeline/ShaderPass/VertMesh.hlsl"
#if defined(WRITE_DECAL_BUFFER) && !defined(_DISABLE_DECALS)
#include "Packages/com.unity.render-pipelines.high-definition/Runtime/Material/Decal/DecalPrepassBuffer.hlsl"
#endif

PackedVaryingsType Vert(AttributesMesh inputMesh)
{
    VaryingsType varyingsType;

#if (SHADERPASS == SHADERPASS_DEPTH_ONLY) && defined(HAVE_RECURSIVE_RENDERING) && !defined(SCENESELECTIONPASS) && !defined(SCENEPICKINGPASS)
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

#if defined(WRITE_NORMAL_BUFFER) && defined(WRITE_MSAA_DEPTH)
#define SV_TARGET_DECAL SV_Target2
#elif defined(WRITE_NORMAL_BUFFER) || defined(WRITE_MSAA_DEPTH)
#define SV_TARGET_DECAL SV_Target1
#else
#define SV_TARGET_DECAL SV_Target0
#endif

void Frag(  PackedVaryingsToPS packedInput
            #if defined(SCENESELECTIONPASS)
            , out float outColor : SV_Target0
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

#ifdef SCENESELECTIONPASS
    // 直接使用插值传递的世界坐标（input.positionRWS），它是在顶点着色器中
    // 通过 TransformObjectToWorld 计算的真实世界坐标，与相机矩阵无关
    outColor = input.positionRWS.y;
#else

    /* #if defined(WRITE_NORMAL_BUFFER)
    EncodeIntoNormalBuffer(ConvertSurfaceDataToNormalData(surfaceData), outNormalBuffer);
    #endif */

#endif
}
