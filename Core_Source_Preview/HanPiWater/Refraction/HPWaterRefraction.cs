using UnityEngine.Experimental.Rendering;
using UnityEngine.Experimental.Rendering.RenderGraphModule;

namespace UnityEngine.Rendering.HighDefinition
{
    /// <summary>
    /// 水体折射输出数据（只包含UV纹理，深度对比改用金字塔深度）
    /// </summary>
    public struct HPWaterRefractionOutput
    {
        public TextureHandle refractionData;    // 全分辨率 UV 偏移纹理
    }

    public partial class HDRenderPipeline
    {
        // 水体折射 Compute Shader（从 defaultResources 获取）和 Kernel
        static partial class HPWaterRefractionShaderIDs
        {
            public static readonly int _HPWaterGBuffer0 = Shader.PropertyToID("_HPWaterGBuffer0");
            public static readonly int _Ray_Marching_Sample_Count = Shader.PropertyToID("_Ray_Marching_Sample_Count");
        }

        /// <summary>
        /// 水面折射渲染PassData
        /// </summary>
        class RenderWaterRefractionPassData
        {
            public HDCamera hdCamera;
            public WaterRefractionInputData parameters;
            public int viewCount;
            public int tileX;
            public int tileY;

            // Input textures
            public TextureHandle depthBuffer;          // 主场景深度（包含水面，用于水面深度）
            public TextureHandle stencilBuffer;        // Stencil 纹理（用于判断水面像素）
            public TextureHandle depthPyramidTexture;  // 场景深度（不含水面，用于场景深度）
            public TextureHandle waterGBuffer0;

            // Output textures
            public TextureHandle WaterRefractionBuffer;    // 全分辨率 UV 偏移XY为UV偏移，Z为折射后的深度，W为是否为水面
        }
        private Material s_WaterRefractionMaterial;
        public class WaterRefractionInputData
        {
            public bool useRayMarching = false;
            public int rayMarchingSampleCount = 8;
            /// <summary>
            /// 验证参数有效性
            /// </summary>
            public bool IsValid()
            {
                if (rayMarchingSampleCount <= 0) return false;
                return true;
            } 
        }

        void CleanupHPWaterRefraction()
        {
            if (s_WaterRefractionMaterial != null)
            {
                CoreUtils.Destroy(s_WaterRefractionMaterial);
                s_WaterRefractionMaterial = null;
            }
        }

        /// <summary>
        /// 水体折射参数提供回调，由外部系统提供水体折射渲染所需的参数
        /// </summary>
        public delegate WaterRefractionInputData WaterRefractionParametersProvider();

        /// <summary>
        /// 水体折射参数提供者事件，在需要水体折射参数时触发
        /// </summary>
        public static event WaterRefractionParametersProvider OnGetWaterRefractionParameters;        

