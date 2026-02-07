#define DIGITS_OFFSET_L 1e-4

// 焦散纹理采样宏 - 跟随官方阴影质量设置
// 直接使用官方的阴影采样函数
#ifdef SHADOW_ULTRA_LOW
#define WATERSHADOW_TEXTURE_FILTER_ALGORITHM(shadowAtlasSize, coord, tex, compSamp, depthBias, worldTexelSize) SampleShadow_Gather_PCF(shadowAtlasSize, coord, tex, compSamp, depthBias)
#elif defined(SHADOW_LOW)
#define WATERSHADOW_TEXTURE_FILTER_ALGORITHM(shadowAtlasSize, coord, tex, compSamp, depthBias, worldTexelSize) SampleShadow_PCF_Tent_5x5(shadowAtlasSize, coord, tex, compSamp, depthBias)
#elif defined(SHADOW_MEDIUM) || defined(SHADOW_HIGH)
#define WATERSHADOW_TEXTURE_FILTER_ALGORITHM(shadowAtlasSize, coord, tex, compSamp, depthBias, worldTexelSize) SampleShadow_PCF_Tent_7x7(shadowAtlasSize, coord, tex, compSamp, depthBias)
#endif

float3 GetHPWaterCaustic(float4 shadowAtlasSize, float3 coord, float worldTexelSize,int cascadeIndex)
{
    // shadowAtlasSize 格式：(1/width, 1/height, width, height)
    // 计算像素坐标（最近邻采样，保持焦散锐利边缘）
    uint2 pixelCoord = uint2(coord.xy * shadowAtlasSize.zw);
    
    // 采样焦散纹理（从 uint 纹理 LOAD 采样）
    float3 causticColor;
    if (_Is_Use_RGB_Caustic > 0)
    {
        // RGB 模式：分别 Load 三张 uint 纹理
        uint causticR_uint = LOAD_TEXTURE2D(_CausticCascadeAtlas_R, pixelCoord).r;
        uint causticG_uint = LOAD_TEXTURE2D(_CausticCascadeAtlas_G, pixelCoord).r;
        uint causticB_uint = LOAD_TEXTURE2D(_CausticCascadeAtlas_B, pixelCoord).r;
        
        // 转换为 float 并缩放
        causticColor.r = (float)causticR_uint * DIGITS_OFFSET_L;
        causticColor.g = (float)causticG_uint * DIGITS_OFFSET_L;
        causticColor.b = (float)causticB_uint * DIGITS_OFFSET_L;
    }
    else
    {
        // 单通道模式：通过折射差异模拟色散
        
        // 获取光线方向和水面法线
        half3 L = _DirectionalLightDatas[_DirectionalShadowIndex].forward;
        
        // 从法线纹理 Load（精确像素，避免插值）
        // 计算像素坐标
        uint2 pixelCoord = uint2(coord.xy * shadowAtlasSize.zw);
        NormalData normalDataDecode;
        DecodeFromNormalBuffer(LOAD_TEXTURE2D(_WaterNormalAtlas, pixelCoord), normalDataDecode);
        float3 waterNormal = normalDataDecode.normalWS;
        
        // 计算折射差异作为色散偏移
        // eta_base ≈ 1/1.333 (空气到水)
        const float eta_base = 0.75; // 1.0 / 1.333
        float dispersionStrength = _CausticDispersionStrength * 100; // 色散强度
        
        // 计算实际水面折射与平面折射的差异
        //R:0.7513,G:0.7501
        half3 refractedDir_R = refract(L, waterNormal, eta_base + 0.001);  // 水面折射R
        half3 refractedDir_G = refract(L, waterNormal, eta_base);    // 实际水面折射
        half3 refractionDeltaR = refractedDir_G - refractedDir_R;   // 折射差异向量


        // 色散偏移向量
        refractionDeltaR = mul(_WaterCascadeAtlasVP[cascadeIndex], float4(refractionDeltaR, 0.0)).xyz;
        
        // 色散偏移方向
        half2 dispersionDir = refractionDeltaR.xy * dispersionStrength;
        
        // UV 偏移
        // worldTexelSize = 每个纹素对应的世界空间大小
        float uvToWorld = worldTexelSize * shadowAtlasSize.z + 0.001;
        half2 uvOffset = dispersionDir;
        
        // 限制 UV 坐标在 [0,1] 范围内，避免越界
        float2 uvR = saturate(coord.xy + uvOffset);
        float2 uvG = saturate(coord.xy);
        float2 uvB = saturate(coord.xy - uvOffset);
        
        float causticR = SAMPLE_TEXTURE2D_LOD(_CausticCascadeAtlas_Float, s_linear_clamp_sampler, uvR, 0).r;
        float causticG = SAMPLE_TEXTURE2D_LOD(_CausticCascadeAtlas_Float, s_linear_clamp_sampler, uvG, 0).r;
        float causticB = SAMPLE_TEXTURE2D_LOD(_CausticCascadeAtlas_Float, s_linear_clamp_sampler, uvB, 0).r;
        
        causticColor.r = causticR;
        causticColor.g = causticG;
        causticColor.b = causticB;
    }
    return causticColor;
}

