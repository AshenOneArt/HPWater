using System.Runtime.InteropServices;
using UnityEngine.Experimental.Rendering;
using UnityEngine.Experimental.Rendering.RenderGraphModule;
using UnityEngine.Rendering.RendererUtils;

namespace UnityEngine.Rendering.HighDefinition
{
    public partial class HDRenderPipeline
    {
        static class HPWaterFluidDynamicsShaderIDs
        {
            public static readonly int _HPWaterFluidDynamicsDepth = Shader.PropertyToID("_HPWaterFluidDynamicsDepth");
            public static readonly string HPWaterFluidDynamicsDepthPassName = "HPWaterFluidDynamicsDepth";
            
            // 波动方程 Compute Shader 参数
            public static readonly int _WaveHeightCurrent = Shader.PropertyToID("_WaveHeightCurrent");
            public static readonly int _WaveHeightPrevious = Shader.PropertyToID("_WaveHeightPrevious");
            public static readonly int _WaveHeightNext = Shader.PropertyToID("_WaveHeightNext");
            public static readonly int _HPSceneHeight = Shader.PropertyToID("_HPSceneHeight");
            public static readonly int _HPWaterHeight = Shader.PropertyToID("_HPWaterHeight");
            public static readonly int _WaveSpeed = Shader.PropertyToID("_WaveSpeed");
            public static readonly int _DampingFactor = Shader.PropertyToID("_DampingFactor");
            public static readonly int _DeltaTime = Shader.PropertyToID("_DeltaTime");
            public static readonly int _WaveSourceUV = Shader.PropertyToID("_WaveSourceUV");
            public static readonly int _WaveSourceIntensity = Shader.PropertyToID("_WaveSourceIntensity");
            public static readonly int _WaveSourceRadius = Shader.PropertyToID("_WaveSourceRadius");
            public static readonly int HPWaterFluidDynamicsPass = Shader.PropertyToID("HPWaterFluidDynamicsPass");

            // 全局波高纹理（供外部Shader采样）
            public static readonly int _HPWaterWaveHeightTexture = Shader.PropertyToID("_HPWaterWaveHeightTexture");
            public static readonly int _HPWaterFluidDynamicsBoxCenter = Shader.PropertyToID("_HPWaterFluidDynamicsBoxCenter");
            public static readonly int _HPWaterFluidDynamicsBoxSize = Shader.PropertyToID("_HPWaterFluidDynamicsBoxSize");
        }

        /// <summary>
        /// 流体动力学输入数据
        /// </summary>
        public class HPWaterFluidDynamicsInputData
        {
            public bool startFrameBakeProcess = false; // 起始帧烘焙流程
            public Vector3 boxCenter;          // Box 中心位置（世界空间）
            public Vector3 boxSize;            // Box 尺寸（世界空间）
            public int sceneDepthTextureResolution; // 深度纹理分辨率（正方形）
            public int waterDepthTextureResolution; // 水面深度纹理分辨率（正方形）
            public int waveHeightTextureResolution; // 波高纹理分辨率（正方形）
            public float cameraHeight;         // 相机高度（Box上方多少米）
            
            // 波动方程参数
            public float waveSpeed = 1.0f;           // 波速
            public float dampingFactor = 0.02f;      // 阻尼系数
            public float waveSourceRadius = 5f;      // 波源半径（像素）
            
            // 鼠标波源输入（单点）
            public Vector2 waveSourceUV = new Vector2(-1, -1);   // UV坐标 (0-1)，(-1,-1)表示无输入
            public float waveSourceIntensity = 0f;               // 强度，0表示无输入
        }

        /// <summary>
        /// 流体动力学Pass渲染数据
        /// </summary>
        class RenderHPWaterFluidDynamicsPassData
        {
            public HDCamera hdCamera;
            public Camera virtualCamera;  // 虚拟相机（用于裁剪和创建 RendererList）
            public LayerMask LayerMask;   // 排除水面层
            
