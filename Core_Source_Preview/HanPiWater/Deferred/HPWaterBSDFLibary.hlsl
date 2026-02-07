#ifndef HPWATER_BSDF_LIBARY_HLSL
#define HPWATER_BSDF_LIBARY_HLSL

#if defined(HP_WATER_VOLUME)
#include "Packages/com.unity.render-pipelines.high-definition/Runtime/HanPiWater/Deferred/HPWaterVolumetrics.hlsl"
#endif

void WaterPostEvaluateBSDF(WaterLightLoopData waterLightLoopData,LightLoopContext lightLoopContext,
    float3 V, PositionInputs posInput,
    PreLightData preLightData, BSDFData bsdfData, BuiltinData builtinData, AggregateLighting lighting,
    out LightLoopOutput lightLoopOutput)
{

    float3 TotalIndirectLighting = 0;
    float3 absorbance = 1;
    float3 transmittance = 0;
    float verticalFactor = -safeNormalize(waterLightLoopData.NoLinearRayDirection).y;
    verticalFactor = clamp(verticalFactor - 0.15, 0.0, 1.0);
    verticalFactor = pow(1.0 - pow(1.0 - verticalFactor, 2.0), 2.0);
    verticalFactor *= 14.0;
#define AExpFactor 120

    //[unroll]
    for (int count = 0; count < WATER_SAMPLE_COUNT; count++)
    {
        float d = (pow(AExpFactor, float(count+waterLightLoopData.Dither)/float(WATER_SAMPLE_COUNT))/AExpFactor - 1.0/AExpFactor)/(1-1.0/AExpFactor);
        float dd = pow(AExpFactor, float(count+waterLightLoopData.Dither)/float(WATER_SAMPLE_COUNT)) * log(AExpFactor) / float(WATER_SAMPLE_COUNT)/(AExpFactor-1.0);

        float3 indirectLighting = builtinData.bakeDiffuseLighting * _IndirectLightStrength;
        float crossDistance = dd * waterLightLoopData.NoLinearRayLength + (waterLightLoopData.NoLinearAmbientDepth * dd );
        crossDistance = max(crossDistance,0.00001);
           
        float3 indirectScatteredLight = WaterVolumeLightLoop::CaculateScatteredLight(
            indirectLighting,waterLightLoopData.AbsorptionCoefficient,waterLightLoopData.ScatterCoefficient,
            crossDistance,1,transmittance);

        TotalIndirectLighting += indirectScatteredLight;
        absorbance *= transmittance;
    }

    float fresneNdotV = saturate(dot(safeNormalize(bsdfData.normalWS), -safeNormalize(waterLightLoopData.RelativeStartPos)));// 取反，从表面指向相机
    TotalIndirectLighting *= (1 - WaterVolumeLightLoop::FresnelSchlick(fresneNdotV, bsdfData.fresnel0.x));

    lightLoopOutput.diffuseLighting = lighting.direct.diffuse + TotalIndirectLighting + builtinData.emissiveColor;

    //lightLoopOutput.diffuseLighting = modifiedDiffuseColor * lighting.direct.diffuse + builtinData.emissiveColor;

    // If refraction is enable we use the transmittanceMask to lerp between current diffuse lighting and refraction value
    // Physically speaking, transmittanceMask should be 1, but for artistic reasons, we let the value vary
    //
    // Note we also transfer the refracted light (lighting.indirect.specularTransmitted) into diffuseLighting
    // since we know it won't be further processed: it is called at the end of the LightLoop(), but doing this
    // enables opacity to affect it (in ApplyBlendMode()) while the rest of specularLighting escapes it.

    lightLoopOutput.specularLighting = lighting.direct.specular + lighting.indirect.specularReflected;
    // Rescale the GGX to account for the multiple scattering.
    lightLoopOutput.specularLighting *= 1.0 + bsdfData.fresnel0 * preLightData.energyCompensation;
}