// 标准模式：使用水面阴影贴图计算完整的焦散效果
float3 EvalHPWaterCaustic_CascadedDepth_Dither_SplitIndex(inout HDShadowContext shadowContext, SHADOW_TYPE shadowValue,
#if !defined(HP_WATER_VOLUME)
    Texture2D tex, SamplerComparisonState samp,
#endif
 float2 positionSS, float3 positionWS, float3 normalWS, int index, float3 L, out int shadowSplitIndex)
{
    float   alpha;
    int     cascadeCount;
    float   shadow = 1.0;
    float3  caustic = 1.0;
    shadowSplitIndex = EvalShadow_GetSplitIndex(shadowContext, index, positionWS, alpha, cascadeCount);
#ifdef SHADOWS_SHADOWMASK
    shadowContext.shadowSplitIndex = shadowSplitIndex;
    shadowContext.fade = alpha;
#endif

    // Forcing the alpha to zero allows us to avoid the dithering as it requires the screen space position and an additional
    // shadow read wich can be avoided in this case.
#if defined(SHADER_STAGE_RAY_TRACING)
    alpha = 0.0;
#endif

    float3 basePositionWS = positionWS;

    if (shadowSplitIndex >= 0.0)
    {
        HDShadowData sd = shadowContext.shadowDatas[index];
        LoadDirectionalShadowDatas(sd, shadowContext, index + shadowSplitIndex);
        positionWS = basePositionWS + sd.cacheTranslationDelta.xyz;

        /* normal based bias - 使用水面级联的 worldTexelSize */
        // 水面级联分辨率 = _WaterCascadeAtlasSize.x / 2
        // worldTexelSize = 级联覆盖的世界空间范围 / 级联像素分辨率
        float officialTexelSize = sd.worldTexelSize;
        float officialCascadeResolution = sd.shadowMapSize.x;
        float waterCascadeResolution = _WaterCascadeAtlasSize.x * 0.5;
        float worldTexelSize = officialTexelSize * (officialCascadeResolution / waterCascadeResolution);
        
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
        
        // 使用相机相对坐标系统（精度）
        // positionWS 是相机相对坐标
        // _WaterCascadeAtlasVP 已在 C# 端调整为接受相机相对坐标
        // 直接使用，不需要坐标转换
        int cascadeIndex = evalNextCascade ? nextSplit : shadowSplitIndex;
        
        // 相机相对坐标 -> 裁剪空间
        float4 posCS = mul(_WaterCascadeAtlasVP[cascadeIndex], float4(positionWS, 1.0));
        
        // NDC -> [0, 1] 纹理坐标
        float3 posTC = float3(posCS.xy * 0.5 + 0.5, posCS.z);
        
        // 应用水面的级联偏移和尺寸
        float4 waterAtlasOffsetAndSize = _WaterCascadeAtlasOffsetsAndSizes[cascadeIndex];
        posTC.xy = posTC.xy * waterAtlasOffsetAndSize.zw * _WaterCascadeAtlasSize.zw + waterAtlasOffsetAndSize.xy * _WaterCascadeAtlasSize.zw;        

        // 计算阴影
#if !defined(HP_WATER_VOLUME)
        shadow = WATERSHADOW_TEXTURE_FILTER_ALGORITHM(_WaterCascadeAtlasSize.zwxy, posTC, tex, samp, FIXED_UNIFORM_BIAS,worldTexelSize);        
#endif

        // 计算焦散
        caustic = GetHPWaterCaustic(_WaterCascadeAtlasSize.zwxy, posTC, worldTexelSize,cascadeIndex);

#if !defined(HP_WATER_VOLUME)
        caustic = lerp(caustic, 1.0, shadow);
        
        // 计算透射率（水体吸收/散射衰减）
        float transmittance = 1.0;
        {
            // 直接从纹理获取实际尺寸
            uint waterAtlasWidth, waterAtlasHeight;
            _WaterCascadeAtlas.GetDimensions(waterAtlasWidth, waterAtlasHeight);
            
            float waterDepth = _WaterCascadeAtlas.Load(int3(posTC.xy * float2(waterAtlasWidth, waterAtlasHeight), 0)).r;
            float sceneDepth = posTC.z;
            
            float absorptionValue, scatteringValue;
            DecodeHPWaterCausticGBufferUpsampling(_WaterGbuffer1Atlas, _WaterCascadeDepth1Atlas, s_point_clamp_sampler,
                posTC.xy, waterDepth, waterAtlasWidth, absorptionValue, scatteringValue);
            
            float waterDepthMeters = NormalizedDepthToMeters(waterDepth, cascadeIndex);
            float sceneDepthMeters = NormalizedDepthToMeters(sceneDepth, cascadeIndex);
            float realCrossDistance = abs(sceneDepthMeters - waterDepthMeters);
            
            float extinctionCoeff = absorptionValue + scatteringValue;
            transmittance = exp(-extinctionCoeff * realCrossDistance);
            transmittance = lerp(transmittance, 1.0, shadow);
        }
        
        // 应用场景阴影遮蔽 - 与 Blend 版本保持一致的处理方式
        caustic *= shadowValue;
        
        // 漏光部分Mask - 与 Blend 版本一致
        float3 causticLeakMask = smoothstep(_CausticShadowAlphaClipThreshold, 1.0, shadowValue);
        caustic = lerp(shadowValue, caustic, causticLeakMask);
        
        // 应用消光
        caustic *= transmittance;
#endif
        // 焦散级联边界平滑处理
        caustic = (shadowSplitIndex < cascadeCount - 1) ? caustic : lerp(caustic, 1.0, alpha);
    }

    return caustic;
}