            // 垂直相机矩阵
            public Matrix4x4 verticalViewMatrix;
            public Matrix4x4 verticalProjectionMatrix;
            
            // 输出深度纹理
            public TextureHandle fluidDynamicsHeight;
        }
        
        /// <summary>
        /// 波动方程Pass渲染数据
        /// </summary>
        class RenderWaveEquationPassData
        {
            public ComputeShader waveEquationCS;
            public int waveEquationKernel;
            public TextureHandle sceneHeightTexture;
            public TextureHandle waterHeightTexture;
            public TextureHandle waveHeightCurrent;
            public TextureHandle waveHeightPrevious;
            public TextureHandle waveHeightNext;
            public HPWaterFluidDynamicsInputData inputData;
            public int resolution;
        }

        /// <summary>
        /// 流体动力学输出数据
        /// </summary>
        public class HPWaterFluidDynamicsPackage
        {
            public TextureHandle fluidDynamicsDepth;   // 深度纹理
            public TextureHandle waveHeightTexture;    // 当前波高纹理
            public Vector3 boxCenter;              // Box中心位置
            public Vector3 boxSize;              // Box尺寸
        }

        public HPWaterFluidDynamicsPackage IsHPWaterFluidDynamicsDataValid(HPWaterFluidDynamicsPackage fluidDynamicsPackage,RenderGraph renderGraph)
        {
            if (fluidDynamicsPackage.fluidDynamicsDepth.IsValid() && 
                fluidDynamicsPackage.waveHeightTexture.IsValid())
            {
                return fluidDynamicsPackage; 
            }
            
            var blackTexture = renderGraph.defaultResources.blackTexture;
            return new HPWaterFluidDynamicsPackage
            {
                fluidDynamicsDepth = blackTexture,
                waveHeightTexture = blackTexture
            };
        }

        void SetGlobalHPWaterFluidDynamics(RenderGraph renderGraph, HPWaterFluidDynamicsPackage fluidDynamicsPackage)
        {
            fluidDynamicsPackage = IsHPWaterFluidDynamicsDataValid(fluidDynamicsPackage, renderGraph);
            using (var builder = renderGraph.AddRenderPass<HPWaterFluidDynamicsPackage>("Set Global HP Water Fluid Dynamics", out var passData, new ProfilingSampler("Set Global HP Water Fluid Dynamics")))
            {
                // 禁止 Pass 剪裁（确保 Pass 一定会执行）
                builder.AllowPassCulling(false);
                passData.fluidDynamicsDepth = fluidDynamicsPackage.fluidDynamicsDepth;
                passData.waveHeightTexture = fluidDynamicsPackage.waveHeightTexture;
                passData.boxCenter = fluidDynamicsPackage.boxCenter;
                passData.boxSize = fluidDynamicsPackage.boxSize;
                builder.SetRenderFunc((HPWaterFluidDynamicsPackage data, RenderGraphContext ctx) =>
                {
                    //ctx.cmd.SetGlobalTexture(HPWaterFluidDynamicsShaderIDs._HPWaterFluidDynamicsDepth, data.fluidDynamicsDepth);
                    ctx.cmd.SetGlobalTexture(HPWaterFluidDynamicsShaderIDs._HPWaterWaveHeightTexture, data.waveHeightTexture);
                    ctx.cmd.SetGlobalVector(HPWaterFluidDynamicsShaderIDs._HPWaterFluidDynamicsBoxCenter, data.boxCenter);
                    ctx.cmd.SetGlobalVector(HPWaterFluidDynamicsShaderIDs._HPWaterFluidDynamicsBoxSize, data.boxSize);
                });
            }
        }

