#ifndef HPWATER_BSDF_LIBARY_HLSL
#define HPWATER_BSDF_LIBARY_HLSL

#if defined(HP_WATER_VOLUME)
#include "Packages/com.unity.render-pipelines.high-definition/Runtime/HanPiWater/Deferred/HPWaterVolumetrics.hlsl"

// ============================================================================
// 水体 BSDF 模型概述
// ============================================================================
//
// 【物理场景：圆锥形薄层 + 深水区域】
//
//              ☀ 光源
//              |
//         波峰（薄层）         thickness ≈ 0
//          /\
//         /  \    ← 薄层：透射率高，fallback 到深水
//        /    \
//       /      \               thickness 渐变
//      /________\  ← 圆锥底部，thickness = 1（薄层与深水边界）
//     |          |
//     |  深水区  |  ← ray marching 区域（macroScattering）
//     |__________|
//          ↓
//        水底
//
// 【散射模型分解】
//
//   1. 宏观体积散射 (diffR)：
//      - 正面入射 → 水下 ray marching → 正面出射
//      - 处理深水区域的体积散射
//
//   2. 薄层散射 (diffT)：
//      - 薄层 SSS：近似深水散射在薄层区域的延续
//      - 背光透射：光直接穿透薄层，强前向散射
//      - 处理波峰、浪花等薄水区域
//
// 【薄层与深水的过渡】
//
//   薄层（thickness 小）→ 透射率高 → 直接使用深水散射颜色（S_volume）
//   厚层（thickness 大）→ 透射率低 → 使用薄层 SSS（近似深水累积）
//
//   通过 sss_transmittance 自动混合两者
//
// 【出射菲涅尔】
//
//   T_exit = 1 - F(NdotV) 在 PostEvaluateBSDF 末尾统一应用
//
// ============================================================================

// ----------------------------------------------------------------------------
// 薄层 SSS 参数
// ----------------------------------------------------------------------------

// SSS 光程缩放（米）
// thickness ∈ [0,1]，乘以此系数得到等效光程
// 值较大（20m）是因为薄层 SSS 近似的是深水区域累积的散射光：
//   - 薄层底部与深水区域连接，thickness=1 时"看到"深水的累积散射
//   - 这个缩放系数让单次计算能匹配深水 ray marching 的视觉效果
#define HPWATER_SSS_PATH_SCALE 20.0

// SSS 非线性修正强度
// 控制厚层时光程的非线性增长，用于匹配深水累积效果
// 0 = 纯线性，1 = 完全非线性
#define HPWATER_SSS_NONLINEAR_STRENGTH 0.5

// SSS 能量补偿系数
// 让薄层 SSS 的亮度与深水 ray marching 的累积效果匹配
#define HPWATER_SSS_SCATTER_BOOST 2.0

// ----------------------------------------------------------------------------
// 背光透射参数
// ----------------------------------------------------------------------------

// 背光透射光程缩放（米）
// 独立于 SSS，用于计算直接穿透的衰减
// 通常比 SSS 光程短，因为是更纯粹的穿透路径
#define HPWATER_BACKLIT_PATH_SCALE 20.0

// ----------------------------------------------------------------------------
// 通用参数
// ----------------------------------------------------------------------------

// Snell 折射率比：空气→水
#define HPWATER_AIR_TO_WATER_ETA (1.0 / 1.33)

#endif

