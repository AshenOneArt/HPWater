//-----------------------------------------------------------------------------
// Includes
//-----------------------------------------------------------------------------

struct BSDFData
{
    real3 scatterColor;
    real3 absorptionColor;
    real fresnel0;
    float3 normalWS;
    real perceptualRoughness;
    uint diffusionProfileIndex;
    real roughness;
    real3 geomNormalWS;
    real thickness;
    real foam;
};

// Generated from UnityEngine.Rendering.HighDefinition.Lit+SurfaceData
// PackingRules = Exact
struct SurfaceData
{
    real3 scatterColor;
    real3 absorptionColor;
    float3 normalWS;
    real perceptualSmoothness;
    real3 geomNormalWS;
    real foam;
};

// Those define allow to include desired SSS/Transmission functions
#define MATERIAL_INCLUDE_SUBSURFACESCATTERING
#define MATERIAL_INCLUDE_TRANSMISSION
#include "Packages/com.unity.render-pipelines.high-definition/Runtime/Material/BuiltinGIUtilities.hlsl"
#include "Packages/com.unity.render-pipelines.high-definition/Runtime/Material/NormalBuffer.hlsl"
#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/VolumeRendering.hlsl"


//-----------------------------------------------------------------------------
// Configuration
//-----------------------------------------------------------------------------

// Choose between Lambert diffuse and Disney diffuse (enable only one of them)
// #define USE_DIFFUSE_LAMBERT_BRDF

#define LIT_USE_GGX_ENERGY_COMPENSATION

// Enable reference mode for IBL and area lights
// Both reference define below can be define only if LightLoop is present, else we get a compile error
#ifdef HAS_LIGHTLOOP
// #define LIT_DISPLAY_REFERENCE_AREA
// #define LIT_DISPLAY_REFERENCE_IBL
#endif

//-----------------------------------------------------------------------------
// Texture and constant buffer declaration
//-----------------------------------------------------------------------------

// HPWater GBuffer 纹理 (3 个)
TEXTURE2D_X(_HPWaterGBuffer0); // normalWS + roughness (全分辨率)
TEXTURE2D_X(_HPWaterGBuffer1); // scatterColor (全分辨率)
TEXTURE2D_X(_HPWaterGBuffer2); // absorptionColor + foam (全分辨率, exp 编码 + alpha=foam)
TEXTURE2D_X(_GBufferTexture3); // Bake lighting and/or emissive
TEXTURE2D_X(_GBufferTexture4); // VTFeedbakc or Light layer or shadow mask
TEXTURE2D_X(_GBufferTexture5); // Light layer or shadow mask
TEXTURE2D_X(_GBufferTexture6); // shadow mask


TEXTURE2D_X(_LightLayersTexture);
#ifdef SHADOWS_SHADOWMASK
TEXTURE2D_X(_ShadowMaskTexture); // Alias for shadow mask, so we don't need to know which gbuffer is used for shadow mask
#endif

#include "Packages/com.unity.render-pipelines.high-definition/Runtime/Material/LTCAreaLight/LTCAreaLight.hlsl"
#include "Packages/com.unity.render-pipelines.high-definition/Runtime/Material/PreIntegratedFGD/PreIntegratedFGD.hlsl"

//-----------------------------------------------------------------------------
// Definition
//-----------------------------------------------------------------------------

#ifdef UNITY_VIRTUAL_TEXTURING
    #define OUT_GBUFFER_VTFEEDBACK outGBuffer4
    #define OUT_GBUFFER_OPTIONAL_SLOT_1 outGBuffer5
    #define OUT_GBUFFER_OPTIONAL_SLOT_2 outGBuffer6
    #if (SHADERPASS == SHADERPASS_GBUFFER)
        #if defined(SHADER_API_PSSL)
            //For exact packing on pssl, we want to write exact 16 bit unorm (respect exact bit packing).
            //In some sony platforms, the default is FMT_16_ABGR, which would incur in loss of precision.
            //Thus, when VT is enabled, we force FMT_32_ABGR
            #pragma PSSL_target_output_format(target 4 FMT_32_ABGR)
        #endif
    #endif
#else
    #define OUT_GBUFFER_OPTIONAL_SLOT_1 outGBuffer4
    #define OUT_GBUFFER_OPTIONAL_SLOT_2 outGBuffer5
#endif

