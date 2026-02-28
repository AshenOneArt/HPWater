
#ifndef WATER_VOLUMETRICS_INCLUDED
#define WATER_VOLUMETRICS_INCLUDED


#define PI 3.14159265358979323846

#include "Packages/com.unity.render-pipelines.high-definition/Runtime/HanPiWater/Caustic/HPWaterCausticSampleFunction.hlsl"
#include "Packages/com.unity.render-pipelines.high-definition/Runtime/HanPiWater/Caustic/HPWaterCausticPass.cs.hlsl"
//================================================================================
//Shadow
//================================================================================
#ifdef SHADOW_ULTRA_LOW
#define WATER_DIRECTIONAL_FILTER_ALGORITHM(sd, posSS, posTC, tex, samp, bias,isSpecularLighting) SampleShadow_Gather_PCF(_CascadeShadowAtlasSize.zwxy, posTC, tex, samp, bias)
#elif defined(SHADOW_LOW)
#define WATER_DIRECTIONAL_FILTER_ALGORITHM(sd, posSS, posTC, tex, samp, bias,isSpecularLighting) SampleShadow_PCF_Tent_5x5(_CascadeShadowAtlasSize.zwxy, posTC, tex, samp, bias)
#elif defined(SHADOW_MEDIUM)
#define WATER_DIRECTIONAL_FILTER_ALGORITHM(sd, posSS, posTC, tex, samp, bias,isSpecularLighting) SampleShadow_PCF_Tent_7x7(_CascadeShadowAtlasSize.zwxy, posTC, tex, samp, bias)
// Note: currently quality settings for PCSS need to be expose in UI and is control in HDLightUI.cs file IsShadowSettings
#elif defined(SHADOW_HIGH)
    #if defined(USE_CUSTOM_WATER_SHADOW_PARAMS)
        #define SHADOW_SOFTNESS_FACTOR clamp(_HPWaterShadowParams.x,0,10)
        // 使用自定义全局参数 _HPWaterShadowParams (x: softness, y: minFilterSize, z: blockerCount, w: filterCount)
        //软阴影强度通过水面自定义乘法控制，因为原生PCSS shadowSoftness计算复杂，不用再计算一次
        //镜面反射渲染时，使用原生PCSS阴影算法的Softness，这一层的计算都是在表面
        #define WATER_DIRECTIONAL_FILTER_ALGORITHM(sd, posSS, posTC, tex, samp, bias,isSpecularLighting)\
        SampleShadow_PCSS(posTC, posSS, sd.shadowMapSize.xy * _CascadeShadowAtlasSize.zw, sd.atlasOffset,\
        isSpecularLighting ? sd.shadowFilterParams0.x : SHADOW_SOFTNESS_FACTOR * sd.shadowFilterParams0.x, sd.shadowFilterParams0.y,\
        int(_HPWaterShadowParams.z), int(_HPWaterShadowParams.w),\
        tex, samp, s_point_clamp_sampler, bias, sd.zBufferParam, false, _CascadeShadowAtlasSize.xz)
    #else
        #define WATER_DIRECTIONAL_FILTER_ALGORITHM(sd, posSS, posTC, tex, samp, bias,isSpecularLighting) SampleShadow_Gather_PCF(_CascadeShadowAtlasSize.zwxy, posTC, tex, samp, bias)
    #endif