        /// <summary>
        /// 清理波动方程纹理缓存（用于组件重新启用时重置状态）
        /// </summary>
        void ResetWaveEquationTextures()
        {
            // 释放所有波高纹理
            RTHandles.Release(m_WaveHeightCurrent);
            RTHandles.Release(m_WaveHeightPrevious);
            RTHandles.Release(m_WaveHeightNext);
            
            // 重置为null
            m_WaveHeightCurrent = null;
            m_WaveHeightPrevious = null;
            m_WaveHeightNext = null;
            
            // 标记为需要重新初始化
            s_CurrentWaveTextureResolution = -1;
            
            // 释放烘焙的深度纹理
            RTHandles.Release(m_CachedWaterDepth);
            RTHandles.Release(m_CachedSceneDepth);
            m_CachedWaterDepth = null;
            m_CachedSceneDepth = null;
            m_HasBakedDepthTextures = false;
        }

        void CleanupHPWaterFluidDynamics()
        {
            ResetWaveEquationTextures();
            if (m_CachedFluidDynamicsCamera != null)
            {
                CoreUtils.Destroy(m_CachedFluidDynamicsCamera);
                m_CachedFluidDynamicsCamera = null;
            }
            if (m_CachedCameraGameObject != null)
            {
                CoreUtils.Destroy(m_CachedCameraGameObject);
                m_CachedCameraGameObject = null;
            }

        }

        /// <summary>
        /// 流体动力学参数提供回调委托
        /// </summary>
        public delegate HPWaterFluidDynamicsInputData HPWaterFluidDynamicsInputDataProvider();

        /// <summary>
        /// 流体动力学参数提供者事件，在需要流体动力学参数时触发
        /// </summary>
        public static event HPWaterFluidDynamicsInputDataProvider OnGetHPWaterFluidDynamicsInputData;
        
        // 缓存的虚拟相机（避免每帧创建 GC）
        private  Camera m_CachedFluidDynamicsCamera;
        private  GameObject m_CachedCameraGameObject;
        
        // 波动方程纹理缓存（Ping-Pong Buffer）
        private  RTHandle m_WaveHeightCurrent;
        private  RTHandle m_WaveHeightPrevious;
        private  RTHandle m_WaveHeightNext;
        private static int s_CurrentWaveTextureResolution = -1;
        
        // 起始帧烘焙缓存
        private RTHandle m_CachedWaterDepth;        // 缓存的水面深度纹理
        private RTHandle m_CachedSceneDepth;        // 缓存的场景深度纹理
        private bool m_HasBakedDepthTextures = false; // 是否已经烘焙过深度纹理
        

