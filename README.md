
<h1 align="center">🌊 HPWater Wiki</h1>

<p align="center">
  <img width="250" src="https://github.com/user-attachments/assets/5fc59cbf-b677-48df-acce-34e4b25832e0" style="pointer-events: none;" />
</p>

<p align="center">
  <a href="https://github.com/AshenOneArt/HPWater/wiki/BSDF‐Model"><b>📖 HPWater BSDF 散射光照模型</b></a>
</p>

---
# HPWater

**HP Water Rendering System for Unity HDRP**
*(基于 Unity HDRP 的HP水体渲染系统)*

### 🎮 Controls (Demo) / 操作指南

The demo scene features an **Advanced Camera Controller**. 
Demo 场景内置了 **相机控制器**，操作方式如下：

* <kbd>W</kbd> <kbd>A</kbd> <kbd>S</kbd> <kbd>D</kbd> ── Move Camera / 前后左右移动
* <kbd>Q</kbd> / <kbd>E</kbd> ── Move Up & Down / 垂直升降
* <kbd>Shift</kbd> ── **Sprint (Boost)** / **加速移动**
* <kbd>Tab</kbd> ── Unlock Cursor / 切换鼠标模式
* <kbd>🖱️ Left Click</kbd> ── **Interactive Waves** / **按住左键 拖动交互**
---

## 🇬🇧 English

**Have a question?** [Start a Discussion](../../discussions)

> ⚠️ **IMPORTANT NOTE**
>
> This repository currently acts as a **Source Code Preview**.
>
> **It is NOT a complete Unity Project.** **Do not try to open this repository directly in Unity.**

### 📦 Download & Play (Demo)
If you want to test the interactive water simulation, please download the playable demo from the **[Releases](../../releases)** page.

### 🔍 Source Code Preview
programmers are welcome to explore the core implementation details in the [`HanPiWater`](./Core_Source_Preview/HanPiWater) folder:

* **Rendering Pipeline & GBuffer:** `HanPiWater/GBuffer`
    * **Deep Integration with HDRP RenderGraph:** Manages custom passes for efficient water rendering.
    * **Optimized GBuffer Layout:** Custom 3-MRT packing strategy for efficient storage of water surface data (Normal, Roughness, Scatter Color, Absorption, Foam).

* **Ray-Traced Refraction:** `HanPiWater/Refraction` & `HPWater.shader`
    * **Optional High-Precision Mode:** Ray Marching is **disabled by default** and serves as an optional solution strictly for resolving **refraction artifacts** (e.g., disjointed underwater objects). A high-performance approximation is used otherwise.
    * **Exponential Step Ray Marching:** Implements **Exponential Stepping** for efficient intersection search, balancing performance and precision without heavy Hi-Z traversal overhead.
    * **Thickness-Aware & Jittered:** Features **Thickness Offset** logic to prevent self-intersection and utilizes **IGN (Interleaved Gradient Noise)** to eliminate banding artifacts with minimal samples.

* **Volumetric Lighting:** `HanPiWater/Deferred` & `HPWaterVolumetrics.hlsl`
    * **Decoupled Architecture:** The rendering pipeline is split into a **Low-Res Volumetric Accumulation** pass and a **Full-Res Composite** pass to balance cost and quality.
    * **Sampling Strategy:** Implements **Ray Marching** with **Interleaved Gradient Noise (IGN)** for Monte Carlo integration.
    * **Denoising Pipeline:** Addresses sampling noise using **Temporal Reprojection** based on **Motion Vectors (MV)**, incorporating **Depth Rejection** and **Velocity Weighting** to minimize ghosting artifacts. An **À-trous Wavelet Spatial Filter** is applied for further variance reduction.
    * **Depth-Aware Upsampling:** Uses **Joint Bilateral Upsampling** guided by the full-resolution depth buffer to reconstruct volumetric edges, effectively preventing color bleeding onto foreground objects.
    * **Multi-Light Framework (WIP):** Integrating HDRP's **VBuffer (BigTile/Cluster)** specifically for accelerating volumetric light culling. **Specular lighting** continues to be handled by the standard deferred lighting pass.

* **Interactive Caustics:** `HanPiWater/Caustic`
    * **Native HDRP Integration:** The cascade layout and culling process align perfectly with the **official HDRP shadow workflow**. Reuses the **official Directional Light Shadow Atlas** for depth intersection testing, avoiding redundant depth rendering passes.
    * **Compute Shader Simulation:** Uses **Ray Marching** with **Atomic Operations (InterlockedAdd)** for high-performance photon accumulation.
    * **Dual-Mode Chromatic Dispersion:**
        * **Physical RGB Mode:** Performs spectral ray marching for three distinct wavelengths, writing to **separate caustic buffers** for physically accurate dispersion.
        * **Single-Channel Mode:** Optimized for performance; simulates dispersion during the **sampling phase** using surface normal data to approximate the spectral effect.
    * **Physically-Based Reconstruction:** Utilizes **Joint Bilateral Upsampling** to reconstruct high-fidelity **Absorption & Scattering coefficients** from low-res buffers.
        * **Absorption** determines the energy loss (intensity attenuation).
        * **Scattering** dynamically modulates the texture **Mipmap Level** to simulate physical blurring based on depth and medium density.