#endif
SHADOW_TYPE EvalWater_CascadedDepth_Dither_SplitIndex(inout HDShadowContext shadowContext, Texture2D shadowMap,SamplerComparisonState samp, 
    float2 positionSS, float3 positionWS, float3 normalWS, int index, float3 L,int isSpecularLighting, out int shadowSplitIndex)
{
    float   alpha;
    int     cascadeCount;
    SHADOW_TYPE  shadow = 1.0;
    shadowSplitIndex = EvalShadow_GetSplitIndex(shadowContext, index, positionWS, alpha, cascadeCount);    

    float3 basePositionWS = positionWS;

    if (shadowSplitIndex >= 0.0)
    {
        HDShadowData sd = shadowContext.shadowDatas[index];
        LoadDirectionalShadowDatas(sd, shadowContext, index + shadowSplitIndex);
        positionWS = basePositionWS + sd.cacheTranslationDelta.xyz;

        /* normal based bias */
        float worldTexelSize = sd.worldTexelSize;
        float3 normalBias = EvalShadow_NormalBiasOrtho(worldTexelSize, sd.normalBias, normalWS);

        /* We select what split we need to sample from */
        float nextSplit = min(shadowSplitIndex + 1, cascadeCount - 1);
        bool evalNextCascade = nextSplit != shadowSplitIndex && alpha > 0 && step(InterleavedGradientNoise(positionSS.xy, _TaaFrameInfo.z), alpha);

        if (evalNextCascade)
        {
            LoadDirectionalShadowDatas(sd, shadowContext, index + nextSplit);
            positionWS = basePositionWS + sd.cacheTranslationDelta.xyz;
            float biasModifier = (sd.worldTexelSize / worldTexelSize);
            normalBias *= biasModifier;
        }

        positionWS += normalBias;
        float3 posTC = EvalShadow_GetTexcoordsAtlas(sd, _CascadeShadowAtlasSize.zw, positionWS, false);

#if defined(HP_WATER_VOLUME)    
        shadow = WATER_DIRECTIONAL_FILTER_ALGORITHM(sd, positionSS, posTC, shadowMap, samp, FIXED_UNIFORM_BIAS,isSpecularLighting);
#else
        shadow = SampleShadow_Gather_PCF(_CascadeShadowAtlasSize.zwxy, posTC, shadowMap, samp, FIXED_UNIFORM_BIAS);
#endif
        
        shadow = (shadowSplitIndex < cascadeCount - 1) ? shadow : lerp(shadow, 1.0, alpha);
    }

    return shadow;
}

SHADOW_TYPE GetWaterDirectionalShadowAttenuation(inout HDShadowContext shadowContext, float2 positionSS, float3 positionWS, float3 normalWS, int shadowDataIndex, float3 L,int isSpecularLighting = 0)
{
#if SHADOW_AUTO_FLIP_NORMAL
    normalWS *= FastSign(dot(normalWS, L));
#endif
    int unusedSplitIndex;
    return EvalWater_CascadedDepth_Dither_SplitIndex(shadowContext, _ShadowmapCascadeAtlas,
        s_linear_clamp_compare_sampler, positionSS, positionWS, normalWS, shadowDataIndex, L,isSpecularLighting, unusedSplitIndex);
}

SHADOW_TYPE ComputeShadowValue(float3 samplePos,uint featureFlags,LightLoopContext lightLoopContext,PositionInputs posInput,BSDFData bsdfData)
{
    SHADOW_TYPE shadowValue = 1.0;
    if (featureFlags & LIGHTFEATUREFLAGS_DIRECTIONAL)
    {
        if (_DirectionalShadowIndex >= 0)
        {
            DirectionalLightData light = _DirectionalLightDatas[_DirectionalShadowIndex];
#if defined(SCREEN_SPACE_SHADOWS_ON) && !defined(_SURFACE_TYPE_TRANSPARENT)
            if (UseScreenSpaceShadow(light, bsdfData.normalWS))
            {
                shadowValue = GetScreenSpaceColorShadow(posInput, light.screenSpaceShadowIndex).SHADOW_TYPE_SWIZZLE;
            }
            else
#endif                
            {
            
                // TODO: this will cause us to load from the normal buffer first. Does this cause a performance problem?
                float3 L = -light.forward;

                // Is it worth sampling the shadow map?
                if ((light.lightDimmer > 0) && (light.shadowDimmer > 0))
                {
                    float3 positionWS = samplePos;
                    shadowValue = GetWaterDirectionalShadowAttenuation(lightLoopContext.shadowContext,
#if defined(NEED_LOWRES_POSITIONINPUT)    
                                                                    _HPWaterLowResPositionSS,
#else
                                                                    posInput.positionSS,
#endif
                                                                    positionWS, GetNormalForShadowBias(bsdfData),
                                                                    light.shadowIndex, L,0);
                }
            }
        }
    }
    return shadowValue;
}

