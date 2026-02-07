using System.Runtime.InteropServices;
using UnityEngine.Experimental.Rendering;
using UnityEngine.Experimental.Rendering.RenderGraphModule;
using UnityEngine.Rendering.RendererUtils;

namespace UnityEngine.Rendering.HighDefinition
{
    public partial class HDRenderPipeline
    {
        static class HPWaterGlobalShaderVariableShaderIDs
        {
            public static readonly int _HPWaterGlobalParams = Shader.PropertyToID("HPWaterGlobalParams");
        }

        /// <summary>
        /// 水体全局参数结构体 - 与 HLSL 中的 CBUFFER 对应
        /// </summary>
        [GenerateHLSL(needAccessors = false, generateCBuffer = true)]
        public struct HPWaterGlobalParams
        {
            public float _MaxCrossDistance;
            public float _RefractionStrength;
            public float _IndirectLightStrength;
            public float _MaxRefractionCrossDistance;
            public float _MultiScatterScale;
            public float _CausticDispersionStrength;
            public float _WaterDispersionStrength;
            public float _ForwardScatterBlurDensity;
            public float _PhaseG;
            public float _CausticShadowAlphaClipThreshold;
            public int _Is_Use_RGB_Caustic;
            public float _UnusedHPWaterGlobalParams;
        }

        /// <summary>
        /// 水体全局参数提供回调委托
        /// </summary>
        public delegate HPWaterGlobalParams HPWaterGlobalParamsProvider();

        /// <summary>
        /// 水体全局参数提供者事件，在需要水体全局参数时触发
        /// </summary>
        public static event HPWaterGlobalParamsProvider OnGetHPWaterGlobalParams;

        /// <summary>
        /// 获取水体全局参数（带默认值）
        /// </summary>
        static HPWaterGlobalParams GetHPWaterGlobalParams()
        {
            if (OnGetHPWaterGlobalParams != null)
            {
                return OnGetHPWaterGlobalParams.Invoke();
            }

            // 返回默认参数
            return new HPWaterGlobalParams
            {
                _MaxCrossDistance = 100.0f,
                _RefractionStrength = 1.0f,
                _IndirectLightStrength = 1.0f,
                _MaxRefractionCrossDistance = 20.0f,
                _MultiScatterScale = 10,
                _CausticDispersionStrength = 0.1f,
                _WaterDispersionStrength = 0.1f,
                _ForwardScatterBlurDensity = 0.5f,
                _PhaseG = 0.80f,
                _CausticShadowAlphaClipThreshold = 0.8f,
                _Is_Use_RGB_Caustic = -1,
                _UnusedHPWaterGlobalParams = 0.0f
            };
        }

        /// <summary>
        /// 水面 GBuffer 渲染 PassData
        /// </summary>
        class HPWaterGlobalShaderVariablePassData
        {
            public HPWaterGlobalParams globalParams;
        }

        void PushHPWaterGlobalShaderVariable(RenderGraph renderGraph,CausticPackage causticToDeferredData)
        {

            using (var builder = renderGraph.AddRenderPass<HPWaterGlobalShaderVariablePassData>(
                "HanPi Water Global Shader Variable", out var passData, new ProfilingSampler("HanPi Water Global Shader Variable")))
            {
                passData.globalParams = GetHPWaterGlobalParams();
                // 如果 causticToDeferredData 为 null，创建一个包含默认白色纹理的对象（防御性检查）
                causticToDeferredData = IsCausticDataValid(causticToDeferredData, renderGraph);
                // 获取焦散模式
                int causticMode = causticToDeferredData.causticEnabled ? (causticToDeferredData.useRGBCaustic ? 1 : 0) : -1;
                passData.globalParams._Is_Use_RGB_Caustic = causticMode;

                builder.SetRenderFunc((HPWaterGlobalShaderVariablePassData data, RenderGraphContext ctx) =>
                {
                    // 推送水体全局参数到 ConstantBuffer
                    ConstantBuffer.PushGlobal(ctx.cmd, data.globalParams, HPWaterGlobalShaderVariableShaderIDs._HPWaterGlobalParams);
                });
            }
        }
    }
}
