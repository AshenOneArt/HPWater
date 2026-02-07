using System;
using UnityEngine.Experimental.Rendering;
using UnityEngine.Experimental.Rendering.RenderGraphModule;

namespace UnityEngine.Rendering.HighDefinition
{
    public partial class HDRenderPipeline
    {
        static class CausticShaderIDs
        {
            public static readonly int CausticComputeParams = Shader.PropertyToID("CausticComputeParams");
            // Water Cascade Atlas
            public static readonly int _WaterCascadeDepth0Atlas = Shader.PropertyToID("_WaterCascadeDepth0Atlas");
            public static readonly int _WaterGbuffer0Atlas = Shader.PropertyToID("_WaterGbuffer0Atlas");
            public static readonly int _WaterCascadeDepth1Atlas = Shader.PropertyToID("_WaterCascadeDepth1Atlas");
            public static readonly int _WaterGbuffer1Atlas = Shader.PropertyToID("_WaterGbuffer1Atlas");
            public static readonly int _ShadowDepthCascadeAtlas = Shader.PropertyToID("_ShadowDepthCascadeAtlas");


            // Caustic Textures - RW（写入）
            public static readonly int _causticIrradianceRT_R = Shader.PropertyToID("_causticIrradianceRT_R");
            public static readonly int _causticIrradianceRT_G = Shader.PropertyToID("_causticIrradianceRT_G");
            public static readonly int _causticIrradianceRT_B = Shader.PropertyToID("_causticIrradianceRT_B");
            public static readonly int _causticRT_Color_FLOAT = Shader.PropertyToID("_causticRT_Color_FLOAT");
            public static readonly int _causticRT_Color_FLOAT4 = Shader.PropertyToID("_causticRT_Color_FLOAT4");

            // Caustic Textures - Read（只读）
            public static readonly int _causticIrradianceRT_R_Read = Shader.PropertyToID("_causticIrradianceRT_R_Read");
            public static readonly int _causticIrradianceRT_G_Read = Shader.PropertyToID("_causticIrradianceRT_G_Read");
            public static readonly int _causticIrradianceRT_B_Read = Shader.PropertyToID("_causticIrradianceRT_B_Read");
            public static readonly int _causticRT_Color_FLOAT_Read = Shader.PropertyToID("_causticRT_Color_FLOAT_Read");
            public static readonly int _causticRT_Color_FLOAT4_Read = Shader.PropertyToID("_causticRT_Color_FLOAT4_Read");

            public static readonly int _CausticCascadeAtlas = Shader.PropertyToID("_CausticCascadeAtlas");
            public static readonly int _CausticCascadeAtlas_R = Shader.PropertyToID("_CausticCascadeAtlas_R");
            public static readonly int _CausticCascadeAtlas_G = Shader.PropertyToID("_CausticCascadeAtlas_G");
            public static readonly int _CausticCascadeAtlas_B = Shader.PropertyToID("_CausticCascadeAtlas_B");
            public static readonly int _Is_Use_RGB_Caustic = Shader.PropertyToID("_Is_Use_RGB_Caustic");
            public static readonly string HPWaterCausticGBufferPassName = "HPWaterCausticGBufferPass";
            
            // 全局变量：控制渲染模式
            public static readonly int _RenderGbuffer1Only = Shader.PropertyToID("_RenderGbuffer1Only");
            
            // À-trous降噪参数
            public static readonly int _AtrousLuminanceWeight = Shader.PropertyToID("_AtrousLuminanceWeight");
            public static readonly int _MipRangePerLevel = Shader.PropertyToID("_MipRangePerLevel");

        }

        // Blur Material
        private Material s_BlurMaterial;
        
        // 缓存的级联虚拟相机（避免每帧创建 GC）
        private static Camera[] s_CachedCascadeCameras;
        private static GameObject[] s_CachedCascadeCameraObjects;
        
        // 平台检测
        private static bool UseDX11Path => true;

        class RenderCausticsPassData
        {
            public CausticComputeParams causticComputeParams;
            public HDCamera hdCamera;
            public CausticInputData parameters;
            public CullingResults cullingResults;
            public LayerMask WaterlayerMask;
            //Graph内计算
            public Light directionalLight;//主光源
            public int directionalLightIndex = -1;//主光源索引
            public int cascadeCount; // 从HDCamera.volumeStack获取的实际级联数量
            public Matrix4x4[] cascadeViewMatrices;// 级联View矩阵
            public Matrix4x4[] cascadeProjectionMatrices;// 级联Projection矩阵
            public Matrix4x4[] cascadeVPMatrices;// 级联VP矩阵
            public Matrix4x4[] cascadeVPMatricesInverse;// 级联VP矩阵逆矩阵
            public ShadowSplitData[] cascadeSplitData;// 级联阴影分割数据
            public Vector4[] cascadeOffsetsAndSizes;// 级联图集位置和大小
            public Vector4[] cascadeDepthRanges; // 每个级联的深度范围                        
            public Camera[] cascadeVirtualCameras;// 级联虚拟相机（用于裁剪和 RendererList）

            // RenderGraph 管理的焦散纹理
            public TextureHandle waterCascadeDepth0Atlas;//水面级联深度Gbuffer Depth 0 
            public TextureHandle waterCascadeDepth1Atlas;//水面低分辨率级联深度Gbuffer Depth 1，用于Decode 双边上采样
            public TextureHandle waterGbuffer0Atlas;//水面级联法线rgb/未用Gbuffer0
            public TextureHandle waterGbuffer1Atlas;//水面级联吸收/散射r8g8，低分辨率Gbuffer1
            public TextureHandle causticIrradianceR;//焦散辐射强度R，只有RGB模式需要
            public TextureHandle causticIrradianceG;//焦散辐射强度G，只有RGB模式需要
            public TextureHandle causticIrradianceB;//焦散辐射强度B，只有RGB模式需要
            public TextureHandle causticColor;//焦散颜色，只有单通道模式需要
            public TextureHandle causticColorTemp;//焦散颜色临时，只有单通道模式需要
            public TextureHandle shadowDepthCascadeAtlas;//场景阴影级联深度纹理
            public CausticPackage causticPackage;//焦散传递给延迟光照的数据打包
        }

