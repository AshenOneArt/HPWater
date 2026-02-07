using System;

namespace UnityEngine.Rendering.HighDefinition
{
    /// <summary>
    /// 水体渲染回调管理器
    /// 允许外部模块（HanPi.WaterSystem）控制 HDRP 渲染行为
    /// </summary>
    public static class HPWaterRenderCallbacks
    {
        /// <summary>
        /// 返回是否应该跳过 RenderForwardTransparent
        /// 返回 true 表示跳过，false 表示正常渲染
        /// </summary> 
        public static Func<bool> ShouldSkipForwardTransparent;

        /// <summary>
        /// 返回是否应该跳过 RenderForwardTransparentBehindWater
        /// 返回 true 表示跳过，false 表示正常渲染
        /// </summary> 
        public static Func<bool> ShouldRenderForwardTransparentBehindWater;

        /// <summary>
        /// 返回是否应该跳过 TransparentSSR 的 FrameSettings 检查
        /// 返回 true 表示跳过检查（即不要求 FrameSettingsField.TransparentSSR 启用）
        /// </summary>
        public static Func<bool> ShouldBypassTransparentSSRFrameSettings;

        /// <summary>
        /// 返回水层掩码
        /// </summary>
        public static Func<LayerMask> GetWaterLayerMask;

        /// <summary>
        /// 检查是否应该跳过 ForwardTransparent 渲染
        /// </summary>
        internal static bool CheckSkipForwardTransparent()
        {
            return ShouldSkipForwardTransparent?.Invoke() ?? false;
        }

        /// <summary>
        /// 检查是否应该跳过 RenderForwardTransparentBehindWater 渲染
        /// </summary>
        internal static bool CheckShouldRenderForwardTransparentBehindWater()
        {
            return ShouldRenderForwardTransparentBehindWater?.Invoke() ?? false;
        }

        /// <summary>
        /// 检查是否应该绕过 TransparentSSR 的 FrameSettings 检查
        /// </summary>
        internal static bool CheckBypassTransparentSSRFrameSettings()
        {
            return ShouldBypassTransparentSSRFrameSettings?.Invoke() ?? false;
        }

        /// <summary>
        /// 获取水层掩码
        /// </summary>
        internal static LayerMask CheckGetWaterLayerMask()
        {
            return GetWaterLayerMask?.Invoke() ?? 1<<4;
        }

        /// <summary>
        /// 清除所有回调（用于清理）
        /// </summary>
        public static void ClearCallbacks()
        {
            ShouldSkipForwardTransparent = null;
            ShouldBypassTransparentSSRFrameSettings = null;
        }
    }
}