#if defined(LIGHT_LAYERS) && defined(SHADOWS_SHADOWMASK)
#define OUT_GBUFFER_LIGHT_LAYERS OUT_GBUFFER_OPTIONAL_SLOT_1
#define OUT_GBUFFER_SHADOWMASK OUT_GBUFFER_OPTIONAL_SLOT_2
#elif defined(LIGHT_LAYERS)
#define OUT_GBUFFER_LIGHT_LAYERS OUT_GBUFFER_OPTIONAL_SLOT_1
#elif defined(SHADOWS_SHADOWMASK)
#define OUT_GBUFFER_SHADOWMASK OUT_GBUFFER_OPTIONAL_SLOT_1
#endif

#define HAS_REFRACTION (defined(_REFRACTION_PLANE) || defined(_REFRACTION_SPHERE) || defined(_REFRACTION_THIN))

// It is safe to include this file after the G-Buffer macros above.
#include "Packages/com.unity.render-pipelines.high-definition/Runtime/Material/MaterialGBufferMacros.hlsl"

//-----------------------------------------------------------------------------
// Light and material classification for the deferred rendering path
// Configure what kind of combination is supported
//-----------------------------------------------------------------------------

// Lighting architecture and material are suppose to be decoupled files.
// However as we use material classification it is hard to be fully separated
// the dependecy is define in this include where there is shared define for material and lighting in case of deferred material.
// If a user do a lighting architecture without material classification, this can be remove
#include "Packages/com.unity.render-pipelines.high-definition/Runtime/Lighting/LightLoop/LightLoop.cs.hlsl"


//-----------------------------------------------------------------------------
// Helper functions/variable specific to this material
//-----------------------------------------------------------------------------

// This function return diffuse color or an equivalent color (in case of metal). Alpha channel is 0 is dieletric or 1 if metal, or in between value if it is in between
// This is use for MatCapView and reflection probe pass
// replace is 0.0 if we want diffuse color or 1.0 if we want default color
float4 GetDiffuseOrDefaultColor(BSDFData bsdfData, float replace)
{
    // Use frensel0 as mettalic weight. all value below 0.2 (ior of diamond) are dielectric
    // all value above 0.45 are metal, in between we lerp.
    float weight = saturate((Max3(bsdfData.fresnel0.r, bsdfData.fresnel0.r, bsdfData.fresnel0.r) - 0.2) / (0.45 - 0.2));

    return float4(lerp(float3(1,1,1), bsdfData.fresnel0, weight * replace), weight);
}

float3 GetNormalForShadowBias(BSDFData bsdfData)
{
    // In forward we can used geometric normal for shadow bias which improve quality
#if (SHADERPASS == SHADERPASS_FORWARD)
    return bsdfData.geomNormalWS;
#else
    return bsdfData.normalWS;
#endif
}

float GetAmbientOcclusionForMicroShadowing(BSDFData bsdfData)
{
    return 1;
}

#include "Packages/com.unity.render-pipelines.high-definition/Runtime/Lighting/LightDefinition.cs.hlsl"
#include "Packages/com.unity.render-pipelines.high-definition/Runtime/Lighting/Reflection/VolumeProjection.hlsl"
#include "Packages/com.unity.render-pipelines.high-definition/Runtime/Lighting/ScreenSpaceLighting/ScreenSpaceTracing.hlsl"
#include "Packages/com.unity.render-pipelines.high-definition/Runtime/Lighting/ScreenSpaceLighting/ScreenSpaceLighting.hlsl"
#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Refraction.hlsl"

#if HAS_REFRACTION
    // Note that this option is referred as "Box" in the UI, we are keeping _REFRACTION_PLANE as shader define to avoid complication with already created materials.
    #if defined(_REFRACTION_PLANE)
    #define REFRACTION_MODEL(V, posInputs, bsdfData) RefractionModelBox(V, posInputs.positionWS, bsdfData.normalWS, bsdfData.ior, bsdfData.thickness)
    #elif defined(_REFRACTION_SPHERE)
    #define REFRACTION_MODEL(V, posInputs, bsdfData) RefractionModelSphere(V, posInputs.positionWS, bsdfData.normalWS, bsdfData.ior, bsdfData.thickness)
    #elif defined(_REFRACTION_THIN)
    #define REFRACTION_THIN_DISTANCE 0.005
    #define REFRACTION_MODEL(V, posInputs, bsdfData) RefractionModelBox(V, posInputs.positionWS, bsdfData.normalWS, bsdfData.ior, bsdfData.thickness)
    #endif
#endif