        /// <summary>
        /// 焦散渲染参数：前端输入数据结构体，用于传递给焦散渲染Pass
        /// </summary>
        public class CausticInputData
        {
            // 基础设置        
            public int causticRenderSize = 1024;//焦散渲染尺寸
            public int gbuffer1AtlasSize = 256;//低分辨率Gbuffer1尺寸
            public int waterCascadeAtlasSize = 1024;//水面级联图集尺寸
            public bool useRGBCaustic = true;//是否使用RGB焦散
            public bool showDebugInfo = true;//是否显示调试信息
            public bool useSpecifiedMaterial = false;//是否使用指定材质
            public Material specifiedMaterial;//指定材质

            //联级参数
            public float depthBias = 1.0f;//深度偏移
            public float slopeBias = 0.5f;//斜率偏移

            // 渲染参数
            public float forwardRandomOffset = 1.0f;//向前随机偏移
            public float causticIntensity = 1.0f;//焦散强度
            public float crossDistance = 1.0f;//穿越距离
            public float dispersionStrength = 1.0f;//色散强度
            
            // À-trous降噪参数
            public float atrousLuminanceWeight = 0.5f;//À-trous降噪权重
            public bool useAtrousDenoise = true;//是否使用À-trous降噪


            /// <summary>
            /// 验证参数有效性
            /// </summary>
            public bool IsValid()
            {
                if (causticRenderSize <= 0 || waterCascadeAtlasSize <= 0) return false;
                return true;
            }            
        }
        /// <summary>
        /// 焦散Compute参数结构体 - 与 HLSL 中的 CBUFFER 对应
        /// 注意：使用 Vector4 而不是 Vector3 以确保正确的 16 字节对齐
        /// </summary>
        [GenerateHLSL(needAccessors = false, generateCBuffer = true)]
        public unsafe struct CausticComputeParams
        {
            public uint _CascadeCount;
            public float _ForwardRandomOffset;
            public float _CrossDistance;
            public float _CausticIntensity;
            public float _DispersionStrength;
            public float _unused1;
            public float _unused2;
            public float _unused3;
            public Vector4 _MainLightDirection;
            public Vector4 _WaterCascadeDepth0AtlasSize; // (width, height, 1/width, 1/height)
            [HLSLArray(4, typeof(Vector4))]
            public fixed float _WaterCascadeDepth0AtlasOffsetsAndSizes[4 * 4];
            [HLSLArray(4, typeof(Matrix4x4))]
            public fixed float _WaterCascadeDepth0AtlasVPInverse[4 * 4 * 4];
            [HLSLArray(4, typeof(Matrix4x4))]
            public fixed float _WaterCascadeDepth0AtlasVP[4 * 4 * 4];
            // 每个级联的深度范围 (x=near, y=far, z=range, w=unused)
            [HLSLArray(4, typeof(Vector4))]
            public fixed float _WaterCascadeDepthRanges[4 * 4];
        }
        public class CausticPackage
        {
            //这里的cascadeWaterDepth和causticColorFloat其实可以打包，但综合考虑下来，
            //只有不透明LightLoop两者都需要，打包可以增加L2 cache命中率
            //但后续的水下和水面对焦散的采样是不需要水面深度的，没有必要强制增加一倍带宽
            public TextureHandle cascadeWaterDepth;
            // RGB 模式：使用三张独立纹理
            public TextureHandle causticColorR;
            public TextureHandle causticColorG;
            public TextureHandle causticColorB;
            // 单通道模式：使用单张纹理（复用 causticColorG）
            public TextureHandle causticColorFloat;
            // 焦散法线/遮蔽纹理
            public TextureHandle causticGbuffer0;
            // 焦散吸收/散射纹理
            public TextureHandle causticGbuffer1;
            // 焦散低分辨率深度（用于 Decode 双边上采样）
            public TextureHandle causticCascadeDepth1;

            public bool useRGBCaustic;
            public bool causticEnabled; // 焦散是否启用（false 时采样返回 1.0）
        }
        public CausticPackage IsCausticDataValid(CausticPackage causticToDeferredData,RenderGraph renderGraph)
        {
            // 验证所有纹理（RGB 和单通道模式都需要 R/G/B 全部有效，因为单通道会复用 G）
            if (causticToDeferredData.causticColorR.IsValid() && 
                causticToDeferredData.causticColorG.IsValid() && 
                causticToDeferredData.causticColorB.IsValid() &&
                causticToDeferredData.cascadeWaterDepth.IsValid() &&
                causticToDeferredData.causticGbuffer0.IsValid() &&
                causticToDeferredData.causticGbuffer1.IsValid() &&
                causticToDeferredData.causticCascadeDepth1.IsValid() &&
                causticToDeferredData.causticColorFloat.IsValid())
            {
                return causticToDeferredData; 
            }
            
            // 无效则返回默认值（R/G/B 都设置为白色纹理）
            var whiteTexture = renderGraph.defaultResources.whiteTexture;
            var blackTexture = renderGraph.defaultResources.blackTexture;
            return new CausticPackage
            {
                causticColorR = whiteTexture,
                causticColorG = whiteTexture,
                causticColorB = whiteTexture,
                causticColorFloat = whiteTexture,
                cascadeWaterDepth = whiteTexture,
                causticGbuffer0 = whiteTexture,
                causticGbuffer1 = blackTexture,
                causticCascadeDepth1 = whiteTexture,
                useRGBCaustic = false,
                causticEnabled = false // 焦散关闭，采样时返回 1.0
            };
        }

        void CleanupHPWaterCaustic()
        {
            if (s_BlurMaterial != null)
            {
                CoreUtils.Destroy(s_BlurMaterial);
                s_BlurMaterial = null;
            }
            // s_BlurShader 不需要清理，因为它来自 defaultResources
        }

        /// <summary>
        /// 焦散参数提供回调，由外部系统提供焦散渲染所需的参数
        /// </summary>
        public delegate CausticInputData CausticParametersProvider();

        /// <summary>
        /// 焦散参数提供者事件，在需要焦散参数时触发
        /// </summary>
        public static event CausticParametersProvider OnGetCausticParameters;
        public static readonly int maxCascades = 4;

#if UNITY_EDITOR || DEVELOPMENT_BUILD
        // 日志限流：记录上次日志输出时间
        private static float s_LastLogTime_ShadowRequestCount = -1f;
        private static float s_LastLogTime_InvalidParameters = -1f;
        private const float LOG_COOLDOWN_SECONDS = 1.0f; // 日志输出间隔（秒）
#endif


