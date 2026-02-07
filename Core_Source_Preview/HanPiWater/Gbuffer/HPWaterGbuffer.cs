using System.Runtime.InteropServices;
using UnityEngine.Experimental.Rendering;
using UnityEngine.Experimental.Rendering.RenderGraphModule;
using UnityEngine.Rendering.RendererUtils;

namespace UnityEngine.Rendering.HighDefinition
{
    public partial class HDRenderPipeline
    {
        static class HPWaterGbufferShaderIDs
        {
            // 注意：水面深度已写入主场景深度，使用 HDShaderIDs._DepthTexture
            public static readonly int _HPWaterGlobalParams = Shader.PropertyToID("HPWaterGlobalParams");
            // GBuffer 纹理 (3 个 MRT)
            public static readonly int _HPWaterGBuffer0 = Shader.PropertyToID("_HPWaterGBuffer0"); // normalWS + roughness (全分辨率)
            public static readonly int _HPWaterGBuffer1 = Shader.PropertyToID("_HPWaterGBuffer1"); // scatterColor (全分辨率)
            public static readonly int _HPWaterGBuffer2 = Shader.PropertyToID("_HPWaterGBuffer2"); // absorptionColor + foam (全分辨率)
            public static readonly int _StencilWaterRefGBuffer = Shader.PropertyToID("_StencilWaterRefGBuffer");
            public static readonly int _StencilWaterWriteMaskGBuffer = Shader.PropertyToID("_StencilWaterWriteMaskGBuffer");
        }

        /// <summary>
        /// 水面 GBuffer 渲染数据
        /// </summary>
        public class HPWaterGbufferData
        {
            public TextureHandle waterDepthBuffer;
            
            // GBuffer 纹理 (全部全分辨率，一次 3 MRT 绘制)
            public TextureHandle waterGBuffer0;         // normalWS + roughness
            public TextureHandle waterGBuffer1;         // scatterColor
            public TextureHandle waterGBuffer2;         // absorptionColor + foam
        }

        /// <summary>
        /// 水面 GBuffer 渲染 PassData
        /// </summary>
        class RenderWaterGbufferPassData
        {
            public HDCamera hdCamera;
            public CullingResults cullingResults;
            public LayerMask waterLayerMask;
            public RendererListHandle rendererListHandle;
            //public HPWaterGlobalParams globalParams;
            
            // GBuffer 纹理 (全部全分辨率，一次 3 MRT 绘制)
            public TextureHandle waterGBuffer0;         // normalWS + roughness
            public TextureHandle waterGBuffer1;         // scatterColor
            public TextureHandle waterGBuffer2;         // absorptionColor + foam
        }