// This function is use to help with debugging and must be implemented by any lit material
// Implementer must take into account what are the current override component and
// adjust SurfaceData properties accordingdly
void ApplyDebugToSurfaceData(float3x3 tangentToWorld, inout SurfaceData surfaceData)
{
#ifdef DEBUG_DISPLAY
    // Override value if requested by user
    // this can be use also in case of debug lighting mode like diffuse only
    bool overrideAlbedo = _DebugLightingAlbedo.x != 0.0;
    bool overrideSmoothness = _DebugLightingSmoothness.x != 0.0;
    bool overrideNormal = _DebugLightingNormal.x != 0.0;
    bool overrideAO = _DebugLightingAmbientOcclusion.x != 0.0;

    if (overrideAlbedo)
    {
        float3 overrideAlbedoValue = _DebugLightingAlbedo.yzw;
        surfaceData.baseColor = overrideAlbedoValue;
    }

    if (overrideSmoothness)
    {
        float overrideSmoothnessValue = _DebugLightingSmoothness.y;
        surfaceData.perceptualSmoothness = overrideSmoothnessValue;
    }

    if (overrideNormal)
    {
        surfaceData.normalWS = tangentToWorld[2];
    }

    if (overrideAO)
    {
        float overrideAOValue = _DebugLightingAmbientOcclusion.y;
        surfaceData.ambientOcclusion = overrideAOValue;
    }

    // There is no metallic with SSS and specular color mode
    float metallic = HasFlag(surfaceData.materialFeatures, MATERIALFEATUREFLAGS_LIT_SPECULAR_COLOR | MATERIALFEATUREFLAGS_LIT_SUBSURFACE_SCATTERING | MATERIALFEATUREFLAGS_LIT_TRANSMISSION) ? 0.0 : surfaceData.metallic;

    float3 diffuseColor = ComputeDiffuseColor(surfaceData.baseColor, metallic);
    bool specularWorkflow = HasFlag(surfaceData.materialFeatures, MATERIALFEATUREFLAGS_LIT_SPECULAR_COLOR);
    float3 specularColor =  specularWorkflow ? surfaceData.specularColor : ComputeFresnel0(surfaceData.baseColor, surfaceData.metallic, DEFAULT_SPECULAR_VALUE);

    if (_DebugFullScreenMode == FULLSCREENDEBUGMODE_VALIDATE_DIFFUSE_COLOR)
    {
        surfaceData.baseColor = pbrDiffuseColorValidate(diffuseColor, specularColor, metallic > 0.0, !specularWorkflow).xyz;
    }
    else if (_DebugFullScreenMode == FULLSCREENDEBUGMODE_VALIDATE_SPECULAR_COLOR)
    {
        surfaceData.baseColor = pbrSpecularColorValidate(diffuseColor, specularColor, metallic > 0.0, !specularWorkflow).xyz;
    }

#endif
}

// This function is similar to ApplyDebugToSurfaceData but for BSDFData
void ApplyDebugToBSDFData(inout BSDFData bsdfData)
{
#ifdef DEBUG_DISPLAY
    // Override value if requested by user
    // this can be use also in case of debug lighting mode like specular only
    bool overrideSpecularColor = _DebugLightingSpecularColor.x != 0.0;

    if (overrideSpecularColor)
    {
        float3 overrideSpecularColor = _DebugLightingSpecularColor.yzw;
        bsdfData.fresnel0 = overrideSpecularColor;
    }
#endif
}

NormalData ConvertSurfaceDataToNormalData(SurfaceData surfaceData)
{
    NormalData normalData;
    normalData.normalWS = surfaceData.normalWS;
    normalData.perceptualRoughness = PerceptualSmoothnessToPerceptualRoughness(surfaceData.perceptualSmoothness);
    return normalData;
}

void UpdateSurfaceDataFromNormalData(uint2 positionSS, inout BSDFData bsdfData)
{
    NormalData normalData;

    DecodeFromNormalBuffer(positionSS, normalData);

    bsdfData.normalWS = normalData.normalWS;
    bsdfData.perceptualRoughness = normalData.perceptualRoughness;
}

BSDFData ConvertSurfaceDataToBSDFData(uint2 positionSS, SurfaceData surfaceData)
{
    BSDFData bsdfData;
    ZERO_INITIALIZE(BSDFData, bsdfData);
    return bsdfData;
}


// ============================================================================
// 解码函数 (Compute Shader / Deferred Lighting 使用)
// ============================================================================

#define SACTTER_DECODE_SCALE 0.01
#define ABSORPTION_DECODE_SCALE 2