        CausticPackage RenderCaustics(
            RenderGraph renderGraph,
            HDCamera hdCamera,
            CullingResults cullingResults,
            in ShadowResult shadowResult,
            LayerMask WaterlayerMask)
        {
            // 如果没有指定水面Layer，使用默认Layer 4
            if (WaterlayerMask == 0)
            {
                WaterlayerMask = 1 << 4;
            }
            
            // 初始化 Pack Shader 和 Material
            if (s_BlurMaterial == null && defaultResources.shaders.hanPiWaterShader != null)
                s_BlurMaterial = CoreUtils.CreateEngineMaterial(defaultResources.shaders.hanPiWaterShader);

            // 返回空的焦散数据（包含默认白色纹理，不影响渲染效果）
            var emptyData = new CausticPackage
            {
                causticColorR = renderGraph?.defaultResources.whiteTexture ?? TextureHandle.nullHandle,
                causticColorG = renderGraph?.defaultResources.whiteTexture ?? TextureHandle.nullHandle,
                causticColorB = renderGraph?.defaultResources.whiteTexture ?? TextureHandle.nullHandle,
                causticColorFloat = renderGraph?.defaultResources.whiteTexture ?? TextureHandle.nullHandle,
                cascadeWaterDepth = renderGraph?.defaultResources.whiteTexture ?? TextureHandle.nullHandle,
                causticGbuffer0 = renderGraph?.defaultResources.whiteTexture ?? TextureHandle.nullHandle,
                causticGbuffer1 = renderGraph?.defaultResources.blackTexture ?? TextureHandle.nullHandle,
                causticCascadeDepth1 = renderGraph?.defaultResources.whiteTexture ?? TextureHandle.nullHandle,
                useRGBCaustic = false,
                causticEnabled = false // 焦散关闭，采样时返回 1.0
            };

            // 空值检查（如果条件不满足，直接返回 emptyData）
            if (OnGetCausticParameters == null || hdCamera == null || renderGraph == null ||
            m_HanPiCausticCompute == null || m_HanPiCausticKernel < 0)
            {
                return emptyData;
            }

            var parameters = OnGetCausticParameters.Invoke();

            // 验证参数有效性
            if (parameters == null || !parameters.IsValid())
            {
#if UNITY_EDITOR || DEVELOPMENT_BUILD
                if (parameters != null && parameters.showDebugInfo)
                {
                    // 日志限流：只在冷却时间后才输出
                    float currentTime = Time.realtimeSinceStartup;
                    if (currentTime - s_LastLogTime_InvalidParameters >= LOG_COOLDOWN_SECONDS)
                    {
                        Debug.LogWarning("[RenderCaustics] 焦散参数无效");
                        s_LastLogTime_InvalidParameters = currentTime;
                    }
                }
#endif
                return emptyData;
            }

            // 检查阴影请求计数
            if (m_ShadowManager.GetShadowRequestCount() == 0)
            {
#if UNITY_EDITOR || DEVELOPMENT_BUILD
                if (parameters.showDebugInfo)
                {
                    // 日志限流：只在冷却时间后才输出
                    float currentTime = Time.realtimeSinceStartup;
                    if (currentTime - s_LastLogTime_ShadowRequestCount >= LOG_COOLDOWN_SECONDS)
                    {
                        Debug.LogWarning($"[RenderCaustics] ShadowRequestCount: {m_ShadowManager.GetShadowRequestCount()}");
                        s_LastLogTime_ShadowRequestCount = currentTime;
                    }
                }
#endif                
                return emptyData;
            }

#if UNITY_EDITOR || DEVELOPMENT_BUILD
            if (parameters.showDebugInfo)
            {
                Debug.Log($"[RenderCaustics] Pass 创建成功，开始添加到 RenderGraph");
            }
#endif

            using var builder = renderGraph.AddRenderPass<RenderCausticsPassData>
            ("Caustic Render",out var passData, new ProfilingSampler("Caustic Render"));

            passData.hdCamera = hdCamera;
            passData.parameters = parameters;
            passData.WaterlayerMask = WaterlayerMask;
            passData.causticComputeParams = new CausticComputeParams();            
            passData.cullingResults = cullingResults;

            // 初始化数组            
            passData.cascadeViewMatrices = new Matrix4x4[maxCascades];
            passData.cascadeVPMatrices = new Matrix4x4[maxCascades];
            passData.cascadeVPMatricesInverse = new Matrix4x4[maxCascades];
            passData.cascadeProjectionMatrices = new Matrix4x4[maxCascades];
            passData.cascadeSplitData = new ShadowSplitData[maxCascades];
            passData.cascadeOffsetsAndSizes = new Vector4[maxCascades];
            passData.cascadeDepthRanges = new Vector4[maxCascades];
            
            // 从HDCamera的volumeStack获取实际的级联数量（与HDRP原生阴影使用相同的来源）
            var shadowSettings = hdCamera.volumeStack.GetComponent<HDShadowSettings>();
            passData.cascadeCount = shadowSettings.cascadeShadowSplitCount.value;

            CalculateAtlasLayout(passData.cascadeOffsetsAndSizes, passData.cascadeCount, parameters.waterCascadeAtlasSize);
            
            // ========================================
            // 初始化级联虚拟相机（缓存避免 GC）
            // ========================================
            if (s_CachedCascadeCameras == null || s_CachedCascadeCameras.Length < passData.cascadeCount)
            {
                // 销毁旧的相机
                if (s_CachedCascadeCameras != null)
                {
                    for (int i = 0; i < s_CachedCascadeCameras.Length; i++)
                    {
                        if (s_CachedCascadeCameraObjects[i] != null)
                        {
                            if (Application.isPlaying)
                                Object.Destroy(s_CachedCascadeCameraObjects[i]);
                            else
                                Object.DestroyImmediate(s_CachedCascadeCameraObjects[i]);
                        }
                    }
                }
                
                // 创建新的相机数组
                s_CachedCascadeCameras = new Camera[maxCascades];
                s_CachedCascadeCameraObjects = new GameObject[maxCascades];
                
                for (int i = 0; i < maxCascades; i++)
                {
                    s_CachedCascadeCameraObjects[i] = new GameObject($"CausticCascadeCamera_{i}");
                    s_CachedCascadeCameraObjects[i].hideFlags = HideFlags.HideAndDontSave;
                    s_CachedCascadeCameras[i] = s_CachedCascadeCameraObjects[i].AddComponent<Camera>();
                    s_CachedCascadeCameras[i].enabled = false; // 不自动渲染
                }
            }
            
            passData.cascadeVirtualCameras = s_CachedCascadeCameras;
            
#if UNITY_EDITOR || DEVELOPMENT_BUILD
            if (parameters.showDebugInfo)
            {
                Debug.Log($"[Caustic] CascadeCount = {passData.cascadeCount}, AtlasSize = {parameters.waterCascadeAtlasSize}, 布局模式: {(passData.cascadeCount <= 2 ? "上下排列(X轴拉伸)" : "2x2网格")}");
                for (int i = 0; i < passData.cascadeCount; i++)
                {
                    Debug.Log($"  级联{i}: offset=({passData.cascadeOffsetsAndSizes[i].x}px, {passData.cascadeOffsetsAndSizes[i].y}px), size=({passData.cascadeOffsetsAndSizes[i].z}px × {passData.cascadeOffsetsAndSizes[i].w}px)");
                }
            }
#endif
            // 用于生成焦散HitTexture的纹理
            if (parameters.useRGBCaustic)
            {
                passData.causticIrradianceR = builder.WriteTexture(renderGraph.CreateTexture(new TextureDesc(parameters.causticRenderSize, parameters.causticRenderSize)
                {
                    colorFormat = GraphicsFormat.R32_SInt,
                    enableRandomWrite = true,
                    clearColor = Color.clear,
                    clearBuffer = true,
                    name = "CausticIrradianceR"
                }));

                passData.causticIrradianceB = builder.WriteTexture(renderGraph.CreateTexture(new TextureDesc(parameters.causticRenderSize, parameters.causticRenderSize)
                {
                    colorFormat = GraphicsFormat.R32_SInt,
                    enableRandomWrite = true,
                    clearColor = Color.clear,
                    clearBuffer = true,
                    name = "CausticIrradianceB"
                }));

                passData.causticIrradianceG = builder.WriteTexture(renderGraph.CreateTexture(new TextureDesc(parameters.causticRenderSize, parameters.causticRenderSize)
                {
                    colorFormat = GraphicsFormat.R32_SInt,
                    enableRandomWrite = true,  
                    clearColor = Color.clear,
                    clearBuffer = true,
                    name = "CausticIrradianceG"
                }));
            }
            else
            {
                //如果单通道模式，则使用临时纹理，最后传递的是16bit的降噪纹理
                passData.causticIrradianceG = builder.CreateTransientTexture(new TextureDesc(parameters.causticRenderSize, parameters.causticRenderSize)
                {
                    colorFormat = GraphicsFormat.R32_SInt,
                    enableRandomWrite = true,  
                    clearColor = Color.clear,
                    clearBuffer = true,
                    name = "CausticIrradianceG"
                });
            }
            // 单通道下的最后传递纹理
            passData.causticColor = builder.WriteTexture(renderGraph.CreateTexture(new TextureDesc(parameters.causticRenderSize, parameters.causticRenderSize)
            {
                colorFormat = GraphicsFormat.R16_SFloat,
                enableRandomWrite = true,
                clearColor = Color.clear,
                clearBuffer = true,
                name = "CausticColor"
            }));
            // 单通道下的临时纹理，用于交换数据做降噪
            passData.causticColorTemp = builder.CreateTransientTexture(new TextureDesc(parameters.causticRenderSize, parameters.causticRenderSize)
            {
                colorFormat = GraphicsFormat.R16_SFloat,
                enableRandomWrite = true,
                useMipMap = true,
                clearColor = Color.clear,
                clearBuffer = true,
                name = "CausticColorTemp"
            });            
            // 创建法线/遮蔽纹理
            passData.waterGbuffer0Atlas = builder.WriteTexture(renderGraph.CreateTexture(new TextureDesc(parameters.waterCascadeAtlasSize, parameters.waterCascadeAtlasSize)
            {
                colorFormat = GraphicsFormat.R8G8B8A8_UNorm,
                clearColor = Color.clear,
                wrapMode = TextureWrapMode.Clamp,
                clearBuffer = true,
                name = "WaterGbuffer0CascadeAtlas"    
            }));            

            // 创建全分辨率深度纹理
            passData.waterCascadeDepth0Atlas = builder.WriteTexture(renderGraph.CreateTexture(new TextureDesc(parameters.waterCascadeAtlasSize, parameters.waterCascadeAtlasSize)
            {
                colorFormat = GraphicsFormat.None,
                depthBufferBits = DepthBits.Depth16,
                clearColor = Color.clear,
                clearBuffer = true,
                wrapMode = TextureWrapMode.Clamp,
                name = "WaterDepthCascadeAtlas"
            }));

            // ========================================================================
            // 渲染水面低频信息（两次渲染通道）
            // ========================================================================
            // 创建Gbuffer纹理,低频信息：吸收、散射
            int gbufferAtlasSize = parameters.gbuffer1AtlasSize;
            passData.waterGbuffer1Atlas = builder.WriteTexture(renderGraph.CreateTexture(new TextureDesc(gbufferAtlasSize, gbufferAtlasSize)
            {
                colorFormat = GraphicsFormat.R8G8_UNorm,
                clearColor = Color.clear,
                wrapMode = TextureWrapMode.Clamp,
                clearBuffer = true,
                name = "WaterGbuffer1CascadeAtlas"    
            }));
            // 创建低分辨率深度纹理，用于(双边上采样)
            passData.waterCascadeDepth1Atlas = builder.WriteTexture(renderGraph.CreateTexture(new TextureDesc(gbufferAtlasSize, gbufferAtlasSize)
            {
                colorFormat = GraphicsFormat.None,
                depthBufferBits = DepthBits.Depth16,
                clearColor = Color.clear,
                clearBuffer = true,
                wrapMode = TextureWrapMode.Clamp,
                name = "WaterDepth1CascadeAtlas"
            }));

            // 读取阴影纹理
            passData.shadowDepthCascadeAtlas = builder.ReadTexture(shadowResult.directionalShadowResult);

            // 封装焦散传递给延迟光照的数据
            passData.causticPackage = new CausticPackage
            {
                // RGB 模式：传递三张独立纹理；单通道模式：复用 G 通道
                causticColorR = parameters.useRGBCaustic ? passData.causticIrradianceR : renderGraph.defaultResources.whiteTexture,
                causticColorG = parameters.useRGBCaustic ? passData.causticIrradianceG : renderGraph.defaultResources.whiteTexture,
                causticColorB = parameters.useRGBCaustic ? passData.causticIrradianceB : renderGraph.defaultResources.whiteTexture,
                causticColorFloat = passData.causticColor,
                cascadeWaterDepth = passData.waterCascadeDepth0Atlas,
                causticCascadeDepth1 = passData.waterCascadeDepth1Atlas,
                causticGbuffer0 = passData.waterGbuffer0Atlas,
                causticGbuffer1 = passData.waterGbuffer1Atlas,                
                useRGBCaustic = parameters.useRGBCaustic,
                causticEnabled = true // 焦散启用
            };

            builder.SetRenderFunc(
            (RenderCausticsPassData data, RenderGraphContext context) =>
            {
                var param = data.parameters;
                var cmd = context.cmd;

                // 清除焦散纹理
                if (param.useRGBCaustic)
                {
                    cmd.SetRenderTarget(data.causticIrradianceR);
                    cmd.ClearRenderTarget(false, true, Color.clear);
                    cmd.SetRenderTarget(data.causticIrradianceB);
                    cmd.ClearRenderTarget(false, true, Color.clear);
                }
                cmd.SetRenderTarget(data.causticIrradianceG);
                cmd.ClearRenderTarget(false, true, Color.clear);

                // 获取主光源
                data.directionalLight = RenderSettings.sun;
                if (data.directionalLight == null)
                {
#if UNITY_EDITOR || DEVELOPMENT_BUILD
                    Debug.LogWarning("[RenderCaustics] RenderSettings.sun 为 null");
#endif
                    return;
                }

                // 查找光源索引
                data.directionalLightIndex = FindLightIndex(data.cullingResults, data.directionalLight);
                if (data.directionalLightIndex < 0)
                {
#if UNITY_EDITOR || DEVELOPMENT_BUILD
                    if (param.showDebugInfo)
                        Debug.LogWarning($"[RenderCaustics] 光源 {data.directionalLight.name} 不在CullingResults中");
#endif
                    return;
                }                                

                //使用原生API计算所有级联
                CalculateAllCascadesNative(data);
                
                // ========================================================================
                // 渲染水面深度和法线（两次渲染通道）- 使用虚拟相机 + RendererList
                // ========================================================================
                // 第一次渲染：法线数据（全分辨率）
                cmd.BeginSample("Render Water Normal & Depth");
                RenderAllCascadesGbuffer(cmd, data, context, 0);
                cmd.EndSample("Render Water Normal & Depth");

                // 第二次渲染：吸收/散射数据（低分辨率）
                cmd.BeginSample("Render Water Scatter & Absorption");
                RenderAllCascadesGbuffer(cmd, data, context, 1);
                cmd.EndSample("Render Water Scatter & Absorption");

                // ========================================
                // DX11 Compute
                // ========================================
                cmd.BeginSample("HanPi Water Compute Caustics");

                // 设置 RGB 焦散宏
                var compute = m_HanPiCausticCompute;
                var kernel = m_HanPiCausticKernel;
                
                if (param.useRGBCaustic)
                    compute.EnableKeyword("_USE_RGB_CAUSTIC_ON");
                else
                    compute.DisableKeyword("_USE_RGB_CAUSTIC_ON");
                    
                for (int i = 0; i < data.cascadeVPMatrices.Length; i++)
                    data.cascadeVPMatricesInverse[i] = data.cascadeVPMatrices[i].inverse;

                // 设置 Cbuffer 数据（包含焦散和模糊所有参数）
                PushCausticCbuffer(data, param, cmd);

                // 输入纹理
                cmd.SetComputeTextureParam(compute, kernel, CausticShaderIDs._WaterGbuffer0Atlas, data.waterGbuffer0Atlas);    
                cmd.SetComputeTextureParam(compute, kernel, CausticShaderIDs._WaterGbuffer1Atlas, data.waterGbuffer1Atlas); 
                cmd.SetComputeTextureParam(compute, kernel, CausticShaderIDs._WaterCascadeDepth0Atlas, data.waterCascadeDepth0Atlas);
                cmd.SetComputeTextureParam(compute, kernel, CausticShaderIDs._WaterCascadeDepth1Atlas, data.waterCascadeDepth1Atlas);                               
                cmd.SetComputeTextureParam(compute, kernel, CausticShaderIDs._ShadowDepthCascadeAtlas, data.shadowDepthCascadeAtlas);

                // 输出纹理（RenderGraph 管理）
                if (param.useRGBCaustic)
                {
                    cmd.SetComputeTextureParam(compute, kernel, CausticShaderIDs._causticIrradianceRT_R, data.causticIrradianceR);
                    cmd.SetComputeTextureParam(compute, kernel, CausticShaderIDs._causticIrradianceRT_B, data.causticIrradianceB);
                }
                cmd.SetComputeTextureParam(compute, kernel, CausticShaderIDs._causticIrradianceRT_G, data.causticIrradianceG);

                // 执行焦散计算
                compute.GetKernelThreadGroupSizes(m_HanPiCausticKernel, out uint x, out uint y, out _);
                int dispatchX = Mathf.CeilToInt(param.causticRenderSize / (float)x);
                int dispatchY = Mathf.CeilToInt(param.causticRenderSize / (float)y);
                cmd.DispatchCompute(compute, m_HanPiCausticKernel, dispatchX, dispatchY, 1);
                cmd.EndSample("HanPi Water Compute Caustics");
                
                // ========================================
                // À-trous降噪（RGB跳过，单通道固定2次迭代）
                // ========================================
                
                // RGB模式：完全跳过降噪
                if (param.useRGBCaustic || !param.useAtrousDenoise) 
                {
                    cmd.BeginSample("HanPi Water PackToFloat");
                    cmd.SetGlobalTexture(CausticShaderIDs._causticIrradianceRT_G_Read, data.causticIrradianceG);                    
                    cmd.SetRenderTarget(data.causticColor);
                    cmd.DrawProcedural(Matrix4x4.identity, s_BlurMaterial, 1, MeshTopology.Triangles, 3, 1);
                    cmd.EndSample("HanPi Water PackToFloat");
                    // RGB焦散不做任何模糊处理，保持原始数据
                    return;
                }                

                // 单通道模式：固定2次迭代
                // 第1次迭代：Compute Shader with LDS（IrradianceG → Color）
                cmd.BeginSample("HanPi Water Atrous Iteration 1");
                int atrousFirstKernel = compute.FindKernel("AtrousDenoiseFirst_Single");
                
                cmd.SetComputeFloatParam(compute, CausticShaderIDs._AtrousLuminanceWeight, param.atrousLuminanceWeight);
                cmd.SetComputeTextureParam(compute, atrousFirstKernel, CausticShaderIDs._causticIrradianceRT_G_Read, data.causticIrradianceG);
                cmd.SetComputeTextureParam(compute, atrousFirstKernel, CausticShaderIDs._causticRT_Color_FLOAT, data.causticColorTemp);
                
                compute.GetKernelThreadGroupSizes(atrousFirstKernel, out x, out y, out _);
                dispatchX = Mathf.CeilToInt(param.causticRenderSize / (float)x);
                dispatchY = Mathf.CeilToInt(param.causticRenderSize / (float)y);
                cmd.DispatchCompute(compute, atrousFirstKernel, dispatchX, dispatchY, 1);
                cmd.EndSample("HanPi Water Atrous Iteration 1");
                
                // 生成mipmap
                cmd.BeginSample("HanPi Water Generate Mipmap");
                cmd.GenerateMips(data.causticColorTemp);
                cmd.EndSample("HanPi Water Generate Mipmap");
                
                // 第2次迭代：Pixel Shader（Color → IrradianceG，使用mipmap）
                cmd.BeginSample("HanPi Water Atrous Iteration 2");
                cmd.SetGlobalFloat(CausticShaderIDs._AtrousLuminanceWeight, param.atrousLuminanceWeight);
                cmd.SetGlobalTexture(CausticShaderIDs._causticRT_Color_FLOAT, data.causticColorTemp);
                cmd.SetGlobalTexture(CausticShaderIDs._WaterCascadeDepth0Atlas, data.waterCascadeDepth0Atlas);
                cmd.SetGlobalTexture(CausticShaderIDs._ShadowDepthCascadeAtlas, data.shadowDepthCascadeAtlas);
                cmd.SetGlobalTexture(CausticShaderIDs._WaterGbuffer1Atlas, data.waterGbuffer1Atlas);
                cmd.SetGlobalTexture(CausticShaderIDs._WaterCascadeDepth1Atlas, data.waterCascadeDepth1Atlas);
                
                cmd.SetRenderTarget(data.causticColor);
                cmd.DrawProcedural(Matrix4x4.identity, s_BlurMaterial, 2, MeshTopology.Triangles, 3, 1);
                cmd.EndSample("HanPi Water Atrous Iteration 2");
                
                
            });
            return passData.causticPackage;
        }