CBSDF WaterEvaluateBSDF(WaterLightLoopData waterLightLoopData,uint featureFlags,float3 V, float3 L,float3 LightColor, PreLightData preLightData, BSDFData bsdfData,
    PositionInputs posInput,LightLoopContext lightLoopContext,DirectionalLightData light,BuiltinData builtinData)
{
    CBSDF cbsdf;
    ZERO_INITIALIZE(CBSDF, cbsdf);

    float3 N = bsdfData.normalWS;
    float NdotL_LF = dot(N, L);
    float NdotLWrappedDiffuseLowFrequency = ComputeWrappedDiffuseLighting(NdotL_LF, 1.0f);
    float clampedNdotL_LF = saturate(NdotL_LF);
    float NdotV = preLightData.NdotV;
    float clampedNdotV = ClampNdotV(NdotV);

    float NdotL = dot(N, L);
    float clampedNdotL = saturate(NdotL);

    float LdotV, NdotH, LdotH, invLenLV;
    GetBSDFAngle(V, L, NdotL, NdotV, LdotV, NdotH, LdotH, invLenLV);

    float3 F = F_Schlick(bsdfData.fresnel0, LdotH);
    // We use abs(NdotL) to handle the none case of double sided
    float DV = DV_SmithJointGGX(NdotH, abs(NdotL), clampedNdotV, bsdfData.roughness, preLightData.partLambdaV);

    float specularSelfOcclusion = saturate(clampedNdotL_LF * 5.f);

    float2 sceneScreenCoord = waterLightLoopData.RefractWaterScreenCoord;    

    float3 absorbance = 1;        

#if defined(HP_WATER_VOLUME)
    //前向散射颜色,这里会经过二次前向散射，所以 + waterLightLoopData.ForwardScatterOffset 
    float forwardScatterBlurDensity = Luminance(waterLightLoopData.ScatterCoefficient);

    // 计算模糊等级（HPWaterBSDFLibary.hlsl）
    float blurMipLevel = CalculateHPWaterMipLevel(waterLightLoopData.NoLinearRayLength,FORWARD_SCALING_FACTOR,forwardScatterBlurDensity,6);
    
    //计算二次前向散射颜色
    float3 forwardScatterColor = HPSampleCameraColor(
        waterLightLoopData.RefractWaterScreenCoord.xy, clamp(blurMipLevel, 0, 6)).rgb * _MultiScatterScale;

    //计算水体散射颜色
    float3 waterScatterColor =  WaterVolumetrics(waterLightLoopData,
        featureFlags,_MaxCrossDistance,posInput.positionNDC.xy,L,LightColor,
        forwardScatterColor,
        posInput,lightLoopContext,bsdfData,absorbance
    );

    _HPWaterAbsorption = absorbance;
    cbsdf.diffR = waterScatterColor;    
#else
    float3 sceneColor = HPSampleCameraColor(sceneScreenCoord.xy, 0).rgb;
    cbsdf.diffR = sceneColor * absorbance * GetInverseCurrentExposureMultiplier();    
#endif
    cbsdf.diffT = 0;
    if (g_drawDebugColorFlag)
    {
        cbsdf.diffR = g_drawDebugColor * GetInverseCurrentExposureMultiplier();
        cbsdf.diffT = 0;
    }

    //由diffR来定义吸收，diffT来定义散射
    // Probably worth branching here for perf reasons.
    // This branch will be optimized away if there's no transmission.
    if (NdotL > 0)
    {
        cbsdf.specR = F * DV * clampedNdotL * specularSelfOcclusion;
    }

    // We don't multiply by 'bsdfData.diffuseColor' here. It's done only once in PostEvaluateBSDF().
    return cbsdf;
}