        HPWaterFluidDynamicsPackage RenderHPWaterFluidDynamics(
            RenderGraph renderGraph,
            HDCamera hdCamera,
            CullingResults cullingResults,
            LayerMask waterLayerMask)
        {
            // 如果没有指定水面Layer，使用默认Layer 4
            if (waterLayerMask == 0)
            {
                waterLayerMask = 1 << 4;
            }

            // 检查是否有参数提供者
            if (OnGetHPWaterFluidDynamicsInputData == null)
            {
                ResetWaveEquationTextures();//释放纹理
                return new HPWaterFluidDynamicsPackage
                {
                    fluidDynamicsDepth = renderGraph.defaultResources.blackTexture
                };
            }

            // 获取输入参数
            var inputData = OnGetHPWaterFluidDynamicsInputData();
            if (inputData == null)
            {
                ResetWaveEquationTextures();//释放纹理
                return new HPWaterFluidDynamicsPackage 
                {
                    fluidDynamicsDepth = renderGraph.defaultResources.blackTexture
                };
            }

            // ========================================
            // 计算垂直正交相机矩阵
            // ========================================
            Vector3 boxCenter = inputData.boxCenter;
            Vector3 boxSize = inputData.boxSize;
            float cameraHeight = inputData.cameraHeight;

            // 相机参数
            Vector3 cameraPosition = boxCenter + Vector3.up * cameraHeight;
            float orthoWidth = boxSize.x * 0.5f;
            float orthoHeight = boxSize.z * 0.5f;
            
            // nearClip: 从相机到 Box 顶部的距离
            // farClip: 从相机到 Box 底部的距离
            float nearClip = cameraHeight - boxSize.y * 0.5f;
            float farClip = cameraHeight + boxSize.y * 0.5f;

            // ========================================
            // 创建或复用虚拟垂直相机用于裁剪
            // ========================================
            if (m_CachedFluidDynamicsCamera == null)
            {
                m_CachedCameraGameObject = new GameObject("FluidDynamicsVirtualCamera");
                m_CachedCameraGameObject.hideFlags = HideFlags.HideAndDontSave; 
                m_CachedFluidDynamicsCamera = m_CachedCameraGameObject.AddComponent<Camera>();
                m_CachedFluidDynamicsCamera.enabled = false; // 不自动渲染
            }

            Camera virtualCamera = m_CachedFluidDynamicsCamera;

            // 通过 Transform 设置相机位置和朝向，让 Unity 正确计算 worldToCameraMatrix
            virtualCamera.transform.position = cameraPosition;
            // LookRotation: forward = 朝下 (Vector3.down), up = 世界 Z 轴 (Vector3.forward)
            virtualCamera.transform.rotation = Quaternion.LookRotation(Vector3.down, Vector3.forward);
            virtualCamera.orthographic = true;
            virtualCamera.orthographicSize = orthoHeight; // 正交相机的半高
            virtualCamera.aspect = orthoWidth / orthoHeight;
            virtualCamera.nearClipPlane = nearClip;
            virtualCamera.farClipPlane = farClip;

            // 从配置好的相机获取正确的矩阵
            // 使用 HDRP 官方的方式处理矩阵
            Matrix4x4 viewMatrix = virtualCamera.worldToCameraMatrix;
            Matrix4x4 projMatrix = virtualCamera.projectionMatrix;
            
            Matrix4x4 verticalViewMatrix = viewMatrix;
            Matrix4x4 verticalProjectionMatrix = projMatrix;

            // ========================================
            // 渲染水面深度纹理
            // ========================================
            TextureHandle fluidDynamicsWaterDepth;
            TextureHandle fluidDynamicsSceneDepth;
            
            // 判断是否使用起始帧烘焙流程
            if (inputData.startFrameBakeProcess)
            {
                // 起始帧烘焙流程：只在第一帧渲染，之后使用缓存
                if (!m_HasBakedDepthTextures)
                {
                    // 第一帧：渲染并保存到 RTHandle
                    fluidDynamicsWaterDepth = RenderFluidHeightAndCache(
                        renderGraph, 
                        hdCamera, 
                        waterLayerMask, 
                        inputData, 
                        verticalViewMatrix, 
                        verticalProjectionMatrix,
                        virtualCamera, 
                        true,
                        ref m_CachedWaterDepth);

                    fluidDynamicsSceneDepth = RenderFluidHeightAndCache(
                        renderGraph, 
                        hdCamera, 
                        ~waterLayerMask, 
                        inputData, 
                        verticalViewMatrix, 
                        verticalProjectionMatrix,
                        virtualCamera, 
                        false,
                        ref m_CachedSceneDepth);
                    
                    // 标记已完成烘焙
                    m_HasBakedDepthTextures = true;
                }
                else
                {
                    // 后续帧：直接使用缓存的纹理
                    fluidDynamicsWaterDepth = renderGraph.ImportTexture(m_CachedWaterDepth);
                    fluidDynamicsSceneDepth = renderGraph.ImportTexture(m_CachedSceneDepth);
                }
            }
            else
            {
                // 普通流程：每帧都重新渲染
                // 如果之前开启过烘焙，现在关闭了，需要清理缓存
                if (m_HasBakedDepthTextures)
                {
                    RTHandles.Release(m_CachedWaterDepth);
                    RTHandles.Release(m_CachedSceneDepth);
                    m_CachedWaterDepth = null;
                    m_CachedSceneDepth = null;
                    m_HasBakedDepthTextures = false;
                }
                
                fluidDynamicsWaterDepth = RenderFluidHeight(
                    renderGraph, 
                    hdCamera, 
                    waterLayerMask, 
                    inputData, 
                    verticalViewMatrix, 
                    verticalProjectionMatrix,
                    virtualCamera, 
                    true);

                fluidDynamicsSceneDepth = RenderFluidHeight(
                    renderGraph, 
                    hdCamera, 
                    ~waterLayerMask, 
                    inputData, 
                    verticalViewMatrix, 
                    verticalProjectionMatrix,
                    virtualCamera, 
                    false);
            }
            
            // ========================================
            // 计算波动方程（使用深度作为边界）
            // 内部会自动设置全局波高纹理
            // ========================================
            TextureHandle waveHeightTexture = RenderWaveEquation(renderGraph, hdCamera, fluidDynamicsSceneDepth, fluidDynamicsWaterDepth, inputData);
            
            // ========================================
            // 返回完整的流体动力学数据包
            // ========================================
            return new HPWaterFluidDynamicsPackage
            {
                fluidDynamicsDepth = fluidDynamicsSceneDepth,
                waveHeightTexture = waveHeightTexture,
                boxCenter = inputData.boxCenter,
                boxSize = inputData.boxSize
            };
        }