void WaterPostEvaluateBSDF(WaterLightLoopData waterLightLoopData,LightLoopContext lightLoopContext,
    float3 V, PositionInputs posInput,
    PreLightData preLightData, BSDFData bsdfData, BuiltinData builtinData, AggregateLighting lighting,
    out LightLoopOutput lightLoopOutput)
{

    float3 TotalIndirectLighting = 0;
    float3 transmittance = 0;
    float3 indirectLighting = builtinData.bakeDiffuseLighting * _IndirectLightStrength;

    // 与 HPWaterVolumetrics 一致的指数步进优化
    float rcpCount = rcp(float(WATER_SAMPLE_COUNT));
    float kDenom = rcp(EXP_FACTOR - 1.0);
    float kDD = log(EXP_FACTOR) * rcpCount * kDenom;
    float expStep = pow(EXP_FACTOR, rcpCount);
    float currentExp = pow(EXP_FACTOR, waterLightLoopData.Dither * rcpCount);

    for (int count = 0; count < WATER_SAMPLE_COUNT; count++)
    {
        float dd = currentExp * kDD;
        float crossDistance = dd * (waterLightLoopData.NoLinearRayLength + waterLightLoopData.NoLinearAmbientDepth);
        crossDistance = max(crossDistance, 0.00001);

        float3 indirectScatteredLight = WaterVolumeLightLoop::CaculateScatteredLight(
            indirectLighting, waterLightLoopData.AbsorptionCoefficient, waterLightLoopData.ScatterCoefficient,
            crossDistance, 1, transmittance);

        TotalIndirectLighting += indirectScatteredLight;
        currentExp *= expStep;
    }

    // 出射菲尼尔已移至 HPWaterVolumeDeferred.compute Composite 阶段统一应用
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

    float3 transmittance = 1;        

#if defined(HP_WATER_VOLUME)
    // ============================================================================
    // 水体 BSDF 模型（类比 BRDF 的 DGF 分解）
    // ============================================================================
    //
    // 关于 diffR / diffT 的命名（HDRP CBSDF 结构）：
    //   R = Reflection：光从表面"同一侧"出射（入射/出射在法线同侧）
    //   T = Transmission：光从表面"另一侧"穿过（入射/出射在法线两侧）
    //
    // 输出：
    //   diffR = 宏观体积散射（正面入射 → 水下散射 → 正面出射）→ 反射方向
    //   diffT = 薄层散射 + 背光透射（光穿过薄层后出射）→ 透射方向
    //
    // 出射菲涅尔 T_exit = 1 - F(NdotV) 在 PostEvaluateBSDF 末尾统一处理
    // ============================================================================

    // --------------------------------
    // 预计算：前向散射颜色（屏幕空间模糊）
    // --------------------------------
    float forwardScatterBlurDensity = Luminance(waterLightLoopData.ScatterCoefficient);
    float blurMipLevel = CalculateHPWaterMipLevel(
        waterLightLoopData.NoLinearRayLength, FORWARD_SCALING_FACTOR, forwardScatterBlurDensity, 6);
    float3 forwardScatterColor = HPSampleCameraColor(
        waterLightLoopData.RefractWaterScreenCoord.xy, clamp(blurMipLevel, 2, 6)).rgb * _MultiScatterScale;

    // ============================================================================
    // Part 1: 宏观体积散射 (Macro Volume Scattering) → diffR
    // ============================================================================
    // 物理流程：空气 → [入射] → 水体 → [体积散射] → [出射] → 摄像机
    //
    // 公式：diffR = T_entry × G_entry × S_volume
    //   - T_entry：入射菲涅尔透射
    //   - G_entry：入射几何项（wrapped NdotL）
    //   - S_volume：体积散射（ray marching 累加）
    // --------------------------------

    // T_entry：入射菲涅尔透射 = 1 - F(NdotL)
    // 光从空气进入水面时，未被反射的部分
    float3 T_entry = 1.0 - F_Schlick(bsdfData.fresnel0, clampedNdotL_LF);

    // G_entry：入射几何项 = wrapped(NdotL)
    // 宏观入射光分布，wrap=0.1 让侧面也有少量光进入
    float G_entry = clampedNdotL_LF;

    // 水下入射光能量
    float3 underwaterLight = G_entry * T_entry;

    // S_volume：体积散射（ray marching）
    // 计算光在水体内的多次散射累加
    SHADOW_TYPE lastShadowValue;
    float3 S_volume = WaterVolumetrics(waterLightLoopData,
        featureFlags, _MaxCrossDistance, posInput.positionNDC.xy, L, LightColor,
        forwardScatterColor,
        posInput, lightLoopContext, bsdfData, clampedNdotV, transmittance, lastShadowValue);

    _HPWaterTransmittance = transmittance;

    // diffR = 入射 × 体积散射
    float3 macroScattering = S_volume * underwaterLight;

    // ============================================================================
    // Part 2: 薄层 SSS (Thin Layer Subsurface Scattering) → diffT 的一部分
    // ============================================================================
    //
    // 【物理意义】
    //
    //   薄层 SSS 是深水散射在薄层区域的延续：
    //   - 薄层底部与深水连接，thickness=1 时"看到"深水累积散射
    //   - 用单次计算近似深水 ray marching 的视觉效果
    //
    //     光源 ☀
    //       |
    //       ↓ 入射
    //   ════════════  水面
    //       ↓
    //      ╱ ╲        ← 散射（近似深水累积）
    //     ╱   ╲
    //    ↗     ↖      ← 部分光出射
    //   ════════════  水面
    //       ↑
    //      👁 摄像机
    //
    // 【光程计算：线性 + 非线性修正】
    //
    //   薄层 SSS 近似深水散射在薄层区域的延续：
    //   - thickness=1 时，薄层底部与深水连接，需要匹配深水 ray marching 的效果
    //   - 光程缩放较大（20m）是为了让单次计算产生类似的视觉效果
    //
    //   薄层（d → 0）：透射率高，fallback 到 S_volume，光程影响小
    //   厚层（d → 1）：需要更长光程来匹配深水累积效果
    //
    //   L_linear = d × scale
    //   L_nonlinear = d² × scale × (1 + μs)
    //   L_effective = lerp(L_linear, L_nonlinear, τ × strength)
    //
    // 【公式】
    //
    //   SSS = LightColor × S_sss × P_sss × Shadow × Boost
    //     - S_sss：散射光量（Beer-Lambert + 散射）
    //     - P_sss：相位函数（散射方向性）
    //
    // --------------------------------

    // thickness：归一化厚度 [0, 1]
    //   0 = 极薄（波峰顶部）
    //   1 = 最厚（深水区域边界）
    // 通常由高度场或法线近似得到，乘以 SCALE 转换为实际光程（米）
    float thickness = max(bsdfData.thickness, 0.001);
    
    // 消光系数（用于光学深度计算）
    float3 sss_extinctionCoeff = bsdfData.absorptionColor + bsdfData.scatterColor;
    float sss_extinctionScalar = Luminance(sss_extinctionCoeff);
    
    // 光程计算：线性 + 非线性修正
    // 
    // 线性部分：薄层区域，散射效果较弱
    float L_linear = thickness * HPWATER_SSS_PATH_SCALE;
    
    // 非线性部分：厚层区域，需要更长光程来匹配深水累积效果
    // d² 让光程在 thickness 接近 1 时增长更快
    float scatterStrength = Luminance(bsdfData.scatterColor);
    float L_nonlinear = thickness * thickness * HPWATER_SSS_PATH_SCALE * (1.0 + scatterStrength);
    
    // 光学深度决定线性/非线性的混合比例
    // τ 大时使用非线性，匹配深水散射的累积特性
    float opticalDepth = sss_extinctionScalar * thickness * HPWATER_SSS_PATH_SCALE;
    float nonlinearWeight = saturate(opticalDepth * HPWATER_SSS_NONLINEAR_STRENGTH);
    
    // 有效光程
    float sssPathLength = lerp(L_linear, L_nonlinear, nonlinearWeight);

    // P_sss：相位函数
    // cosTheta = dot(-V, L)：从摄像机反方向看向光源的夹角
    float sss_cosTheta = dot(-V, L);
    float3 P_sss = CaculateScatterPhase(sss_cosTheta, _PhaseG);

    // S_sss：散射光计算
    float3 sss_transmittance;
    float3 S_sss = WaterVolumeLightLoop::CaculateScatteredLight(
        LightColor, bsdfData.absorptionColor, bsdfData.scatterColor,
        sssPathLength, P_sss, sss_transmittance);

    // --------------------------------
    // G_sss：薄层 SSS 入射项
    // --------------------------------
    //
    // 【物理分工】
    //
    //   正面入射（NdotL > 0）：
    //     └─ 大部分光穿过薄层进入深水 → diffR 处理
    //     └─ G_sss 弱化，避免与 diffR 重复
    //
    //   侧面/背面入射（NdotL ≤ 0）：
    //     └─ diffR 的 G_entry 为 0，深水散射无贡献
    //     └─ G_sss = 1，薄层散射主导
    //
    // 公式：G_sss = 1 - G_entry = 1 - clampedNdotL
    //
    float G_sss = 1.0 - G_entry;
    
    // 薄层 SSS 输出 = 入射项 × 散射 × 阴影 × 补偿
    float3 thinLayerSSS = S_sss * G_sss * lastShadowValue * HPWATER_SSS_SCATTER_BOOST;

    // --------------------------------
    // 薄层与深水的混合（Fallback 机制）
    // --------------------------------
    //
    //   薄层区域（thickness 小）：
    //     └─ transmittance 高 → sssWeight 低
    //     └─ 直接使用深水散射颜色（S_volume）
    //
    //   厚层区域（thickness 大）：
    //     └─ transmittance 低 → sssWeight 高
    //     └─ 使用薄层 SSS（近似深水累积散射的延续）
    //
    //   注意：两个分支都乘以 G_sss，保持入射分工一致
    //
    float sssWeight = saturate(1.0 - Luminance(sss_transmittance));
    thinLayerSSS = lerp(S_volume * G_sss, thinLayerSSS, sssWeight);

    // ============================================================================
    // Part 3: 背光透射 (Backlit Transmission) → diffT 的一部分
    // ============================================================================
    //
    // 【物理流程】
    //
    //           ☀ 光源
    //            \
    //             \  入射
    //   ══════════════════  水面（背面）
    //              \
    //               → → →   ← 光直接穿透（Beer-Lambert 衰减）
    //              /
    //   ══════════════════  水面（正面）
    //             /
    //            ↗ 出射（强前向散射）
    //           👁
    //          摄像机
    //
    // 【与薄层 SSS 的区别】
    //
    //   薄层 SSS：光散射后出射，方向较分散（相位函数 g ≈ 0.8）
    //   背光透射：光几乎直穿，极强方向性（相位函数 g ≈ 0.999）
    //
    // 【典型场景】
    //
    //   - 波峰薄处的阳光穿透
    //   - 浪花边缘的透光
    //   - 看向太阳时水面的辉光
    //
    // 【公式】
    //
    //   Backlit = LightColor × G_backlit × T_backlit × P_backlit × Shadow
    //     - G_backlit：背面入射投影 = saturate(-NdotL)
    //     - T_backlit：Beer-Lambert 透射率
    //     - P_backlit：前向相位函数（g ≈ 0.999）
    //
    // --------------------------------

    // G_backlit：背面入射投影
    // 光从背面入射，投影面积 = saturate(-NdotL)
    //   NdotL = -1（背面正对光源）→ G = 1（完整入射）
    //   NdotL = 0 （侧面）        → G = 0（无入射）
    //   NdotL > 0 （正面）        → G = 0（光从正面入射，不是背光）
    float G_backlit = saturate(-NdotL_LF);

    // 光程计算（独立的较短光程，纯穿透路径）
    float backlitPathLength = thickness * HPWATER_BACKLIT_PATH_SCALE;

    // T_backlit：Beer-Lambert 透射
    // 使用已计算的消光系数
    float3 T_backlit = exp(-sss_extinctionCoeff * backlitPathLength);

    // P_backlit：前向相位函数
    // cosTheta = dot(V, -L)：摄像机看向光源穿透方向
    // g = 0.9985：极强前向散射，只在看向光源时才有明显贡献
    float backlit_cosTheta = dot(V, -L);
    float backlit_g = 0.9998;
    float P_backlit = HenyeyPhase(backlit_cosTheta, backlit_g);

    // 背光透射输出 = 入射投影 × 透射率 × 相位函数
    float3 backlitTransmission = LightColor * G_backlit * T_backlit * P_backlit * lastShadowValue;

    // ============================================================================
    // Part 4: 输出汇总（无遮罩，各组件自带入射项）
    // ============================================================================
    //
    // 【物理分工模型】
    //
    //   每个组件有独立的入射几何项，自然分离，无需额外遮罩：
    //
    //   ┌─────────────────────────────────────────────────────────────┐
    //   │                                                             │
    //   │  diffR = G_entry × T_entry × S_volume                      │
    //   │        │                                                    │
    //   │        └─ G_entry = clampedNdotL（正面入射）               │
    //   │           正面：G = 1，深水散射主导                         │
    //   │           背面：G = 0，无贡献                               │
    //   │                                                             │
    //   │  diffT = thinLayerSSS + backlitTransmission                │
    //   │        │                                                    │
    //   │        ├─ thinLayerSSS：G_sss = 1 - G_entry                │
    //   │        │     正面：G = 0，弱化（避免与 diffR 重复）        │
    //   │        │     背面：G = 1，薄层散射主导                      │
    //   │        │                                                    │
    //   │        └─ backlitTransmission：G_backlit = saturate(-NdotL)│
    //   │              正面：G = 0，无背光透射                        │
    //   │              背面：G > 0，背光穿透                          │
    //   │                                                             │
    //   │  最终出射：× T_exit = 1 - F(NdotV)                         │
    //   │          （在 PostEvaluateBSDF 末尾统一应用）               │
    //   │                                                             │
    //   └─────────────────────────────────────────────────────────────┘
    //
    // 【入射分工图示】
    //
    //        G_entry (diffR)     G_sss (thinLayerSSS)    G_backlit
    //     1 ─┐                 1 ─────────────┐        1 ─┐
    //        │\                               │           │\
    //        │ \                             /│           │ \
    //     0 ─┴──┴─────────    0 ─┴─────────┴──    0 ─────┴──┴─
    //       -1    0    +1       -1    0    +1       -1    0    +1
    //      背面  侧面  正面    背面  侧面  正面    背面  侧面  正面
    //
    //   正面（NdotL=1）：diffR 主导，diffT ≈ 0
    //   侧面（NdotL=0）：thinLayerSSS 主导
    //   背面（NdotL=-1）：thinLayerSSS + backlitTransmission
    //
    // --------------------------------
    cbsdf.diffR = macroScattering;
    cbsdf.diffT = thinLayerSSS + backlitTransmission;
                
#else
    float3 sceneColor = HPSampleCameraColor(sceneScreenCoord.xy, 0).rgb;
    cbsdf.diffR = sceneColor * transmittance * GetInverseCurrentExposureMultiplier();
    cbsdf.diffT = 0;
#endif
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

        // 官方公式：diffR + diffT * transmittance
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

        // 水面忽略太阳角半径对粗糙度的影响，但设置最小粗糙度防止高光消失
        // 0.002 对应 perceptualSmoothness ≈ 0.955，足够光滑且避免数值问题
        ClampRoughness(preLightData, bsdfData, 0.002);

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