// 解码 GBuffer0: normalWS + roughness
void DecodeHPWaterGBuffer0(float4 gbuffer0, out float3 normalWS, out float roughness)
{
    NormalData normalData;
    DecodeFromNormalBuffer(gbuffer0, normalData);
    normalWS = normalData.normalWS;
    roughness = normalData.perceptualRoughness;
}

// 解码 GBuffer1: scatterColor (R8G8B8A8_UNorm)
void DecodeHPWaterGBuffer1(float4 gbuffer1, out float3 scatterColor, out float thickness)
{
    // R8G8B8A8_UNorm 格式，读取SRGB空间值
    scatterColor = gbuffer1.rgb * SACTTER_DECODE_SCALE;
    thickness = FastSRGBToLinear(gbuffer1.a);
}

// 解码 GBuffer2: absorptionColor + foam
void DecodeHPWaterGBuffer2(float4 gbuffer2, out float3 absorptionColor, out float foam)
{
    // -log(x) 解码，防止 log(0)
    absorptionColor = gbuffer2.rgb * ABSORPTION_DECODE_SCALE;
    foam = gbuffer2.a;
}

// 一次性解码所有 GBuffer 并填充 BSDFData
BSDFData DecodeHPWaterGBuffer(
    float4 gbuffer0,    // normalWS + roughness
    float4 gbuffer1,    // scatterColor
    float4 gbuffer2)    // absorptionColor (exp 编码) + foam (alpha)
{
    BSDFData bsdfData;
    
    // 解码 GBuffer0: normalWS + roughness
    DecodeHPWaterGBuffer0(gbuffer0, bsdfData.normalWS, bsdfData.roughness);
    
    // 解码 GBuffer1: scatterColor
    DecodeHPWaterGBuffer1(gbuffer1, bsdfData.scatterColor, bsdfData.thickness);
    
    // 解码 GBuffer2: absorptionColor + foam
    DecodeHPWaterGBuffer2(gbuffer2, bsdfData.absorptionColor, bsdfData.foam);
    
    return bsdfData;
}

// ============================================================================
// HPWater GBuffer 解码辅助函数
// ============================================================================

// 从屏幕坐标解码完整的 BSDFData
BSDFData DecodeHPWaterBSDFDataFromGBuffer(
    uint2 positionSS,
    TEXTURE2D_X_PARAM(texGBuffer0, samplerGBuffer0),  // 纹理 + 采样器
    TEXTURE2D_X_PARAM(texGBuffer1, samplerGBuffer1),
    TEXTURE2D_X_PARAM(texGBuffer2, samplerGBuffer2))
{
    BSDFData data;
    ZERO_INITIALIZE(BSDFData, data);
    
    // 加载 3 个 GBuffer
    float4 gb0 = LOAD_TEXTURE2D_X(texGBuffer0, positionSS);
    float4 gb1 = LOAD_TEXTURE2D_X(texGBuffer1, positionSS);
    float4 gb2 = LOAD_TEXTURE2D_X(texGBuffer2, positionSS);
    
    // 解码所有数据
    DecodeHPWaterGBuffer0(gb0, data.normalWS, data.roughness);
    DecodeHPWaterGBuffer1(gb1, data.scatterColor, data.thickness);
    DecodeHPWaterGBuffer2(gb2, data.absorptionColor, data.foam);
    
    return data;
}

// ============================================================================
// HPWater GBuffer 解码辅助函数 (双线性插值)
// ============================================================================

BSDFData DecodeHPWaterBSDFDataFromGBuffer_Bilinear(
    float2 positionNDC,
    TEXTURE2D_X_PARAM(texGBuffer0, samplerGBuffer0),  // 纹理 + 采样器
    TEXTURE2D_X_PARAM(texGBuffer1, samplerGBuffer1),
    TEXTURE2D_X_PARAM(texGBuffer2, samplerGBuffer2))
{
    BSDFData data;
    ZERO_INITIALIZE(BSDFData, data);
    
    // 加载 3 个 GBuffer
    float4 gb0 = SAMPLE_TEXTURE2D_X_LOD(texGBuffer0, samplerGBuffer0, positionNDC, 0);
    float4 gb1 = SAMPLE_TEXTURE2D_X_LOD(texGBuffer1, samplerGBuffer1, positionNDC, 0);
    float4 gb2 = SAMPLE_TEXTURE2D_X_LOD(texGBuffer2, samplerGBuffer2, positionNDC, 0);
    
    // 解码所有数据
    DecodeHPWaterGBuffer0(gb0, data.normalWS, data.roughness);
    DecodeHPWaterGBuffer1(gb1, data.scatterColor, data.thickness);
    DecodeHPWaterGBuffer2(gb2, data.absorptionColor, data.foam);
    
    return data;
}


