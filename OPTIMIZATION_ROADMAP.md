# INT8 CIM SoC — Optimization Roadmap

> 基于项目现状分析 + 领域前沿调研 (2026.05)
> 相关论文/项目见文末 References

---

## 2025 CIM 领域文献调研 (2026-05-04)

基于 [BUAA CIM Literature List](https://github.com/BUAA-CI-LAB/Literatures-on-SRAM-based-CIM) 的 2025 年最新论文分析：

### 2025 年 CIM 领域主要趋势

| 趋势 | 代表工作 | 与我们的相关性 |
|------|----------|---------------|
| **稀疏计算** | ISSCC 14.4 (51.6 TFLOPS/W), CICC 2025 (zero weight skipping), TACO Shift-CIM | 我们的 roadmap 1.2 稀疏权重支持方向正确 |
| **混合精度** | Nature 2025 (memristor+SRAM), LSSC 2025 (segmented precision), ASPDAC 2025 (layer-wise mixed) | 验证了我们 INT4/8 混合精度方向 |
| **Transformer/LLM 加速** | DAC 2025 (ViT+CIM), SHMT (SRAM+HBM), JSSC 2025 (LLM outlier-aware) | CIMple + Transformer attention 方向有强学术支撑 |
| **数字 CIM 设计自动化** | CIMFlow (DAC), SEGA-DCIM (DATE), DAMIL-DCIM (DATE) | 我们的 CIM 编译器计划符合行业趋势 |
| **误差弹性** | ER-DCIM (HPCA), MEJ 2025 (PVT-insensitive) | 验证了误差建模方向 |
| **混合存储架构** | JSSC 2025 (SRAM/ROM hybrid, >95% weight loading 减少), SHMT (SRAM+HBM) | 中长期可探索方向 |

### 关键发现：我们的独特性

**No 2025 paper explicitly addresses** im2col, double buffering, DMA pipeline overlap, or ping-pong buffering in titles. CIM 论文集中在 macro/circuit 层级创新，而**软件侧的数据搬运优化（setup、load_x、im2col）在学术文献中很少讨论**——这正是我们当前 66% 延迟瓶颈所在。我们的优化方向（AXI DMA 双向数据通路 + Python 侧优化）在工程上具有差异化价值。

**数据搬运瓶颈的间接验证：** JSSC 2025 的 Hybrid SRAM/ROM CIM 架构提到"reducing >95% weight data loading from DRAM"——说明即使是最先进的 CIM 芯片，weight loading 也是关键瓶颈。我们在 FPGA 上通过 DMA 优化 weight loading 的方向是正确的。

---

## 项目当前状态

| 模块 | 状态 | 瓶颈 |
|------|------|------|
| CIM Tile (16×16 MAC) | ✅ 完成 | 组合逻辑延迟 → 60MHz 上限 |
| CIM Accel Core | ✅ 完成 | pipeline 已多级 |
| AXI DMA 数据通路 | ✅ 完成 | MM2S + S2MM direct register mode, P0 完成 |
| LeNet-5 e2e benchmark | ✅ 完成 | accuracy 99.50% @200 images |
| 软件侧优化 (im2col + predict_batch + ndarray) | ✅ 完成 | 128.4→56.2ms/img (2.3×) |

### LeNet-5 Latency Breakdown (2026-05-05, k_pack 优化后)

| Phase | ms/img | % |
|-------|--------|---|
| load_x (DMA input) | 14.95 | 36.9% |
| read_out (DMA S2MM) | 12.04 | 29.8% |
| compute (hardware) | 6.74 | 16.6% |
| (other) | 3.32 | 8.2% |
| pool (vectorized) | 1.23 | 3.0% |
| im2col (vectorized) | 1.17 | 2.9% |
| pack (pre-packing) | 0.55 | 1.4% |
| setup (amortized) | 0.41 | 1.0% |
| final (argmax) | 0.05 | 0.1% |
| **TOTAL** | **40.5** | **100%** |

优化历程：
- MMIO path: 1690.54 ms/img (0.59 fps)
- DMA (C3 MM2S only, P0 read_out via MMIO): 503.65 ms/img (1.99 fps), speedup 3.4×
- DMA (C3 MM2S + P0 S2MM direct reg mode): 128.4 ms/img (7.8 fps), speedup 13.2× vs MMIO
- read_out: 257ms → 19.65ms (**13× faster**)
- SW v1 (im2col + predict_batch + maxpool): 128.4 → 73.5 ms/img (13.6 fps), speedup 1.75×
- SW v2 (read_output ndarray + vectorized unpack): 73.5 → 56.2 ms/img (17.8 fps), speedup 1.3×
- **RTL k_pack (MAX_IN_DIM 784→1024, MAX_OUT_DIM 128→256): 56.2 → 40.5 ms/img (24.7 fps), speedup 1.39×**
- **MVM 调用数: 44 → 29 (-34%), DMA overhead 同比例减少**
- **累计 vs MMIO: 41.7×**

# 1. 性能优化（短期 — 1~2 月）

## 1.1 当前瓶颈优化

**已解决 — P0 S2MM (2026-05-03/04):**
- ✅ RTL: `cim_axi_stream_source.sv` — BRAM 2-cycle latency fix, tlast off-by-one, done sticky, is_last_word sticky
- ✅ SW: direct register mode bypass PYNQ _SDMAChannel (MM2S + S2MM), double-buffer
- ✅ read_out 串行 MMIO (257ms) → S2MM DMA (19.65ms), 13× speedup
- ✅ 端到端: 503ms → 128ms/img, 3.9× speedup vs pre-P0 DMA

**已解决 — P1 软件侧三优化 (2026-05-04, 代码完成, 2026-05-05 上板验证 ✅):**

1. **im2col 向量化:** 用 `np.lib.stride_tricks.as_strided` 替换 Python 嵌套循环
   - 方法: 构建 5D 视图 (C, out_h, out_w, K_h, K_w) → transpose → copy → reshape
   - **实测: 20.6ms → 1.2ms (17×)** ✅
2. **setup 优化 (layer-wise batching):** 新增 `CIMModel.predict_batch()` 方法
   - 方法: 逐层处理全部图像，每层 weight/bias 只加载一次
   - **实测: 41.0ms → 0.2ms amortized (195×)** ✅
3. **load_x 优化 (预打包):** Conv 输入列用 numpy reshape 批量预打包
   - 方法: `(col_len, n_pixels)` → pad → reshape/transpose → `(n_batches, k_pack*col_len)` 一次生成
   - 实测: DMA 次数不变 (44/img), 但消除了逐列 Python 分配开销

**附加优化 (2026-05-05):**
4. **maxpool2d 向量化:** as_strided 5D 视图 + `.max(axis=(3,4))` 替代 Python 三层循环 — 实测: 1.3ms
5. **read_output → ndarray + 向量化 unpack** (commit 139af9f):
   - `_read_output_dma/mmio` 返回 numpy int8 数组而非 Python list
   - Conv 输出解包从逐像素 Python for 循环改为 `reshape(batch_size, C_out).T` 单次 numpy 赋值
   - **实测: "other" 19.1→4.9ms (-14.2ms), 总延迟 73.5→56.2ms (-24%)**
6. **Profiler 修复 v2:** 消除 double-counting，新增 pack_ms / pool_ms / final_ms 追踪

### 2026-05-05 上板实测结果 (200 images, DMA + batch)

| Phase | 原始 (DMA) | SW v1 | SW v2 (final) | 累计改善 |
|-------|-----------|-------|---------------|---------|
| im2col_ms | 20.58 | 1.21 | 1.18 | **-94% (17×)** |
| pack_ms | — | 0.57 | 0.55 | — |
| setup_ms | 41.05 | 0.21 | 0.21 | **-99.5% (195×)** |
| load_x_ms | 23.01 | 23.92 | 22.69 | ≈ |
| compute_ms | 7.17 | 7.20 | 6.98 | ≈ |
| read_out_ms | 19.65 | 19.94 | 18.32 | ≈ |
| pool_ms | — | 1.27 | 1.24 | 向量化 |
| final_ms | — | 0.08 | 0.05 | — |
| (other) | ~16 | 19.06 | 4.93 | **-69%** |
| **TOTAL** | **128.4** | **73.5** | **56.2** | **-56% (2.3×)** |

**FPS 演进: 0.59 (MMIO) → 7.8 (DMA) → 13.6 (SW v1) → 17.8 (SW v2), 累计 30× vs MMIO**
**Accuracy: 199/200 (99.5%) 全程不变**

使用方式: `python scripts/benchmark_e2e.py --use-dma --batch --n_images 200`

### 当前瓶颈分析 (40.5 ms/img)

| Phase | ms | % | 优化潜力 |
|-------|-----|-----|------|
| load_x_ms | 14.95 | 36.9% | DMA 与 compute 重叠 (乒乓) |
| read_out_ms | 12.04 | 29.8% | S2MM 与 compute 重叠 |
| compute_ms | 6.74 | 16.6% | 硬件已固定 (60MHz) |
| (other) | 3.32 | 8.2% | 残余 Python overhead / 系统抖动 |
| pool_ms | 1.23 | 3.0% | 已优化 |
| im2col_ms | 1.17 | 2.9% | 已优化 |
| pack_ms | 0.55 | 1.4% | 可忽略 |
| setup_ms | 0.41 | 1.0% | 已优化 |

**下一阶段目标: Pipeline overlap (DMA↔Compute 乒乓) → ~25-30 ms/img (33-40 fps)**

### 已解决 — RTL k_pack 扩展 (2026-05-05, 上板验证 ✅)

**方法:** 将 `MAX_IN_DIM` 784→1024, `MAX_OUT_DIM` 128→256，扩大 block-diagonal weight packing 容量。
- Conv1 k_pack: 21 → 40, MVM 28 → 15 (-46%)
- Conv2 k_pack: 5 → 6, MVM 13 → 11 (-15%)
- 总 MVM 调用数: 44 → 29 (-34%), DMA overhead 同比例减少
- 合成结果: BRAM 70/140 (50%), WNS +1.336ns (clean)
- **实测: 56.2 → 40.5 ms/img (24.7 fps), speedup 1.39×, accuracy 199/200 不变**
- **累计 vs MMIO: 41.7×**

## 1.2 Pipeline 深度优化

**现状：** 已有 weight load → compute → store 三级流水

**方向：**
- **双缓冲 weight SRAM：** 一边计算当前层，一边 DMA 加载下一层权重
- **input/output buffer ping-pong：** 消除层间等待
- **Performance counter 分析：** 量化每一层的 stall 原因

**预期收益：** 多层网络推理 latency 再降 30-50%

## 1.3 时钟频率提升

**现状：** 60MHz（关键路径：w_tile_reg → DSP48 → CARRY4 → tile_psum_reg）

**方向：**
- 评估流水线插入点：在 tile 输出加一级寄存器
- KV260 目标 >100MHz（更快的 FPGA 逻辑）
- 重写 critical path 为两拍组合逻辑

**预期收益：** PYNQ-Z2 提升到 80-100MHz (+30-60%)

---

# 2. 模型支持扩展（中期 — 2~4 月）

## 2.1 LeNet-5 完整验证

**现状：** 有 im2col + quantize 代码，但未完成完整端到端 board 验证

**TODO：**
1. 量化精度验证：golden_model vs CIM 硬件输出 bit-accurate 对比
2. 噪容限分析：多次推理结果一致性
3. 精度-速度 trade-off 表格

## 2.2 更大规模网络支持

**现状约束：** MAX_IN_DIM=784, MAX_OUT_DIM=128（PYNQ-Z2 BRAM 限制）

**方向：**
- **KV260 专属配置：** 利用更多 BRAM，支持 MAX_IN_DIM=4096+
- **权重分片加载：** 超标层分多次加载权重，消除维度硬上限
- **MobileNetV2 CIM mapping：** Depthwise conv 的 CIM 映射策略（特殊性：每 channel 独立）

## 2.3 Transformer Attention 支持

**相关研究：** CIMple (2026.04) — 用 LUT 实现 split softmax，CIM 加速 attention

**方向：**
- **Softmax 硬件化：** LUT-based softmax（INT8 输入对应有限 softmax 值）
- **Q/K/V projection 复用现有 MVM：** 三个投影矩阵可映射到三次 MVM 调用
- **目标模型：** MobileBERT / TinyBERT (<15M 参数) → 纯 FPGA edge 推理

## 2.4 稀疏计算支持

**相关研究：** DUB_Sparsity_for_XBars

**方向：**
- **结构化稀疏（2:4/N:M）：** prune → 只加载非零权重 → 对应输入选中
- **权重压缩传输：** DMA 传输量 = 密度 × original size
- **零值跳过 FSM：** skip zero-weight MAC columns

**预期收益：** 剪枝 50% 权重 → DMA latency 减半 → 总 latency 再降 30-40%

---

# 3. 精度与鲁棒性（中期）

## 3.1 混合精度支持

**现状：** 纯 INT8 量化 + INT32 累加

**方向：**
- **INT4/INT8 混合：** 第一层 INT8（敏感），中间层 INT4（不敏感）
- **FP16 累加器：** 替换 INT32 psum，减少 overflow 风险
- **per-channel quantization：** 替代全局 scale，提升精度

**验证标准：** INT4/8 混合 vs 纯 INT8，MNIST accuracy 下降 < 0.5%

## 3.2 模拟误差建模与补偿

**相关研究：** PSumSim — partial-sum quantization simulator

**方向：**
- 建立 CIM tile 的 bit-level 误差模型（工艺偏差 → MAC 误差）
- 训练时注入噪声（quantization-aware training + noise injection）
- 运行时 calibration（per-layer scale 动态调整）

## 3.3 Hardware-Aware Quantization

**现状：** `model_zoo.py` 有量化流程，但未与硬件特性绑定

**方向：**
- **量化感知训练 (QAT)：** 在训练时模拟 CIM tile 的量化行为
- **自动 calibration 脚本：** 一键 `quantize → golden → CIM → compare`
- **Pareto frontier 可视化：** accuracy vs latency vs energy

---

# 4. PicoRV32 自主推理（中期）

## 4.1 FW 完善

**现状：** `picorv32/fw/` 有基本固件框架

**方向：**
- 完整推理控制流程：load model → load input → run layers → output results
- UART 命令协议：PC 端发指令，RISC-V 执行后回传结果
- 与 Python driver 对标的纯 C 实现

## 4.2 性能对比

**验证标准：**
- PicoRV32 vs ARM PS：inference latency, energy, resource usage 对比

---

# 5. 工具链与自动化（持续）

## 5.1 CIM 编译器

**目标：** PyTorch model → CIM mapping → bitstream 的自动化流程

**Pipeline：**
```
PyTorch model
  → model_zoo.py (train + quantize)
  → cim_compiler.py (layer → CIM CSR sequence mapping)
  → cim_driver.py (on-board execution)
  → result collect + compare
```

## 5.2 CI/CD Pipeline

```yaml
# 每次 push 自动运行
1. RTL Lint (verilator)        # < 30s
2. Unit TB regression          # < 3min (cim_tile + cim_accel_core)
3. E2E MNIST simulation        # < 10min
4. Golden model cross-check    # < 1min
```

## 5.3 性能分析仪表板

- 每个 benchmark run 自动生成：layer latency breakdown, energy estimate, accuracy
- 与之前版本对比的趋势图
- 一键 `make report` 输出 markdown 报告

---

# 6. 长期探索方向

## 6.1 Multi-Tile Scaling

**适合 KV260：** 多 2-4 个 tile 并行计算不同 output channel 段
- 需要 crossbar 互联或广播 input
- weight SRAM 独立 → 总带宽线性增长

## 6.2 CIM + CNN 全流水

- **行缓冲架构：** 流式处理图像行，无需存储完整 feature map
- **im2col 硬件化：** 取消软件 im2col，直接 streaming 卷积 → CIM
- 目标：视频流实时推理（30fps）

## 6.3 跨平台

- **更高端 FPGA：** Alveo U200/U250 → 更大模型（ResNet-18?）
- **ASIC 可行性研究：** 估算面积/功耗/频率

---

# 优先级总览

| 优先级 | 方向 | 预期收益 | 难度 | 时间 |
|--------|------|----------|------|------|
| ✅ DONE | DMA S2MM read_output (P0) — direct reg mode, bypass PYNQ recvchannel, double-buffer | read_out 257→19.65ms (13×) | 中 | 2d | 2026-05-04 |
| ✅ DONE | DMA latency 分解 + 底层 profile | 定位热点: setup 41ms, load_x 23ms, im2col 21ms | 低 | 1w | 2026-05-04 |
| ✅ DONE | 软件侧全优化 (im2col + predict_batch + maxpool + ndarray unpack) | 128.4→56.2ms/img (2.3×, 17.8 fps) | 低 | 2d | 2026-05-05 |
| ✅ DONE | RTL k_pack 扩展 (MAX_IN_DIM 784→1024, MAX_OUT_DIM 128→256) | MVM 44→29 (-34%), 实测 40.5ms/img (24.7 fps, 1.39×) | 低 | 1d | 2026-05-05 |
| 🔴 P0 | Pipeline overlap (DMA↔Compute 乒乓) | 目标 ~30-40ms/img (25-33 fps) | 中 | 2w |
| 🟡 P1 | CIM 编译器 (PyTorch→CIM) | 用研效率 | 高 | 4w |
| 🟡 P1 | 稀疏权重支持 | 30-40% speedup | 高 | 4w |
| 🟢 P2 | 时钟提升 (80-100MHz) | 30-60% throughput | 低 | 2w |
| 🟢 P2 | PicoRV32 自主推理 | 独立模式 | 中 | 3w |
| 🟢 P2 | Transformer Attention | 新颖性 | 高 | 6w |
| 🔵 P3 | Mixed precision (INT4/8) | 精度/速度 tradeoff | 中 | 4w |
| 🔵 P3 | Multi-tile scaling (KV260) | 线性扩展 | 高 | 8w |
| 🔵 P3 | 误差建模与补偿 | 可靠性 | 高 | 6w |

---

# References

## 领域前沿论文 (2025-2026)

### Macro/Circuit 层级
- **ISSCC 2025 14.4** "51.6 TFLOPS/W Full-Datapath CIM Macro Approaching Sparsity Bound" — 稀疏约束下的全数据路径 CIM
- **ISSCC 2025 14.5** "192.3 TFLOPS/W Accurate/Approximate Dual-Mode-Transpose Digital 6T-SRAM CIM" — 支持浮点训练+推理
- **CICC 2025** "20.9-137.2 TOPS/W Output-Stationary CIM with Dynamic Look-ahead Zero Weight Skipping" — 零权重跳过
- **Nature 2025** "Mixed-precision memristor and SRAM CIM AI processor" — 混合存储介质的 CIM 处理器
- **JSSC 2025** "109.3-249.5 TFLOPS/W Outlier-Aware Floating-Point SRAM CIM for LLMs" — 面向 LLM 的浮点 CIM

### 架构层级
- **JSSC 2025** "Hybrid SRAM/ROM CIM for High Task-Level Energy Efficiency in Transformer" — 混合存储减少 >95% weight loading
- **DAC 2025** "Efficient Edge ViT Accelerator with Decoupled Chunk Attention and Hybrid CIM" — ViT + CIM
- **TCAS-I 2025** "FlexDCIM: 400 MHz 249.1 TOPS/W Flexible Digital CIM for CNN" — 数字 CIM 高频设计
- **TACO 2025** "Shift-CIM: In-SRAM Alignment for General-Purpose Bit-level Sparsity" — 比特级稀疏
- **HPCA 2025** "ER-DCIM: Error-Resilient Digital CIM with Run-Time MAC-Cell Error Correction" — 误差纠正

### 软件/工具链
- **CIMFlow** (DAC 2025): 数字 CIM 架构的系统化设计评估框架
- **SEGA-DCIM** (DATE 2025): 设计空间探索引导的自动数字 CIM 编译器（支持多精度）
- **DAMIL-DCIM** (DATE 2025): 数据流感知的数字 CIM 布局综合框架

### 直接相关 (本项目)
- **CIMple** (arxiv 2026.04): Standard-cell SRAM CIM with LUT-based softmax for attention
  — 首次将 CIM 扩展到 Transformer attention，LUT-based softmax 可借鉴
- **Hardware-Software Co-Design for Transformer with CIM** (arxiv 2025.02)
  — Transformer 推理的软硬件协同设计方法论
- **TinyMOA** ([GitHub](https://github.com/EzraWolf/TinyMOA)): RISC-V + SRAM CIM integrated chip
  — 与 PicoRV32 路线高度相关
- **DUB Sparsity for Crossbars** ([GitHub](https://github.com/TimurIbrayev/DUB_Sparsity_for_XBars))
  — 结构化稀疏在 CIM crossbar 上的应用
- **PSumSim** ([GitHub](https://github.com/Joschua-Conrad/PSumSim))
  — 模拟 MVM 中 partial-sum 量化误差的工具
- **BUAA CIM Literature List** ([GitHub](https://github.com/BUAA-CI-LAB/Literatures-on-SRAM-based-CIM))
  — SRAM CIM 领域论文汇总（2025.05 更新）
- **CONV-SRAM** (本项目参考论文): Energy-Efficient SRAM With In-Memory Dot-Product for Low-Power CNN