        TextureHandle RenderFluidHeight(RenderGraph renderGraph, HDCamera hdCamera, LayerMask layerMask, 
        HPWaterFluidDynamicsInputData inputData, Matrix4x4 verticalViewMatrix, Matrix4x4 verticalProjectionMatrix, 
        Camera virtualCamera,bool isWaterDepth)
        {
            string name = isWaterDepth ? "HPWaterFluidWaterHeight" : "HPWaterFluidSceneHeight";
            using (var builder = renderGraph.AddRenderPass<RenderHPWaterFluidDynamicsPassData>(
                                name, out var passData, new ProfilingSampler(name)))
            {
                // 设置基础数据
                passData.hdCamera = hdCamera;
                passData.virtualCamera = virtualCamera;
                passData.LayerMask = layerMask; 
                passData.verticalViewMatrix = verticalViewMatrix;
                passData.verticalProjectionMatrix = verticalProjectionMatrix;

                // ========================================
                // 创建深度纹理
                // ========================================
                int resolution = isWaterDepth ? inputData.waterDepthTextureResolution : inputData.sceneDepthTextureResolution;
                var heightDesc = new TextureDesc(resolution, resolution, false, false)  // 禁用dynamicScale和xrInstancing
                {
                    colorFormat = GraphicsFormat.R16_SFloat,
                    depthBufferBits = DepthBits.None,
                    name = isWaterDepth ? "HPWaterFluidWaterHeight" : "HPWaterFluidSceneHeight"
                };
                passData.fluidDynamicsHeight = builder.WriteTexture(renderGraph.CreateTexture(heightDesc));

                // 禁止 Pass 剪裁（确保 Pass 一定会执行）
                builder.AllowPassCulling(false);

                // ========================================
                // 渲染函数
                // ========================================
                builder.SetRenderFunc((RenderHPWaterFluidDynamicsPassData data, RenderGraphContext ctx) =>
                {
                    // 设置虚拟相机的裁剪遮罩,SetRenderFunc内部修改，因为这里是延迟执行的
                    data.virtualCamera.cullingMask = data.LayerMask;

                    CoreUtils.SetRenderTarget(ctx.cmd, data.fluidDynamicsHeight, ClearFlag.Color);

                    // 使用虚拟相机执行裁剪
                    if (!data.virtualCamera.TryGetCullingParameters(out ScriptableCullingParameters virtualCullingParams))
                    {
                        // 裁剪失败，直接返回
                        return;
                    }

                    // 执行裁剪（使用虚拟相机的视锥体）
                    var virtualCullingResults = ctx.renderContext.Cull(ref virtualCullingParams);

                    // 创建 RendererList
                    var rendererListDesc = new RendererListDesc(
                        new ShaderTagId("HPWaterFluidDynamicsPass"),
                        virtualCullingResults,
                        data.virtualCamera)
                    {
                        renderQueueRange = RenderQueueRange.opaque,  // 只渲染不透明物体
                        sortingCriteria = SortingCriteria.CommonOpaque,
                        layerMask = data.LayerMask,
                    };

                    var rendererList = ctx.renderContext.CreateRendererList(rendererListDesc);

                    // 设置垂直相机的 VP 矩阵
                    ctx.cmd.SetViewProjectionMatrices(
                        data.verticalViewMatrix,
                        data.verticalProjectionMatrix);

                    // 绘制场景物体（除水面）
                    CoreUtils.DrawRendererList(ctx.renderContext, ctx.cmd, rendererList);

                    // 恢复主相机矩阵
                    ctx.cmd.SetViewProjectionMatrices(
                        data.hdCamera.camera.worldToCameraMatrix,
                        data.hdCamera.camera.projectionMatrix);
                });

                return passData.fluidDynamicsHeight;
            }
        }
        