void DecodeFromHPWaterGBuffer(uint2 positionSS, out BSDFData bsdfData, out BuiltinData builtinData)
{
    ZERO_INITIALIZE(BSDFData, bsdfData);
    ZERO_INITIALIZE(BuiltinData, builtinData);

    bsdfData = DecodeHPWaterBSDFDataFromGBuffer(positionSS,
    _HPWaterGBuffer0, s_linear_clamp_sampler,
    _HPWaterGBuffer1, s_linear_clamp_sampler,
    _HPWaterGBuffer2, s_linear_clamp_sampler);

    builtinData.renderingLayers = DEFAULT_LIGHT_LAYERS;
    builtinData.shadowMask0 = 1.0;
    builtinData.shadowMask1 = 1.0;
    builtinData.shadowMask2 = 1.0;
    builtinData.shadowMask3 = 1.0;
    builtinData.emissiveColor = 0.0;


    // Decompress feature-agnostic data from the G-Buffer.
    bsdfData.normalWS = safeNormalize(bsdfData.normalWS);
    // 水面 geomNormalWS 使用 normalWS（不再单独存储）
    bsdfData.geomNormalWS = bsdfData.normalWS;
    bsdfData.perceptualRoughness = RoughnessToPerceptualRoughness(bsdfData.roughness);
    bsdfData.fresnel0 = 0.02;

}


//-----------------------------------------------------------------------------
// PreLightData
//-----------------------------------------------------------------------------

// Precomputed lighting data to send to the various lighting functions
struct PreLightData
{
    float NdotV;                     // Could be negative due to normal mapping, use ClampNdotV()

    // GGX
    float partLambdaV;
    float energyCompensation;

    // IBL
    float3 iblR;                     // Reflected specular direction, used for IBL in EvaluateBSDF_Env()
    float  iblPerceptualRoughness;

    float3 specularFGD;              // Store preintegrated BSDF for both specular and diffuse
    float  diffuseFGD;

    // Area lights (17 VGPRs)
    // TODO: 'orthoBasisViewNormal' is just a rotation around the normal and should thus be just 1x VGPR.
    float3x3 orthoBasisViewNormal;   // Right-handed view-dependent orthogonal basis around the normal (6x VGPRs)
    float3x3 ltcTransformDiffuse;    // Inverse transformation for Lambertian or Disney Diffuse        (4x VGPRs)
    float3x3 ltcTransformSpecular;   // Inverse transformation for GGX                                 (4x VGPRs)

    // Clear coat
    float    coatPartLambdaV;
    float3   coatIblR;
    float    coatIblF;               // Fresnel term for view vector
    float    coatReflectionWeight;   // like reflectionHierarchyWeight but used to distinguish coat contribution between SSR/IBL lighting
    float3x3 ltcTransformCoat;       // Inverse transformation for GGX                                 (4x VGPRs)

#if HAS_REFRACTION
    // Refraction
    float3 transparentRefractV;      // refracted view vector after exiting the shape
    float3 transparentPositionWS;    // start of the refracted ray after exiting the shape
    float3 transparentTransmittance; // transmittance due to absorption
    float transparentSSMipLevel;     // mip level of the screen space gaussian pyramid for rough refraction
#endif
};

//
// ClampRoughness helper specific to this material
//
void ClampRoughness(inout PreLightData preLightData, inout BSDFData bsdfData, float minRoughness)
{
    bsdfData.roughness    = max(minRoughness, bsdfData.roughness);
}

