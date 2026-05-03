# INT8 CIM SoC — Optimization Roadmap

> 基于项目现状分析 + 领域前沿调研 (2026.05)
> 相关论文/项目见文末 References

---

## 项目当前状态

| 模块 | 状态 | 瓶颈 |
|------|------|------|
| CIM Tile (16×16 MAC) | ✅ 完成 | 组合逻辑延迟 → 60MHz 上限 |
| CIM Accel Core | ✅ 完成 | pipeline 已多级 |
| AXI DMA 数据通路 | ✅ 完成 | DMA 503ms/img, MMIO 1690ms/img → speedup 3.4× |
| LeNet-5 e2e benchmark | ✅ 完成 | accuracy 99.50% @200 images |
| 下一步瓶颈 | ❓ 待 profile | DMA→compute 延迟分解, pipeline 利用率 |

# 1. 性能优化（短期 — 1~2 月）

## 1.1 DMA 性能深度分析（最高优先级）

**现状：** DMA 已跑通，end-to-end benchmark 完成：
- LeNet-5 200-image @60MHz: DMA 503.65 ms/img (1.99 fps), MMIO 1690.54 ms/img (0.59 fps)
- Speedup 3.4×，Accuracy 99.50%
- benchmark CSV: `sw/benchmark_e2e_60mhz_dma.csv`, `sw/benchmark_e2e_60mhz_mmio.csv`

**待做：**
- **Latency 分解：** 用 performance counter 拆解每层 weight_load / compute / result_read 占比
- **DMA burst 分析：** 当前 DMA 是否有 fragmented transfer？burst size 是否最优？
- **Ping-pong buffer：** compute 和 DMA load 重叠 → 理论上可接近 pure compute latency

**验证标准：** 完成 latency breakdown report，定位下一步优化热点

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
| ✅ DONE | DMA S2MM read_output (P0) | read_out 257→~1ms | 中 | 2d | 2026-05-03 |
| 🔴 P0 | load_x 优化 (减少 MMIO 同步 + 预打包) | ~15ms (22%) | 低 | 3d |
| 🔴 P0 | Pipeline overlap (DMA↔Compute 乒乓) | 30-50%+ (目标 ~125ms/img) | 中 | 2w |
| 🔴 P0 | DMA latency 分解 + 底层 profile | 定位热点 | 低 | 1w | ✅ 已完成 (2026-05-03) |
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

- **CIMple** (arxiv 2026.04): Standard-cell SRAM CIM with LUT-based softmax for attention
  — 首次将 CIM 扩展到 Transformer attention
- **Hardware-Software Co-Design for Transformer with CIM** (arxiv 2025.02)
  — Transformer 推理的软硬件协同设计方法论
- **TinyMOA** ([GitHub](https://github.com/EzraWolf/TinyMOA)): RISC-V + SRAM CIM integrated chip
  — 与 PicoRV32 路线高度相关
- **DUB Sparsity for Crossbars** ([GitHub](https://github.com/TimurIbrayev/DUB_Sparsity_for_XBars))
  — 结构化稀疏在 CIM crossbar 上的应用
- **PSumSim** ([GitHub](https://github.com/Joschua-Conrad/PSumSim))
  — 模拟 MVM 中 partial-sum 量化误差的工具
- **BUAA CIM Literature List** ([GitHub](https://github.com/BUAA-CI-LAB/Literatures-on-SRAM-based-CIM))
  — SRAM CIM 领域论文汇总
- **CONV-SRAM** (本项目参考论文): Energy-Efficient SRAM With In-Memory Dot-Product for Low-Power CNN