        /// <summary>
        /// 渲染流体高度并缓存到 RTHandle（用于起始帧烘焙流程）
        /// </summary>
        TextureHandle RenderFluidHeightAndCache(
            RenderGraph renderGraph, 
            HDCamera hdCamera, 
            LayerMask layerMask, 
            HPWaterFluidDynamicsInputData inputData, 
            Matrix4x4 verticalViewMatrix, 
            Matrix4x4 verticalProjectionMatrix, 
            Camera virtualCamera, 
            bool isWaterDepth,
            ref RTHandle cachedTexture)
        {
            string name = isWaterDepth ? "HPWaterFluidWaterHeight_Bake" : "HPWaterFluidSceneHeight_Bake";
            int resolution = isWaterDepth ? inputData.waterDepthTextureResolution : inputData.sceneDepthTextureResolution;
            
            // 如果缓存纹理不存在或分辨率不匹配，创建新的
            if (cachedTexture == null || cachedTexture.rt.width != resolution)
            {
                RTHandles.Release(cachedTexture);
                cachedTexture = RTHandles.Alloc(
                    resolution, resolution,
                    colorFormat: GraphicsFormat.R16_SFloat,
                    enableRandomWrite: false,
                    name: name);
            }
            
            using (var builder = renderGraph.AddRenderPass<RenderHPWaterFluidDynamicsPassData>(
                                name, out var passData, new ProfilingSampler(name)))
            {
                // 设置基础数据
                passData.hdCamera = hdCamera;
                passData.virtualCamera = virtualCamera;
                passData.LayerMask = layerMask;
                passData.verticalViewMatrix = verticalViewMatrix;
                passData.verticalProjectionMatrix = verticalProjectionMatrix;
                
                // 导入并写入 RTHandle
                passData.fluidDynamicsHeight = builder.WriteTexture(renderGraph.ImportTexture(cachedTexture));

                // 禁止 Pass 剪裁
                builder.AllowPassCulling(false);

                // 渲染函数
                builder.SetRenderFunc((RenderHPWaterFluidDynamicsPassData data, RenderGraphContext ctx) =>
                {
                    // 设置虚拟相机的裁剪遮罩
                    data.virtualCamera.cullingMask = data.LayerMask;

                    CoreUtils.SetRenderTarget(ctx.cmd, data.fluidDynamicsHeight, ClearFlag.Color);

                    // 使用虚拟相机执行裁剪
                    if (!data.virtualCamera.TryGetCullingParameters(out ScriptableCullingParameters virtualCullingParams))
                    {
                        return;
                    }

                    // 执行裁剪
                    var virtualCullingResults = ctx.renderContext.Cull(ref virtualCullingParams);

                    // 创建 RendererList
                    var rendererListDesc = new RendererListDesc(
                        new ShaderTagId("HPWaterFluidDynamicsPass"),
                        virtualCullingResults,
                        data.virtualCamera)
                    {
                        renderQueueRange = RenderQueueRange.opaque,
                        sortingCriteria = SortingCriteria.CommonOpaque,
                        layerMask = data.LayerMask,
                    };

                    var rendererList = ctx.renderContext.CreateRendererList(rendererListDesc);

                    // 设置垂直相机的 VP 矩阵
                    ctx.cmd.SetViewProjectionMatrices(
                        data.verticalViewMatrix,
                        data.verticalProjectionMatrix);

                    // 绘制场景物体
                    CoreUtils.DrawRendererList(ctx.renderContext, ctx.cmd, rendererList);

                    // 恢复主相机矩阵
                    ctx.cmd.SetViewProjectionMatrices(
                        data.hdCamera.camera.worldToCameraMatrix,
                        data.hdCamera.camera.projectionMatrix);
                });

                return passData.fluidDynamicsHeight;
            }
        }
        