        /// <summary>
        /// 查找光源索引
        /// </summary>
        private int FindLightIndex(CullingResults cullResults, Light light)
        {
            var visibleLights = cullResults.visibleLights;
            for (int i = 0; i < visibleLights.Length; i++)
            {
                if (visibleLights[i].lightType == LightType.Directional &&
                    visibleLights[i].light == light)
                {
                    return i;
                }
            }
            return -1;
        }
        /// <summary>
        /// 计算所有级联 - 与HDRP原生阴影完全一致
        /// 级联i → 图集位置i → VP矩阵[i]
        /// </summary>
        private void CalculateAllCascadesNative(RenderCausticsPassData data)
        {
            var parameters = data.parameters;
            
            // 直接从HDCamera的volumeStack获取阴影设置（与HDRP原生阴影使用相同的来源）
            var shadowSettings = data.hdCamera.volumeStack.GetComponent<HDShadowSettings>();
            int cascadeCount = shadowSettings.cascadeShadowSplitCount.value;
            
            // 准备级联分割比例（从Volume获取，与HDRP完全一致）
            Vector3 cascadeRatios = new(
                shadowSettings.cascadeShadowSplit0.value,
                shadowSettings.cascadeShadowSplit1.value,
                shadowSettings.cascadeShadowSplit2.value
            );

            // 保存级联数量到data中，供后续使用
            data.cascadeCount = cascadeCount;
            
            // 简单直接：级联i的VP矩阵存到索引i
            for (int i = 0; i < cascadeCount; i++)
            {
                // 调用Unity原生的级联计算
                data.cullingResults.ComputeDirectionalShadowMatricesAndCullingPrimitives
                (
                    data.directionalLightIndex,
                    i,                          // cascadeIndex
                    cascadeCount,               // cascadeCount
                    cascadeRatios,
                    parameters.waterCascadeAtlasSize / 2,  // 每个级联的分辨率是图集的一半
                    QualitySettings.shadowNearPlaneOffset,
                    out data.cascadeViewMatrices[i],
                    out data.cascadeProjectionMatrices[i],
                    out data.cascadeSplitData[i]
                );
                
                // 从投影矩阵中提取深度范围（正交投影）
                Matrix4x4 proj = data.cascadeProjectionMatrices[i];
                float m22 = proj.m22;
                float m23 = proj.m23;
                
                // 计算 near 和 far（Unity 使用 Reversed-Z）
                // 正交投影：z_ndc = m22 * z_view + m23
                // 反算：z_view = (z_ndc - m23) / m22
                #if UNITY_REVERSED_Z
                    float near = (1.0f - m23) / m22;
                    float far = (0.0f - m23) / m22;
                #else
                    float near = (-1.0f - m23) / m22;
                    float far = (1.0f - m23) / m22;
                #endif
                
                float range = Mathf.Abs(far - near);
                
                // 存储深度范围（x=near, y=far, z=range, w=unused）
                data.cascadeDepthRanges[i] = new Vector4(near, far, range, 0);
                
                // 计算相机相对的 VP 矩阵（精度）
                // 目标：VP_new * P_rel = VP * P_abs，其中 P_rel = P_abs - CameraPos
                // 推导：VP * P_abs = VP * (P_rel + C) = VP * P_rel + VP * C
                // 因此：VP_new 的平移部分需要加上 VP * C 的贡献
                Matrix4x4 deviceProjection = GL.GetGPUProjectionMatrix(data.cascadeProjectionMatrices[i], false);
                Matrix4x4 VP = deviceProjection * data.cascadeViewMatrices[i];
                
                Vector3 C = data.hdCamera.camera.transform.position;
                
                // VP * [C.x, C.y, C.z, 0] 的结果（w=0，只计算旋转缩放部分）
                float offsetX = VP.m00 * C.x + VP.m01 * C.y + VP.m02 * C.z;
                float offsetY = VP.m10 * C.x + VP.m11 * C.y + VP.m12 * C.z;
                float offsetZ = VP.m20 * C.x + VP.m21 * C.y + VP.m22 * C.z;
                
                // 修改平移部分
                VP.m03 += offsetX;
                VP.m13 += offsetY;
                VP.m23 += offsetZ;
                
                data.cascadeVPMatrices[i] = VP;
            }
        }
        /// <summary>
        /// 渲染所有级联（使用虚拟相机 + RendererList）
        /// GbufferIndex: 0 - 法线/焦散透明度/深度, 1 - 吸收/散射
        /// </summary>
        private void RenderAllCascadesGbuffer(CommandBuffer cmd, RenderCausticsPassData data, RenderGraphContext ctx, int GbufferIndex)
        {
            // 空值检查
            if (data == null || data.parameters == null || cmd == null) 
                return;
            
            var parameters = data.parameters;

#if UNITY_EDITOR || DEVELOPMENT_BUILD
            if (parameters.showDebugInfo)
            {
                Debug.Log($"[RenderAllCascadesWithRendererList] 开始渲染\n" +
                        $"  级联数量: {data.cascadeCount}\n" +
                        $"  使用 RendererList + 虚拟相机裁剪");
            }
#endif

            // 设置为 Gbuffer0 或 Gbuffer1 模式
            cmd.SetGlobalInt(CausticShaderIDs._RenderGbuffer1Only, GbufferIndex);

            // 设置渲染目标
            if (GbufferIndex == 0)
            {
                CoreUtils.SetRenderTarget(cmd,
                    new RenderTargetIdentifier[] { data.waterGbuffer0Atlas },
                    data.waterCascadeDepth0Atlas,
                    ClearFlag.Color | ClearFlag.Depth);
            }
            else if (GbufferIndex == 1)
            {
                CoreUtils.SetRenderTarget(cmd,
                    data.waterGbuffer1Atlas, data.waterCascadeDepth1Atlas,
                    ClearFlag.Color | ClearFlag.Depth);
            }
            
            int cascadeCount = data.cascadeCount;
            int gbufferAtlasSize = parameters.gbuffer1AtlasSize;
            int atlasSize = GbufferIndex == 0 ? parameters.waterCascadeAtlasSize : gbufferAtlasSize;
            
            // 计算缩放因子
            float atlasScale = (float)atlasSize / parameters.waterCascadeAtlasSize;

            // 遍历每个级联
            for (int i = 0; i < cascadeCount; i++)
            {
                // 配置级联虚拟相机
                Camera cascadeCamera = data.cascadeVirtualCameras[i];
                cascadeCamera.projectionMatrix = data.cascadeProjectionMatrices[i];
                cascadeCamera.worldToCameraMatrix = data.cascadeViewMatrices[i];
                cascadeCamera.cullingMask = data.WaterlayerMask;  // 使用参数中的 LayerMask
                
                // 使用虚拟相机执行裁剪
                ScriptableCullingParameters cullingParams;
                if (!cascadeCamera.TryGetCullingParameters(out cullingParams))
                {
#if UNITY_EDITOR || DEVELOPMENT_BUILD
                    if (parameters.showDebugInfo)
                    {
                        Debug.LogWarning($"级联 {i}: 裁剪参数获取失败");
                    }
#endif
                    continue;
                }
                
                // 执行裁剪（自动剔除不在级联视锥体内的物体）
                var cascadeCullingResults = ctx.renderContext.Cull(ref cullingParams);
                
                // 创建 RendererList
                var rendererListDesc = new RendererUtils.RendererListDesc(
                    new ShaderTagId(CausticShaderIDs.HPWaterCausticGBufferPassName),
                    cascadeCullingResults,
                    cascadeCamera)
                {
                    renderQueueRange = RenderQueueRange.all,
                    sortingCriteria = SortingCriteria.CommonOpaque,
                    layerMask = data.WaterlayerMask
                };

                // 如果需要使用统一材质，设置 overrideMaterial
                if (parameters.useSpecifiedMaterial && parameters.specifiedMaterial != null)
                {
                    int passIndex = parameters.specifiedMaterial.FindPass(CausticShaderIDs.HPWaterCausticGBufferPassName);
                    if (passIndex >= 0)
                    {
                        rendererListDesc.overrideMaterial = parameters.specifiedMaterial;
                        rendererListDesc.overrideMaterialPassIndex = passIndex;
                    }
                    else
                    {
                        // 找不到 Pass，降级为使用场景物体自身材质
                        Debug.LogWarning($"[Caustic] 指定材质中找不到 Pass '{CausticShaderIDs.HPWaterCausticGBufferPassName}'，使用默认材质");
                    }
                }
                
                var rendererList = ctx.renderContext.CreateRendererList(rendererListDesc);
                
                // 设置视口
                cmd.SetViewport(new Rect(
                    data.cascadeOffsetsAndSizes[i].x * atlasScale,
                    data.cascadeOffsetsAndSizes[i].y * atlasScale,
                    data.cascadeOffsetsAndSizes[i].z * atlasScale,
                    data.cascadeOffsetsAndSizes[i].w * atlasScale
                ));

                // 设置 VP 矩阵
                cmd.SetViewProjectionMatrices(data.cascadeViewMatrices[i], data.cascadeProjectionMatrices[i]);
                cmd.SetGlobalDepthBias(parameters.depthBias, parameters.slopeBias);

                // 绘制（自动批处理 + GPU Instancing）
                CoreUtils.DrawRendererList(ctx.renderContext, cmd, rendererList);

#if UNITY_EDITOR || DEVELOPMENT_BUILD
                if (parameters.showDebugInfo)
                {
                    var splitData = data.cascadeSplitData[i];
                    Debug.Log($"级联 {i}: 使用 RendererList 绘制, 裁剪球半径: {splitData.cullingSphere.w:F1}");
                }
#endif

                cmd.SetGlobalDepthBias(0f, 0f);
            }

            // 恢复主相机矩阵
            cmd.SetViewProjectionMatrices(
                data.hdCamera.camera.worldToCameraMatrix,
                data.hdCamera.camera.projectionMatrix
            );
        }