float3 EvalHPWaterCaustic_CascadedDepth_Dither(inout HDShadowContext shadowContext, SHADOW_TYPE shadowValue, 
#if !defined(HP_WATER_VOLUME)
    Texture2D tex, SamplerComparisonState samp, 
#endif
float2 positionSS, float3 positionWS, float3 normalWS, int index, float3 L)
{
    int unusedSplitIndex;
    return EvalHPWaterCaustic_CascadedDepth_Dither_SplitIndex(shadowContext, shadowValue,
#if !defined(HP_WATER_VOLUME)
    tex, samp, 
#endif
    positionSS, positionWS, normalWS, index, L, unusedSplitIndex);
}


// 标准模式：使用水面阴影贴图
float3 EvalHPWaterCaustic_CascadedDepth_Blend_SplitIndex(inout HDShadowContext shadowContext, inout SHADOW_TYPE shadowValue,
#if !defined(HP_WATER_VOLUME)
    Texture2D tex, SamplerComparisonState samp, 
#endif
float2 positionSS, float3 positionWS, float3 normalWS, int index, float3 L, out int shadowSplitIndex)
{
    float   alpha;
    int     cascadeCount;
    float   shadow = 1.0;
    float   shadow2 = 1.0;
    float   transmittance = 1.0;
    float   transmittance2 = 1.0;
    float3  caustic = 1.0;
    float3  caustic2 = 1.0;
    
    
    shadowSplitIndex = EvalShadow_GetSplitIndex(shadowContext, index, positionWS, alpha, cascadeCount);
#ifdef SHADOWS_SHADOWMASK
    shadowContext.shadowSplitIndex = shadowSplitIndex;
    shadowContext.fade = alpha;
#endif

    float3 basePositionWS = positionWS;

    if (shadowSplitIndex >= 0.0)
    {
        HDShadowData sd = shadowContext.shadowDatas[index];
        LoadDirectionalShadowDatas(sd, shadowContext, index + shadowSplitIndex);
        positionWS = basePositionWS + sd.cacheTranslationDelta.xyz;

        /* normal based bias - 使用水面级联的 worldTexelSize */
        float officialTexelSize = sd.worldTexelSize;
        float officialCascadeResolution = sd.shadowMapSize.x;
        float waterCascadeResolution = _WaterCascadeAtlasSize.x * 0.5;
        float worldTexelSize = officialTexelSize * (officialCascadeResolution / waterCascadeResolution);
        
        float3 normalBias = EvalShadow_NormalBiasOrtho(worldTexelSize, sd.normalBias, normalWS);
        float3 orig_pos = positionWS;
        positionWS += normalBias;
        
        // 使用相机相对坐标系统
        int cascadeIndex = shadowSplitIndex;
        
        // 相机相对坐标 -> 裁剪空间
        float4 posCS = mul(_WaterCascadeAtlasVP[cascadeIndex], float4(positionWS, 1.0));
        
        // NDC -> [0, 1] 纹理坐标
        float3 posTC = float3(posCS.xy * 0.5 + 0.5, posCS.z);
        
        // 应用水面的级联偏移和尺寸
        float4 waterAtlasOffsetAndSize = _WaterCascadeAtlasOffsetsAndSizes[cascadeIndex];
        posTC.xy = posTC.xy * waterAtlasOffsetAndSize.zw * _WaterCascadeAtlasSize.zw + waterAtlasOffsetAndSize.xy * _WaterCascadeAtlasSize.zw;

        // 计算第一个级联的阴影和焦散
#if !defined(HP_WATER_VOLUME)
        shadow = WATERSHADOW_TEXTURE_FILTER_ALGORITHM(_WaterCascadeAtlasSize.zwxy, posTC, tex, samp, FIXED_UNIFORM_BIAS, worldTexelSize);
#endif          
        caustic = GetHPWaterCaustic(_WaterCascadeAtlasSize.zwxy, posTC, worldTexelSize,cascadeIndex);
        
#if !defined(HP_WATER_VOLUME)             
        caustic = lerp(caustic, 1.0, shadow);
        
        // 公共变量，用于计算透射率
        uint depthWidth = (uint)_WaterCascadeAtlasSize.x;
        
        // 计算第一个级联的透射率（水体吸收/散射衰减）
        {
            float waterDepth = _WaterCascadeAtlas.Load(int3(posTC.xy * float2(depthWidth, depthWidth), 0)).r;
            float sceneDepth = posTC.z;
            
            float absorptionValue, scatteringValue;
            DecodeHPWaterCausticGBufferUpsampling(_WaterGbuffer1Atlas, _WaterCascadeDepth1Atlas, s_point_clamp_sampler,
                posTC.xy, waterDepth, depthWidth, absorptionValue, scatteringValue);
            
            float waterDepthMeters = NormalizedDepthToMeters(waterDepth, cascadeIndex);
            float sceneDepthMeters = NormalizedDepthToMeters(sceneDepth, cascadeIndex);
            float realCrossDistance = abs(sceneDepthMeters - waterDepthMeters);
            
            float extinctionCoeff = absorptionValue + scatteringValue;
            transmittance = exp(-extinctionCoeff * realCrossDistance);
            transmittance = lerp(transmittance, 1.0, shadow);
        }
#endif
        

        shadowSplitIndex++;
        if (shadowSplitIndex < cascadeCount)
        {
            shadow2 = shadow;
            caustic2 = caustic;

            if (alpha > 0.0)
            {
                // 加载下一个级联数据
                LoadDirectionalShadowDatas(sd, shadowContext, index + shadowSplitIndex);

                // 更新 bias（世界纹素大小在级联间变化）
                float officialTexelSize2 = sd.worldTexelSize;
                float officialCascadeResolution2 = sd.shadowMapSize.x;
                float worldTexelSize2 = officialTexelSize2 * (officialCascadeResolution2 / waterCascadeResolution);
                float biasModifier = (worldTexelSize2 / worldTexelSize);
                normalBias *= biasModifier;

                float3 evaluationPosWS = basePositionWS + sd.cacheTranslationDelta.xyz + normalBias;
                
                // 计算下一个级联的坐标
                int cascadeIndex2 = shadowSplitIndex;
                float4 posCS2 = mul(_WaterCascadeAtlasVP[cascadeIndex2], float4(evaluationPosWS, 1.0));
                float3 posNDC = posCS2.xyz;
                float3 posTC2 = float3(posCS2.xy * 0.5 + 0.5, posCS2.z);
                
                float4 waterAtlasOffsetAndSize2 = _WaterCascadeAtlasOffsetsAndSizes[cascadeIndex2];
                posTC2.xy = posTC2.xy * waterAtlasOffsetAndSize2.zw * _WaterCascadeAtlasSize.zw + waterAtlasOffsetAndSize2.xy * _WaterCascadeAtlasSize.zw;

                // 仅在有效范围内采样下一个级联
                UNITY_BRANCH
                if (all(abs(posNDC.xy) <= (1.0 - waterAtlasOffsetAndSize2.zw * _WaterCascadeAtlasSize.zw * 0.5)))
                {
#if !defined(HP_WATER_VOLUME)
                    shadow2 = WATERSHADOW_TEXTURE_FILTER_ALGORITHM(_WaterCascadeAtlasSize.zwxy, posTC2, tex, samp, FIXED_UNIFORM_BIAS, worldTexelSize2);
#endif
                    caustic2 = GetHPWaterCaustic(_WaterCascadeAtlasSize.zwxy, posTC2, worldTexelSize2,cascadeIndex2);

#if !defined(HP_WATER_VOLUME)
                    // 双曲线映射
                    caustic2 = lerp(caustic2, 1.0, shadow2);
                    
                    // 计算第二个级联的透射率（水体吸收/散射衰减）
                    {
                        float waterDepth2 = _WaterCascadeAtlas.Load(int3(posTC2.xy * float2(depthWidth, depthWidth), 0)).r;
                        float sceneDepth2 = posTC2.z;
                        
                        float absorptionValue2, scatteringValue2;
                        DecodeHPWaterCausticGBufferUpsampling(_WaterGbuffer1Atlas, _WaterCascadeDepth1Atlas, s_point_clamp_sampler,
                            posTC2.xy, waterDepth2, depthWidth, absorptionValue2, scatteringValue2);
                        
                        float waterDepthMeters2 = NormalizedDepthToMeters(waterDepth2, cascadeIndex2);
                        float sceneDepthMeters2 = NormalizedDepthToMeters(sceneDepth2, cascadeIndex2);
                        float realCrossDistance2 = abs(sceneDepthMeters2 - waterDepthMeters2);
                        
                        float extinctionCoeff2 = absorptionValue2 + scatteringValue2;
                        transmittance2 = exp(-extinctionCoeff2 * realCrossDistance2);
                        transmittance2 = lerp(transmittance2, 1.0, shadow2);
                    }
#endif
                }
            }
        }
        
        // 在两个级联之间平滑混合焦散，应用场景阴影遮蔽
        caustic = lerp(caustic, caustic2, alpha) * shadowValue;  
#if !defined(HP_WATER_VOLUME)     
        //漏光部分Mask
        //最恶心的地方，漏光原因：
        //焦散在步进的时候是沿直线步进的，但软阴影是模拟光线扩散的过程，而阴影又需要来遮蔽焦散
        //所以当阴影越软时，焦散会漏光越严重，并且焦散没有办法到这里来做PCF或者PCSS，这会糊掉+超级昂贵
        //最后我能想到最优雅的解法是：把阴影的软阴影区域Mask出来，替换为焦散，认定这就是焦散，跟随焦散一起处理消光(transmittance)
        //这样既能解决漏光，又能保持软阴影的质感，只是焦散下阴影的周围会有一圈
        float3 causticLeakMask = smoothstep(_CausticShadowAlphaClipThreshold, 1.0, shadowValue);
        //将阴影的软阴影区域Mask出来，替换为焦散
        caustic = lerp(shadowValue, caustic, causticLeakMask);
        //将两个级联的透射率混合
        transmittance = lerp(transmittance, transmittance2, alpha);
        //应用消光
        caustic *= transmittance;
#endif
    }

    return caustic;
}

