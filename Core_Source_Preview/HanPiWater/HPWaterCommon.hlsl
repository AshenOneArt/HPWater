
#ifndef WATER_VOLUMETRICS_READY_INCLUDED
#define WATER_VOLUMETRICS_READY_INCLUDED

StructuredBuffer<int2> _DepthPyramidMipLevelOffsets;
#include "Packages/com.unity.render-pipelines.high-definition/Runtime/HanPiWater/HPWaterGlobalShaderVariable.cs.hlsl"

//逆时针Gather顺序：wzyx
#define HP_GATHER_TEXTURE2D(textureName, samplerName, coord2)                textureName.Gather(samplerName, coord2).wzyx
#define HP_GATHER_RED_TEXTURE2D(textureName, samplerName, coord2)            textureName.GatherRed(samplerName, coord2).wzyx
#define HP_GATHER_GREEN_TEXTURE2D(textureName, samplerName, coord2)          textureName.GatherGreen(samplerName, coord2).wzyx
#define HP_GATHER_BLUE_TEXTURE2D(textureName, samplerName, coord2)           textureName.GatherBlue(samplerName, coord2).wzyx
#define HP_GATHER_ALPHA_TEXTURE2D(textureName, samplerName, coord2)          textureName.GatherAlpha(samplerName, coord2).wzyx

//Debug
static float3 g_drawDebugColor = float3(0.0, 1.0, 0.0);
static bool g_drawDebugColorFlag = false;
void drawDebugColor(float3 color)
{ 
    g_drawDebugColorFlag = true;
    g_drawDebugColor = color;
}

//==============================================================================
//Ray Marching Core
//==============================================================================
#define EXP_FACTOR 12//指数步进因子，用于指数步进计算：焦散光追、水体折射光追
#define CAUSTIC_REFERENCE_DISTANCE 10.0//参考距离，用于自适应指数步进计算：焦散光追
#define REFRACTION_REFERENCE_DISTANCE 20.0//参考距离，用于自适应指数步进计算：水体折射光追
//自适应指数步进计算：根据静态距离计算指数步进因子:
//当距离>referenceDistance时，指数步进因子会逐渐增大,采样点在靠近referenceDistance的地方更密集
//当距离<referenceDistance时，指数步进因子会逐渐减小,采样点趋近线性
#define ADAPTIVE_EXP_FACTOR_STATIC(distance,referenceDistance) (clamp(pow(max(distance, 0.01) * rcp(referenceDistance), 2), 1.01, 32.0))
#define WATER_SAMPLE_COUNT 6//水体光追采样次数

//==============================================================================
// 计算深度模糊Mipmap MipLevel ∈ log2(Depth)
//==============================================================================
#define FORWARD_SCATTER_BLUR_DENSITY_SCALE 10
#define CAUSTIC_SCALING_FACTOR 0.01//焦散基础几何扩散
#define WATER_SCALING_FACTOR   0.2  //水体基础几何扩散
#define FORWARD_SCALING_FACTOR 1.0    //前向散射基础几何扩散
float CalculateHPWaterMipLevel(float depth,float scalingFactor,float scatterDensity,float maxBlurLevel = 4)
{
    // 参数定义：
    // scalingFactor: 基础几何扩散
    // FORWARD_SCATTER_BLUR_DENSITY_SCALE: 散射对模糊的贡献权重 
    // scattering: 输入的散射强度 (0 ~ 1)

    // 核心逻辑：
    // 当 scatterDensity = 0 时，回退到纯物理几何模糊。
    // 当 scatterDensity = 1 时，扩散率变得巨大，水面下去一点点就糊成一团。
    float effectiveScale = scalingFactor + (scatterDensity * _ForwardScatterBlurDensity * FORWARD_SCATTER_BLUR_DENSITY_SCALE);
    float mipLevel = log2(1.0 + depth * effectiveScale);
    
    return clamp(mipLevel, 0, maxBlurLevel);
}

// 安全的标准化函数，避免零向量导致的NaN
float3 safeNormalize(float3 v)
{
    float len = length(v);
    return len > 0.0001 ? v * rcp(max(len, 1e-6)) : float3(0, 1, 0);
}

float2 safeNormalize(float2 v)
{
    float len = length(v);
    return len > 0.0001 ? v * rcp(len) : float2(0, 1);
}