        /// <summary>
        /// 计算级联在图集中的布局 - 与HDRP原生阴影一致
        /// 
        /// HDRP的阴影图集布局规则：
        /// - cascadeCount > 1 时 X轴翻倍 (2列)
        /// - cascadeCount > 2 时 Y轴翻倍 (2行)
        /// 
        /// 1个级联: 整个图集
        /// [0]
        /// 
        /// 2个级联: 左右排列（2列1行）
        /// [0][1]
        /// 
        /// 3-4个级联: 2x2网格
        /// [0][1]
        /// [2][3]
        /// 格式：(offsetX_pixels, offsetY_pixels, sizeX_pixels, sizeY_pixels)
        /// </summary>
        private void CalculateAtlasLayout(Vector4[] cascadeOffsetsAndSizes, int cascadeCount, int atlasSize)
        {
            for (int i = 0; i < maxCascades; i++)
            {
                float gridOffsetX, gridOffsetY, gridSize;
                
                if (cascadeCount == 1)
                {
                    // 1个级联：整个图集
                    gridOffsetX = 0; gridOffsetY = 0; gridSize = 2;
                }
                else if (cascadeCount == 2)
                {
                    // 2个级联：左右排列
                    gridOffsetX = i; gridOffsetY = 0; gridSize = 1;
                }
                else
                {
                    // 3-4个级联：标准2x2网格
                    int x = i % 2;  // 0, 1, 0, 1
                    int y = i / 2;  // 0, 0, 1, 1
                    gridOffsetX = x; gridOffsetY = y; gridSize = 1;
                }
                
                // 转换为像素坐标（与官方阴影系统格式一致）
                float cascadeSizePixels = gridSize * atlasSize * 0.5f;  // 级联像素尺寸
                float offsetX = gridOffsetX * atlasSize * 0.5f;          // 像素偏移
                float offsetY = gridOffsetY * atlasSize * 0.5f;
                
                // 格式：(offsetX_pixels, offsetY_pixels, size_pixels, size_pixels)
                cascadeOffsetsAndSizes[i] = new Vector4(offsetX, offsetY, cascadeSizePixels, cascadeSizePixels);
            }
        }

