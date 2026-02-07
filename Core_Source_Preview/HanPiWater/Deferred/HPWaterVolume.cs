using UnityEngine.Experimental.Rendering;
using UnityEngine.Experimental.Rendering.RenderGraphModule;

namespace UnityEngine.Rendering.HighDefinition
{
    public partial class HDRenderPipeline
    {
        // 水体积历史纹理（用于 Temporal Filtering）
        RTHandle m_WaterVolumeHistoryColor = null;
        RTHandle m_WaterVolumeHistoryAbsorbance = null;
        RTHandle m_WaterVolumeHistoryDepth = null;
        bool m_WaterVolumeFirstFrame = true;
        int m_WaterVolumeHistoryWidth = 0;
        int m_WaterVolumeHistoryHeight = 0;

        static partial class HPWaterVolumeShaderIDs
        {
            // Shader properties
            // 注意：水面深度已写入主场景深度，使用 HDShaderIDs._DepthTexture
            public static readonly int _HPWaterGBuffer0 = Shader.PropertyToID("_HPWaterGBuffer0");
            public static readonly int _HPWaterGBuffer1 = Shader.PropertyToID("_HPWaterGBuffer1");
            public static readonly int _HPWaterGBuffer2 = Shader.PropertyToID("_HPWaterGBuffer2");
            public static readonly int _HPWaterOutputTexture = Shader.PropertyToID("_HPWaterOutputTexture");
            public static readonly int _HPWaterAbsorbanceTexture = Shader.PropertyToID("_HPWaterAbsorbanceTexture");
            public static readonly int _HPWaterLowResColor = Shader.PropertyToID("_HPWaterLowResColor");
            public static readonly int _HPWaterLowResAbsorbance = Shader.PropertyToID("_HPWaterLowResAbsorbance");
            public static readonly int _HPWaterLowResDepth = Shader.PropertyToID("_HPWaterLowResDepth");
            public static readonly int _HPWaterCompositeOutput = Shader.PropertyToID("_HPWaterCompositeOutput");
            public static readonly int _HPWaterHistoryColor = Shader.PropertyToID("_HPWaterHistoryColor");
            public static readonly int _HPWaterHistoryAbsorbance = Shader.PropertyToID("_HPWaterHistoryAbsorbance");
            public static readonly int _HPWaterHistoryDepth = Shader.PropertyToID("_HPWaterHistoryDepth");
            public static readonly int _HPWaterDepthOutputTexture = Shader.PropertyToID("_HPWaterDepthOutputTexture");
            public static readonly int _HPWaterTemporalParams = Shader.PropertyToID("_HPWaterTemporalParams");
            public static readonly int _HPWaterFilterParams = Shader.PropertyToID("_HPWaterFilterParams");
            public static readonly int _HPWaterShadowParams = Shader.PropertyToID("_HPWaterShadowParams");
            public static readonly int _AtrousStride = Shader.PropertyToID("_AtrousStride");
            public static readonly int _MaxCrossDistance = Shader.PropertyToID("_MaxCrossDistance");
            public static readonly int _IndirectLightStrength = Shader.PropertyToID("_IndirectLightStrength");
            public static readonly int _MaxRefractionCrossDistance = Shader.PropertyToID("_MaxRefractionCrossDistance");
            public static readonly int _RefractionStrength = Shader.PropertyToID("_RefractionStrength");
            public static readonly int _GBufferTexture3 = Shader.PropertyToID("_GBufferTexture3");
            public static readonly int _HPWaterColorUVScale = Shader.PropertyToID("_HPWaterColorUVScale");
            public static readonly int _HPWaterVolumeResolution = Shader.PropertyToID("_HPWaterVolumeResolution");
            // 折射 UV 纹理
            public static readonly int _HPWaterRefractionUVBuffer = Shader.PropertyToID("_HPWaterRefractionUVBuffer");
        }

        /// <summary>
        /// 水体延迟渲染 PassData
        /// </summary>
        class RenderWaterVolumePassData
        {
            public HDCamera hdCamera;
            public FrameSettings frameSettings;
            public ComputeShader m_HanPiWaterVolumeCS;
            public int m_HanPiWaterVolumeKernel;
            public int viewCount;

            // Input textures
            public TextureHandle colorBuffer;
            public TextureHandle depthBuffer;          // 主场景深度（包含水面，用于水面深度 + Stencil）
            public TextureHandle depthPyramidBuffer;  // 场景深度（不含水面，用于场景深度）
            public TextureHandle normalBuffer;
            public TextureHandle causticCascadeAtlas;
            public TextureHandle causticCascadeAtlasR;
            public TextureHandle causticCascadeAtlasG;
            public TextureHandle causticCascadeAtlasB;
            public TextureHandle causticNormalAtlas;
            public TextureHandle motionVectorsBuffer;  // 用于历史帧混合去残影
            // 折射 UV 纹理
            public TextureHandle refractionDataBuffer;    // 全分辨率 UV 偏移
            
            // HPWater GBuffer 纹理 (全部全分辨率，一次 3 MRT 绘制)
            public TextureHandle waterGBuffer0;         // normalWS + roughness
            public TextureHandle waterGBuffer1;         // scatterColor
            public TextureHandle waterGBuffer2;         // absorptionColor + foam

            // Lighting buffers
            public LightingBuffers lightingBuffers;
            
            // Light list
            public ComputeBufferHandle lightListBuffer;
            