//水面采样中使用
float3 ComputeCausticValue(float3 samplePos,inout SHADOW_TYPE shadowValue,uint featureFlags,LightLoopContext lightLoopContext,PositionInputs posInput,BSDFData bsdfData)
{
    if (_Is_Use_RGB_Caustic < 0)
        return 1;
    float3 causticValue = 0;
    if (featureFlags & LIGHTFEATUREFLAGS_DIRECTIONAL)
    {
        if (_DirectionalShadowIndex >= 0)
        {
            DirectionalLightData light = _DirectionalLightDatas[_DirectionalShadowIndex];
            // TODO: this will cause us to load from the normal buffer first. Does this cause a performance problem?
            float3 L = -light.forward;

            // Is it worth sampling the shadow map?
            if ((light.lightDimmer > 0) && (light.shadowDimmer > 0))
            {
                float3 positionWS = samplePos;
                causticValue = GetCausticDirectionalAttenuation(lightLoopContext.shadowContext,
                                                                shadowValue,
                                                                posInput.positionSS, positionWS, GetNormalForShadowBias(bsdfData),
                                                                light.shadowIndex, L);
            }
        }
    }
    return causticValue;
}

float FogPhase(float lightPoint)
{
	float slinear = clamp(-lightPoint*0.5+0.5,0.0,1.0);
	float linear2 = 1.0 - clamp(lightPoint,0.0,1.0);

	float exponential = exp2(pow(slinear,0.3) * -15.0 ) * 1.5;
	exponential += sqrt(exp2(sqrt(slinear) * -12.5));

	// float exponential = 1.0 / (linear * 10.0 + 0.05);

	return exponential;
}
float HenyeyPhase(float cosTheta,float phaseG)
{
    float g2 = phaseG * phaseG;
    float denom = 1.0 + g2 - 2.0 * phaseG * cosTheta;
    float mieScatter = (1.0 - g2) * rcp(pow(abs(denom), 1.5));
    return  mieScatter;
}

float FresnelSchlick(float cosTheta, float F0)
{
    return F0 + (1.0 - F0) * SafePow(1.0 - cosTheta, 5.0);
}
  
//==============================================================================
//WaterScatterPhase
//==============================================================================
float3 CaculateScatterPhase(float cosTheta,float phaseG)
{
    //瑞丽散射占比5%，米氏散射占比95%
    static const float3 betaRayleigh = float3(5.8e-6, 13.5e-6, 33.1e-6); // ∝ 1/λ⁴        
    float rayleighPhase = (1.0 + cosTheta * cosTheta) * (3 / (16 * PI));
    float3 rayleighScatter = betaRayleigh * rayleighPhase * 1e6;

    float mieScatter = HenyeyPhase(cosTheta,phaseG);
    float3 scatterPhase = rayleighScatter * 0.05 + float3(mieScatter,mieScatter,mieScatter) * 0.95;
    return scatterPhase;
}

float3 CaculateScatteredLight(float3 originLight,float3 absorptionCoeff,float3 scatteringCoeff,float crossDistance,float3 phase,out float3 transmittance)
{
    // 1. 计算总的消光系数
    float3 extinctionCoeff = absorptionCoeff + scatteringCoeff;

    // 2. 计算透射率（光线幸存的比例），这里用总的消光系数
    transmittance = exp(-extinctionCoeff * (crossDistance)); 

    // 3. 计算被“消光”（吸收+散射）的总光量        
    float3 extinguishedLight = originLight * (1.0 - transmittance);

    // 4. 计算在所有消光的光中，到底有多少是真正被散射的
    // 这个比例就是 散射系数 / 消光系数，也称为“反照率”(Albedo)
    // 为了避免除以零，需要做安全处理
    float3 scatteringAlbedo = (extinctionCoeff > 0) ? (scatteringCoeff * rcp(extinctionCoeff)) : 0;

    // 5. 计算出真正被散射的光量        
    float3 scatteredLight = extinguishedLight * scatteringAlbedo;
    scatteredLight = scatteredLight * phase;
    return scatteredLight;
}