* **Fluid Dynamics:** `HanPiWater/FluidDynamics`
    * Implementation of the **Wave Equation** for real-time interactive wave propagation.

### 📄 License
This project is licensed under the **Mozilla Public License 2.0 (MPL 2.0)**.

---

**Have a question?** [Start a Discussion](../../discussions)

## 🇨🇳 中文

> ⚠️ **重要提示**
>
> 本仓库目前仅作为 **核心源码预览 (Source Code Preview)** 使用。
>
> **这不是一个完整的 Unity 工程。** **请勿尝试直接在 Unity 中打开本仓库。**

### 📦 下载与试玩 (Demo)
如果您希望测试水体交互的实际运行效果，请前往 **[Releases (发布页)](../../releases)** 下载最新版本的演示包。

### 🔍 核心源码预览
欢迎开发者在 [`HanPiWater`](./Core_Source_Preview/HanPiWater) 文件夹中查阅以下核心实现的细节：

* **渲染管线与 GBuffer (Rendering Pipeline & GBuffer):** `HanPiWater/GBuffer`
    * **HDRP RenderGraph 深度集成:** 管理自定义的水体渲染 Pass。
    * **优化的 GBuffer 布局:** 自定义 3-MRT 打包策略，高效存储水体表面数据（法线、粗糙度、散射色、吸收系数、泡沫）。

* **光线追踪折射 (Ray-Traced Refraction):** `HanPiWater/Refraction` & `HPWater.shader`
    * **按需开启的高精度模式 (Optional High-Precision Mode):** 光线步进默认为 **关闭状态**。仅推荐在必须解决 **折射伪影**（如水下物体位置严重错位）时开启，常规情况使用高性能近似模拟。
    * **指数步进 (Exponential Stepping):** 采用 **指数步进** 算法进行交点搜索，相比昂贵的 Hi-Z 遍历，在保持高性能的同时提供了足够的精度。
    * **厚度感知与抖动 (Thickness-Aware & Jittered):** 实现了基于 **厚度阈值** 的深度比对逻辑防止自遮挡，并利用 **IGN 随机抖动** 消除低采样下的断层伪影。

* **体积光照 (Volumetric Lighting):** `HanPiWater/Deferred` & `HPWaterVolumetrics.hlsl`
    * **解耦架构 (Decoupled Architecture):** 将管线拆分为 **低分辨率体积累积** 与 **全分辨率合成** 两个阶段，以平衡性能与画质。
    * **采样策略:** 在光线步进中采用 **IGN (Interleaved Gradient Noise)** 进行蒙特卡洛积分。
    * **降噪管线:** 利用 **运动矢量 (Motion Vectors)** 进行 **时间重投影 (Temporal Reprojection)**，并结合 **深度拒绝 (Depth Rejection)** 与 **速度权重** 逻辑以最小化动态残影。随后应用 **À-trous 小波空间滤波** 进一步降低噪点。
    * **深度感知上采样 (Depth-Aware Upsampling):** 采用由全分辨率深度缓冲引导的 **联合双边上采样** 技术，有效重建体积光边缘并防止前景漏光。
    * **多光源框架 (WIP):** 计划集成 HDRP **VBuffer (BigTile/Cluster)** 专门用于优化体积光的剔除与计算。**镜面反射 (Specular)** 依然沿用现有的标准延迟光照 Pass 进行处理。

* **交互式焦散 (Interactive Caustics):** `HanPiWater/Caustic`
    * **原生 HDRP 集成 (Native Integration):** 级联流程与 **官方 HDRP 阴影系统** 完全一致。直接复用 **官方定向光阴影图集 (Shadow Atlas)** 进行深度命中测试，避免了额外的场景深度渲染开销。
    * **Compute Shader 模拟:** 使用 **光线步进** 配合 **原子操作 (InterlockedAdd)** 进行光子累积。
    * **双模式色散渲染 (Dual-Mode Chromatic Dispersion):**
        * **真实物理 RGB 模式:** 在光线步进阶段针对三种不同波长分别计算折射，并写入 **三张独立的纹理**，实现物理正确的色散效果。
        * **高性能单通道模式:** 仅计算一次步进，在 **级联采样阶段** 利用法线数据模拟 RGB 色散，平衡性能与视觉效果。
    * **物理重建与上采样:** 采用 **联合双边上采样** 技术从低分辨率 GBuffer 中重建 **吸收与散射系数**。
        * **吸收系数 (Absorption)** 决定焦散的能量损失（强度衰减）。
        * **散射系数 (Scattering)** 动态调节纹理采样的 **Mipmap 等级**，以模拟基于深度和介质密度的物理模糊效果。

* **流体动力学 (Fluid Dynamics):** `HanPiWater/FluidDynamics`
    * 包含基于 **波动方程 (Wave Equation)** 的实时交互与波传播模拟。

### 📄 开源协议
本项目采用 **Mozilla Public License 2.0 (MPL 2.0)** 协议。
您可以自由使用或修改代码，但针对文件级别的源代码修改必须开源回馈。