PreLightData GetPreLightData(float3 V, PositionInputs posInput, inout BSDFData bsdfData)
{
    PreLightData preLightData;
    ZERO_INITIALIZE(PreLightData, preLightData);

    float3 N = bsdfData.normalWS;
    preLightData.NdotV = dot(N, V);
    preLightData.iblPerceptualRoughness = bsdfData.perceptualRoughness;

    float clampedNdotV = ClampNdotV(preLightData.NdotV);

    // Handle IBL + area light + multiscattering.
    // Note: use the not modified by anisotropy iblPerceptualRoughness here.
    float specularReflectivity;
    GetPreIntegratedFGDGGXAndDisneyDiffuse(clampedNdotV, preLightData.iblPerceptualRoughness, bsdfData.fresnel0, preLightData.specularFGD, preLightData.diffuseFGD, specularReflectivity);
#ifdef USE_DIFFUSE_LAMBERT_BRDF
    preLightData.diffuseFGD = 1.0;
#endif

#ifdef LIT_USE_GGX_ENERGY_COMPENSATION
    // Ref: Practical multiple scattering compensation for microfacet models.
    // We only apply the formulation for metals.
    // For dielectrics, the change of reflectance is negligible.
    // We deem the intensity difference of a couple of percent for high values of roughness
    // to not be worth the cost of another precomputed table.
    // Note: this formulation bakes the BSDF non-symmetric!
    preLightData.energyCompensation = 1.0 / specularReflectivity - 1.0;
#else
    preLightData.energyCompensation = 0.0;
#endif // LIT_USE_GGX_ENERGY_COMPENSATION

    float3 iblN;

    // We avoid divergent evaluation of the GGX, as that nearly doubles the cost.
    // If the tile has anisotropy, all the pixels within the tile are evaluated as anisotropic.
    preLightData.partLambdaV = GetSmithJointGGXPartLambdaV(clampedNdotV, bsdfData.roughness);
    iblN = N;

    preLightData.iblR = reflect(-V, iblN);

    // Area light
    // UVs for sampling the LUTs
    // We use V = sqrt( 1 - cos(theta) ) for parametrization which is kind of linear and only requires a single sqrt() instead of an expensive acos()
    float cosThetaParam = sqrt(1 - clampedNdotV); // For Area light - UVs for sampling the LUTs
    float2 uv = Remap01ToHalfTexelCoord(float2(bsdfData.perceptualRoughness, cosThetaParam), LTC_LUT_SIZE);

    // Note we load the matrix transpose (avoid to have to transpose it in shader)
#ifdef USE_DIFFUSE_LAMBERT_BRDF
    preLightData.ltcTransformDiffuse = k_identity3x3;
#else
    // Get the inverse LTC matrix for Disney Diffuse
    preLightData.ltcTransformDiffuse      = 0.0;
    preLightData.ltcTransformDiffuse._m22 = 1.0;
    preLightData.ltcTransformDiffuse._m00_m02_m11_m20 = SAMPLE_TEXTURE2D_ARRAY_LOD(_LtcData, s_linear_clamp_sampler, uv, LTCLIGHTINGMODEL_DISNEY_DIFFUSE, 0);
#endif

    // Get the inverse LTC matrix for GGX
    // Note we load the matrix transpose (avoid to have to transpose it in shader)
    preLightData.ltcTransformSpecular      = 0.0;
    preLightData.ltcTransformSpecular._m22 = 1.0;
    preLightData.ltcTransformSpecular._m00_m02_m11_m20 = SAMPLE_TEXTURE2D_ARRAY_LOD(_LtcData, s_linear_clamp_sampler, uv, LTCLIGHTINGMODEL_GGX, 0);

    // Construct a right-handed view-dependent orthogonal basis around the normal
    preLightData.orthoBasisViewNormal = GetOrthoBasisViewNormal(V, N, preLightData.NdotV);
    
    return preLightData;
}

//-----------------------------------------------------------------------------
// bake lighting function
//-----------------------------------------------------------------------------

// This define allow to say that we implement a ModifyBakedDiffuseLighting function to be call in PostInitBuiltinData
#define MODIFY_BAKED_DIFFUSE_LIGHTING

// This function allow to modify the content of (back) baked diffuse lighting when we gather builtinData
// This is use to apply lighting model specific code, like pre-integration, transmission etc...
// It is up to the lighting model implementer to chose if the modification are apply here or in PostEvaluateBSDF
void ModifyBakedDiffuseLighting(float3 V, PositionInputs posInput, PreLightData preLightData, BSDFData bsdfData, inout BuiltinData builtinData)
{
    // In case of deferred, all lighting model operation are done before storage in GBuffer, as we store emissive with bakeDiffuseLighting

    // Premultiply (back) bake diffuse lighting information with DisneyDiffuse pre-integration
    // Note: When baking reflection probes, we approximate the diffuse with the fresnel0
    builtinData.bakeDiffuseLighting *= preLightData.diffuseFGD * GetDiffuseOrDefaultColor(bsdfData, _ReplaceDiffuseForIndirect).rgb;
}

//-----------------------------------------------------------------------------
// light transport functions
//-----------------------------------------------------------------------------