float3 EvalHPWaterCaustic_CascadedDepth_Blend(inout HDShadowContext shadowContext, inout SHADOW_TYPE shadowValue, 
#if !defined(HP_WATER_VOLUME)
    Texture2D tex, SamplerComparisonState samp, 
#endif
float2 positionSS, float3 positionWS, float3 normalWS, int index, float3 L)
{
    int unusedSplitIndex;
    return EvalHPWaterCaustic_CascadedDepth_Blend_SplitIndex(shadowContext, shadowValue,
#if !defined(HP_WATER_VOLUME)
    tex, samp, 
#endif
    positionSS, positionWS, normalWS, index, L, unusedSplitIndex);
}

float3 GetCausticDirectionalAttenuation(inout HDShadowContext shadowContext,inout SHADOW_TYPE shadowValue, float2 positionSS, float3 positionWS, float3 normalWS, int shadowDataIndex, float3 L)
{    
    if (_Is_Use_RGB_Caustic < 0)
        return 1;
#if defined(HP_WATER_VOLUME)
    // HP_WATER_VOLUME（无 tex 参数）
    #if defined(SHADOW_ULTRA_LOW) || defined(SHADOW_LOW) || defined(SHADOW_MEDIUM)
        return EvalHPWaterCaustic_CascadedDepth_Dither(shadowContext, shadowValue, positionSS, positionWS, normalWS, shadowDataIndex, L);
    #else
        return EvalHPWaterCaustic_CascadedDepth_Blend(shadowContext, shadowValue, positionSS, positionWS, normalWS, shadowDataIndex, L);
    #endif
#else
    // 标准模式：调用完整版本（有 tex 参数）
    #if defined(SHADOW_ULTRA_LOW) || defined(SHADOW_LOW) || defined(SHADOW_MEDIUM)
        return EvalHPWaterCaustic_CascadedDepth_Dither(shadowContext, shadowValue, _WaterCascadeAtlas, s_linear_clamp_compare_sampler, positionSS, positionWS, normalWS, shadowDataIndex, L);
    #else
        return EvalHPWaterCaustic_CascadedDepth_Blend(shadowContext, shadowValue, _WaterCascadeAtlas, s_linear_clamp_compare_sampler, positionSS, positionWS, normalWS, shadowDataIndex, L);
    #endif
#endif
}