DirectLighting WaterSurface_Infinitesimal(WaterLightLoopData waterLightLoopData,uint featureFlags,PreLightData preLightData, BSDFData bsdfData,
    float3 V, float3 L, float3 lightColor,float diffuseDimmer,
    float specularDimmer,PositionInputs posInput,
    LightLoopContext lightLoopContext,DirectionalLightData light,BuiltinData builtinData)//添加额外的采样阴影数据
{
    DirectLighting lighting;
    ZERO_INITIALIZE(DirectLighting, lighting);
#if defined(HP_WATER_VOLUME)
#else
    if (Max3(lightColor.r, lightColor.g, lightColor.b) > 0)
#endif
    {
        CBSDF cbsdf = WaterEvaluateBSDF(waterLightLoopData,featureFlags,V, L, lightColor, preLightData, bsdfData,posInput,lightLoopContext,
        light,builtinData);

        lighting.diffuse  = (cbsdf.diffR + cbsdf.diffT) * diffuseDimmer;
        lighting.specular = (cbsdf.specR + cbsdf.specT) * lightColor * specularDimmer;
    }

#ifdef DEBUG_DISPLAY
    if (_DebugLightingMode == DEBUGLIGHTINGMODE_LUX_METER)
    {
        // Only lighting, no BSDF.
        lighting.diffuse = lightColor * saturate(dot(bsdfData.normalWS, L));
    }
#endif

    return lighting;
}


DirectLighting WaterSurface_Directional(WaterLightLoopData waterLightLoopData,uint featureFlags,LightLoopContext lightLoopContext,
                                        PositionInputs posInput, BuiltinData builtinData,
                                        PreLightData preLightData, DirectionalLightData light,
                                        BSDFData bsdfData, float3 V)
{
    DirectLighting lighting;
    ZERO_INITIALIZE(DirectLighting, lighting);

    float3 L = -light.forward;

    // Is it worth evaluating the light?
    if ((light.lightDimmer > 0))
    {
        float4 lightColor = EvaluateLight_Directional(lightLoopContext, posInput, light);
        lightColor.rgb *= lightColor.a; // Composite

        {
            //水体渲染不需要Micro阴影或者Contact阴影
            SHADOW_TYPE shadow = EvaluateShadow_Directional(lightLoopContext, posInput, light, builtinData, GetNormalForShadowBias(bsdfData));
            float NdotL  = dot(bsdfData.normalWS, L); // No microshadowing when facing away from light (use for thin transmission as well) 
            shadow *= NdotL >= 0.0 ? ComputeMicroShadowing(GetAmbientOcclusionForMicroShadowing(bsdfData), NdotL, _MicroShadowOpacity) : 1.0;            
            lightColor.rgb *= ComputeShadowColor(shadow, light.shadowTint, light.penumbraTint);
            //drawDebugColor(shadow.rgb);

#ifdef LIGHT_EVALUATION_SPLINE_SHADOW_VISIBILITY_SAMPLE
            if ((light.shadowIndex >= 0))
            {
                bsdfData.splineVisibility = lightLoopContext.splineVisibility;
            }
            else
            {
                bsdfData.splineVisibility = -1;
            }
#endif
        }

        // Simulate a sphere/disk light with this hack.
        // Note that it is not correct with our precomputation of PartLambdaV
        // (means if we disable the optimization it will not have the
        // same result) but we don't care as it is a hack anyway.
        ClampRoughness(preLightData, bsdfData, light.minRoughness);

        lighting = WaterSurface_Infinitesimal(waterLightLoopData,featureFlags,preLightData, bsdfData, V, L, lightColor.rgb,
                                              light.diffuseDimmer, light.specularDimmer,posInput,
                                              lightLoopContext,light,builtinData);
    }

    return lighting;
}


DirectLighting WaterEvaluateBSDF_Directional(WaterLightLoopData waterLightLoopData,uint featureFlags,LightLoopContext lightLoopContext,
    float3 V, PositionInputs posInput,
    PreLightData preLightData, DirectionalLightData lightData,
    BSDFData bsdfData, BuiltinData builtinData)
{
    return WaterSurface_Directional(waterLightLoopData,featureFlags,lightLoopContext, posInput, builtinData, preLightData, lightData, bsdfData, V);
}

#endif