LightTransportData GetLightTransportData(SurfaceData surfaceData, BuiltinData builtinData, BSDFData bsdfData)
{
    LightTransportData lightTransportData;

    // diffuseColor for lightmapping should basically be diffuse color.
    // But rough metals (black diffuse) still scatter quite a lot of light around, so
    // we want to take some of that into account too.

    float roughness = PerceptualRoughnessToRoughness(bsdfData.perceptualRoughness);
    lightTransportData.diffuseColor = float3(1,1,1) + bsdfData.fresnel0 * roughness * 0.5;
    lightTransportData.emissiveColor = builtinData.emissiveColor;

    return lightTransportData;
}

//-----------------------------------------------------------------------------
// LightLoop related function (Only include if required)
// HAS_LIGHTLOOP is define in Lighting.hlsl
//-----------------------------------------------------------------------------

#ifdef HAS_LIGHTLOOP

//-----------------------------------------------------------------------------
// BSDF share between directional light, punctual light and area light (reference)
//-----------------------------------------------------------------------------

bool IsNonZeroBSDF(float3 V, float3 L, PreLightData preLightData, BSDFData bsdfData)
{
    float NdotL = dot(bsdfData.normalWS, L);

    return (NdotL > 0.0);
}

//-----------------------------------------------------------------------------
// Surface shading (all light types) below
//-----------------------------------------------------------------------------

#include "Packages/com.unity.render-pipelines.high-definition/Runtime/Lighting/LightEvaluation.hlsl"
#include "Packages/com.unity.render-pipelines.high-definition/Runtime/Material/MaterialEvaluation.hlsl"


IndirectLighting EvaluateBSDF_ScreenSpaceReflection(PositionInputs posInput,
                                                    // Note: We use inout here with PreLightData to track an extra reflectionHierarchyWeight for the coat, but it should be avoided otherwise
                                                    inout PreLightData preLightData,
                                                    BSDFData       bsdfData,
                                                    inout float    reflectionHierarchyWeight)
{
    IndirectLighting lighting;
    ZERO_INITIALIZE(IndirectLighting, lighting);

    // TODO: this texture is sparse (mostly black). Can we avoid reading every texel? How about using Hi-S?
    float4 ssrLighting = LOAD_TEXTURE2D_X(_SsrLightingTexture, posInput.positionSS);
    InversePreExposeSsrLighting(ssrLighting);

    // Apply the weight on the ssr contribution (if required)
    ApplyScreenSpaceReflectionWeight(ssrLighting);

    // TODO: we should multiply all indirect lighting by the FGD value only ONCE.

    // When this material has a clear coat, we should not be using specularFGD (used for bottom layer lobe) to modulate the coat traced light but coatIblF.
    // The condition for it is a combination of a material feature and the coat mask.

    // Without coat we use the SSR lighting (traced with coat parameters) and fallback on reflection probes (EvaluateBSDF_Env())
    // if there's still room in reflectionHierarchyWeight (ie if reflectionHierarchyWeight < 1 in the light loop).
    //
    // With the clear coat, the coat-traced SSR light can't be used to contribute for the bottom lobe in general and we still want to use the probe lighting
    // as a fallback. This requires us to return a reflectionHierarchyWeight < 1 (ie 0 if we didnt add any light for the bottom lobe yet) to the lightloop
    // regardless of what we consumed for the coat. In turn, in EvaluateBSDF_Env(), we need to track what weight we already used up for the coat lobe via the
    // current SSR callback to avoid double coat lighting contributions (which would otherwise come from both the SSR and from reflection probes called to
    // contribute mainly to the bottom lobe). We use a separate coatReflectionWeight for that which we hold in preLightData
    //
    // Note that the SSR with clear coat is a binary state, which means we should never enter the if condition if we don't have an active
    // clear coat (which is not guaranteed by the HasFlag condition in deferred mode in some cases). We then need to make sure that coatMask is actually non zero.
    reflectionHierarchyWeight = ssrLighting.a;
    lighting.specularReflected = ssrLighting.rgb * preLightData.specularFGD;

    return lighting;
}