float safeDivide(float a,float b)
{
    return a * rcp(max(b, 1e-8));
}
float2 safeDivide(float2 a,float2 b)
{
    return float2(a.x * rcp(max(b.x, 1e-8)), a.y * rcp(max(b.y, 1e-8)));
}
float3 safeDivide(float3 a,float3 b)
{
    return float3(a.x * rcp(max(b.x, 1e-8)), a.y * rcp(max(b.y, 1e-8)), a.z * rcp(max(b.z, 1e-8)));
}

float SafePow(float base, float exponent)
{
    return pow(max(base, 1e-6), exponent);
}

float4 GetTaaFrameInfo()
{
#if SHADER_TARGET < 45
		return float4(0,0,0,0);
#else
		return _TaaFrameInfo;//x:Jitter,y:FrameIndex,z:FrameCount,w:FrameDeltaTime
#endif
}
//获取三个[0, 1]的随机数
float3 GetRandom3(float3 seed)
{
    float3 p = frac(seed * 0.1031);
    p += dot(p, p.yzx + 33.33);
    return frac((p.xxy + p.yzz) * p.zyx);
}

//生成实心的随机方向,用于模拟前向散射
float3 GenerateSolidRandomDirection(float2 screenUV,float2 screenSize, float time)
{
    // 构造种子：结合 屏幕位置 + 时间
    float3 seed = float3(screenUV * screenSize, time);
    
    // 获取三个 [0, 1] 的随机数
    float3 rand = GetRandom3(seed);
    
    // 映射到 [-1, 1]
    float3 randomVec = rand * 2.0 - 1.0;
    
    // 不归一化，意味着向量长度是随机的 (0 到 1.73 之间)。
    // 自然就形成了“中间密、边缘疏”的实心效果，就像高斯模糊一样。
    
    // 【关键点 2】(可选) 如果觉得随机性不够“聚拢”，可以自乘一次
    // randomVec *= abs(randomVec); // 这会让结果更集中在中心，减少边缘噪点
    
    return randomVec;
}
float GetInterleavedGradientNoise(float2 pixelPos, int frameCount)
{
    // 每一帧给像素坐标加一个巨大的偏移
    // 5.588238 是一个随便选的非整数，防止和像素网格对齐
    pixelPos += (float)(frameCount) * 5.588238;

    const float3 magic = float3(0.06711056, 0.00583715, 52.9829189);
    return frac(magic.z * frac(dot(pixelPos, magic.xy)));
}
// ========================================================
// 生成随机 1D 偏移
// ========================================================
float GenerateRandom1DOffset(float2 screenUV, float2 resolution, float frameCount)
{
    return InterleavedGradientNoise(screenUV * resolution,frameCount);
}
// ========================================================
// 生成圆盘内的随机 2D 偏移（IGN）
// ========================================================
float2 GenerateRandomDiskOffset(float2 screenUV, float2 resolution, float frameCount)
{
    // 生成空间高频噪声 (IGN)
    // 这负责让每个像素的采样点“距离”不同
    float spatialNoise = InterleavedGradientNoise(screenUV * resolution,frameCount);

    // 半径分布 (Radius)
    // 保持 sqrt 以确保圆盘均匀分布
    // 如果您想要高斯分布（中心密边缘疏），可以去掉 sqrt
    float r = sqrt(spatialNoise);

    // 角度分布 (Angle)
    // 黄金角度 ≈ 2.39996323 弧度 (约 137.5 度)
    // 特性：每次旋转这个角度，永远不会重叠，填充效率最高
    float goldenAngle = 2.39996323;
    
    // - frameCount * goldenAngle: 每一帧整体旋转，确保 TAA 历史积累能填满圆。
    // - spatialNoise * 6.28: 加上这个是为了让相邻像素的角度初始值不同，防止整个屏幕看起来在同步旋转。
    float theta = frameCount * goldenAngle + spatialNoise * 6.2831853;

    // 转换为笛卡尔坐标
    float sinTheta, cosTheta;
    sincos(theta, sinTheta, cosTheta);
    
    return float2(cosTheta, sinTheta) * r;
}
//==============================================================================
//Dither,适用于更加静态的完全随机均匀的Noise
//==============================================================================
float R2_dither(float2 samplePositionSS,float frameCount)
{
    float2 coord = samplePositionSS;

	coord += (frameCount * 2)%1000;
	
	float2 alpha = float2(0.75487765, 0.56984026);
	return frac(alpha.x * coord.x + alpha.y * coord.y);
}
// ========================================================
// 生成圆盘内的随机 2D 偏移（R2_dither）
// ========================================================
float2 GenerateRandomDiskOffsetByR2_dither(float2 screenUV, float2 resolution, float frameCount)
{
    // 生成空间高频噪声 (IGN)
    // 这负责让每个像素的采样点“距离”不同
    float spatialNoise = R2_dither(screenUV * resolution,frameCount);

    // 半径分布 (Radius)
    // 保持 sqrt 以确保圆盘均匀分布
    // 如果您想要高斯分布（中心密边缘疏），可以去掉 sqrt
    float r = sqrt(spatialNoise);

    // 角度分布 (Angle)
    // 黄金角度 ≈ 2.39996323 弧度 (约 137.5 度)
    // 特性：每次旋转这个角度，永远不会重叠，填充效率最高
    float goldenAngle = 2.39996323;
    
    // - frameCount * goldenAngle: 每一帧整体旋转，确保 TAA 历史积累能填满圆。
    // - spatialNoise * 6.28: 加上这个是为了让相邻像素的角度初始值不同，防止整个屏幕看起来在同步旋转。
    float theta = frameCount * goldenAngle + spatialNoise * 6.2831853;

    // 转换为笛卡尔坐标
    float sinTheta, cosTheta;
    sincos(theta, sinTheta, cosTheta);
    
    return float2(cosTheta, sinTheta) * r;
}
//==============================================================================
//À-trous降噪边缘权重计算
//==============================================================================
float ComputeEdgeWeight(float centerLum, float sampleLum, float _AtrousLuminanceWeight)
{
    float lumDiff = abs(log2(1.0 + centerLum) - log2(1.0 + sampleLum));
    float strictness = smoothstep(0.0, 0.25, min(centerLum, sampleLum));
    
    return exp2(-lumDiff * _AtrousLuminanceWeight * strictness);
}
//==============================================================================
//ScreenToWorldPosition
//==============================================================================
float3 ScreenToWorldPosition(float2 rayScreenUV,float rawDepth)
{
    // 从屏幕位置重建视图空间坐标
    float2 ndcXY = rayScreenUV * 2.0 - 1.0;
    
#if UNITY_UV_STARTS_AT_TOP
        ndcXY.y = -ndcXY.y;
#endif
    
    // 重建视图空间位置
    float4 viewPos = mul(UNITY_MATRIX_I_P, float4(ndcXY, rawDepth, 1.0));
    viewPos.xyz /= viewPos.w;
    
    // 转换到世界空间
    float4 Result = mul(UNITY_MATRIX_I_V, float4(viewPos.xyz, 1.0));
    return Result.xyz + _WorldSpaceCameraPos.xyz;
}
//==============================================================================
//ScreenToWorldPositionOrthographic
//==============================================================================
float3 ScreenToWorldPositionOrthographic(float2 rayScreenUV,float rawDepth,float4x4 VPMatrixInverse)
{
    // 从屏幕位置重建视图空间坐标
    float2 ndcXY = rayScreenUV * 2.0 - 1.0;

    // 转换到世界空间
    float4 Result = mul(VPMatrixInverse, float4(ndcXY, rawDepth, 1.0));
    return Result.xyz;
}