        /// <summary>
        /// 渲染水面 GBuffer (3 MRT 一次绘制)
        /// </summary>
        /// <param name="prepassDepthBuffer">传入 prepass 深度缓冲，让水面直接写入（用于 SSR）</param>
        /// <param name="prepassNormalBuffer">传入 prepass 法线缓冲，水面法线直接写入（用于 SSR），省去额外复制 pass</param>
        HPWaterGbufferData RenderHPWaterGbuffer(
            RenderGraph renderGraph,
            HDCamera hdCamera,
            CullingResults cullingResults,
            LayerMask waterLayerMask,
            TextureHandle prepassDepthBuffer,
            TextureHandle prepassNormalBuffer)
        {
            // 如果没有指定水面Layer，使用默认Layer 4
            if (waterLayerMask == 0)
            {
                waterLayerMask = 1 << 4;
            }
            if (OnGetHPWaterVolumeInputData == null)
            {
                return new HPWaterGbufferData
                {
                    waterDepthBuffer = prepassDepthBuffer,
                    waterGBuffer0 = prepassNormalBuffer,
                    waterGBuffer1 = renderGraph.defaultResources.whiteTexture,
                    waterGBuffer2 = renderGraph.defaultResources.whiteTexture
                };
            }

            using (var builder = renderGraph.AddRenderPass<RenderWaterGbufferPassData>(
                    "HanPi Water Gbuffer", out var passData, new ProfilingSampler("HanPi Water Gbuffer")))
                {
                    passData.hdCamera = hdCamera;
                    passData.cullingResults = cullingResults;
                    passData.waterLayerMask = waterLayerMask;

                    // ========================================
                    // GBuffer0: 直接使用 prepassNormalBuffer（normalWS + roughness）
                    // 不再单独创建，省去后续的复制 pass
                    // 注意：不清除该 buffer，场景物体法线已在里面，水面像素会覆盖
                    // ========================================
                    passData.waterGBuffer0 = prepassNormalBuffer;

                    // GBuffer1: scatterColor
                    var gbuffer1Desc = new TextureDesc(Vector2.one, true, true)
                    {
                        colorFormat = GraphicsFormat.R8G8B8A8_SRGB,
                        bindTextureMS = false,
                        clearColor = Color.clear,
                        clearBuffer = true,
                        name = "HPWaterGBuffer1_Scatter"
                    };
                    passData.waterGBuffer1 = renderGraph.CreateTexture(gbuffer1Desc);

                    // GBuffer2: absorptionColor + foam (exp 编码, clear 为白色 = exp(0) = 1, alpha = 0 for foam)
                    var gbuffer2Desc = new TextureDesc(Vector2.one, true, true)
                    {
                        colorFormat = GraphicsFormat.R8G8B8A8_SRGB,
                        bindTextureMS = false,
                        clearColor = Color.clear,
                        clearBuffer = true,
                        name = "HPWaterGBuffer2_AbsorptionFoam"
                    };
                    passData.waterGBuffer2 = renderGraph.CreateTexture(gbuffer2Desc);

                    // ========================================
                    // GBuffer0 直接使用 prepassNormalBuffer，水面法线直接写入
                    // ========================================
                    builder.UseColorBuffer(passData.waterGBuffer0, 0);  // prepassNormalBuffer
                    builder.UseColorBuffer(passData.waterGBuffer1, 1);
                    builder.UseColorBuffer(passData.waterGBuffer2, 2);

                    // 直接使用 prepass 深度缓冲（和官方水系统一致）
                    // 水面深度直接写入主场景深度，用于 SSR
                    builder.UseDepthBuffer(prepassDepthBuffer, DepthAccess.ReadWrite);

                    // 创建 RendererList 用于绘制水面
                    var rendererListDesc = new RendererListDesc(
                        new ShaderTagId("HPWaterGBuffer"), cullingResults, hdCamera.camera)
                    {
                        renderQueueRange = RenderQueueRange.all,
                        sortingCriteria = SortingCriteria.CommonOpaque,
                        layerMask = waterLayerMask
                    };

                    passData.rendererListHandle = builder.UseRendererList(
                        renderGraph.CreateRendererList(rendererListDesc));

                    // 禁止 Pass 剪裁（确保 Pass 一定会执行）
                    builder.AllowPassCulling(false);

                    builder.SetRenderFunc((RenderWaterGbufferPassData data, RenderGraphContext ctx) =>
                    {
                        // 设置水面 Stencil 值（用于后续判断水面像素）
                        // 参考官方水系统：使用 WaterSurface | TraceReflectionRay
                        // 使用水面专用属性名称，避免被材质属性覆盖
                        int waterStencilRef = (int)(StencilUsage.WaterSurface | StencilUsage.TraceReflectionRay);
                        ctx.cmd.SetGlobalFloat(HPWaterGbufferShaderIDs._StencilWaterRefGBuffer, waterStencilRef);
                        ctx.cmd.SetGlobalFloat(HPWaterGbufferShaderIDs._StencilWaterWriteMaskGBuffer, waterStencilRef);

                        // RenderGraph 已经通过 UseColorBuffer/UseDepthBuffer 自动设置了 RenderTarget
                        // 直接绘制水面，输出到所有 3 个 GBuffer + 深度
                        CoreUtils.DrawRendererList(ctx.renderContext, ctx.cmd, data.rendererListHandle);
                    });

                    // 返回水面 GBuffer 数据
                    // waterDepthBuffer 使用 prepassDepthBuffer（水面深度已写入主场景深度）
                    return new HPWaterGbufferData
                    {
                        waterDepthBuffer = prepassDepthBuffer,
                        waterGBuffer0 = passData.waterGBuffer0,
                        waterGBuffer1 = passData.waterGBuffer1,
                        waterGBuffer2 = passData.waterGBuffer2
                    };
                }
        }

        /// <summary>
        /// 验证水面 GBuffer 数据是否有效
        /// </summary>
        HPWaterGbufferData IsWaterGbufferDataValid(HPWaterGbufferData waterGbufferData, RenderGraph renderGraph)
        {
            if (waterGbufferData != null && 
                waterGbufferData.waterDepthBuffer.IsValid() &&
                waterGbufferData.waterGBuffer0.IsValid() &&
                waterGbufferData.waterGBuffer1.IsValid() &&
                waterGbufferData.waterGBuffer2.IsValid())
            {
                return waterGbufferData;
            }

            // 返回默认的空数据
            return new HPWaterGbufferData
            {
                waterDepthBuffer = renderGraph.defaultResources.blackTexture,
                waterGBuffer0 = renderGraph.defaultResources.whiteTexture,
                waterGBuffer1 = renderGraph.defaultResources.whiteTexture,
                waterGBuffer2 = renderGraph.defaultResources.whiteTexture
            };
        }
    }
}