        /// <summary>
        /// 渲染波动方程
        /// </summary>
        private TextureHandle RenderWaveEquation(
            RenderGraph renderGraph,
            HDCamera hdCamera,
            TextureHandle sceneHeightTexture,
            TextureHandle waterHeightTexture,
            HPWaterFluidDynamicsInputData inputData)
        {
            // 检查Compute Shader是否可用
            if (m_HanPiWaterWaveEquationCS == null || m_HanPiWaterWaveEquationUpdateKernel < 0)
            {
                return renderGraph.defaultResources.blackTexture;
            }
            
            int resolution = inputData.waveHeightTextureResolution;
            
            // 创建或重新分配波高纹理（Ping-Pong Buffer）
            bool needsInitialization = (m_WaveHeightCurrent == null || s_CurrentWaveTextureResolution != resolution);

            if (needsInitialization)
            {
                // 释放旧纹理
                RTHandles.Release(m_WaveHeightCurrent);
                RTHandles.Release(m_WaveHeightPrevious);
                RTHandles.Release(m_WaveHeightNext);

                // 创建新纹理（R16 格式存储波高）
                m_WaveHeightCurrent = RTHandles.Alloc(
                    resolution, resolution,
                    colorFormat: GraphicsFormat.R16_SFloat,
                    enableRandomWrite: true,
                    name: "WaveHeightCurrent");

                m_WaveHeightPrevious = RTHandles.Alloc(
                    resolution, resolution,
                    colorFormat: GraphicsFormat.R16_SFloat,
                    enableRandomWrite: true,
                    name: "WaveHeightPrevious");

                m_WaveHeightNext = RTHandles.Alloc(
                    resolution, resolution,
                    colorFormat: GraphicsFormat.R16_SFloat,
                    enableRandomWrite: true,
                    name: "WaveHeightNext");

                s_CurrentWaveTextureResolution = resolution;

                using (var builder = renderGraph.AddRenderPass<object>("Init Clear Wave Textures", out var passData, new ProfilingSampler("Init Clear")))
                {
                    // 禁止 Pass 剪裁（确保 Pass 一定会执行）
                    builder.AllowPassCulling(false);
                    var texCurrent = builder.WriteTexture(renderGraph.ImportTexture(m_WaveHeightCurrent));
                    var texPrev = builder.WriteTexture(renderGraph.ImportTexture(m_WaveHeightPrevious));
                    var texNext = builder.WriteTexture(renderGraph.ImportTexture(m_WaveHeightNext));

                    builder.SetRenderFunc((object data, RenderGraphContext ctx) =>
                    {
                        var cmd = ctx.cmd;

                        cmd.SetRenderTarget(texCurrent);
                        cmd.ClearRenderTarget(false, true, Color.clear);

                        cmd.SetRenderTarget(texPrev);
                        cmd.ClearRenderTarget(false, true, Color.clear);

                        cmd.SetRenderTarget(texNext);
                        cmd.ClearRenderTarget(false, true, Color.clear);
                    });
                }
            }
            
            using (var builder = renderGraph.AddRenderPass<RenderWaveEquationPassData>(
                "HanPi Water Wave Equation", out var passData, new ProfilingSampler("HanPi Water Wave Equation")))
            {
                // 设置Pass数据
                passData.waveEquationCS = m_HanPiWaterWaveEquationCS;
                passData.waveEquationKernel = m_HanPiWaterWaveEquationUpdateKernel;
                passData.inputData = inputData;
                passData.resolution = resolution;
                
                // 导入深度纹理
                passData.sceneHeightTexture = builder.ReadTexture(sceneHeightTexture);
                passData.waterHeightTexture = builder.ReadTexture(waterHeightTexture);
                
                // 导入波高纹理（从RTHandle转换为TextureHandle）
                passData.waveHeightCurrent = builder.ReadTexture(renderGraph.ImportTexture(m_WaveHeightCurrent));
                passData.waveHeightPrevious = builder.ReadTexture(renderGraph.ImportTexture(m_WaveHeightPrevious));
                passData.waveHeightNext = builder.ReadWriteTexture(renderGraph.ImportTexture(m_WaveHeightNext));
                
                // 禁止Pass剪裁
                builder.AllowPassCulling(false);
                
                // 设置渲染函数
                builder.SetRenderFunc((RenderWaveEquationPassData data, RenderGraphContext ctx) =>
                {
                    ComputeShader cs = data.waveEquationCS;
                    int kernel = data.waveEquationKernel;
                    
                    // 设置纹理
                    ctx.cmd.SetComputeTextureParam(cs, kernel, HPWaterFluidDynamicsShaderIDs._WaveHeightCurrent, data.waveHeightCurrent);
                    ctx.cmd.SetComputeTextureParam(cs, kernel, HPWaterFluidDynamicsShaderIDs._WaveHeightPrevious, data.waveHeightPrevious);
                    ctx.cmd.SetComputeTextureParam(cs, kernel, HPWaterFluidDynamicsShaderIDs._WaveHeightNext, data.waveHeightNext);
                    ctx.cmd.SetComputeTextureParam(cs, kernel, HPWaterFluidDynamicsShaderIDs._HPWaterHeight, data.waterHeightTexture);
                    ctx.cmd.SetComputeTextureParam(cs, kernel, HPWaterFluidDynamicsShaderIDs._HPSceneHeight, data.sceneHeightTexture);
                    
                    // 设置波动方程参数
                    ctx.cmd.SetComputeFloatParam(cs, HPWaterFluidDynamicsShaderIDs._WaveSpeed, data.inputData.waveSpeed);
                    ctx.cmd.SetComputeFloatParam(cs, HPWaterFluidDynamicsShaderIDs._DampingFactor, data.inputData.dampingFactor);
                    ctx.cmd.SetComputeFloatParam(cs, HPWaterFluidDynamicsShaderIDs._DeltaTime, Time.deltaTime);
                    
                    // 设置波源参数
                    ctx.cmd.SetComputeVectorParam(cs, HPWaterFluidDynamicsShaderIDs._WaveSourceUV, 
                        data.inputData.waveSourceUV);
                    ctx.cmd.SetComputeFloatParam(cs, HPWaterFluidDynamicsShaderIDs._WaveSourceIntensity, 
                        data.inputData.waveSourceIntensity);
                    ctx.cmd.SetComputeFloatParam(cs, HPWaterFluidDynamicsShaderIDs._WaveSourceRadius, 
                        data.inputData.waveSourceRadius);
                    
                    // Dispatch Compute Shader
                    cs.GetKernelThreadGroupSizes(kernel, out uint x, out uint y, out _);
                    int dispatchX = Mathf.CeilToInt((float)data.resolution / (float)x);
                    int dispatchY = Mathf.CeilToInt((float)data.resolution / (float)y);
                    ctx.cmd.DispatchCompute(cs, kernel, dispatchX, dispatchY, 1);
                });
                
                // Ping-Pong交换：Previous <- Current <- Next
                // 交换RTHandle引用（不复制数据）
                var temp = m_WaveHeightPrevious;
                m_WaveHeightPrevious = m_WaveHeightCurrent;
                m_WaveHeightCurrent = m_WaveHeightNext;
                m_WaveHeightNext = temp;
                
                // 返回当前波高纹理
                return passData.waveHeightNext;  // 这是写入后的结果，下一帧会成为Current
            }
        }

    }
}