//==============================================================================
// 从深度重建几何法线 (用于 Fragment Shader，使用 ddx/ddy)
// 输入: worldPos - 当前像素的世界坐标
// 输出: 归一化的世界空间几何法线
//==============================================================================
float3 ReconstructGeomNormalFromPosition(float3 worldPos)
{
    float3 worldPosDdx = ddx(worldPos);
    float3 worldPosDdy = ddy(worldPos);
    return safeNormalize(-cross(worldPosDdx, worldPosDdy));
}

// Blue noise sampling (simplified for Unity)
float BlueNoise(float2 screenPos, float frameCount)
{
    return frac(sin(dot(screenPos + frameCount, float2(12.9898, 78.233))) * 43758.5453);
}

//==============================================================================
// 3D Noise Functions
//==============================================================================

// Hash function for noise generation
float3 hash3(float3 p)
{
    p = float3(dot(p, float3(127.1, 311.7, 74.7)),
               dot(p, float3(269.5, 183.3, 246.1)),
               dot(p, float3(113.5, 271.9, 124.6)));
    
    return -1.0 + 2.0 * frac(sin(p) * 43758.5453123);
}

// Single hash function
float hash(float3 p)
{
    p = frac(p * 0.3183099 + 0.1);
    p *= 17.0;
    return frac(p.x * p.y * p.z * (p.x + p.y + p.z));
}