float3 CaculateScatteredLight(float3 originLight,float3 absorptionCoeff,float3 scatteringCoeff,float crossDistance,float3 phase,
out float3 transmittance,out float3 scatteringAlbedo)
{
    // 1. 计算总的消光系数
    float3 extinctionCoeff = absorptionCoeff + scatteringCoeff;

    // 2. 计算透射率（光线幸存的比例），这里用总的消光系数
    transmittance = exp(-extinctionCoeff * (crossDistance)); 

    // 3. 计算被“消光”（吸收+散射）的总光量        
    float3 extinguishedLight = originLight * (1.0 - transmittance);

    // 4. 计算在所有消光的光中，到底有多少是真正被散射的
    // 这个比例就是 散射系数 / 消光系数，也称为“反照率”(Albedo)
    // 为了避免除以零，需要做安全处理
    scatteringAlbedo = (extinctionCoeff > 0) ? (scatteringCoeff * rcp(extinctionCoeff)) : 0;

    // 5. 计算出真正被散射的光量        
    float3 scatteredLight = extinguishedLight * scatteringAlbedo;
    scatteredLight = scatteredLight * phase;
    return scatteredLight;
}

//==============================================================================
//WaterVolumetrics
//==============================================================================
float3 WaterVolumetrics(
    // Input parameters
    WaterLightLoopData waterLightLoopData,
    uint featureFlags,
    float MaxDistance,
    float2 ScreenUV,    
    float3 LightDir,
    float3 LightColor,
    float3 SceneColor,
    PositionInputs posInput,
    LightLoopContext lightLoopContext,
    BSDFData bsdfData,
    float NdotV,  // 预计算的 NdotV，用于厚度近似（法线朝向相机处更薄）
    
    // Output
    out float3 accumTransmittance,
    out SHADOW_TYPE lastShadowValue)
{    
    // Initialize variables        
    float3 RayStart                 = waterLightLoopData.RelativeStartPos;
    float3 RayStartNoMatOffset      = waterLightLoopData.RelativeStartPosNoMatOffset;
    float3 RayEnd                   = waterLightLoopData.RelativeRefractedEndPos;
    float3 AbsorptionCoefficient    = waterLightLoopData.AbsorptionCoefficient;
    float3 ScatterCoefficient       = waterLightLoopData.ScatterCoefficient;
    float3 NoLinearRayDirection     = waterLightLoopData.NoLinearRayDirection;
    float3 LinearRayDirection       = waterLightLoopData.LinearRayDirection;
    float3 DynamicRayDirection       = waterLightLoopData.NoLinearDynamicRayDirection;
    float NoLinearRayLength         = waterLightLoopData.NoLinearRayLength;    
    float AmbientDepth              = waterLightLoopData.NoLinearAmbientDepth;
    float SunDepth                  = waterLightLoopData.NoLinearSunDepth;    
    float Dither                    = waterLightLoopData.Dither;   

    accumTransmittance      = 1;
    float totalShadowValue  = 1;    
    float3  causticValue    = 1;
    float3 scatteredLight   = 0;
    float3 transmittance    = 0;    
    float3 scatteringAlbedo = 0;
    SHADOW_TYPE   shadowValue     = 1;
    lastShadowValue        = 1;
    
  
    float verticalFactor = -safeNormalize(NoLinearRayDirection).y;
    verticalFactor = clamp(verticalFactor - 0.15, 0.0, 1.0);
    verticalFactor = pow(1.0 - pow(1.0 - verticalFactor, 2.0), 2.0);
    verticalFactor *= 5;

    // ===== 指数步进参数预计算 =====
    //
    // 目标：将 [0, 1] 区间映射到指数分布的采样点，近处密集、远处稀疏
    //
    // 数学推导：
    //   设 t ∈ [0, 1] 是归一化的采样索引（t = i/N）
    //   指数映射：d(t) = (e^(k·t) - 1) / (e^k - 1)，其中 k = ln(EXP_FACTOR)
    //   当 t=0 时 d=0，当 t=1 时 d=1
    //
    // 实现优化：
    //   令 currentExp = e^(k·t) = EXP_FACTOR^t
    //   则 d = (currentExp - 1) / (EXP_FACTOR - 1) = (currentExp - 1) * kDenom
    //   步长 dd = d'(t) · dt = currentExp · k / (e^k - 1) · (1/N) = currentExp · kDD
    //
    float rcpCount = rcp(float(WATER_SAMPLE_COUNT));
    float kDenom = rcp(EXP_FACTOR - 1.0);
    float kDD = log(EXP_FACTOR) * rcpCount * kDenom;

    // expStep = EXP_FACTOR^(1/N)，每次迭代乘以它来递增 currentExp
    float expStep = pow(EXP_FACTOR, rcpCount);

    // Dither 抖动起始点，减少带状 artifact
    float currentExp = pow(EXP_FACTOR, Dither * rcpCount);

    for (int i = 0; i < WATER_SAMPLE_COUNT; i++)
    {
        // d: 归一化采样位置 [0, 1]，乘以 RayLength 得到实际距离
        // dd: 当前步的归一化步长
        float d = (currentExp - 1.0) * kDenom;
        float dd = currentExp * kDD;   
        float3 samplePos = RayStart + NoLinearRayDirection * d;  
        float3 samplePosLinear = RayStart + LinearRayDirection * d;
        float3 samplePosDynamic = RayStart + DynamicRayDirection * d;
        
        shadowValue = ComputeShadowValue(samplePosDynamic,featureFlags,lightLoopContext,posInput,bsdfData);
        if(i == 0)
        {
            lastShadowValue = shadowValue;
        }
        
        //causticValue = ComputeCausticValue(samplePosLinear,shadowValue,featureFlags,lightLoopContext,posInput,bsdfData); 
        //焦散的分布会从水面到水下，呈无分散到有分散，到达底部将会变成受折射后的焦散图采样结果
        causticValue = 1;

        // ===== 一次散射：直接光照 =====
        float cosTheta = dot(safeNormalize(samplePos), safeNormalize(LightDir));
        float3 scatterPhase = CaculateScatterPhase(cosTheta,_PhaseG);
        float3 directLighting = LightColor * shadowValue * causticValue;
        float directCrossDistance = dd * NoLinearRayLength + SunDepth * dd;        

        // 先计算不带相位的基础散射（phase = 1）
        float3 baseScatter = CaculateScatteredLight(
            directLighting, AbsorptionCoefficient, ScatterCoefficient,
            directCrossDistance, 1, transmittance, scatteringAlbedo).rgb; 
        
        // 多次散射效果：根据透射率决定相位的各向同性程度
        // transmittance 高 -> 薄介质 -> 单次散射主导 -> 保留方向性相位
        // transmittance 低 -> 厚介质 -> 多次散射充分 -> 相位趋于各向同性
        float scatterAlbedo = Luminance(scatteringAlbedo) * GetInverseCurrentExposureMultiplier();
        float3 effectivePhase = lerp(scatterPhase, 1.0, saturate(smoothstep(0,0.5,scatterAlbedo)));
        
        float3 directScatteredLight = baseScatter * effectivePhase;
        
        accumTransmittance *= transmittance;
        scatteredLight += directScatteredLight;
        currentExp *= expStep;
        shadowValue *= shadowValue;
    }
    // ===== 水下场景散射（Scene In-Scattering）=====
    // 
    // 物理含义：水下物体反射的光，在穿过水体到达摄像机的过程中，也会被散射
    // 这会产生"雾化"效果，让远处的水下物体看起来更模糊、更偏向散射色
    //
    // 简化公式（避免对场景光再做完整 ray marching）：
    //   sceneScatteredLight = sceneLight × T_accum × μs × d × I_sun
    //
    // 各项含义：
    //   sceneLight：水下场景光（考虑 30% 阴影穿透，因为水下阴影较软）
    //   T_accum：累积透射率（场景光穿过水体的衰减）
    //   μs：散射系数（决定多少光被散射出来）
    //   d：光程长度（路径越长散射越多）
    //   I_sun：光源亮度（用于调制，使场景散射与直接光散射亮度一致）
    //
    float3 sceneLight = SceneColor * lerp(shadowValue, 1, 0.3);
    float lightIntensity = Luminance(LightColor);
    float3 sceneScatteredLight = sceneLight * accumTransmittance * ScatterCoefficient * NoLinearRayLength * lightIntensity;
    scatteredLight += sceneScatteredLight;

    return scatteredLight;
}

#endif