//-----------------------------------------------------------------------------
// EvaluateBSDF_Env
// ----------------------------------------------------------------------------
// _preIntegratedFGD and _CubemapLD are unique for each BRDF
IndirectLighting EvaluateBSDF_Env(  LightLoopContext lightLoopContext,
                                    float3 V, PositionInputs posInput,
                                    inout PreLightData preLightData, // inout, see preLightData.coatReflectionWeight
                                    EnvLightData lightData, BSDFData bsdfData,
                                    int influenceShapeType, int GPUImageBasedLightingType,
                                    inout float hierarchyWeight)
{
    IndirectLighting lighting;
    ZERO_INITIALIZE(IndirectLighting, lighting);
#if !HAS_REFRACTION
    if (GPUImageBasedLightingType == GPUIMAGEBASEDLIGHTINGTYPE_REFRACTION)
        return lighting;
#endif

    float3 envLighting;
    float3 positionWS = posInput.positionWS;
    float weight = 1.0;

#ifdef LIT_DISPLAY_REFERENCE_IBL

    envLighting = IntegrateSpecularGGXIBLRef(lightLoopContext, V, preLightData, lightData, bsdfData);

    // TODO: Do refraction reference (is it even possible ?)
    // TODO: handle clear coat


//    #ifdef USE_DIFFUSE_LAMBERT_BRDF
//    envLighting += IntegrateLambertIBLRef(lightData, V, bsdfData);
//    #else
//    envLighting += IntegrateDisneyDiffuseIBLRef(lightLoopContext, V, preLightData, lightData, bsdfData);
//    #endif

#else

    float3 R = preLightData.iblR;

#if HAS_REFRACTION
    if (GPUImageBasedLightingType == GPUIMAGEBASEDLIGHTINGTYPE_REFRACTION)
    {
        positionWS = preLightData.transparentPositionWS;
        R = preLightData.transparentRefractV;
    }
    else
#endif
    {
        if (!IsEnvIndexTexture2D(lightData.envIndex)) // ENVCACHETYPE_CUBEMAP
        {
            R = GetSpecularDominantDir(bsdfData.normalWS, R, preLightData.iblPerceptualRoughness, ClampNdotV(preLightData.NdotV));
            // When we are rough, we tend to see outward shifting of the reflection when at the boundary of the projection volume
            // Also it appear like more sharp. To avoid these artifact and at the same time get better match to reference we lerp to original unmodified reflection.
            // Formula is empirical.
            float roughness = PerceptualRoughnessToRoughness(preLightData.iblPerceptualRoughness);
            R = lerp(R, preLightData.iblR, saturate(smoothstep(0, 1, roughness * roughness)));
        }
    }

    // Note: using influenceShapeType and projectionShapeType instead of (lightData|proxyData).shapeType allow to make compiler optimization in case the type is know (like for sky)
    float intersectionDistance = EvaluateLight_EnvIntersection(positionWS, bsdfData.normalWS, lightData, influenceShapeType, R, weight);

    // Don't do clear coating for refraction
    float3 coatR = preLightData.coatIblR;
    if (GPUImageBasedLightingType == GPUIMAGEBASEDLIGHTINGTYPE_REFLECTION)
    {
        float unusedWeight = 0.0;
        EvaluateLight_EnvIntersection(positionWS, bsdfData.normalWS, lightData, influenceShapeType, coatR, unusedWeight);
    }

    float3 F = preLightData.specularFGD;

    float4 preLD = SampleEnvWithDistanceBaseRoughness(lightLoopContext, posInput, lightData, R, preLightData.iblPerceptualRoughness, intersectionDistance);
    weight *= preLD.a; // Used by planar reflection to discard pixel

    if (GPUImageBasedLightingType == GPUIMAGEBASEDLIGHTINGTYPE_REFLECTION)
    {
        envLighting = F * preLD.rgb;

        // Note: we have the same EnvIntersection weight used for the coat, but NOT the same headroom left to be used in the
        // hierarchy, so we saved the intersection weight here:
        float coatWeight = weight;

        // Apply the main lobe weight and update main reflection hierarchyWeight:
        UpdateLightingHierarchyWeights(hierarchyWeight, weight);
        envLighting *= weight;
    }
#if HAS_REFRACTION
    else
    {
        // No clear coat support with refraction

        // specular transmisted lighting is the remaining of the reflection (let's use this approx)
        // With refraction, we don't care about the clear coat value, only about the Fresnel, thus why we use 'envLighting ='
        envLighting = (1.0 - F) * preLD.rgb * preLightData.transparentTransmittance;

        // Apply the main lobe weight and update reflection hierarchyWeight:
        UpdateLightingHierarchyWeights(hierarchyWeight, weight);
        envLighting *= weight;
    }
#endif

#endif // LIT_DISPLAY_REFERENCE_IBL

    envLighting *= lightData.multiplier;

    if (GPUImageBasedLightingType == GPUIMAGEBASEDLIGHTINGTYPE_REFLECTION)
        lighting.specularReflected = envLighting;
#if HAS_REFRACTION
    else
        lighting.specularTransmitted = envLighting;
#endif

    return lighting;
}


#endif // #ifdef HAS_LIGHTLOOP