// Gradient noise (Perlin-like)
float gradientNoise(float3 p)
{
    float3 i = floor(p);
    float3 f = frac(p);
    
    // Smooth interpolation
    float3 u = f * f * (3.0 - 2.0 * f);
    
    // Sample gradients at 8 corners of the cube
    return lerp(lerp(lerp(dot(hash3(i + float3(0, 0, 0)), f - float3(0, 0, 0)),
                         dot(hash3(i + float3(1, 0, 0)), f - float3(1, 0, 0)), u.x),
                    lerp(dot(hash3(i + float3(0, 1, 0)), f - float3(0, 1, 0)),
                         dot(hash3(i + float3(1, 1, 0)), f - float3(1, 1, 0)), u.x), u.y),
               lerp(lerp(dot(hash3(i + float3(0, 0, 1)), f - float3(0, 0, 1)),
                         dot(hash3(i + float3(1, 0, 1)), f - float3(1, 0, 1)), u.x),
                    lerp(dot(hash3(i + float3(0, 1, 1)), f - float3(0, 1, 1)),
                         dot(hash3(i + float3(1, 1, 1)), f - float3(1, 1, 1)), u.x), u.y), u.z);
}

// Value noise (simpler, faster)
float valueNoise(float3 p)
{
    float3 i = floor(p);
    float3 f = frac(p);
    
    // Smooth interpolation
    float3 u = f * f * (3.0 - 2.0 * f);
    
    // Sample values at 8 corners of the cube
    return lerp(lerp(lerp(hash(i + float3(0, 0, 0)),
                         hash(i + float3(1, 0, 0)), u.x),
                    lerp(hash(i + float3(0, 1, 0)),
                         hash(i + float3(1, 1, 0)), u.x), u.y),
               lerp(lerp(hash(i + float3(0, 0, 1)),
                         hash(i + float3(1, 0, 1)), u.x),
                    lerp(hash(i + float3(0, 1, 1)),
                         hash(i + float3(1, 1, 1)), u.x), u.y), u.z);
}

// Fractal Brownian Motion (fBm) for more complex noise
float fBmNoise(float3 p, int octaves, float lacunarity, float gain)
{
    float amplitude = 0.5;
    float frequency = 1.0;
    float value = 0.0;
    float maxValue = 0.0;
    
    for (int i = 0; i < octaves; i++)
    {
        value += gradientNoise(p * frequency) * amplitude;
        maxValue += amplitude;
        amplitude *= gain;
        frequency *= lacunarity;
    }
    
    return value / maxValue;
}

// Main 3D Noise function with customizable intensity and scale
// @param position: 3D world position
// @param scale: Controls the frequency/size of noise features (smaller = larger features)
// @param intensity: Controls the strength/amplitude of the noise
// @param octaves: Number of noise layers (more = more detail, but slower)
// @param lacunarity: Frequency multiplier between octaves (typically 2.0)
// @param gain: Amplitude multiplier between octaves (typically 0.5)
// @param useGradient: true for gradient noise (smoother), false for value noise (faster)
float Noise3D(float3 position, float scale, float intensity, int octaves = 4, float lacunarity = 2.0, float gain = 0.5, bool useGradient = true)
{
    float3 scaledPos = position * scale;
    float noise;
    
    if (octaves > 1)
    {
        // Use fractal Brownian motion for complex noise
        noise = fBmNoise(scaledPos, octaves, lacunarity, gain);
    }
    else
    {
        // Use single octave noise
        if (useGradient)
        {
            noise = gradientNoise(scaledPos);
        }
        else
        {
            noise = valueNoise(scaledPos);
        }
    }
    
    return noise * intensity;
}

// Simplified 3D Noise function (most commonly used)
float Noise3DSimple(float3 position, float scale, float intensity)
{
    return Noise3D(position, scale, intensity, 4, 2.0, 0.5, true);
}

// Turbulence function (absolute value of noise for more chaotic patterns)
float Turbulence3D(float3 position, float scale, float intensity, int octaves = 4)
{
    float3 scaledPos = position * scale;
    float amplitude = intensity;
    float frequency = 1.0;
    float turbulence = 0.0;
    
    for (int i = 0; i < octaves; i++)
    {
        turbulence += abs(gradientNoise(scaledPos * frequency)) * amplitude;
        amplitude *= 0.5;
        frequency *= 2.0;
    }
    
    return turbulence;
}
  


#endif // WATER_VOLUMETRICS_INCLUDED 