            // Output textures
            public TextureHandle lowResColorBuffer;      // 低分辨率水体颜色（当前帧）
            public TextureHandle absorbanceBuffer;       // 吸收缓冲（当前帧）
            public TextureHandle depthOutputBuffer;      // 深度输出缓冲（当前帧）
            
            // History textures (for temporal filtering)
            public TextureHandle historyColorBuffer;      // 历史颜色缓冲（上一帧）
            public TextureHandle historyAbsorbanceBuffer; // 历史吸收缓冲（上一帧）
            public TextureHandle historyDepthBuffer;      // 历史深度缓冲（上一帧）
            
            // Temporal parameters
            public float temporalBlendFactor;             // 时间混合因子 (0.9 = 90% history)
            public bool isFirstFrame;                     // 是否首帧（禁用混合）

            // Water volume input data
            public HPWaterVolumeInputData waterVolumeInputData;
        }

        /// <summary>
        /// 水体合成 PassData
        /// </summary>
        class CompositeWaterVolumePassData
        {
            public HDCamera hdCamera;
            public ComputeShader m_HanPiWaterVolumeCS;
            public int compositeKernel;
            public int viewCount;
            
            // Input textures
            public TextureHandle colorBuffer;
            public TextureHandle depthBuffer;      // 主场景深度（包含水面，用于 Stencil）
            public TextureHandle depthPyramidBuffer;  // 场景深度（不含水面）
            public TextureHandle lowResColorBuffer;
            public TextureHandle absorbanceBuffer;
            public TextureHandle lowResDepthBuffer;    // 低分辨率深度（折射后的场景深度）
            // 折射 UV 纹理
            public TextureHandle refractionUVBuffer;    // 全分辨率 UV 偏移
            public TextureHandle ssrLightingBuffer; // SSR 光照缓冲
            
            // HPWater GBuffer 纹理
            public TextureHandle waterGBuffer0;         // normalWS + roughness
            public TextureHandle waterGBuffer1;         // scatterColor
            public TextureHandle waterGBuffer2;         // absorptionColor + foam
            
            // Output texture
            public TextureHandle outputColorBuffer;
            
            // Resolution info
            public Vector4 volumeResolution;
            
            // Switches
            public bool enableDepthAwareUpsampling;
        }

        /// <summary>
        /// 水体参数
        /// </summary>
        public class HPWaterVolumeInputData
        {
            public float resolutionScale = 0.5f;
            public float temporalBlendFactor = 0.9f;  // 时间滤波混合因子
            public bool enableSpatialFilter = true;   // 启用空间滤波
            public int spatialFilterIterations = 2;   // À-trous滤波迭代次数
            public bool enableDepthAwareUpsampling = true; // 启用深度感知上采样
            public bool enableMotionVectors = true;   // 启用运动矢量
            public float motionVectorVelocityScale = 0.1f; // 速度权重
            public bool enableTemporalDepthRejection = true; // 启用时间深度拒绝
            public float temporalDepthThreshold = 0.5f; // 时间深度阈值
            public bool enableSpatialDepthAware = true; // 启用空间深度感知
            public float spatialDepthSensitivity = 100.0f; // 空间深度敏感度
            
            // Shadow params
            public float shadowSoftness = 1.0f;
            public int blockerSampleCount = 16;
            public int filterSampleCount = 16;
            public float minFilterSize = 0.1f;
        }

        /// <summary>
        /// 水体参数提供回调，由外部系统提供水体渲染所需的参数
        /// </summary>
        public delegate HPWaterVolumeInputData HPWaterVolumeInputDataProvider();

        /// <summary>
        /// 水体参数提供者事件，在需要水体参数时触发
        /// </summary>
        public static event HPWaterVolumeInputDataProvider OnGetHPWaterVolumeInputData;

        /// <summary>
        /// 确保水体积历史纹理已创建且尺寸正确
        /// </summary>
        void EnsureWaterVolumeHistoryBuffers(int width, int height)
        {
            // 检查是否需要重新分配（分辨率变化）
            if (m_WaterVolumeHistoryColor != null && 
                (m_WaterVolumeHistoryWidth != width || m_WaterVolumeHistoryHeight != height))
            {
                RTHandles.Release(m_WaterVolumeHistoryColor);
                RTHandles.Release(m_WaterVolumeHistoryAbsorbance);
                RTHandles.Release(m_WaterVolumeHistoryDepth);
                m_WaterVolumeHistoryColor = null;
                m_WaterVolumeHistoryAbsorbance = null;
                m_WaterVolumeHistoryDepth = null;
                m_WaterVolumeFirstFrame = true;
            }
            
            // 创建历史纹理
            if (m_WaterVolumeHistoryColor == null)
            {
                m_WaterVolumeHistoryColor = RTHandles.Alloc(
                    width, height,
                    TextureXR.slices,
                    dimension: TextureXR.dimension,
                    colorFormat: GraphicsFormat.B10G11R11_UFloatPack32,
                    enableRandomWrite: true,
                    name: "WaterVolumeHistoryColor"
                );
                
                m_WaterVolumeHistoryAbsorbance = RTHandles.Alloc(
                    width, height,
                    TextureXR.slices,
                    dimension: TextureXR.dimension,
                    colorFormat: GraphicsFormat.B10G11R11_UFloatPack32,
                    enableRandomWrite: true,
                    name: "WaterVolumeHistoryAbsorbance"
                );
                
                m_WaterVolumeHistoryDepth = RTHandles.Alloc(
                    width, height,
                    TextureXR.slices,
                    dimension: TextureXR.dimension,
                    colorFormat: GraphicsFormat.R16_SFloat,
                    enableRandomWrite: true,
                    name: "WaterVolumeHistoryDepth"
                );
                
                m_WaterVolumeHistoryWidth = width;
                m_WaterVolumeHistoryHeight = height;
                m_WaterVolumeFirstFrame = true;
            }
        }