        private void PushCausticCbuffer(RenderCausticsPassData data,CausticInputData param,CommandBuffer cmd)
        {
            // 填充 CausticComputeParams 结构体
                data.causticComputeParams._CascadeCount = (uint)data.cascadeCount;
                data.causticComputeParams._ForwardRandomOffset = param.forwardRandomOffset;
                data.causticComputeParams._CrossDistance = param.crossDistance;
                data.causticComputeParams._CausticIntensity = param.causticIntensity;
                data.causticComputeParams._DispersionStrength = param.dispersionStrength;
                data.causticComputeParams._MainLightDirection = new Vector4(
                    data.directionalLight.transform.forward.x,
                    data.directionalLight.transform.forward.y,
                    data.directionalLight.transform.forward.z,
                    0
                );
                
                // 设置水面图集尺寸（用于正确的PCF插值）
                int atlasSize = param.waterCascadeAtlasSize;
                data.causticComputeParams._WaterCascadeDepth0AtlasSize = new Vector4(
                    atlasSize,           // width
                    atlasSize,           // height
                    1.0f / atlasSize,    // 1/width
                    1.0f / atlasSize     // 1/height
                );
                
                // 手动复制数组到 fixed 数组（需要 unsafe）
                unsafe
                {
                    // 复制 Vector4 数组 (4 个 Vector4 = 16 个 float)
                    fixed (float* offsetsPtr = data.causticComputeParams._WaterCascadeDepth0AtlasOffsetsAndSizes)
                    {
                        for (int i = 0; i < Mathf.Min(data.cascadeOffsetsAndSizes.Length, 4); i++)
                        {
                            Vector4 v = data.cascadeOffsetsAndSizes[i];
                            offsetsPtr[i * 4 + 0] = v.x;
                            offsetsPtr[i * 4 + 1] = v.y;
                            offsetsPtr[i * 4 + 2] = v.z;
                            offsetsPtr[i * 4 + 3] = v.w;
                        }
                    }
                    
                    // 复制 Matrix4x4 数组 - VPInverse (4 个 Matrix4x4 = 64 个 float)
                    fixed (float* vpInversePtr = data.causticComputeParams._WaterCascadeDepth0AtlasVPInverse)
                    {
                        for (int i = 0; i < Mathf.Min(data.cascadeVPMatricesInverse.Length, 4); i++)
                        {
                            Matrix4x4 m = data.cascadeVPMatricesInverse[i];
                            for (int j = 0; j < 16; j++)
                            {
                                vpInversePtr[i * 16 + j] = m[j];
                            }
                        }
                    }
                    
                    // 复制 Matrix4x4 数组 - VP (4 个 Matrix4x4 = 64 个 float)
                    fixed (float* vpPtr = data.causticComputeParams._WaterCascadeDepth0AtlasVP)
                    {
                        for (int i = 0; i < Mathf.Min(data.cascadeVPMatrices.Length, 4); i++)
                        {
                            Matrix4x4 m = data.cascadeVPMatrices[i];
                            for (int j = 0; j < 16; j++)
                            {
                                vpPtr[i * 16 + j] = m[j];
                            }
                        }
                    }
                    
                    // 复制深度范围数组 (4 个 Vector4 = 16 个 float)
                    fixed (float* depthRangesPtr = data.causticComputeParams._WaterCascadeDepthRanges)
                    {
                        for (int i = 0; i < Mathf.Min(data.cascadeDepthRanges.Length, 4); i++)
                        {
                            Vector4 v = data.cascadeDepthRanges[i];
                            depthRangesPtr[i * 4 + 0] = v.x;
                            depthRangesPtr[i * 4 + 1] = v.y;
                            depthRangesPtr[i * 4 + 2] = v.z;
                            depthRangesPtr[i * 4 + 3] = v.w;
                        }
                    }
                }
                
                ConstantBuffer.PushGlobal(cmd, data.causticComputeParams, CausticShaderIDs.CausticComputeParams);
        }
        /// <summary>
        /// 判断物体是否在级联内
        /// </summary>
        private bool IsRendererInCascade(Renderer renderer, ShadowSplitData splitData)
        {
            // 简单的球形裁剪
            Vector3 center = new(
                splitData.cullingSphere.x,
                splitData.cullingSphere.y,
                splitData.cullingSphere.z
            );
            float radius = splitData.cullingSphere.w;

            if (radius <= 0) return true; // 没有裁剪球,渲染所有

            Vector3 rendererCenter = renderer.bounds.center;
            float rendererRadius = renderer.bounds.extents.magnitude;

            return Vector3.Distance(rendererCenter, center) < (radius + rendererRadius);
        }
                
        
    }
    
}