        /// <summary>
        /// 渲染水面折射
        /// </summary>
        /// <param name="depthBuffer">主场景深度（包含水面，用于水面深度 + Stencil 判断）</param>
        /// <param name="depthPyramidTexture">场景深度（不含水面，用于场景深度）</param>
        /// <param name="waterGBuffer0">水面 GBuffer0（法线 + 粗糙度）</param>
        /// <returns>HPWaterRefractionOutput 包含 UV 纹理（全分辨率）</returns>
        HPWaterRefractionOutput RenderHPWaterRefraction(
            RenderGraph renderGraph,
            HDCamera hdCamera,
            TextureHandle depthBuffer,
            TextureHandle depthPyramidTexture,
            TextureHandle waterGBuffer0)
        {
            // 默认Fallback
            HPWaterRefractionOutput output = new HPWaterRefractionOutput
            {
                refractionData = renderGraph.defaultResources.whiteTextureXR
            };
            if (OnGetWaterRefractionParameters == null || hdCamera == null || renderGraph == null)
            {
                return output;
            } 
            // 空值检查（如果条件不满足，直接返回 emptyData）
            if (s_WaterRefractionMaterial == null && defaultResources.shaders.hanPiWaterShader != null)
                s_WaterRefractionMaterial = CoreUtils.CreateEngineMaterial(defaultResources.shaders.hanPiWaterShader);
            if(s_WaterRefractionMaterial == null)
            {
#if UNITY_EDITOR || DEVELOPMENT_BUILD
                Debug.LogWarning("[RenderWaterRefraction] 水体折射Shader或Material无效");
#endif
                return output;
            }           
            // 获取水体折射参数
            var parameters = OnGetWaterRefractionParameters.Invoke();

            // 验证参数有效性
            if (parameters == null || !parameters.IsValid())
            {
#if UNITY_EDITOR || DEVELOPMENT_BUILD
                Debug.LogWarning("[RenderWaterRefraction] 水体折射参数无效");
#endif
                return output;
            }
            // ========================================================================
            // 水体折射
            // 用stencilBuffer判断水面像素，并且输出到refractionBuffer的W
            // 计算完折射后的深度，输出到refractionBuffer的Z
            // ========================================================================
            using (var builder = renderGraph.AddRenderPass<RenderWaterRefractionPassData>(
                "HanPi Water Refraction", out var passData, new ProfilingSampler("HanPi Water Refraction")))
            {
                passData.hdCamera = hdCamera;
                passData.viewCount = hdCamera.viewCount;
                passData.parameters = parameters;

                // 计算 tile 数量（全分辨率）
                int screenWidth = hdCamera.actualWidth;
                int screenHeight = hdCamera.actualHeight;
                const int groupSize = 8;
                passData.tileX = HDUtils.DivRoundUp(screenWidth, groupSize);
                passData.tileY = HDUtils.DivRoundUp(screenHeight, groupSize);

                // 输入纹理（参考 HPWaterVolume.cs 的方式）
                passData.depthBuffer = builder.UseDepthBuffer(depthBuffer, DepthAccess.Read);  // 水面深度（只读）
                passData.stencilBuffer = builder.ReadTexture(depthBuffer);                       // Stencil 纹理（用于手动判断水面）
                passData.depthPyramidTexture = builder.ReadTexture(depthPyramidTexture);       // 场景深度（不含水面）
                passData.waterGBuffer0 = builder.ReadTexture(waterGBuffer0);
                
                //用GetDistortionBufferFormat，让后续的Distortion能够在池子复用此纹理
                passData.WaterRefractionBuffer = builder.UseColorBuffer(renderGraph.CreateTexture(
                    new TextureDesc(Vector2.one, true, true)
                    {
                        colorFormat = Builtin.GetDistortionBufferFormat(),
                        clearBuffer = true,
                        clearColor = Color.clear,
                        name = "Distortion"
                    }), 0);

                builder.SetRenderFunc((RenderWaterRefractionPassData data, RenderGraphContext ctx) =>
                {
                    var cmd = ctx.cmd;

                    if (data.parameters.useRayMarching)
                        s_WaterRefractionMaterial.EnableKeyword("_USE_RAY_MARCHING_ON");
                    else
                        s_WaterRefractionMaterial.DisableKeyword("_USE_RAY_MARCHING_ON");

                    // 绑定深度金字塔 Mip Level Offsets（DrawProcedural 需要使用 SetGlobalBuffer）
                    cmd.SetGlobalBuffer(HDShaderIDs._DepthPyramidMipLevelOffsets,
                        data.hdCamera.depthBufferMipChainInfo.GetOffsetBufferData(m_DepthPyramidMipLevelOffsetsBuffer));

                    cmd.SetGlobalTexture(HDShaderIDs._DepthTexture, data.depthBuffer);
                    cmd.SetGlobalTexture(HDShaderIDs._CameraDepthTexture, data.depthPyramidTexture);
                    cmd.SetGlobalTexture(HPWaterRefractionShaderIDs._HPWaterGBuffer0, data.waterGBuffer0);
                    // Stencil 纹理用于 Shader 中手动判断水面像素                  
                    cmd.SetGlobalTexture(HDShaderIDs._StencilTexture, data.stencilBuffer, RenderTextureSubElement.Stencil);

                    s_WaterRefractionMaterial.SetInt(HPWaterRefractionShaderIDs._Ray_Marching_Sample_Count, data.parameters.rayMarchingSampleCount);

                    // 【DX11 修复】只绑定颜色目标，不绑定深度缓冲区（避免读写冲突）
                    // 使用 Shader 中的手动 Stencil 判断代替硬件 Stencil 测试
                    cmd.SetRenderTarget(data.WaterRefractionBuffer);
                    cmd.DrawProcedural(Matrix4x4.identity, s_WaterRefractionMaterial, 3, MeshTopology.Triangles, 3, 1);
                });

                output.refractionData = passData.WaterRefractionBuffer;

            }
            return output;
        }
    }
}