        /// <summary>
        /// 渲染水体延迟光照（使用自定义 LightLoop）
        /// </summary>
        /// <param name="depthPyramidTexture">场景深度（不含水面，用于计算水体厚度）</param>
        /// <param name="waterRefractionData">折射纹理数据（UV + 0 + W为是否为水面）</param>
        TextureHandle RenderHPWaterDeferredLighting(        
            RenderGraph renderGraph,
            HDCamera hdCamera,
            TextureHandle colorBuffer,
            TextureHandle colorPyramid,
            CausticPackage causticToDeferredData,
            HPWaterGbufferData waterGbufferData,
            TextureHandle depthPyramidTexture,
            in LightingBuffers lightingBuffers,
            in BuildGPULightListOutput lightLists,
            in ShadowResult shadowResult,
            TextureHandle motionVectorsBuffer,
            HPWaterRefractionOutput waterRefractionData, // 折射纹理数据（UV + 0 + W为是否为水面）
            TextureHandle ssrLightingBuffer) // SSR 光照缓冲
            
        {
            // 如果没有水体 GBuffer 数据，直接返回
            if (waterGbufferData == null || !waterGbufferData.waterDepthBuffer.IsValid())
                return colorBuffer;

            // 空值检查（renderGraph 必须有效才能创建 emptyData）
            if (OnGetHPWaterVolumeInputData == null)
                return colorBuffer;

            var parameters = OnGetHPWaterVolumeInputData.Invoke();

            // 验证参数有效性
            if (parameters == null)
            {
#if UNITY_EDITOR || DEVELOPMENT_BUILD
                Debug.LogWarning("[HPWaterVolume] Water Volume Input Data is invalid");
#endif
                return colorBuffer;
            }

            // 如果没有提供有效的 compute shader 或 kernel，直接返回
            if (m_HanPiWaterVolumeCS == null || m_HanPiWaterVolumeKernel < 0 ||
                m_HanPiWaterVolumeSpatialFilterKernel < 0 || m_HanPiWaterVolumeCompositeKernel < 0)
                return colorBuffer;

            // 计算低分辨率尺寸
            float resScale = Mathf.Clamp(parameters.resolutionScale, 0.01f, 1.0f);
            int lowResWidth = Mathf.Max(1, (int)(hdCamera.actualWidth * resScale));
            int lowResHeight = Mathf.Max(1, (int)(hdCamera.actualHeight * resScale));

            // 确保历史纹理已创建且尺寸正确
            EnsureWaterVolumeHistoryBuffers(lowResWidth, lowResHeight);

            // Pass 1: 在低分辨率下渲染水体体积光照
            TextureHandle lowResColorBuffer;
            TextureHandle absorbanceBuffer;
            // ========================================================================
            // DownSample处理水体散射和吸收率
            // ========================================================================
            using (var builder = renderGraph.AddRenderPass<RenderWaterVolumePassData>(
                "HanPi Water Volume Deferred Lighting (LowRes)", out var passData, new ProfilingSampler("HanPi Water Volume Deferred Lighting")))
            {
                // 准备 pass data
                passData.hdCamera = hdCamera;
                passData.frameSettings = hdCamera.frameSettings;
                passData.m_HanPiWaterVolumeCS = m_HanPiWaterVolumeCS;
                passData.m_HanPiWaterVolumeKernel = m_HanPiWaterVolumeKernel;
                passData.viewCount = hdCamera.viewCount;
                passData.waterVolumeInputData = parameters;

                // 读取输入纹理
                passData.colorBuffer = builder.ReadTexture(colorPyramid);
                passData.depthBuffer = builder.UseDepthBuffer(waterGbufferData.waterDepthBuffer, DepthAccess.Read);
                passData.depthPyramidBuffer = builder.ReadTexture(depthPyramidTexture);  // 场景深度（不含水面）
                passData.normalBuffer = builder.ReadTexture(waterGbufferData.waterGBuffer0);

                // 初始化焦散纹理 Handle 为默认贴图，防止绑定为空
                // 焦散纹理使用黑色 uint 纹理（值为 0 表示无焦散强度）
                passData.causticCascadeAtlas = renderGraph.defaultResources.blackUIntTextureXR;
                passData.causticCascadeAtlasR = renderGraph.defaultResources.blackUIntTextureXR;
                passData.causticCascadeAtlasG = renderGraph.defaultResources.blackUIntTextureXR;
                passData.causticCascadeAtlasB = renderGraph.defaultResources.blackUIntTextureXR;
                passData.causticNormalAtlas = renderGraph.defaultResources.whiteTexture;
                // 验证焦散纹理是否有效
                causticToDeferredData = IsCausticDataValid(causticToDeferredData, renderGraph);
                passData.causticCascadeAtlasR = builder.ReadTexture(causticToDeferredData.causticColorR);
                passData.causticCascadeAtlasG = builder.ReadTexture(causticToDeferredData.causticColorG);
                passData.causticCascadeAtlasB = builder.ReadTexture(causticToDeferredData.causticColorB);
                passData.causticCascadeAtlas = builder.ReadTexture(causticToDeferredData.causticColorFloat);
                passData.causticNormalAtlas = builder.ReadTexture(causticToDeferredData.causticGbuffer0);
                
                // 读取 HPWater GBuffer 纹理 (3 个)
                passData.waterGBuffer0 = builder.ReadTexture(waterGbufferData.waterGBuffer0);
                passData.waterGBuffer1 = builder.ReadTexture(waterGbufferData.waterGBuffer1);
                passData.waterGBuffer2 = builder.ReadTexture(waterGbufferData.waterGBuffer2);

                // 读取光照缓冲区
                passData.lightingBuffers = ReadLightingBuffers(lightingBuffers, builder);

                // 读取光源列表
                passData.lightListBuffer = builder.ReadComputeBuffer(lightLists.lightList);

                // 读取阴影数据
                HDShadowManager.ReadShadowResult(shadowResult, builder);

                // 导入历史纹理（读取上一帧数据，写入更新后数据）
                // 注意：历史纹理通过 CopyTexture 写入，需要声明 ReadWrite 权限
                passData.historyColorBuffer = builder.ReadWriteTexture(renderGraph.ImportTexture(m_WaterVolumeHistoryColor));
                passData.historyAbsorbanceBuffer = builder.ReadWriteTexture(renderGraph.ImportTexture(m_WaterVolumeHistoryAbsorbance));
                passData.historyDepthBuffer = builder.ReadWriteTexture(renderGraph.ImportTexture(m_WaterVolumeHistoryDepth));
                passData.temporalBlendFactor = Mathf.Clamp(parameters.temporalBlendFactor, 0f, 0.99f);
                passData.isFirstFrame = m_WaterVolumeFirstFrame;

                // 读取运动矢量
                passData.motionVectorsBuffer = builder.ReadTexture(motionVectorsBuffer);

                // 读取折射 UV 纹理
                passData.refractionDataBuffer = builder.ReadTexture(waterRefractionData.refractionData);

                // 创建低分辨率输出纹理 - 使用 R11G11B10 格式节省带宽 (HDR, 32-bit)
                var lowResColorDesc = new TextureDesc(lowResWidth, lowResHeight)
                {
                    slices = TextureXR.slices,  // 支持 XR
                    dimension = TextureXR.dimension,  // 支持 XR
                    colorFormat = GraphicsFormat.B10G11R11_UFloatPack32,  // HDR, 32-bit, 适合水体颜色
                    enableRandomWrite = true,
                    name = "HPWaterVolume_LowResColor",
                    clearBuffer = true,
                    clearColor = Color.clear
                };
                passData.lowResColorBuffer = builder.WriteTexture(renderGraph.CreateTexture(lowResColorDesc));
                
                // 创建吸收缓冲区 - 使用 RGBA32 UNorm 格式 (32-bit)
                // 吸收值范围 [0,1]，可以用 8-bit UNorm，但可能有轻微色带
                // 如果出现色带，可以改回 R16G16B16A16_SFloat (64-bit)
                var absorbanceDesc = new TextureDesc(lowResWidth, lowResHeight)
                {
                    slices = TextureXR.slices,  // 支持 XR
                    dimension = TextureXR.dimension,  // 支持 XR
                    colorFormat = GraphicsFormat.B10G11R11_UFloatPack32,  // Half float, 64-bit, 吸收需要精度
                    enableRandomWrite = true,
                    name = "HPWaterVolume_Absorbance",
                    clearBuffer = true,
                    clearColor = Color.clear  // 默认无吸收
                };
                passData.absorbanceBuffer = builder.WriteTexture(renderGraph.CreateTexture(absorbanceDesc));
                
                // 创建深度输出纹理 (用于下一帧对比)
                var depthOutputDesc = new TextureDesc(lowResWidth, lowResHeight)
                {
                    slices = TextureXR.slices,
                    dimension = TextureXR.dimension,
                    colorFormat = GraphicsFormat.R16_SFloat,
                    enableRandomWrite = true,
                    name = "HPWaterVolume_DepthOutput",
                    clearBuffer = true,
                    clearColor = Color.clear
                };
                passData.depthOutputBuffer = builder.WriteTexture(renderGraph.CreateTexture(depthOutputDesc));


                // 设置渲染函数
                builder.SetRenderFunc((RenderWaterVolumePassData data, RenderGraphContext ctx) =>
                {
                    // 绑定输入纹理
                    ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.m_HanPiWaterVolumeKernel, 
                        HDShaderIDs._CameraColorTexture, data.colorBuffer);
                    // 绑定深度纹理
                    // _DepthTexture = depthBuffer（包含水面）→ 用于水面深度
                    ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.m_HanPiWaterVolumeKernel, 
                        HDShaderIDs._DepthTexture, data.depthBuffer);
                    // _CameraDepthTexture = depthPyramidTexture（不含水面）→ 用于场景深度
                    ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.m_HanPiWaterVolumeKernel, 
                        HDShaderIDs._CameraDepthTexture, data.depthPyramidBuffer);
                    ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.m_HanPiWaterVolumeKernel, 
                        HDShaderIDs._NormalBufferTexture, data.normalBuffer);
                    ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.m_HanPiWaterVolumeKernel,
                        HDShaderIDs._CausticCascadeAtlas_Float, data.causticCascadeAtlas);
                    ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.m_HanPiWaterVolumeKernel,
                        HDShaderIDs._CausticCascadeAtlas_R, data.causticCascadeAtlasR);
                    ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.m_HanPiWaterVolumeKernel,
                        HDShaderIDs._CausticCascadeAtlas_G, data.causticCascadeAtlasG);
                    ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.m_HanPiWaterVolumeKernel,
                        HDShaderIDs._CausticCascadeAtlas_B, data.causticCascadeAtlasB);
                    ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.m_HanPiWaterVolumeKernel,
                        HDShaderIDs._WaterNormalAtlas, data.causticNormalAtlas);
                    
                    // 绑定 HPWater GBuffer 纹理 (3 个)
                    ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.m_HanPiWaterVolumeKernel,
                        HPWaterVolumeShaderIDs._HPWaterGBuffer0, data.waterGBuffer0);
                    ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.m_HanPiWaterVolumeKernel,
                        HPWaterVolumeShaderIDs._HPWaterGBuffer1, data.waterGBuffer1);
                    ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.m_HanPiWaterVolumeKernel,
                        HPWaterVolumeShaderIDs._HPWaterGBuffer2, data.waterGBuffer2);
                    
                    // 绑定运动矢量
                    ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.m_HanPiWaterVolumeKernel,
                        HDShaderIDs._CameraMotionVectorsTexture, data.motionVectorsBuffer);
                    
                    // 绑定折射 UV 纹理
                    ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.m_HanPiWaterVolumeKernel,
                        HPWaterVolumeShaderIDs._HPWaterRefractionUVBuffer, data.refractionDataBuffer);
                    
                    // 设置正确的 RTHandle UV Scale
                    var rtHandleScale = RTHandles.rtHandleProperties.rtHandleScale;
                    ctx.cmd.SetGlobalVector(HPWaterVolumeShaderIDs._HPWaterColorUVScale,
                        new Vector4(rtHandleScale.x, rtHandleScale.y, rtHandleScale.z, rtHandleScale.w));
                    
                    // 设置低分辨率信息（用于坐标映射）
                    float resScale = data.waterVolumeInputData.resolutionScale;
                    int lowResWidth = Mathf.Max(1, (int)(data.hdCamera.actualWidth * resScale));
                    int lowResHeight = Mathf.Max(1, (int)(data.hdCamera.actualHeight * resScale));
                    ctx.cmd.SetComputeVectorParam(data.m_HanPiWaterVolumeCS,
                        HPWaterVolumeShaderIDs._HPWaterVolumeResolution, 
                        new Vector4(lowResWidth, lowResHeight, 1.0f / lowResWidth, 1.0f / lowResHeight));

                    // 绑定光照缓冲区
                    BindGlobalLightingBuffers(data.lightingBuffers, ctx.cmd);

                    // 绑定光源列表
                    ctx.cmd.SetComputeBufferParam(data.m_HanPiWaterVolumeCS, data.m_HanPiWaterVolumeKernel,
                        HDShaderIDs.g_vLightListGlobal, data.lightListBuffer);

                    // 绑定历史纹理（用于 Temporal Filtering）
                    ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.m_HanPiWaterVolumeKernel,
                        HPWaterVolumeShaderIDs._HPWaterHistoryColor, data.historyColorBuffer);
                    ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.m_HanPiWaterVolumeKernel,
                        HPWaterVolumeShaderIDs._HPWaterHistoryAbsorbance, data.historyAbsorbanceBuffer);
                    ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.m_HanPiWaterVolumeKernel,
                        HPWaterVolumeShaderIDs._HPWaterHistoryDepth, data.historyDepthBuffer);

                    // 设置时间参数 
                    // x: blend factor
                    // y: isFirstFrame
                    // z: motion vector velocity scale
                    // w: enable motion vectors (1.0 = true)
                    Vector4 temporalParams = new Vector4(
                        data.temporalBlendFactor,
                        data.isFirstFrame ? 1.0f : 0.0f,
                        data.waterVolumeInputData.motionVectorVelocityScale,
                        data.waterVolumeInputData.enableMotionVectors ? 1.0f : 0.0f
                    );
                    ctx.cmd.SetComputeVectorParam(data.m_HanPiWaterVolumeCS,
                        HPWaterVolumeShaderIDs._HPWaterTemporalParams, temporalParams);

                    // 设置滤波参数 (x: temporal depth thresh, y: spatial depth sens, z: temporal depth enable, w: spatial depth enable)
                    ctx.cmd.SetComputeVectorParam(data.m_HanPiWaterVolumeCS, HPWaterVolumeShaderIDs._HPWaterFilterParams,
                        new Vector4(data.waterVolumeInputData.temporalDepthThreshold, 
                                    data.waterVolumeInputData.spatialDepthSensitivity, 
                                    data.waterVolumeInputData.enableTemporalDepthRejection ? 1.0f : 0.0f, 
                                    data.waterVolumeInputData.enableSpatialDepthAware ? 1.0f : 0.0f));

                    // 设置阴影参数 (x: softness, y: blocker count, z: filter count, w: min size)
                    ctx.cmd.SetComputeVectorParam(data.m_HanPiWaterVolumeCS, HPWaterVolumeShaderIDs._HPWaterShadowParams,
                        new Vector4(data.waterVolumeInputData.shadowSoftness, 
                                    data.waterVolumeInputData.minFilterSize,
                                    data.waterVolumeInputData.blockerSampleCount, 
                                    data.waterVolumeInputData.filterSampleCount));

                    // 绑定输出纹理
                    ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.m_HanPiWaterVolumeKernel, 
                        HPWaterVolumeShaderIDs._HPWaterOutputTexture, data.lowResColorBuffer);
                    ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.m_HanPiWaterVolumeKernel, 
                        HPWaterVolumeShaderIDs._HPWaterAbsorbanceTexture, data.absorbanceBuffer);
                    ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.m_HanPiWaterVolumeKernel,
                        HPWaterVolumeShaderIDs._HPWaterDepthOutputTexture, data.depthOutputBuffer);
                    data.m_HanPiWaterVolumeCS.GetKernelThreadGroupSizes(data.m_HanPiWaterVolumeKernel, out uint x, out uint y, out _);
                    int dispatchX = Mathf.CeilToInt(lowResWidth / (float)x);
                    int dispatchY = Mathf.CeilToInt(lowResHeight / (float)y);
                    // Dispatch compute shader
                    ctx.cmd.DispatchCompute(data.m_HanPiWaterVolumeCS, data.m_HanPiWaterVolumeKernel, 
                        dispatchX, dispatchY, data.viewCount);    

                    // 移除此处的 CopyTexture，改为在后续步骤中处理历史更新
                    // 如果禁用了空间滤波，则需要在这里复制
                    if (!data.waterVolumeInputData.enableSpatialFilter)
                    {
                        ctx.cmd.CopyTexture(data.lowResColorBuffer, data.historyColorBuffer);
                        ctx.cmd.CopyTexture(data.absorbanceBuffer, data.historyAbsorbanceBuffer);
                    }
                    
                    // 复制当前帧深度到历史深度 (无论是否开启空间滤波)
                    ctx.cmd.CopyTexture(data.depthOutputBuffer, data.historyDepthBuffer);
                });

                lowResColorBuffer = passData.lowResColorBuffer;
                absorbanceBuffer = passData.absorbanceBuffer;
            }

            // Pass 1.5: 空间滤波 - À-trous 迭代
            // ========================================================================
            // 使用 Ping-Pong 策略进行多次À-trous迭代
            // ========================================================================
            if (parameters.enableSpatialFilter)
            {
                int iterations = Mathf.Clamp(parameters.spatialFilterIterations, 1, 4);
                
                // 创建用于 Ping-Pong 的临时纹理引用（重用物理内存，不创建新纹理）
                // 这些 Handle 用于在迭代间交替读写
                TextureHandle currentColorInput = lowResColorBuffer;
                TextureHandle currentAbsorbanceInput = absorbanceBuffer;
                
                // À-trous 多次迭代
                for (int i = 0; i < iterations; i++)
                {
                    int stride = 1 << i; // À-trous 步长: 1, 2, 4, 8
                    
                    // 限制最大步长，避免越界采样
                    int maxStride = 8;
                    stride = Mathf.Min(stride, maxStride);
                    
                    bool isLastIteration = (i == iterations - 1);
                    
                    // 捕获循环变量到局部变量，避免闭包问题
                    int currentIteration = i;
                    int totalIterations = iterations;
                    int currentStride = stride;
                    
                    using (var builder = renderGraph.AddRenderPass<RenderWaterVolumePassData>(
                        $"HanPi Water À-trous Filter (Iteration {i + 1}, Stride {stride})", 
                        out var passData, 
                        new ProfilingSampler($"HanPi Water À-trous Filter Iter{i + 1}")))
                    {
                        passData.hdCamera = hdCamera;
                        passData.m_HanPiWaterVolumeCS = m_HanPiWaterVolumeCS;
                        passData.m_HanPiWaterVolumeKernel = m_HanPiWaterVolumeSpatialFilterKernel;
                        passData.viewCount = hdCamera.viewCount;
                        passData.waterVolumeInputData = parameters;
                        
                        // 输入：从当前缓冲区读取（第一次迭代从 Pass 1 输出，后续从上一次迭代结果）
                        passData.lowResColorBuffer = builder.ReadTexture(currentColorInput);
                        passData.absorbanceBuffer = builder.ReadTexture(currentAbsorbanceInput);
                        
                        // 读取深度纹理（已在 Pass 1 完成写入，通过 ImportTexture 同步）
                        passData.depthOutputBuffer = builder.ReadTexture(renderGraph.ImportTexture(m_WaterVolumeHistoryDepth));

                        passData.depthBuffer = builder.ReadTexture(waterGbufferData.waterDepthBuffer);
                        passData.depthPyramidBuffer = builder.ReadTexture(depthPyramidTexture);
                        passData.refractionDataBuffer = builder.ReadTexture(waterRefractionData.refractionData);
                        
                        // 输出：写入 History Buffer（用于下一次迭代）
                        passData.historyColorBuffer = builder.WriteTexture(renderGraph.ImportTexture(m_WaterVolumeHistoryColor));
                        passData.historyAbsorbanceBuffer = builder.WriteTexture(renderGraph.ImportTexture(m_WaterVolumeHistoryAbsorbance));
                        
                        // 为下一次迭代准备：将当前输入缓冲区声明为可写（用于 CopyTexture）
                        // 这确保 RenderGraph 正确追踪资源依赖
                        if (!isLastIteration)
                        {
                            // 不是最后一次迭代，需要复制回输入缓冲区供下一次迭代使用
                            currentColorInput = builder.WriteTexture(currentColorInput);
                            currentAbsorbanceInput = builder.WriteTexture(currentAbsorbanceInput);
                        }
                        
                        builder.AllowPassCulling(false);
                        
                        builder.SetRenderFunc((RenderWaterVolumePassData data, RenderGraphContext ctx) =>
                        {
                            // 设置低分辨率信息
                            float resScale = data.waterVolumeInputData.resolutionScale;
                            int lowResWidth = Mathf.Max(1, (int)(data.hdCamera.actualWidth * resScale));
                            int lowResHeight = Mathf.Max(1, (int)(data.hdCamera.actualHeight * resScale));
                            ctx.cmd.SetComputeVectorParam(data.m_HanPiWaterVolumeCS,
                                HPWaterVolumeShaderIDs._HPWaterVolumeResolution, 
                                new Vector4(lowResWidth, lowResHeight, 1.0f / lowResWidth, 1.0f / lowResHeight));
                            
                            // 设置À-trous步长
                            ctx.cmd.SetComputeIntParam(data.m_HanPiWaterVolumeCS, 
                                HPWaterVolumeShaderIDs._AtrousStride, currentStride);
                            
                            // 设置滤波参数
                            ctx.cmd.SetComputeVectorParam(data.m_HanPiWaterVolumeCS, HPWaterVolumeShaderIDs._HPWaterFilterParams,
                                new Vector4(data.waterVolumeInputData.temporalDepthThreshold, 
                                            data.waterVolumeInputData.spatialDepthSensitivity, 
                                            data.waterVolumeInputData.enableTemporalDepthRejection ? 1.0f : 0.0f, 
                                            data.waterVolumeInputData.enableSpatialDepthAware ? 1.0f : 0.0f));

                            // 绑定深度和折射
                            ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.m_HanPiWaterVolumeKernel, 
                                HDShaderIDs._DepthTexture, data.depthBuffer);
                            ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.m_HanPiWaterVolumeKernel, 
                                HDShaderIDs._CameraDepthTexture, data.depthPyramidBuffer);
                            ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.m_HanPiWaterVolumeKernel,
                                HPWaterVolumeShaderIDs._HPWaterRefractionUVBuffer, data.refractionDataBuffer);

                            // 绑定输入纹理（从当前输入读取）
                            ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.m_HanPiWaterVolumeKernel,
                                HPWaterVolumeShaderIDs._HPWaterLowResColor, data.lowResColorBuffer);
                            ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.m_HanPiWaterVolumeKernel,
                                HPWaterVolumeShaderIDs._HPWaterLowResAbsorbance, data.absorbanceBuffer);
                            ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.m_HanPiWaterVolumeKernel,
                                HPWaterVolumeShaderIDs._HPWaterLowResDepth, data.depthOutputBuffer);
                                
                            // 绑定输出纹理（写入 history buffer）
                            ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.m_HanPiWaterVolumeKernel,
                                HPWaterVolumeShaderIDs._HPWaterOutputTexture, data.historyColorBuffer);
                            ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.m_HanPiWaterVolumeKernel,
                                HPWaterVolumeShaderIDs._HPWaterAbsorbanceTexture, data.historyAbsorbanceBuffer);
                            
                            // Dispatch
                            data.m_HanPiWaterVolumeCS.GetKernelThreadGroupSizes(data.m_HanPiWaterVolumeKernel, out uint x, out uint y, out _);
                            int dispatchX = Mathf.CeilToInt(lowResWidth / (float)x);
                            int dispatchY = Mathf.CeilToInt(lowResHeight / (float)y);
                            ctx.cmd.DispatchCompute(data.m_HanPiWaterVolumeCS, data.m_HanPiWaterVolumeKernel,
                                dispatchX, dispatchY, data.viewCount);
                                
                            // Ping-Pong: 复制结果回输入缓冲区供下一次迭代使用
                            // 注意：最后一次迭代不需要复制，因为结果已经在 history buffer 中
                            if (currentIteration < totalIterations - 1)
                            {
                                ctx.cmd.CopyTexture(data.historyColorBuffer, data.lowResColorBuffer);
                                ctx.cmd.CopyTexture(data.historyAbsorbanceBuffer, data.absorbanceBuffer);
                            }
                        });
                    }
                }
                
                // 更新最终结果的引用（用于后续的 Composite Pass）
                // 最终结果在 history buffer 中
                lowResColorBuffer = renderGraph.ImportTexture(m_WaterVolumeHistoryColor);
                absorbanceBuffer = renderGraph.ImportTexture(m_WaterVolumeHistoryAbsorbance);
            }
            // 标记首帧完成
            m_WaterVolumeFirstFrame = false;

            // ========================================================================
            // Upsample水体积渲染结果到全分辨率 ColorBuffer，并且进行Specular延迟光照
            // ========================================================================
            using (var builder = renderGraph.AddRenderPass<CompositeWaterVolumePassData>(
                "HanPi Water Composite & Specular Deferred Lighting", out var passData, new ProfilingSampler("HanPi Water Composite & Specular Deferred Lighting")))
            {
                passData.hdCamera = hdCamera;
                passData.m_HanPiWaterVolumeCS = m_HanPiWaterVolumeCS;
                passData.compositeKernel = m_HanPiWaterVolumeCompositeKernel;
                passData.viewCount = hdCamera.viewCount;
                
                // 设置分辨率信息
                passData.volumeResolution = new Vector4(lowResWidth, lowResHeight, 1.0f / lowResWidth, 1.0f / lowResHeight);
                passData.enableDepthAwareUpsampling = parameters.enableDepthAwareUpsampling;
                
                // 读取输入纹理
                passData.colorBuffer = builder.ReadTexture(colorPyramid);
                passData.depthBuffer = builder.ReadTexture(waterGbufferData.waterDepthBuffer);
                passData.depthPyramidBuffer = builder.ReadTexture(depthPyramidTexture);  // 场景深度（不含水面）
                passData.lowResColorBuffer = builder.ReadTexture(lowResColorBuffer);
                passData.absorbanceBuffer = builder.ReadTexture(absorbanceBuffer);
                passData.lowResDepthBuffer = builder.ReadTexture(renderGraph.ImportTexture(m_WaterVolumeHistoryDepth));  // 低分辨率深度
                // 读取折射 UV 纹理
                passData.refractionUVBuffer = builder.ReadTexture(waterRefractionData.refractionData);
                // 读取 SSR 光照缓冲
                passData.ssrLightingBuffer = builder.ReadTexture(ssrLightingBuffer);
                
                // 读取 HPWater GBuffer 纹理 (3 个)
                passData.waterGBuffer0 = builder.ReadTexture(waterGbufferData.waterGBuffer0);
                passData.waterGBuffer1 = builder.ReadTexture(waterGbufferData.waterGBuffer1);
                passData.waterGBuffer2 = builder.ReadTexture(waterGbufferData.waterGBuffer2);
                
                // 创建全分辨率输出纹理
                passData.outputColorBuffer = builder.WriteTexture(
                    CreateColorBuffer(renderGraph, hdCamera, false));
                
                // 禁止 Pass 剪裁
                builder.AllowPassCulling(false);
                
                builder.SetRenderFunc((CompositeWaterVolumePassData data, RenderGraphContext ctx) =>
                {
                    // 绑定全分辨率输入纹理
                    ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.compositeKernel,
                        HDShaderIDs._CameraColorTexture, data.colorBuffer);
                    // _DepthTexture = depthBuffer（包含水面）→ 用于水面深度
                    ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.compositeKernel, 
                        HDShaderIDs._DepthTexture, data.depthBuffer);
                    // _CameraDepthTexture = depthPyramidTexture（不含水面）→ 用于场景深度
                    ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.compositeKernel, 
                        HDShaderIDs._CameraDepthTexture, data.depthPyramidBuffer);
                    
                    // 绑定折射 UV 纹理
                    ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.compositeKernel,
                        HPWaterVolumeShaderIDs._HPWaterRefractionUVBuffer, data.refractionUVBuffer);
                    
                    // 绑定低分辨率输入纹理（只读）
                    ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.compositeKernel,
                        HPWaterVolumeShaderIDs._HPWaterLowResColor, data.lowResColorBuffer);
                    ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.compositeKernel,
                        HPWaterVolumeShaderIDs._HPWaterLowResAbsorbance, data.absorbanceBuffer);
                    ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.compositeKernel,
                        HPWaterVolumeShaderIDs._HPWaterLowResDepth, data.lowResDepthBuffer);
                    
                    // 绑定全分辨率输出纹理
                    ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.compositeKernel,
                        HPWaterVolumeShaderIDs._HPWaterCompositeOutput, data.outputColorBuffer);

                    // 绑定 SSR 光照缓冲
                    ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.compositeKernel,
                        HDShaderIDs._SsrLightingTexture, data.ssrLightingBuffer);
                    
                    // 绑定 HPWater GBuffer 纹理 (3 个)
                    ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.compositeKernel,
                        HPWaterVolumeShaderIDs._HPWaterGBuffer0, data.waterGBuffer0);
                    ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.compositeKernel,
                        HPWaterVolumeShaderIDs._HPWaterGBuffer1, data.waterGBuffer1);
                    ctx.cmd.SetComputeTextureParam(data.m_HanPiWaterVolumeCS, data.compositeKernel,
                        HPWaterVolumeShaderIDs._HPWaterGBuffer2, data.waterGBuffer2);
                    
                    // 设置分辨率信息
                    // 使用 w 分量的正负号来传递 enableDepthAwareUpsampling 开关
                    // 如果启用，w > 0；如果不启用，w < 0
                    // 原始 w 是 1/height，肯定是正数
                    float invHeight = data.volumeResolution.w;
                    if (!data.enableDepthAwareUpsampling) invHeight *= -1.0f;
                    
                    ctx.cmd.SetComputeVectorParam(data.m_HanPiWaterVolumeCS,
                        HPWaterVolumeShaderIDs._HPWaterVolumeResolution, 
                        new Vector4(data.volumeResolution.x, data.volumeResolution.y, data.volumeResolution.z, invHeight));
                    data.m_HanPiWaterVolumeCS.GetKernelThreadGroupSizes(data.compositeKernel, out uint x, out uint y, out _);
                    int dispatchX = Mathf.CeilToInt(hdCamera.actualWidth / (float)x);
                    int dispatchY = Mathf.CeilToInt(hdCamera.actualHeight / (float)y);
                    // Dispatch
                    ctx.cmd.DispatchCompute(data.m_HanPiWaterVolumeCS, data.compositeKernel,
                        dispatchX, dispatchY, data.viewCount);
                });
                
                return passData.outputColorBuffer;
            }
        }
    }
}


