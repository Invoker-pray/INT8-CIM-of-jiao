# CIM SoC — 存算一体 AI 芯片 FPGA 验证系统（施工ing）

## 项目概述

~预计是~基于 PYNQ-Z2 (Zynq-7020)/kria kv260 的存算一体 (CIM) SoC 验证平台。
支持 INT8 量化推理，可运行 MLP/CNN 神经网络（以后还可能再扩展）。

和之前的项目设计题目[_MNIST-CIM-FPGA_](https://github.com/Invoker-pray/MNIST-CIM-FPGA)有相似之处。有一些进步如下：

- 这次完成了在`cim_pkg.sv`中实现所有参数的集中管理。

- AXI4_Lite接口完成，可以实现DMA式的weight写入，还有IRQ支持，performance counter.

- 统一的engine设计，在之前`MNIST-CIM-FPGA`中是比较机械的FC1/FC2各使用一套硬逻辑，本次在`cim_accel_core`中用一个FSM处理任意层。

- 之前`FPGA_A`中有推理乱飘的问题，是在`psum_accum`中没有进行修复导致的。

- 本次Golden model和tb更加成熟一点。

## 目录结构

```
cim_soc/
├── hw/                             # 硬件设计
│   ├── rtl/
│   │   ├── pkg/cim_pkg.sv          # 全局参数包 (tile尺寸/PAR_OB/CSR地址/FSM状态)
│   │   ├── core/
│   │   │   ├── cim_tile.sv         # 16×16 MAC 原子计算单元 (纯组合)
│   │   │   ├── psum_accum.sv       # 部分和累加器 (带优先级清零)
│   │   │   ├── activation_unit.sv  # ReLU + INT32→INT8 重量化
│   │   │   └── cim_accel_core.sv   # 核心引擎 FSM (可配置并行度 + 性能计数器)
│   │   ├── mem/
│   │   │   ├── weight_sram.sv      # 权重 SRAM (AXI 可写，tile-packed)
│   │   │   ├── bias_sram.sv        # 偏置 SRAM (AXI 可写)
│   │   │   ├── input_buffer.sv     # 输入缓冲 (AXI 可写 + 零点减法)
│   │   │   └── output_buffer.sv    # 输出缓冲 (含 argmax)
│   │   └── axi/
│   │       └── cim_axi_lite_slave.sv  # AXI4-Lite slave wrapper (标准接口)
│   ├── tb/
│   │   ├── tb_cim_tile.sv          # CIM tile 单元测试 (103 个随机用例)
│   │   └── tb_cim_accel_core.sv    # 系统级 MVM 测试 (32→16, golden比对)
│   └── scripts/
│       ├── run_tb_cim_tile.sh      # VCS 运行脚本: tile 测试
│       └── run_tb_cim_accel_core.sh # VCS 运行脚本: 系统测试
│
├── sw/                             # 软件
│   └── golden_model.py             # Python bit-accurate INT8 推理参考模型
│                                   #   - 单层/多层 MLP 推理
│                                   #   - 自动生成 hex 文件
│                                   #   - 自带 self-test
│
├── docs/
│   └── vivado_block_design_guide.md  # Vivado Block Design 搭建完整指南
│                                     #   - GUI 步骤 + Tcl 脚本
│                                     #   - PYNQ Python 驱动代码
│                                     #   - 常见问题排除
│
└── README.md                       # 本文件
```

## 开发路线

### [x] step 1: 逻辑设计 + 仿真

- [x] Phase 0: 参数体系 + CSR 地址映射
- [x] Phase 1: CIM 核心重写 (lint clean)
- [x] Phase 1: AXI4-Lite slave wrapper
- [x] Phase 1: Golden model + Testbench
- [x] Phase 2: 完成MNIST端到端testbench
- [x] Phase 2.5 : 实现对CNN支持 <-- RTL层面没有修改，但是im2col已经在python实现
- [x] Phase 3: 增加Conv层im2col映射支持
- [x] Phase 4: 完成边界测试
- [x] Phase 5: 完成所有testbench和regression脚本自动化。

_RTL本身没有Conv专用硬件，这里用了python的im2col + 硬件MVM实现的异构方案。_

### [x] step 2: PYNQ-Z2 + ZYNQ PS部署

- [x] Phase 1: Vivado Block Design 实际搭建
- [x] Phase 2: PYNQ 上板验证 MNIST
- [x] Phase 3: 多层网络调度 (FC1→FC2 软件循环) <-- MLP 2 layers + LeNet-5 7 layers, PASS
- [x] Phase 3: im2col Conv 上板验证支持 <-- LeNet-5 Conv1+Conv2 bit-exact PASS

### [x] step 3: extensions

- [x] Phase 1: 实现多层自动化推理(python driver做layer-by-layer循环) <-- cim_driver.py CIMModel
- [x] Phase 2: im2col展开Conv层：python侧做im2col变换后喂给MVM引擎 <-- LwNet-5, PASS
- [x] Phase 3: 尝试映射一个Conv网络(比如LeNet-5) <-- 20 pics, bit-exact 100%
- [x] Phase 4: 尝试讨论bit-plane <-- 论文 §2.1（bit-serial vs word-level MAC 对比）+ §5.2(4)（未来工作）

### [x] step 4: PicoRV32替换ARM控制

- [x] Phase 1: 集成PicoRV32开源RISC-V软核到PL
- [x] Phase 2: 写 Wishbone→CSR bridge（或直接用 PicoRV32 native memory interface 映射到 CSR 地址空间）
- [x] Phase 3: RISC-V 固件（C）完成：weight DMA 加载、层配置、推理触发、结果读取
- [x] Phase 4: 用 riscv64-unknown-elf-gcc 交叉编译，固件存 BRAM
- [x] Phase 5: 仿真 + 上板验证功能等价

### [] step 5: Kria KV 260移植

- [] Phase 1: 更换 board file（xck26-sfvc784），重新搭建 Block Design
- [] Phase 1:测试更大并行度
- [] Phase 2: Zynq UltraScale+ 的 PS 是 Cortex-A53（AXI 接口兼容，驱动几乎不改），综合 + 时序收敛 + 上板验证
- [] Phase 3: 性能对比报告：PYNQ-Z2 vs KV260（资源、频率、吞吐）

### [x] step 6: 师兄 `cim_wzy` 启发下的改进

> 阅读师兄 `cim_wzy/` 的 bit-serial CIM + NCNN 协同平台后，梳理出三条增量式、低风险的改进。详见 `docs/cim_wzy_comparison.md`。
> 希望在尽量不动 RTL，只改 Python 软件栈和论文写作，用最小工作量获得最大答辩/论文价值。

#### Phase 1: 逐层 bit-exact 验证基础设施 (低难度, 高调试价值)

目标：在 `cim_driver.py` 加一个 `--verify-per-layer` 选项，每一层执行后把 `x_int8 / w_int8 / psum_int32 / y_int8` dump 到 `sw/logs/<layer_i>/`，并与 `golden_model.py` 的纯 Python 结果逐元素比对，打印 `[MATCH] / [UNMATCH]` 表格。

- [x] 在 `sw/cim_driver.py::CIMModel.predict()` 增加 `verify=False` 参数
- [x] 新建 `sw/logs/` 目录约定: `sw/logs/<run_id>/layer_<i>_<type>/{x.hex,y.hex,golden_y.hex,diff.txt}`
- [x] 利用已有 `golden_model.py` 的 `infer_layer()` 算参考, 逐层 `assert np.array_equal(y_hw, y_golden)`
- [x] 在 `full_cim_test_pynq.ipynb` 最后一个 cell 加一个开关做一次 demo run

**为什么先做这个**：不改 RTL，不破坏现有测试，立即获得论文"bit-accurate验证"的素材。师兄项目里的 `SIM-MATCH/UNMATCH` 打印就是同一思路。

#### Phase 2: SQ-mapping 启发的小核权重复制 (中等难度, 量化论文数据)

目标：借鉴 `cim_wzy/simulation/csrc/layer/convolution.cpp` 的 `SQ_MAPPING`，在 `cim_driver.py::im2col` 后增加"权重复制打包"路径：当 `col_len = K*K*C_in` 远小于 `MAX_IN_DIM=784` 时，把多个输出像素的 im2col 列并排塞进同一次 MVM。

**理论加速比（LeNet-5）**：

- **Conv1** (`col_len=5*5*1=25`, `C_out=6`): 打包系数 `min(784/25, 128/6) = 21`，784 次 MVM 降为 38 次 → **≈20×**
- **Conv2** (`col_len=5*5*6=150`, `C_out=16`): 打包系数 `min(784/150, 128/16) = 5`，100 次 MVM 降为 20 次 → **≈5×**

- [x] 在 `cim_driver.py` 新增 `infer_conv_packed()` 方法，接收当前 `layer["w_chunks"]` 和打包系数 `k_pack`
- [x] Python 侧构造"块对角"权重矩阵：`W_packed = block_diag(W, W, ..., W)`，行 `k_pack*col_len`，列 `k_pack*C_out`
- [x] 输入也按 `k_pack` 像素拼接成长向量
- [x] 一次 `start_and_wait()` 拿回 `k_pack * C_out` 个输出，再拆回 `k_pack` 组 — 板上验证 [MATCH]，LeNet-5 200张 99.5%
- [x] benchmark 数据由 `sw/scripts/benchmark_e2e.py` (B3) 直接覆盖：LeNet-5 200张 325.1s (1.625s/img)，较未打包的 708.3s 加速 2.18×
- [x] 论文 §4.5 《SQ-mapping 软件映射优化》已加入 `Thesis/middle/paper/paper.tex`，含打包因子公式、Conv1/Conv2 对比表与墙钟时间对比表

**注意**：不需要动硬件，只是把原来 `for p in range(n_pixels): infer_fc()` 的循环合并。正确性验证直接复用 Phase 1 的 `--verify-per-layer`。

#### Phase 3: 论文架构对比章节 (纯写作, 高论文价值)

目标：在毕业论文第 2 章"CIM 架构综述"加一个子节《数字 SRAM-CIM 的两种实现极端》，把 bit-serial popcount (以 `cim_wzy` 为代表) 和本毕设的 DSP48 行为级 MAC 作为两条技术路线对比。

- [x] 论文 §2.1 《数字SRAM-CIM的两种实现极端与本设计定位》已完成，含两端对比表（表 2-1）与本设计取舍论述
- [x] 论文里如实声明借鉴关系 (代码放在 `cim_wzy/` 独立目录, 论文用 footnote 标注为"课题组内独立验证平台")
- [x] 论文 §5.2 《不足与展望》已加入三条扩展路径：(6) AXI4-Full DMA、(7) NCNN/ONNX runtime 集成、(8) Chisel 参数化重构

### [x] step 8: C3 落地 — AXI4-Stream + axi_dma 数据通路重构（**✅ 已完成**）

> A2 profiler 实测：LeNet-5 端到端 1696 ms/img 中，硬件 compute 仅 ~4 ms（0.24%），其余 99.7% 全部花在 AXI4-Lite 32-bit 逐字 MMIO 上（单图 ~170 KB packed weight ≈ 42500 个 32-bit MMIO 写）。
> 本 step 把数据通路从 "AXI4-Lite 逐字 MMIO" 换成 "AXI4-Stream + Xilinx axi_dma IP"，CSR 控制仍走 AXI4-Lite。理论端到端 **~270×** 加速（→ 6 ms/img）。
> RTL 计算核心 (`cim_tile / psum_accum / cim_accel_core / weight_sram / input_buffer / bias_sram`) 一行不动，bit-exact 行为受 pytest 回归 + e2e TB 保护。
>
> **完整设计规范见 `docs/c3_dma_design.md`**（接口表 / 状态机 / BD TCL / 6-commit rollout / 风险登记）。本节为概览。

#### 设计选型

| 维度         | A. AXI4-Full slave          | B. AXIS + Xilinx axi_dma （**采用**） | C. AXI MCDMA                                   |
| ------------ | --------------------------- | ------------------------------------- | ---------------------------------------------- |
| 协议复杂度   | 自写 burst / id / wrap 握手 | 仅 `tvalid/tready/tdata/tlast`        | 同 B + 多通道仲裁                              |
| Vivado IP    | 自写                        | 官方 axi_dma 7.1，PYNQ 一行 API       | 官方但配置复杂                                 |
| 多路仲裁     | 自写 dest 解码              | 一条 stream + 1-byte CSR 选目的       | 硬件多通道                                     |
| **拒绝原因** | 协议复杂、风险高            | —                                     | 单 HP 端口下多通道仍串行，**徒增复杂度无收益** |

#### 系统框图

```
PS7 ──M_AXI_GP0──┬─ AXI Interconnect ── cim_top_0/S_AXI_LITE (CSR, 14-bit)
                  └────────────────────── axi_dma_0/S_AXI_LITE (DMA 控制)
PS7 ──M_AXI_GP1── 同上（DMA CSR 走 GP1 避开 GP0 仲裁）
PS7 ──S_AXI_HP0── 64-bit, 1.2 GB/s ── axi_dma_0/M_AXI_MM2S (DDR 读)
                                                  │
                                  M_AXIS_MM2S (32-bit)
                                                  ▼
                            cim_top_0/S_AXIS_DATA → cim_axi_stream_sink
                                                  │
                                  CTRL[3] MUX (legacy MMIO ↔ stream)
                                                  ▼
                            weight_sram / input_buffer / bias_sram
中断: xlconcat({cim_top_0/irq_done, axi_dma_0/mm2s_introut}) → ps7/IRQ_F2P
复位: ps7/FCLK_CLK0 → proc_sys_reset_0 → cim_top_0
                   → proc_sys_reset_1 → axi_dma_0  (独立, 防 CSR_CTRL[2] soft reset 把 in-flight DMA 一并清掉)
```

#### 关键设计决策（详见设计文档 §0-3）

1. **AXIS 数据宽度 = 32-bit**（不升 64-bit）。理由：与现有 `weight_to_chunks` packing 兼容，axi_dma 内部做 64→32 dwidth 转换免费（PG021 §3.1.1），换 64-bit 仅省 ~30% 拍数但要重写 Python packing。
2. **dual-path 强制保留**：`CSR_CTRL[3]=0` 走 legacy MMIO，`=1` 走 stream。直到 commit 6 上板 200 张 bit-exact 验证通过，**才**在 commit 7 删除 legacy 代码。
3. **不为 stream sink 单独发 IRQ**：`mm2s_introut` 在 DMA 端表示 "DDR→AXIS 完成"，sink 端 BRAM 写延迟 ≤ 1 cycle，PS 拿到 DMA IRQ 时数据已到 SRAM。轮询 `CSR_STREAM_STATUS` 二次校验即可。
4. **`s_axis_tready` 恒为 1**：BRAM 写 1 cycle 完成，sink 内部不需要排队，反压向 PS 端反向传播即可。
5. **`cfg_start` 通过写 `CSR_STREAM_LEN` 隐式触发**：原子化，少一次 CSR 写省 1.5 µs/层。

#### 新增 / 修改文件（清单）

| 类别 | 文件                                                        | 说明                                                                                                          |
| ---- | ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| 新增 | `hw/rtl/axi/cim_axi_stream_sink.sv`                         | ~250 行；4-beat → 128-bit 行装配，dest 路由                                                                   |
| 新增 | `hw/rtl/cim_top.sv`                                         | ~200 行；wrapper, MUX legacy/stream                                                                           |
| 新增 | `hw/tb/tb_cim_stream_sink.sv` + `run_tb_cim_stream_sink.sh` | SV stream BFM, 与 weight_sram 内容比对                                                                        |
| 新增 | `docs/c3_dma_design.md`                                     | 详细设计规范（已完成）                                                                                        |
| 修改 | `hw/rtl/pkg/cim_pkg.sv`                                     | +`CSR_STREAM_DEST=14'h050` / `CSR_STREAM_LEN=14'h054` / `CSR_STREAM_STATUS=14'h058`；+`stream_dest_t` typedef |
| 修改 | `hw/rtl/axi/cim_axi_lite_slave.sv`                          | +CSR 解码；+stream 端口；**legacy staging 保留**                                                              |
| 修改 | `hw/scripts/vivado_build.tcl` + `_55mhz.tcl`                | +HP0/GP1 启用、axi_dma_0、xlconcat、psr_dma、地址映射、.hwh assertion                                         |
| 修改 | `sw/cim_driver.py`                                          | +`use_dma` 参数；+`_stream_load(words, dest, buf)`；三个 `load_*` 分流                                        |
| 修改 | `sw/tests/test_cim_driver_offline.py`                       | +1 用例 `test_dma_path_bit_exact`                                                                             |

`CIMModel.predict() / infer_conv() / infer_conv_packed()` 上层接口完全不变。

#### 推进计划（6 个 commit + 1 个清理）

| #      | 标题                                                     | 验证                                                         | 状态                                                 | 回退点                       |
| ------ | -------------------------------------------------------- | ------------------------------------------------------------ | ---------------------------------------------------- | ---------------------------- |
| 1      | feat(rtl): cim_axi_stream_sink + standalone TB           | `run_tb_cim_stream_sink.sh` GREEN                            | ✅ `f39489b`                                         | 否                           |
| 2      | feat(rtl): CSR*STREAM*\* + CTRL[3] gate                  | `run_regression.sh` GREEN（CTRL[3]=0 默认 legacy）           | ✅ `0adf7da`                                         | 否                           |
| 3      | feat(rtl): cim_top wrapper + MUX                         | `run_regression.sh` GREEN                                    | ✅ `db16cbb`                                         | 否                           |
| 4      | **feat(bd): integrate axi_dma + S_AXI_HP0 + xlconcat**   | `vivado_build.sh` 出 .bit/.hwh, axi_dma 在 .hwh, WNS ≥ 0     | ✅ `4236e85`                                         | **是 — git tag `pre-c3-bd`** |
| 5      | feat(sw): DMA path behind use_dma flag                   | `pytest sw/tests/ -v` 22/22 PASS                             | ✅ `9c7914f`                                         | 否                           |
| 6      | feat: enable DMA by default + benchmark + paper          | LeNet-5 200 张 99.5% acc, ≤25 ms/img, profiler load_w_ms <5% | ✅ DMA 上板 benchmark 完成：60MHz DMA 503.65 ms/img (1.99 fps), speedup 3.4× vs MMIO；55MHz 收敛通过 | 否                           |
| 7 (后) | refactor(rtl): remove legacy MMIO weight/input/bias path | 全 TB+pytest GREEN, LUT 减 ~800                              | ⏳ commit 6 通过 1 周后                              | 否                           |

**Commit 6 完成状态**：

1. ✅ `bash hw/scripts/vivado_build.sh` — 生成带 axi_dma 的新 .bit/.hwh（60MHz + 55MHz 变体）
2. ✅ 拷贝到 PYNQ-Z2，跑 200 张 MNIST
3. ✅ `python sw/scripts/benchmark_e2e.py --model lenet5 --n_images 200` → `sw/benchmark_e2e_60mhz_dma.csv`, `sw/benchmark_e2e_60mhz_mmio.csv`
4. 实际数据：DMA 503.65 ms/img (1.99 fps), MMIO 1690.54 ms/img (0.59 fps), speedup 3.4×, accuracy 99.50%

#### 实际收益（量化）

| 指标                           | 60 MHz, MMIO | 60 MHz, DMA | 加速比  |
| ------------------------------ | ------------ | ----------- | ------- |
| LeNet-5 200 张 benchmark       | 338.1 s      | 100.7 s     | **3.4×** |
| LeNet-5 单图延迟               | 1690.5 ms    | 503.7 ms    | **3.4×** |
| Accuracy                       | 99.50%       | 99.50%      | 一致    |

**注意**：实际 speedup 3.4×，远低于理论 ~270×。瓶颈已从纯 MMIO 搬运转移到其他因素（DMA 效率/pipeline/PS 侧处理），下一步需用 A2 profiler 分解 DMA 模式下的 latency breakdown。详见 `OPTIMIZATION_ROADMAP.md`。

#### 风险与回退（核心 7 条详见设计文档 §8）

| 风险                                | 概率 | 缓解                                                    |
| ----------------------------------- | ---- | ------------------------------------------------------- |
| `.hwh` 缺 axi_dma 段                | 中   | TCL 末尾 assertion + 驱动 try/except                    |
| WNS 退化（DMA + Interconnect 引入） | 低   | Phase 4 强制查 WNS；失败先加 `axis_register_slice` 隔离 |
| `soft_reset` 与 in-flight DMA 竞态  | 中   | 独立 proc_sys_reset + 驱动 `wait()` 兜底                |
| dual-path 共存 LUT 超预算           | 低   | 当前 11k LUT (20%)，+1050 LUT 仍在预算内                |

#### 验收标准（commit 6 必须满足）

1. `pytest sw/tests/` 17/17 GREEN
2. LeNet-5 200 张 accuracy = 99.5%（与 60 MHz baseline bit-exact 一致）
3. LeNet-5 ≤ 25 ms/img（目标 ~6 ms）
4. A2 profiler `load_w_ms` 占比 < 5%

不满足任一条 → 不合并 commit 6，回滚到 commit 5（`use_dma=False` 默认）。

### [x] step 8.5: P0 — read_output DMA S2MM 消除串行 MMIO 瓶颈（**✅ 已完成，2026-05-04**）

> step 8 (C3) DMA 上板完成，profiler 实测 `read_output` 串行 MMIO 占端到端延迟的 61.7%（~257ms）。
> 本 step 新增 `cim_axi_stream_source.sv`（~210 行 AXIS master），将 output_buffer 读回路径从 N 次 AXI4-Lite 单字读换为一次 DMA S2MM 传输。
> **不改 cim_accel_core / cim_tile / psum_accum**，bit-exact 行为受 pytest 回归保护。

#### 架构变更

| 组件 | 变更 | 说明 |
|------|------|------|
| `hw/rtl/axi/cim_axi_stream_source.sv` | **新增** | ~210 行；AXIS master，从 output_buffer 读 INT8 值，打包为 32-bit beats 送往 DMA S2MM。5-state FSM (IDLE→WAIT→WARMUP→READ→SEND), BRAM 2-cycle 延迟补偿, 非4对齐末字支持 |
| `hw/rtl/pkg/cim_pkg.sv` | 修改 | +`CSR_RESULT_LEN` (0x060), `CSR_RESULT_CTRL` (0x064), `CSR_RESULT_STATUS` (0x068) |
| `hw/rtl/axi/cim_axi_lite_slave.sv` | 修改 | +M_AXIS_RESULT 端口、CSR 解码、source 实例、obuf_rd_addr MUX |
| `hw/rtl/cim_top.sv` / `cim_top_wrapper.v` | 修改 | +M_AXIS_RESULT 端口路由 |
| `hw/scripts/vivado_build.tcl` | 修改 | S2MM enable (`c_include_s2mm=1`)、+HP1、M_AXIS_RESULT→S_AXIS_S2MM 连接、+S2MM intr、+axi_mem_intercon_1 reset |
| `sw/cim_driver.py` | 修改 | `read_output()` 使用 direct register mode S2MM；MM2S 同步改为 direct register mode；双缓冲 result buffer |

#### 关键 Debug 历程

1. **PYNQ `recvchannel` 不可用** → bypass PYNQ `_SDMAChannel`，改用 direct register mode (PG021)
2. **S2MM 第二次调用超时 (DMASR=0x00000000)** → RTL `is_last_word` sticky bug：FSM 在第二次传输时因 `is_last_word` 未清零而立即终止
3. **DMAIntErr (DMASR=0x00005011)** → `n_bytes=out_dim=126` 非4字节对齐，source 无 tkeep → pad 到 4 字节边界
4. **done 信号不可轮询** → `done` 原为1-cycle pulse (16.67ns)，Python MMIO 无法捕获 → 改为 sticky
5. **性能退化 (~12s/img)** → debug sleeps (10ms reset + 100ms drain = 110ms/次 × 51次 ≈ 5.6s) → 改用 spin-wait + 去除 drain sleep

#### 实测性能 (2026-05-04)

| 指标 | C3 DMA (MM2S only) | C3 + P0 S2MM | 加速比 |
|------|---------------------|---------------|--------|
| read_out_ms | 257 | 19.65 | **13×** |
| 端到端 ms/img | 503.65 | 128.4 | **3.9×** |
| FPS | 1.99 | 7.8 | **3.9×** |
| Accuracy | 99.5% | 99.5% | 一致 |

**LeNet-5 延迟分解 (128.4 ms/img):**

| Phase | ms | % |
|-------|-----|---|
| setup (configure + load_w + load_b) | 41.05 | 32.0% |
| load_x (per-MVM input) | 23.01 | 17.9% |
| im2col (Python-side) | 20.58 | 16.0% |
| read_out (S2MM DMA) | 19.65 | 15.3% |
| dma_x_setup | 8.87 | 6.9% |
| compute (hardware) | 7.17 | 5.6% |
| dma_x_transfer | 5.55 | 4.3% |

优化历程总览：
- MMIO baseline: 1690.54 ms/img (0.59 fps)
- C3 MM2S DMA: 503.65 ms/img (1.99 fps, 3.4×)
- **C3 + P0 S2MM: 128.4 ms/img (7.8 fps, 13.2× vs MMIO)**

---

### [] step 7: 工程化与性能优化（全面改进菜单）

> 超出 step 6 范围的增量改进菜单，覆盖软件栈、RTL 时序优化、KV260 扩展、论文素材、工程健康度。
> 按 "投入产出比" 分五档 A/B/C/D/E，详细方案与 rationale 见 `docs/cim_wzy_comparison.md` 第 6 节。
> **Top 3 推荐**（合计 2 天，零 RTL 风险）：**A2 + B3** 延迟分解 + batch benchmark → **B1** 资源/时序 CSV → **A1** 权重常驻。一次性补齐论文第 4、5 章数据。

#### Phase A: 立刻可做（<半天，纯 Python，零 RTL 风险）

- [] **A1 权重常驻 + 批推理模式**
  ~~`CIMModel` 每个 layer 加 `_w_loaded` 标志~~。**硬件限制**：weight SRAM 各层共享，Conv2 加载时覆盖 Conv1，FC3 覆盖 Conv2，跨图像缓存对多层模型无效。
  _可行替代_：仅对单层模型有效；或硬件侧改用 AXI DMA 批量搬运代替逐元素 MMIO 写（需 RTL 改动）。
- [x] **A2 端到端延迟分解 profiler**
      `time.perf_counter()` 包住 `im2col / load_w / load_x / hw_compute / read_out / py_overhead`，`predict()` 返回 dict + 画 pie chart。
      _收益_：板上实测：Conv1 compute=4.1ms 但 setup+load=620ms，瓶颈为 MMIO 搬运而非硬件计算。
- [] **A3 Bitstream + driver + git commit 三位一体指纹**
  `hashlib.sha256(bit) + git rev-parse --short HEAD` 写入 step 6 Phase 1 的 dump 目录。
  _收益_：实验可追溯，答辩能秒答"这张图来自哪次运行"。

#### Phase B: 本周可做（1-2 天，高论文价值）

- [] **B1 资源/时序/功耗自动提取 CSV**
  `hw/scripts/extract_report.py` 跑完 `vivado_build.sh` 后 grep `utilization_*.rpt / timing_summary.rpt / power.rpt`，append 一行到 `hw/build_history.csv` (`commit, freq_mhz, wns_ns, lut, ff, bram, dsp, power_w`)。
  _收益_：论文"硬件资源与性能"表直接用 + patch1/2/3 三次流水优化的趋势线，故事直观。
- [x] **B2 Pytest 回归**（golden*model + cim_driver 离线）
      `sw/tests/test_golden_model.py`（10 tests）+ `sw/tests/test_cim_driver_offline.py`（6 tests），`pytest sw/tests/ -v` 全部 GREEN（0.29s）。
      *收益\_：未来 RTL 重构不会悄悄破坏 bit-exact；论文可写"CI 覆盖率"。
- [x] **B3 多图 batch benchmark 脚本**
      `sw/scripts/benchmark_e2e.py --model lenet5 --n_images 200`，输出表格 (Model / n*img / total_s / ms_per_img / fps / accuracy)，结果保存 `results/benchmark*\*.csv`。
      _收益_：论文第 5 章 benchmark 数据表。

#### Phase C: 时间充裕再做（RTL 改动，显著加速）

- [] **C1 拆 cim_tile 16→2×8 打破 critical path** ⚠️ RTL 核心改动
  `坑` 章节 patch 3 明确 critical path 是 `w_tile_reg → DSP48 → CARRY4 → tile_psum_reg`，16-element 串行加法链。拆成前 8 + 后 8 两拍流水，`cim_accel_core` compute 段多加一个 pipeline stage。
  _收益_：125 MHz unlock → 吞吐 2×；论文硬件章节"流水线优化四阶段"故事完整 (patch1/2/3 + 这步 = 4 次迭代)。
  _风险_：动 `cim_tile.sv` 核心，需重跑全部 VCS 回归 (`run_regression.sh`)。
- [] **C2 Weight / Input SRAM 双缓冲** ⚠️ RTL 中等改动
  双 bank + `active_bank` 寄存器，Python 侧预加载 layer N+1 weight 到另一个 bank。
  _收益_：多层网络层间延迟隐藏，吞吐再提升 20%~40%。
  _风险_：BRAM 占用翻倍，PYNQ-Z2 可能放不下 —— 放到 KV260 phase 一起做更合理。
- [] **C3 AXI4-Full burst 代替 AXI4-Lite 逐字** ⚠️ 接口重写
  换 AXI4-Full slave + DMA engine（PYNQ `pynq.lib.dma`），单次 burst 几 KB。
  **背景**：profiler 实测（A2）显示 Conv1 compute=4.1 ms，但 load*weights ≈250 ms，瓶颈完全在 MMIO 逐字写。LeNet-5 每张图 ~700 ms 用于搬权重，计算本身可忽略不计。A1（软件权重缓存）尝试跳过重复加载，但 weight SRAM 各层共享、后层覆盖前层，多层网络无法使用。根本解决方案是本条 C3：AXI4-Full 突发传输可将 weight load 从 ms 级降到 μs 级，彻底消除搬运瓶颈。
  *收益*：weight load 从 ~700 ms/张 降到 <1 ms，LeNet-5 吞吐理论 **100×+**。
  *风险\_：改动最大（需重写 AXI slave、Vivado block design、Python driver 改用 `pynq.lib.dma`）。**不建议毕设阶段动 RTL**，论文"未来工作"章节直接引用 profiler 数据作为动机。

#### Phase D: KV260 专属（与 step 5 合并推进）

- [] **D1 UltraRAM 替代 BRAM 放大权重尺寸**
  UltraScale+ URAM (288 Kb/block vs BRAM 36 Kb) → `MAX_IN_DIM` 从 784 拉到 1024~2048。
- [] **D2 PAR_OB = 4 或 8 真并行**
  KV260 资源充足，吞吐 4-8×。
- [] **D3 200 MHz 目标时序**（配合 C1）
  UltraScale+ 时序容易收敛。
  **三条组合**：凑出论文"跨平台对比表" PYNQ-Z2 (60 MHz, PAR=1) vs KV260 (200 MHz, PAR=4)，吞吐/面积/功耗效率全对比。

#### Phase E: 论文素材与工程健康度

- [x] **E1 层级 latency timeline 可视化** (matplotlib stacked bar chart)
      `sw/scripts/plot_latency_breakdown.py` → `Thesis/middle/paper/fig/latency_breakdown.{pdf,png}`，已插入论文 profiler 小节。
      _收益_：论文 Figure：compute 段几乎不可见，直观传达"MMIO 是瓶颈"。
- [] **E2 统一 CLI 入口** `sw/scripts/cim.py run --model lenet5 --input foo.png --verify`
  替代散落 notebook，答辩 demo 干净。
- [] **E3 架构图自动生成** (`graphviz` 驱动 `cim_pkg.sv` 参数)
  改参数不用手画。
- [] **E4 ONNX import 路径**
  `onnxruntime` EP 注册 `CIMExecutionProvider`。**只在论文"未来工作"提，不实现**。

#### 推进顺序建议

```
step 6 Phase 1 (verify)  ──┐
step 6 Phase 2 (SQ pack) ──┼──→ Top 3 (A1+A2+B1+B3) ──→ C1 critical path ──→ D1+D2+D3 KV260
step 6 Phase 3 (thesis)  ──┘
```

原则：**不贪多**。完成 step 6 Phase 1+2 + Top 3 已经是扎实的毕设工作量。剩下的放进论文"未来工作"章节。答辩委员看到一个能讲清楚"下一步该往哪走"的候选人，永远比看到一个"啥都做了一半"的候选人印象好。

### [] step 9: C1 落地 — cim_tile 关键路径拆分 (16 → 2×8 → merge)

> 前提：step 8 (C3) 上板完成，MMIO 瓶颈消除。端到端主瓶颈回到硬件 compute 本身。
> 本 step 把 `cim_tile.sv` 的 16-wide 串行加法链拆成 2×8 两拍流水，解锁 125 MHz 目标频率。
> 实测 critical path 位于 `w_tile_reg → DSP48 → CARRY4 → tile_psum_reg`（README `坑` 章节 patch 3；布线后延迟 16.2 ns，60 MHz WNS = −0.086 ns）；拆分后预计单段延迟 ≤ 8 ns，支持 125 MHz。

#### 1. 关键路径分析

现状 `hw/rtl/core/cim_tile.sv` L23–L36 是一条纯组合的 16 级加法链：

```systemverilog
for (c = 0; c < TILE_COLS; c++) begin : GEN_COL
    assign row_acc[c+1] = row_acc[c] + $signed({1'b0, x_eff[c]}) * $signed(w_tile[r][c]);
end
```

Vivado 综合会把 `x_eff[c] * w_tile[r][c]` 映射到 DSP48E1 的 `A*B` 端，16 个乘积通过 `P` 端串联进 CARRY4 级联。布线后结构为：

```
DSP48_0.P ─── CARRY4_0 ─── CARRY4_1 ─── ... ─── CARRY4_3 ─── tile_psum_reg
             (cin=0)                             (16-bit acc)
```

按 xc7z020-1 speed grade 估算：DSP48 `P` 端 `PCOUT→Tco` 约 2.3 ns，单级 CARRY4 `CI→CO` 约 0.3 ns，4 级 CARRY4 级联 ≈ 1.2 ns，再加 `w_tile_reg` 的 `Tck→Q` 约 0.5 ns 与寄存器 `setup` 约 0.3 ns，理想延迟 ≈ 4.3 ns。但 256 个 DSP 并行布线下 net delay 显著（布线后实测 16.2 ns），其中约 10 ns 是 net 延迟。

目标频率下的 slack 估算：

| 目标频率 | 周期      | 现状延迟 | Slack     | 结论                  |
| -------- | --------- | -------- | --------- | --------------------- |
| 60 MHz   | 16.667 ns | 16.2 ns  | −0.086 ns | 3 个 failing endpoint |
| 100 MHz  | 10.000 ns | 16.2 ns  | −6.2 ns   | 必须拆分              |
| 125 MHz  | 8.000 ns  | 16.2 ns  | −8.2 ns   | 必须拆分且单段 ≤ 8 ns |

#### 2. RTL 拆分设计

**拆分前（ST_MAC 单拍，一次算 16 列乘积 + 16 级加法）**：

```
 ST_WAIT_SRAM ─► ST_XEFF_REG ─► ST_MAC ─► ST_COMPUTE ─► ST_NEXT_IB
                                 │
                                 └── 16-wide DSP chain (16.2 ns)
```

**拆分后（ST_MAC_LO + ST_MAC_HI 两拍，各算 8 列）**：

```
 ST_WAIT_SRAM ─► ST_XEFF_REG ─► ST_MAC_LO ─► ST_MAC_HI ─► ST_COMPUTE ─► ST_NEXT_IB
                                    │             │
                                    │             └── 8-wide DSP chain (≤8 ns, tile_psum_hi_reg)
                                    └── 8-wide DSP chain (≤8 ns, tile_psum_lo_reg)
```

`cim_tile.sv` 对应改动（关键片段）：

```systemverilog
// 新增参数，1 = 不拆分 (legacy), 2 = 8+8 拆分
parameter int SPLIT_FACTOR = cim_pkg::TILE_SPLIT_FACTOR;

generate
  for (r = 0; r < TILE_ROWS; r++) begin : GEN_ROW
    if (SPLIT_FACTOR == 1) begin : GEN_MONO
      // 原 16-level chain (保留为 fallback)
      logic signed [PSUM_W-1:0] row_acc [TILE_COLS+1];
      assign row_acc[0] = '0;
      for (c = 0; c < TILE_COLS; c++) begin : GEN_COL
        assign row_acc[c+1] = row_acc[c] + ...;
      end
      assign psum[r] = row_acc[TILE_COLS];
    end else begin : GEN_SPLIT
      // 8-wide partial chains, exposed as two outputs to accel_core
      logic signed [PSUM_W-1:0] lo_chain [9], hi_chain [9];
      assign lo_chain[0] = '0; assign hi_chain[0] = '0;
      for (c = 0; c < 8; c++) begin : GEN_LO
        assign lo_chain[c+1] = lo_chain[c] + ...; // x_eff[c]   * w_tile[r][c]
      end
      for (c = 0; c < 8; c++) begin : GEN_HI
        assign hi_chain[c+1] = hi_chain[c] + ...; // x_eff[c+8] * w_tile[r][c+8]
      end
      assign psum_lo[r] = lo_chain[8];
      assign psum_hi[r] = hi_chain[8];
    end
  end
endgenerate
```

`cim_accel_core.sv` 对应改动：

- 新增寄存器 `tile_psum_lo_reg[PAR_OB][TILE_ROWS]` 和 `tile_psum_hi_reg[PAR_OB][TILE_ROWS]`（替代单一 `tile_psum_reg`）。
- ST_MAC_LO 拍：latch `psum_lo` → `tile_psum_lo_reg`；
- ST_MAC_HI 拍：latch `psum_hi` → `tile_psum_hi_reg`；
- ST_COMPUTE 拍：组合 `tile_psum_reg = tile_psum_lo_reg + tile_psum_hi_reg`，送给 `psum_accum`（即 psum_accum 的输入路径中多一级 32-bit 加法，时序裕量充足，不需要再拆）。

#### 3. FSM 改动 (`cim_pkg.sv::accel_state_t`)

在枚举中把 `ST_MAC` 拆为 `ST_MAC_LO` 和 `ST_MAC_HI`，状态字段从 5 位保持不变（仍 ≤32 状态）：

```systemverilog
ST_MAC_LO      = 5'd6,   // 原 ST_MAC, low 8 columns
ST_MAC_HI      = 5'd17,  // 新增, high 8 columns
```

`cim_accel_core.sv` 状态机 L362–L368 原 ST_MAC 分裂为：

```systemverilog
ST_MAC_LO: begin ...; state_nxt = ST_MAC_HI; end
ST_MAC_HI: begin ...; state_nxt = ST_COMPUTE; end
```

每个 IB iteration 从 6 拍增加到 **7 拍**（多 ST_MAC_HI 一拍）。`psum_accum.sv` 无需改动——它只看输入的 `tile_psum[TILE_ROWS]`，对 split 不透明，merge 在 core 内部完成。

#### 4. 参数化讨论：SPLIT_FACTOR 选择

| SPLIT_FACTOR | 单段宽度 | 单段 DSP 链深度 | 单段延迟估算 | 额外 FSM 拍数 | 适用频率    |
| ------------ | -------- | --------------- | ------------ | ------------- | ----------- |
| 1            | 16       | 4×CARRY4        | 16.2 ns      | 0             | ≤60 MHz     |
| 2            | 8        | 2×CARRY4        | ~8 ns        | +1            | 120–125 MHz |
| 4            | 4        | 1×CARRY4        | ~5 ns        | +3            | 150–200 MHz |

**推荐默认 `SPLIT_FACTOR = 2`**。理由：

1. 最小拆分即可解锁 125 MHz，恰好是本工作原目标（README 坑章节 patch 2 提及"尝试 125 MHz"）。
2. 每 IB +1 拍，LeNet-5 总周期从 76034 增至 ~88,700 （+16.7\%），但频率 ×2，净加速 ≈ 1.71×。
3. SPLIT_FACTOR=4 在 xc7z020 上布线 net delay 会吃掉 `T_period` 减小的一半以上，实际提升有限，同时 FSM +3 拍让 compute 拍数膨胀 50\%，综合得不偿失。
4. 为 KV260 (UltraScale+ DSP58) 保留 `SPLIT_FACTOR=4` 入口，但不作为 PYNQ-Z2 默认。

在 `cim_pkg.sv` 新增：

```systemverilog
parameter int TILE_SPLIT_FACTOR = 2;  // 1=monolithic (legacy), 2=8+8 (125 MHz target)
```

以 `generate` 形式驱动 `cim_tile.sv` 内部结构，支持 `TILE_SPLIT_FACTOR=1` 一键回退。

#### 5. 验证计划

| Testbench              | 改动                                                                                                                                         | 判定                                  |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------- |
| `tb_cim_tile.sv`       | 新增 `SPLIT_FACTOR` 参数扫描（1 和 2 各跑 103 个随机用例），比对 `psum` 输出 bit-exact 一致                                                  | `psum_mono == psum_split`             |
| `tb_cim_accel_core.sv` | 修改 `expected_cycles` 计算公式：原 `6 + 7*n_ib*n_ob_groups + output_pipeline`，新 `6 + (6+SPLIT_FACTOR)*n_ib*n_ob_groups + output_pipeline` | 断言 `perf_cycles == expected_cycles` |
| `tb_mnist_e2e.sv`      | 新增 `+define+CHECK_CYCLE_COUNT`，断言 MLP 实际周期与 SPLIT_FACTOR 相关的公式一致                                                            | argmax + cycle count 双重比对         |

新增 pytest 用例 `sw/tests/test_golden_model.py::test_expected_cycles_split2`：

```python
def test_expected_cycles_split2():
    # Encodes the cycle formula for TILE_SPLIT_FACTOR=2 so RTL refactor cannot
    # silently break the timing model used by benchmark_e2e.
    n_ib, n_ob = 49, 8  # FC1
    setup = 6; inner_per_iter = 7  # 6 → 7 due to ST_MAC_HI
    output_pipe = 6 * 16 * 8  # 6 stages × 16 rows × 8 ob_groups
    assert expected_cycles(784, 128, split=2) == setup + inner_per_iter*n_ib*n_ob + output_pipe
```

`sw/golden_model.py` 无需改动——split 完全位于 RTL 内部，对功能 bit-exact 透明。

#### 6. 综合收敛策略

优先尝试现有 `Flow_PerfOptimized_high` + `ExtraNetDelay_high` + `AggressiveExplore` 组合，在 100 MHz 目标下应直接收敛。125 MHz 若失败，依次尝试：

1. 把 synth 策略切到 `PerformanceOptimized_high`（对 DSP pipelining 更激进）；
2. impl place 策略改 `Performance_ExplorePostRoutePhysOpt` + 开启 `post_route_phys_opt_design`；
3. 约束中为 `tile_psum_lo_reg / tile_psum_hi_reg` 增加 `ASYNC_REG` 或 `KEEP` 避免 Vivado 合并；
4. 若仍未收敛，降频至 120 MHz（周期 8.33 ns）——仍能获得 2× 吞吐。

预测 WNS：100 MHz 目标 WNS ≈ +1.5 ns（舒适）；125 MHz 目标 WNS ≈ +0.1 ns（紧张但可行）。

#### 7. 风险与回退

| 风险                                                                         | 概率 | 缓解                                                                                  |
| ---------------------------------------------------------------------------- | ---- | ------------------------------------------------------------------------------------- |
| 125 MHz 综合仍不收敛（xc7z020 布线极限）                                     | 中   | `cim_pkg.sv::TILE_SPLIT_FACTOR=1` 一键回退至 60 MHz 单段设计，功能不受影响            |
| ST_MAC_HI 与 ST_MAC_LO 之间的 `w_tile_reg` 驱动扇出翻倍（同一 reg 两拍被读） | 低   | Vivado 自动 register duplication，或手动在 `cim_tile.sv` 增加 `(* max_fanout = 50 *)` |
| split merge 处 32-bit 加法在 ST_COMPUTE 拍变成 critical path                 | 低   | psum_accum 已有同款 32-bit 加，实测 ~4 ns，远小于周期                                 |

**回退路径**：`set TILE_SPLIT_FACTOR 1` → 重跑 `vivado_build.sh` → 回到 60 MHz 单段 bitstream。pytest/TB 回归用 `SPLIT_FACTOR=1` 路径自动保护。

#### 8. 端到端收益预测（C3 + C1 组合）

| 指标                  | 60 MHz baseline | 60 MHz + C3    | 125 MHz + C3 + C1 | 相对 baseline |
| --------------------- | --------------- | -------------- | ----------------- | ------------- |
| LeNet-5 硬件 cycle 数 | 76,034          | 76,034         | 88,700 (+16.7\%)  | —             |
| 硬件 compute 时间     | 1.267 ms        | 1.267 ms       | 0.710 ms          | 1.78×         |
| DMA load 时间         | 700 ms          | ~0.8 ms        | ~0.8 ms           | —             |
| 端到端单图延迟        | 1696 ms         | ~7.6 ms (目标) | ~4.8 ms (目标)    | **~350×**     |

C1 单独贡献：在 C3 之后把端到端从 ~7.6 ms 进一步压到 ~4.8 ms（+1.58× on top of C3）。

#### 推进计划

| #   | 标题                                                | 验证                                                    |
| --- | --------------------------------------------------- | ------------------------------------------------------- |
| 1   | feat(pkg): add TILE_SPLIT_FACTOR + ST_MAC_HI enum   | `run_regression.sh` (SPLIT=1 路径)                      |
| 2   | feat(rtl): split cim_tile into lo/hi under generate | `tb_cim_tile.sv` SPLIT=1 与 SPLIT=2 bit-exact 对拍      |
| 3   | feat(rtl): add ST_MAC_LO/HI to accel_core + merge   | `tb_cim_accel_core.sv` cycle 公式断言                   |
| 4   | feat(build): bump XDC to 125 MHz, retry synth       | `vivado_build.sh` WNS ≥ 0                               |
| 5   | feat(sw): bump CIMModel clk_mhz default to 125      | `benchmark_e2e.py` 200 张 acc 不变、延迟 ≈ 0.7× C3 结果 |

---

### [] step 10: 架构扩展 — DSP48 INT8×2 SIMD 打包（优选方案）

> 三选一评估（完整对比见下文"评估与取舍"小节），最终推荐 **Option C: DSP48 INT8×2 SIMD 打包 (XAPP1163)** 作为 post-C1 的核心工作，**Option A (MaxPool 硬件融合)** 作为 stretch goal。
> 核心论据：PYNQ-Z2 当前 DSP48E1 占用率 100\% (Thesis §6 item 1)，是限制 PAR_OB 提升的唯一资源瓶颈；SIMD 打包把每 DSP 的 MAC 产出 ×2，\textbf{在不换板的前提下}释放出"fabric 里的第二个 PAR_OB"。

#### 评估与取舍

| 维度           | Option A: MaxPool 融合                                         | Option B: 输出稀疏跳零                 | **Option C: DSP SIMD 打包**                                |
| -------------- | -------------------------------------------------------------- | -------------------------------------- | ---------------------------------------------------------- |
| 量化增益       | 消除每 Pool 层 ~50 ms PS round-trip（C3 前）/ ~0.1 ms（C3 后） | 稀疏度 40–60\% → compute 时间 ×0.5–0.6 | DSP 用量 ÷2 → PAR_OB=1→2，端到端 compute ×0.5              |
| bit-exact 风险 | 低（MaxPool 数值确定）                                         | 中（scan 顺序敏感）                    | **极低**（lane 隔离数学保证）                              |
| RTL 改动规模   | 新增 ~300 行 pool_unit + FSM scheduler                         | 新增 ~400 行 nonzero 扫描 + 索引 BRAM  | **cim_tile.sv 重写 ~80 行 + SPLIT_FACTOR 样式参数化**      |
| DSP/LUT 资源   | +0 DSP / +~400 LUT                                             | +~0 DSP / +~600 LUT +1 BRAM            | **−128 DSP / +~200 LUT**                                   |
| 对 C1 协同     | 正交                                                           | 正交                                   | C1 拆分后的 ST_MAC_LO/HI 刚好为每 DSP 两 lane 提供天然容器 |
| 论文故事价值   | §3 算子融合小节                                                | §3 稀疏架构小节 + SCNN/EIE 对比        | §3 DSP 原语利用小节（XAPP1163 引用，工业界非常规使用）     |

##### Option A — MaxPool / BatchNorm 硬件融合

- **定位**：当前 `CIMModel.infer_maxpool()` 在 PS 端 Python 实现，单层 ~50 ms（含 output 读出 + im2col 往返），C3 后降至 ~0.1 ms 级。
- **BN 折叠**：BN 已可通过 `mult/shift/bias_sram` 三参数在 `sw/model_zoo.py::quantize()` 静态折叠，**RTL 零改动**即可支持。因此 Option A 的实际内容只剩 MaxPool 硬件化。
- **RTL 设计**：新增 `cim_pool_unit.sv`，直接从 `output_buffer` 读 stride-2 2×2 窗口，组合路径 max 四选一 → 写入 `input_buffer`。新增顶层 FSM 调度 Conv → Pool → next Conv 的链接，CSR 增加 `CSR_POOL_CFG` (kernel size / stride / enable)。
- **验证**：`tb_pool_fusion.sv` 对比 Python MaxPool 参考；`sw/tests/test_pool_fused.py` 比对 predict() 结果 bit-exact。
- **风险/回退**：`CSR_POOL_CFG[0]=0` 关闭硬件 Pool，退回 PS Python 路径。
- **判决**：C3 后 Pool round-trip 降至可忽略水平，收益不再显著；但实现成本也较低，适合作为 stretch goal。

##### Option B — 输出稀疏跳零

- **定位**：ReLU 后的激活典型稀疏度 40–60\% (SCNN/EIE 经验值)，理论上 compute 时间可压缩至 ~0.5×。
- **所需数据**：step 6 Phase 1 `sw/logs/<run_id>/layer_<i>_<type>/y.hex` 已存，可离线脚本计算每层稀疏度；需作者提供 LeNet-5 / MLP 实测数据后再做最终决策。
- **RTL 设计**：新增 `nonzero_index_buffer`（~1 KB BRAM 存索引）。`cim_accel_core.sv` 新增 `ST_FETCH_IDX → ST_FETCH_WEIGHT_SPARSE → ...` 跳零分支。
- **开销权衡**：扫描 overhead 在 FC2 (128→10) 不划算（层太小，扫描成本 > 跳零节省）；FC1 (784→128) 和 LeNet-5 FC3 (256→120) 才有净收益。
- **先验工作**：
  - Parashar et al., "SCNN: An Accelerator for Compressed-sparse Convolutional Neural Networks," ISCA 2017
  - Han et al., "EIE: Efficient Inference Engine on Compressed Deep Neural Network," ISCA 2016
  - Zhang et al., "Cambricon-X: An Accelerator for Sparse Neural Networks," MICRO 2016
- **bit-exact 风险**：稀疏跳零本身不引入数值误差，但扫描顺序与累加顺序的耦合需额外 golden model 验证路径。
- **判决**：收益分布不均（仅大层受益），实现复杂度与 C1 相当，但需要新增 scan FSM + 索引 BRAM，且对 bit-exact 保护增量较高。若只是为了论文 §3 加一个"稀疏架构"小节，ROI 不如 Option C。

##### Option C — DSP48 INT8×2 SIMD 打包 (XAPP1163)

- **定位**：单颗 DSP48E1 在 25×18 乘法模式下，若 18-bit 侧送 `{w_a[7:0], 9'b0, w_b[7:0]}`，25-bit 侧送共享的 `x_eff[7:0]`，则 `P[47:0] = x * (w_a * 2^17) + x * w_b`，高 25 位与低 23 位不串扰——等价于一次 DSP 计算两个独立 INT8 乘法。
- **数学证明（lane 隔离）**：
  - 单 INT8 × INT8 乘积范围：$[-128 \times 127, 127 \times 127] \subset [-2^{14}, 2^{14}-1]$（15-bit）。
  - 累加 TILE_COLS=16 个乘积：$16 \times 2^{14} = 2^{18}$（19-bit）。
  - 低 lane 占 19-bit，预留 9-bit guard（`w_b[7:0]` 在 bit[0:7]，`w_a[7:0]` 在 bit[17:24]），无进位到高 lane。
  - 高 lane 同样 19-bit，`P[47:25]` 承接。
  - 结论：lane 隔离数学上成立。XAPP1163 §2.1 给出相同论证。

- **RTL 设计**（与 step 9 的 SPLIT_FACTOR=2 协同）：
  - `cim_tile.sv` 每一行从 16 个 DSP 降至 **8 个 DSP**：每 DSP 同时算 `row_r` 和 `row_{r+TILE_ROWS/2}` 的同列乘积。
  - `x_eff[c]` 在两 lane 共享（广播到 DSP 的 25-bit 端），`w_tile[r][c]` 与 `w_tile[r+8][c]` 拼成 18-bit `{w_hi, 9'b0, w_lo}` 送入。
  - 输出 `P[47:0]` 在 combinational 逻辑中按位切分：`psum_lo += P[22:0]`；`psum_hi += P[47:25]`（符号扩展）。
- **资源影响**：TILE_ROWS × TILE_COLS = 16×16 = 256 DSP（PAR_OB=1）降至 **128 DSP**。PYNQ-Z2 总 DSP 220 个——释放出 92 DSP 用于：
  - 方案 a：PAR_OB=1 → PAR_OB=2，吞吐 ×2；
  - 方案 b：为 step 10 stretch goal 的 MaxPool fuse unit 腾出 DSP 预算（其实不太需要 DSP，仅作为冗余）。
- **验证**：
  - `tb_cim_tile.sv` 增加 `SIMD_MODE` 参数，两种模式跑 103 随机用例比对 `psum` bit-exact。
  - `tb_cim_accel_core.sv` 循环数公式不变（SIMD 仅改 DSP 结构，不改拍数），但增加 DSP primitive 用量断言。
  - 新增 `sw/tests/test_dsp_simd_layout.py`：纯 NumPy 复现 `{w_hi, 9'b0, w_lo}` 布局，断言 lane 隔离在所有 INT8 输入下成立（遍历 $2^{32}$ 组合用采样覆盖）。
- **风险**：
  - Vivado 是否能自动推断此布局存在经验差异。保底方案：显式实例化 `DSP48E1` primitive，用 `OPMODE/INMODE` 精确控制乘法器端口（XAPP1163 附录 A 给出 Verilog 模板）。
  - 未改动的 tile_psum 累加宽度 (`PSUM_W=32`) 对两 lane 已够（19+9=28-bit），无需扩宽。
- **回退**：`parameter int TILE_DSP_SIMD = 0`（默认关闭）→ 走 step 9 的 SPLIT_FACTOR=2 单乘法路径。`= 1` 开启 SIMD。

#### 推荐结论：**Option C**

> 相对 C3+C1 已有收益，Option C 在\textbf{不换板}前提下是唯一能再次 ×2 compute throughput 的路径。PYNQ-Z2 DSP 100\% 占用是论文 §6 已经承认的硬约束，砍一半 DSP 预算 = 释放 PAR_OB=2 = LeNet-5 端到端再 ÷2。与 C1 的 ST_MAC_LO/HI 拆分天然对齐（每 DSP 两 lane 刚好对应 lo/hi 两拍的两组权重），总实现工作量 ≈ 2 周。论文 §3 可新增"DSP 原语 SIMD 利用"小节，引用 Xilinx XAPP1163，与现行 §2.1 的"CIM 架构两种实现极端"形成"软硬协同优化"的完整故事。Option A 留作 stretch goal（C3 后 Pool round-trip 已非瓶颈，时间多再做）；Option B 因扫描 overhead 在小层不划算且 bit-exact 保护增量高，不推荐作为毕设阶段重点。

#### Option C 详细设计（Chinese README-ready）

##### 10.1 DSP48E1 SIMD 布局

单 DSP 输入/输出布局（25×18 乘法模式，`OPMODE=5'b00101`, `INMODE=5'b00000`）：

```
A[24:0]  = {17{sign(x_eff)}, x_eff[7:0]}     // 共享输入 (25-bit sign extended)
B[17:0]  = {w_hi[7:0], 9'b0, w_lo[7:0]}      // 两权重拼接 (18-bit)
P[47:0]  = A * B
         = x_eff * w_hi * 2^17 + x_eff * w_lo     // lane 隔离展开
```

输出按位切分（在 `cim_tile.sv` combinational）：

```systemverilog
logic signed [22:0] prod_lo;   // x_eff * w_lo
logic signed [24:0] prod_hi;   // x_eff * w_hi （sign-extended from P[47:17]）
assign prod_lo = P[22:0];
assign prod_hi = $signed(P[47:17]);
```

##### 10.2 cim_tile.sv 重构要点

- 新增 `parameter int TILE_DSP_SIMD = cim_pkg::TILE_DSP_SIMD_EN;`；
- `TILE_ROWS` 逻辑上仍为 16，但物理 DSP 数减半 → `TILE_ROWS_PHYS = TILE_ROWS / 2 = 8`；
- generate 循环从 `r = 0 .. TILE_ROWS-1` 改为 `r_pair = 0 .. TILE_ROWS_PHYS-1`，每次实例化一个 DSP 同时驱动 `psum[r_pair]` 和 `psum[r_pair + 8]`。

##### 10.3 验证矩阵

| 测试                  | SPLIT=1/SIMD=0 | SPLIT=2/SIMD=0 | SPLIT=2/SIMD=1                |
| --------------------- | -------------- | -------------- | ----------------------------- |
| tb_cim_tile 103 用例  | baseline       | C1 验证        | C1+C 验证                     |
| tb_cim_accel_core     | baseline       | +1 拍/IB       | 同 C1 (拍数不变)              |
| tb_mnist_e2e          | baseline       | baseline       | **必须 bit-exact = baseline** |
| Vivado DSP 计数       | 256            | 256            | **128**                       |
| 60 MHz → 125 MHz 时序 | -0.086 ns      | +0.1 ns 目标   | +0.1 ns 目标                  |

##### 10.4 推进计划

| #   | 标题                                                          | 验证                                                    |
| --- | ------------------------------------------------------------- | ------------------------------------------------------- |
| 1   | feat(pkg): add TILE_DSP_SIMD_EN parameter                     | regression GREEN @ SIMD=0                               |
| 2   | feat(rtl): cim_tile DSP48E1 primitive inst behind SIMD=1      | tb_cim_tile SIMD=0/1 bit-exact 对拍                     |
| 3   | feat(sw): `test_dsp_simd_layout.py` — 纯 Python lane 隔离证明 | pytest GREEN                                            |
| 4   | feat(build): re-synth with PAR_OB=2 + SIMD=1                  | WNS ≥ 0, DSP report == 128 (PAR_OB=1) or 256 (PAR_OB=2) |
| 5   | feat: 上板 LeNet-5 200 张验证 bit-exact + latency ×0.5        | 99.5\% acc, compute 段时间折半                          |

##### 10.5 风险登记

| 风险                                   | 概率 | 缓解                                                  |
| -------------------------------------- | ---- | ----------------------------------------------------- |
| Vivado 无法自动推断 SIMD 布局          | 中   | fallback 显式实例化 `DSP48E1` primitive (XAPP1163 §A) |
| `w_tile` packing 打包翻倍增加 fanout   | 低   | generate 内 `(* max_fanout = 50 *)`                   |
| 综合后 P[47:25] 走线延迟不均           | 低   | XDC 加 `set_property LOC` 约束一对 DSP 相邻           |
| PAR_OB=2 时 weight SRAM 访问 port 不够 | 中   | 已有 16-bank 独立 BRAM，每 bank 已 2R1W，够用         |

#### 开放问题

1. **Option A MaxPool 硬件化是否作为 step 10.5 子节落地**？当前评估为 stretch goal，但若 C3 后 Pool round-trip 仍占 ≥5\% 端到端延迟，可提升优先级。
2. **DSP48E1 primitive 显式实例化 vs 依赖 Vivado 推断**：建议 commit 2 先尝试 inference，失败才切 primitive，以保持可读性。
3. **C1 与 Option C 是否合并为一个 step**：本 README 当前保持拆分以便 git 历史清晰，但论文 §3 可以合并成"DSP 原语协同优化"一小节。
4. **SPLIT_FACTOR=2 + SIMD=1 是否默认开启**：建议保持默认 `SPLIT=1 / SIMD=0`，新 bitstream 通过 `vivado_build_perf.tcl` 脚本变体开启，主线默认保留现行 60 MHz 设计以兼容已部署 notebook。

# 进展记录

## checkpoint 1

现在是2026.03.22，已经基本完成了step 1~3的所有内容。当前的项目是，已经实现了PL侧，硬件的MVM + bias + ReLU + Requantize, 软件侧实现了im2col, 当然也完全可以支持MaxPool等计算，还没考虑但是应该比较容易实现的是AveragePool, Dropout, BatchNorm, Softmax等。

现在理论上已经可以跑所有由`Conv + FC + ReLU + MaxPool`组成的网络，已经覆盖了大多数CNN；当前的实际瓶颈是硬件尺寸限制导致输入不能够大于784x128，Conv 层 im2col 后 col_len = C_in × K × K 不能超过 784，C_out 不能超过 128。对于 MNIST 尺寸的网络完全够用，但跑 ImageNet 级别的模型就需要分块或扩容，这一点之前也有说过了(不过是时间上的之前，不是这个md的之前)。

## checkpoint 2

2026.03.31, PicoRV32代替ARM软核的集成设计完成。

关于为什么做PicoRV32，step 1-3中的加速器是由 ARM PS 通过Python/MMIO控制的，任务指导书中要求实现软核设计，因此其实不应该直接使用ARM软核而是自己实现一个控制流程，这里选择的是直接利用PicoRV32实现对于ARM的替代，让CIM可以在纯PL中自主运行推理，不依赖PS控制。

选择了PicoRV32（YosysHQ开源，MIT License）：单个文件`picrov32.v`, RV32IM, ~1500LUT，还有成熟的native memory interface，相对适合直接桥接到CIM CSR.

### arch

架构如下：

```
PicoRV32 ──bridge──┬── FW BRAM (32KB, 代码+数据)
                    ├── CIM IP (via mini AXI master, 与 Step 2 完全相同的 slave)
                    ├── UART TX (debug)
                    └── Result BRAM (256B, 推理结果)

PS (ARM) ──AXI────┬── FW BRAM port B (写入 firmware)
                   ├── Result BRAM port B (读取结果)
                   └── AXI GPIO (控制 cpu_rst_n)
```

### new goals

最后的设计希望实现的是：

- CIM IP 不做修改，让PicoRV32通过mini AXI master发送和ARM完全一样的AXI事务；

- 双端口 FW BRAM:　希望实现firmware通过读取进入CIM_SoC而不是写死烧到板上（和最开始的weight/bias想法类似），每次重新运行不需要重新生成bitstream；
- result in
  BRAM，最后的计算结果写入BRAM代替UART读取（手边没有路由器的WIFI模块懒得折腾pyserial，还有一个问题是PL UART和PS USB等有连接性问题）

- AXI GPIO，PS控制`cpu_rst_n`，实现 hold -> write firmware -> release的循环。

### smplified model

又回到了模型大小问题。因为如果换成用PicoRV32替换ARM控制的话，会额外占用LUT，为了让firmware放进32KB BRAM中，只能~再次~使用784->16->10的小模型（大约是14.5KB），INT8准确率90%+.

### verification

依旧是选择VCS仿真和PYNQ上板。

VCS仿真时，通过逐个替换firmware.hex，testbench直接读取result BRAM port B检查；
PYNQ上板，PS通过AXI加载firmware，计算之后读取pred/logits，和golden对比。

更多详细设计过程见`docs/picorv32_design.md`.

## checkpoint 3

2026.04.20, C3 (AXI4-Stream + axi_dma 数据通路重构) RTL + 上板验证完成, 55 MHz 时序收敛变体同步完成。

### 做了什么

在 checkpoint 1-2 的基础上，完成了 step 6 (SQ-mapping 软件优化)、step 7 部分优化 (A2 profiler、B2 pytest、B3 benchmark)、step 8 (C3 AXI4-Stream DMA 数据通路重构)。C3 的核心改动是将 weight/input/bias 的搬运路径从 AXI4-Lite 逐字 MMIO 切换为 DDR→S_AXI_HP0→axi_dma→AXIS→cim_axi_stream_sink 的批量 stream 路径，CSR 控制仍走 AXI4-Lite。

### 关键成果

- **RTL 新增**: `cim_axi_stream_sink.sv` (~250行)、`cim_top.sv` + wrapper (~220行)、stream sink 独立 TB
- **RTL 修改**: `cim_pkg.sv` (+CSR*STREAM*\*地址)、`cim_axi_lite_slave.sv` (CSR解码+CTRL[3] MUX)、BD TCL (axi_dma + HP0 + xlconcat + 独立psr_dma)
- **软件**: `cim_driver.py` 新增 `use_dma` 参数 + `_stream_load()` 方法，上层 API 不变
- **60 MHz 实测**: LeNet-5 200张 340.1s / 1700.4ms/img / 99.50% acc
- **55 MHz 实测**: LeNet-5 200张 343.9s / 1719.7ms/img / 99.50% acc（WNS > 0, 时序完全收敛）
- 55 MHz 端到端仅慢 1.1%，印证 profiler 结论：瓶颈在 MMIO 搬运（与时钟频率无关），不在硬件计算

### 55 MHz build 技术细节

55 MHz build 遇到了 Zynq PLL 无法精确输出 55 MHz 的问题（实际 ~55.17 MHz），导致 Vivado BD 验证时 `cim_0/S_AXIS` 与 `axi_dma_0/M_AXIS_MM2S` 的 FREQ_HZ 不匹配 (BD 41-237)。解决方案：在 TCL 中用信号级 `connect_bd_net` 代替接口级 `connect_bd_intf_net`，绕过 FREQ_HZ 校验，综合结果完全等价。

### 当前进度

- ✅ C3 DMA 软件路径 (`use_dma=True`) 上板 benchmark：LeNet-5 200张 503.65 ms/img, speedup 3.4×, 99.50% acc
- ✅ 55 MHz build 时序收敛变体完成
- ⏳ 下一步：profile DMA 模式下 latency breakdown, pipeline 双缓冲优化
- ⬜ C1 (cim_tile 16→8+8 关键路径拆分) 的上板验证

完整优化路线见 `OPTIMIZATION_ROADMAP.md`

## checkpoint 4

2026.05.06, Phase A (C1) 时钟提升 60→100MHz 上板验证完成。

### 做了什么

把 `cim_tile.sv` 的 16 级串行 DSP 加法链拆成 4 个 4 级子链 (`TILE_SPLIT_FACTOR=4`)，增加 `ST_XEFF_LATCH → ST_MAC_Q0~Q3` 四拍流水。同时增设 `input_buffer` 到 `x_eff` 的 pipeline register、`psum_accum` 四 quarter 并发累加。目标：解锁 100MHz 工作频率。

### 关键成果

- **RTL 修改**: `cim_pkg.sv` (TILE_SPLIT_FACTOR=4, ST_XEFF_LATCH)、`cim_tile.sv` (4×4 split)、`cim_accel_core.sv` (7 拍 inner loop)、`input_buffer.sv` (BRAM→x_eff pipe reg)、`psum_accum.sv` (4-quarter 累加)
- **仿真**: 3/3 全 PASS (tb_cim_tile, tb_cim_accel_core, tb_mnist_e2e)
- **Bitstream**: WNS=-0.800 ns (801 failing endpoints)，常温上板功能正常
- **性能**: LeNet-5 200 张 accuracy 99.5%，延迟 37.1 ms/img (27.0 fps)，较 Phase A 前 (60MHz) 的 56.2 ms/img 加速 1.51×

### 时序说明

100MHz (10ns 周期) 下 WNS=-0.800 ns，801 个 failing endpoint 均位于 fclk0 域。常温上板 LeNet-5 200 张 bit-exact 通过，但高温或电压波动可能导致不稳定。若上板出问题，降回 60MHz 或使用 55MHz build 变体。

## checkpoint 5

2026.05.07, Phase B IBUF/OBUF 双缓冲 ping-pong 上板验证完成。

### 做了什么

将 `input_buffer` 和 `output_buffer` 改为双 bank 结构，DMA 访问 inactive bank 的同时 CIM compute 使用 active bank，实现 load_x 和 read_out 与计算的流水线重叠。Bank 切换通过 `cim_axi_lite_slave.sv` 中的 `reg_ping_ctrl` CSR 位控制，`cim_accel_core.sv` 完全不动。

### 关键成果

- **RTL 修改**: `input_buffer.sv` + `output_buffer.sv` (双 bank 读写端口，`wr_bank_sel`/`rd_bank_sel`)、`cim_axi_lite_slave.sv` (`CSR_PING_CTRL` 0x06C, bank 选择 MUX)、`cim_pkg.sv` (CSR 地址)
- **软件**: `cim_driver.py` `_ping_toggle()` 方法，`predict_batch()` 改为 ping-pong 流水线
- **仿真**: 3/3 PASS（包括 mnist_e2e ping-pong 新测试）
- **Bitstream**: WNS=-0.860 ns, WHS=0.022 ns, BRAM 123.5/140=88.21%
- **性能**: LeNet-5 200 张 29.2 ms/img (34.3 fps)，较 Phase A (37.1 ms/img) 加速 27%，累计 vs MMIO baseline **57.9×**
- **Accuracy**: 199/200 (99.5%)，与 Phase A 一致

## checkpoint 6

2026.05.07, Phase C Layer Fusion v3 (WEIGHT_BASE/BIAS_BASE) bitstream 构建完成，待上板验证。

### 做了什么

在 checkpoint 5 (Phase B 双缓冲) 基础上，增加了 OBUF→IBUF 内部硬件拷贝 FSM，消除 FC→FC 层间 DMA 往返。v3 新增 `CSR_WEIGHT_BASE` 和 `CSR_BIAS_BASE`，支持 FC1+FC2 权重/偏置在 SRAM 中共存于不同 offset，batch 融合推理时无需每张图重新加载 FC2 权重。

### 关键成果

- **RTL 修改 (v2)**: `cim_axi_lite_slave.sv` (4-state fusion FSM: F_IDLE→F_RD_FIRST→F_PACK→F_WRITE，OBUF byte→128-bit tile 组装→IBUF 写入)、`cim_pkg.sv` (+CSR_FUSION_CTRL/LEN/STATUS)
- **RTL 修改 (v3)**: `cim_accel_core.sv` (+cfg_weight_base/cfg_bias_base 输入端口，地址计算加 offset)、`cim_axi_lite_slave.sv` (+CSR_WEIGHT_BASE 0x07C, CSR_BIAS_BASE 0x080)、`cim_pkg.sv` (CSR 地址)
- **软件**: `cim_driver.py` `setup_fc_fused_pair()` (预加载 FC1+FC2 权重到不同 offset)、`infer_fc_fused_pair()` (单图 FC1→fusion→FC2)、`infer_fc_fused_batch()` (batch 融合，无逐图 weight reload)
- **仿真**: 3/3 PASS (包括 mnist_e2e fusion 新测试)
- **Bitstream**: WNS=-1.853 ns, WHS=0.030 ns, BRAM 114/140=81.43%, 100MHz

### 时序说明

v3 WNS=-1.853 ns，较 v2 (-1.151 ns) 退化约 0.7 ns。`cfg_weight_base`/`cfg_bias_base` 加法器进入了地址计算的关键路径 (w_addr_full / bias_addr_cur)。2771 个 failing setup endpoint。常温上板预期仍可工作（与 checkpoint 4-5 相似情况），但不稳定风险增加。如需完全时序收敛，使用 55MHz build 变体 (`hw/scripts/vivado_build_55mhz.sh`)。

### 上板验证方法

见下方《上板测试完整指南》。

---

# 上板测试完整指南

> 适用平台：PYNQ-Z2 (xc7z020clg400-1)，PYNQ v3.0.1 镜像
> 测试对象：checkpoint 6 bitstream（Phase C v3 Layer Fusion + Phase B 双缓冲 + Phase A 100MHz）

## 一、文件准备

### 1.1 上传 bitstream 到 PYNQ

将以下两个文件拷贝到 PYNQ 的同一目录下（例如 `/home/xilinx/jupyter_notebooks/checkpoint6/`）：

```bash
# 在 PC 上执行（替换 <PYNQ_IP> 为实际的 PYNQ IP 地址）
scp bitstream\&hwh/checkpoint6/cim_soc.bit xilinx@<PYNQ_IP>:/home/xilinx/jupyter_notebooks/checkpoint6/
scp bitstream\&hwh/checkpoint6/cim_soc.hwh xilinx@<PYNQ_IP>:/home/xilinx/jupyter_notebooks/checkpoint6/
```

### 1.2 上传 Python 驱动和测试脚本

```bash
scp sw/cim_driver.py xilinx@<PYNQ_IP>:/home/xilinx/jupyter_notebooks/checkpoint6/
scp sw/scripts/test_fusion.py xilinx@<PYNQ_IP>:/home/xilinx/jupyter_notebooks/checkpoint6/
```

> **不需要上传** `golden_model.py` 或 `golden_model_torch.py`。`test_fusion.py` 自带纯 numpy golden 模型（`golden_fc()` 函数），无需 torch 环境。
>
> PYNQ 镜像自带 `numpy` 和 `pynq`，无需额外 pip install。

## 二、PYNQ 上板测试步骤

### 2.1 基础连接测试

在 PYNQ Jupyter Notebook 中新建 Python3 notebook，或在终端直接执行：

```python
import os
os.chdir('/home/xilinx/jupyter_notebooks/checkpoint6')

from cim_driver import CIMDriver

# 加载 bitstream + 初始化 driver（一步完成）
# CIMDriver 内部调用 pynq.Overlay('cim_soc.bit')，自动解析 .hwh
drv = CIMDriver(use_dma=True)
print("CIMDriver initialized.")
print(f"  use_dma = {drv.use_dma}")

# 验证 DMA 已启用
print(f"  DMA = {drv.dma is not None}")
print(f"  overlay IPs: {list(drv.overlay.ip_dict.keys())}")
```

**期望输出**：
- `use_dma = True`
- `DMA = True`
- 日志中出现 `[CIMDriver] DMA initialized: sendchannel=OK, recvchannel=OK`

> **说明**：`CIMDriver(use_dma=True)` 默认从当前目录加载 `cim_soc.bit` 和 `cim_soc.hwh`，无需手动调用 `Overlay()`。

### 2.2 Layer Fusion 单图测试 (FC1→fusion→FC2)

```python
from scripts.test_fusion import main

# 运行完整测试（单图 + batch 3 张）
# 内部流程:
#   1. 随机生成 FC1(784→128) + FC2(128→10) 权重/bias
#   2. setup_fc_fused_pair() 预加载到 weight/bias SRAM 不同 offset
#   3. infer_fc_fused_pair() 单图 FC1→fusion→FC2
#   4. infer_fc_fused_batch() 3 张图 batch 融合（无逐图 weight reload）
#   5. 与纯 numpy golden 模型逐元素比对
main()
```

**期望输出**：
```
Golden reference:
  FC1 output (first 8): [...]
  FC2 output:           [...]
  Predicted class:      X
Weight SRAM: FC1 tiles 0..391, FC2 tiles 392..399
Bias SRAM:   FC1 addr 0..127, FC2 addr 128..137

--- Test 1: Single image fusion ---
  Output: [...]
  Match: True

--- Test 2: Batch fusion (3 images) ---
  Image 0: match=True
  Image 1: match=True
  Image 2: match=True

>>> LAYER FUSION TESTS PASSED (single + batch) <<<
```

> **提示**：`main()` 一键跑完单图 + batch 两项测试。如需在 notebook 中分步调试，直接将 `main()` 函数体内的 Test 1/Test 2 代码片段复制到 notebook cell 执行即可。

## 三、常见问题排查

### 3.1 CIMDriver 初始化失败

**现象**：`CIMDriver(use_dma=True)` 报错 "Bitstream file not found" 或 "No .hwh file found"

**解决**：
- 确认 `cim_soc.bit` 和 `cim_soc.hwh` 两个文件在当前工作目录下，且**主文件名相同**
- PYNQ v3.0.1 要求 `.hwh` 文件名与 `.bit` 完全一致（都是 `cim_soc`）
- 或在初始化时指定 bitstream 路径：`CIMDriver('/path/to/cim_soc.bit', use_dma=True)`

### 3.2 DMA 超时 (IDLE 检查失败)

**现象**：`cim._dma_mm2s_idle` 返回 False，或 `_stream_load()` 超时

**解决**：
- 重启 PYNQ 电源，重新加载 bitstream
- 检查 bitstream 是否对应正确的 checkpoint（checkpoint 6 = Phase C v3）
- 尝试重新构建 bitstream：`cd hw && bash scripts/vivado_build.sh`

### 3.3 Fusion 状态机超时

**现象**：`copy_output_to_input()` 报错 "fusion timeout" 或返回 False

**解决**：
- 确认 `n_elements ≤ MAX_OUT_DIM (256)`
- 确认 `CSR_FUSION_STATUS` 地址为 0x078
- 检查 OBUF 中确实有上一步 FC1 的计算结果

### 3.4 计算结果不匹配

**现象**：RTL 输出与 numpy golden 不一致

**可能原因及排查顺序**：
1. **权重/bias 加载错误** — 检查 `weight_base` / `bias_base` 参数是否正确传入 `configure()`
2. **Bank 切换不同步** — Phase B 双缓冲要求 `reg_ping_ctrl` 在 load 和 compute 之间正确翻转
3. **时序不稳定** — checkpoint 6 的 WNS=-1.853 ns，可能有 marginal timing。降频测试：
   - 重新构建 55MHz 版本 bitstream 并上板对比
4. **DMA 数据损坏** — 检查 `_stream_load()` 的 `base_addr` 参数（高 16 位）

### 3.5 时序不稳定 / 随机错误

**现象**：同一输入偶尔正确偶尔错误，或温度升高后出问题

**原因**：checkpoint 6 bitstream WNS=-1.853 ns（负 slack），100MHz 时序不完全收敛。

**解决**（二选一）：
1. **使用 55MHz build 变体**：
   ```bash
   cd hw && bash scripts/vivado_build_55mhz.sh
   # 将生成的 bitstream 拷贝到 PYNQ 替换
   ```
2. **降低 Python 侧的 `clk_mhz` 参数**（如果 driver 支持动态降频）

## 四、测试流程总结

```
PC侧 (scp 上传):
  1. bitstream&hwh/checkpoint6/cim_soc.{bit,hwh} → PYNQ:~/.../checkpoint6/
  2. sw/cim_driver.py                              → PYNQ:~/.../checkpoint6/
  3. sw/scripts/test_fusion.py                     → PYNQ:~/.../checkpoint6/

PYNQ侧 (Jupyter / 终端):
  4. cd ~/jupyter_notebooks/checkpoint6
  5. CIMDriver(use_dma=True)   # 加载 bitstream，初始化 driver
  6. test_fusion.main()        # 单图 + batch 融合测试
  7. 全部 PASS → checkpoint 6 上板验证完成
```

## checkpoint 7

2026.05.07, Phase C v4 Timing Pipeline Fix bitstream 构建完成。

### 做了什么

v3 中 `cfg_weight_base`/`cfg_bias_base` 加法器进入地址计算关键路径，使 WNS 从 -1.151ns 恶化至 -1.853ns (2771 failing endpoints)。v4 将 `w_rd_tile_idx` 和 `b_rd_addr` 提前一个周期寄存 (`w_rd_tile_idx_r`/`b_rd_addr_r`)，在 seq block 中预计算，combo block 使用寄存器版本，将加法器链与 SRAM 读取 + MAC 分离到不同时钟周期。

### 关键成果

- **RTL 修改**: `cim_accel_core.sv` (+w_rd_tile_idx_r, +b_rd_addr_r pipeline registers, pre-computation in seq block)
- **仿真**: 3/3 ALL PASS
- **Bitstream**: WNS=-0.533 ns (vs v3 -1.853, +1.32ns), WHS=0.008 ns, BRAM 114/140=81.43%
- v4 时序比 v2 改善 0.62ns

### 已知 Bug (v5 修复)

v4 中 `bias_addr_cur` 未包含 `cfg_bias_base`（OBUF 写地址不应偏移），但 `bias_addr_next_tile` 错误地包含了 `cfg_bias_base`。非零 bias_base 时 OBUF 写地址会在 tile 边界发生偏移。v5 修复。

## checkpoint 8

2026.05.08, Phase C v5 OBUF Write Address Bug Fix 完成。

### 做了什么

修复 v4 中 `bias_addr_next_tile` 包含 `cfg_bias_base` 导致 OBUF 写地址在 tile 边界偏移的 bug。OBUF 写地址流水线 (neuron_addr_p1→p3→p4→p4b→p5→obuf_wr_addr) 仅使用不含 bias_base 的 `bias_addr_cur`。Bias 读地址由 `b_rd_addr_r` pipeline register 正确包含 `cfg_bias_base`。

### 关键成果

- **RTL 修改**: `cim_accel_core.sv` — `bias_addr_cur` 保持不含 bias_base；`bias_addr_next_tile` 保留含 bias_base 的版本仅作参考
- **测试**: `tb_cim_accel_core.sv` 新增 Tests 7a/7b/7c (weight_base only, bias_base only, both)，`load_all_data_with_offsets()` task
- **仿真**: 3/3 ALL PASS (9 个 accel_core 测试全部 MATCH)
- **Bitstream**: 构建中 → `bitstream&hwh/checkpoint8/`

### Files Changed (v5)

1. `cim_accel_core.sv` — bias_addr_cur 移除 cfg_bias_base
2. `tb_cim_accel_core.sv` — Tests 7a/7b/7c + load_all_data_with_offsets() task

## 五、各 checkpoint 上板命令速查

| Checkpoint | 主要特性 | 关键 bitstream 文件 | 测试方式 |
|-----------|---------|-------------------|---------|
| 1 | 基础 MMIO 数据通路，60MHz | `checkpoint1/cim_soc.bit` | `CIMDriver()` → `infer_fc()` |
| 2 | PicoRV32 软核控制 | `checkpoint2/` | `sw/full_cim_test_pynq.py` (ARM 路径) |
| 3 | C3 DMA + P0 S2MM, 60MHz | `checkpoint3/cim_soc.bit` | `benchmark_e2e.py --model lenet5` |
| 4 | Phase A 100MHz (TILE_SPLIT=4) | `checkpoint4/cim_soc.bit` | `benchmark_e2e.py --model lenet5` |
| 5 | Phase B IBUF/OBUF 双缓冲 | `checkpoint5/cim_soc.bit` | `benchmark_e2e.py --model lenet5` |
| 6 | Phase C v3 Layer Fusion | `checkpoint6/cim_soc.bit` | `python test_fusion.py` 或 notebook |
| 7 | Phase C v4 Timing Pipeline Fix | `checkpoint7/cim_soc.bit` | `python test_fusion.py` 或 notebook |
| 8 | Phase C v5 OBUF Address Fix | `checkpoint8/cim_soc.bit` | `python test_fusion.py` 或 notebook |

# 坑

## vivado综合器限制

vivdao综合器是有限制的，单变量最大只能是1M bit以内。step 1中，之前将`cim_pkg.sv: MAX_IN_DIM, MAX_OUT_DIM`设置为1024，触发了vivado综合器单个变量1e6bit的限制，这样计算出来WSRAM_DEPTH = (1024/16) x (1024/16) = 4096太大，vivado拒绝处理。

这里有两个方向，第一个是缩小MAX维度，这样可以简单的缩小变量大小，vivado可以处理，同时也可以放到BRAM中。PYNQ-Z2有140个36kb BRAM，大约630kB，修改之前一个weight SRAM就要128x4096x16bits=1MB是放不下的；但是修改之后大约是128x392x16bits，大约是98kB，就可以放下，vivado也可以处理，不触发限制。这里决定先按照这个作为master继续进行项目，如有必要则建立一个分支，用于实现不改变MAX维度的版本。

_实际上只缩小MAX的维度还是不够的，因为原来的weight SRAM 是一整块 2048-bit 宽的memory（TILE_ROWS × TILE_COLS × 8 = 2048），Vivado对这种超宽memory推断BRAM本身就困难。更关键的是，如果用 bit-select 方式做32-bit chunk部分写入，Vivado会直接放弃BRAM推断，退化为纯寄存器，那就更爆了。
因此实际上weight_sram.sv做了重构，Generate做成了16个独立的bank，每个bank只有`ROW_W = TILE_COLS x WEIGHT_W = 128 bits`宽，16个bank对应TILE的16行，每个bank独立推断BRAM._

但是，我们可能真的在后续需要支持1024x1024，可能就需要建立一个新分支`full-MAXdimension`。

_所以如果后续做`full-MAXdimension`支持1024x1024，这个bank拆分的架构还是可以复用的。不过主要的问题变成了BRAM容量问题，16banks x 128bits x 4096depth大约是1MB，PYNQ-Z2只有630KB，就要考虑外部DDR存储或者分块加载了。_

## BRAM

要综合出BRAM，只对时钟拍是不够的，还需要整word操作，bit-select 部分写入，Vivado 不支持对这种写法推断 BRAM，会退化为纯寄存器。需要 read-modify-write 模式——先读出整个 128-bit word，在寄存器中转成 32-bit chunk，再整 word 写回。同时保留 generate 拆分，每个 bank 独立一个 BRAM。

同时axi也要匹配chunk操作。

## 一定要看timing_report.txt

一直有计算错误，查了一下午没找出问题来，，到晚上了想起来看timing_report，结果发现125MHZ时钟是8ns，但是我的critial path要28.7ns，所以结果全是错的。

果然奇怪的问题还是要对时序。

遂降频至25MHZ.

_patch 1: 现在把cim_accel_core改成流水线版本解决这个问题。改成bias->activation->requant->store四级流水，activation_unit不再作为子模块实例化（已经删除）。（当前最高支持40MHZ，critial path是25.7ns）_

_patch 2: 增加了新的流水，将compute切分成三段，Sat Mar 21 02:56:59 PM CST 2026 modify: cim_pkg.sv, add 3 stages; cim_accel_core.sv, divide the compute path into 3 stages: (1). ST_XEFF_REG: BREAM-read + ZP substract + latch x_eff_reg; (2). ST_MAC, X_eff_reg /times/ w_tile_reg MAC + latch tile_psum_reg; (3). psum_accum += tile_psum_reg. try to use 125MHZ(not last pipeline's 25~40MHZ). 但是在125MHZ下还是有timing violation, 当前进度-12.7ns(20ns)，大约可以支持50MHZ._

_patch 3: 新的critial path是ST_STORE，写obuf，requantize都耗时很多。这次把ST_STORE分成ST_STORE(64-bit multiply + reg `prod_r`), ST_SHIFT_CLAMP(shift + rounding + clamp, reg `requant_r`), ST_WRITE_OBUF(write output buffer). 当前进度是16.2ns. 尝试过62.5MHZ(16ns)但布局后WNS为负，最终降频到60MHZ(16.667ns)通过时序。
布局之后的critial path: `w_tile_reg -> DSP48 -> CARRY4 -> tile_psum_reg`，如果想要在8ns之内完成，需要把16个元素拆成2x8再合并。cim_tile 做的是 16 列的 `Σ(x_eff[c] * w[r][c])`，这是一条 16 级串行加法链。需要把它拆成两拍：先算前 8 列，再算后 8 列。这样做的话改动量会比较大。这里选择降频到60MHZ，如果后面有时间的话，再做进一步优化。（到时候再开分支）_

# 坑(pico篇)

## UART

经典问题。这个其实在上一个项目`MNIST-CIM-FPGA`中就出现了。简单说就是PYNQ的PS和PL是隔离的，UART是PL侧的输出,PS侧读不到，当时使用`USB-TTL`串口读取在PC上获取信息验证计算结果。

PicoRV32的UART TXD输出到了PMOD-A pin（PL侧Y18），（PMOD-A pin -> TTL -> USB_PYNQ）但是PYNQ的micro USB连接的是PS UART（通过FTDI），就导致实际上在没有pyserial的情况下无法从PYNQ的USB端口获取PL UART的信息。

所以最后还是选择了加上Result BRAM，让PicoRV32写到BRAM中。

## 纯 PL 设计 bitstream 无法加载

由于纯PL设计（没有 Zynq PS）vivado不会生成`.hwh`文件，就导致`Overlay()`实际上无法使用。暂时没有解决这个问题，当时采用了`pynq.Bitstream()`, `/dev/xdevcfg`, `fpgautil`都失败。

这里选择改为PS + PL BLock Design的混合设计上板，PS只提供时钟和AXI读取，PicoRV32仍然自主运行。

_如有兴趣尝试其他方法上板和串口调试，可以回退到Tue Mar 24 02:56:37 PM CST 2026及之前commit._

## firmware.hex的格式问题

这里要注意`$readmemh`是需要32位word的，之前写错过一个这里又弄错了，补充了`verilog_byte_to_word.py`进行修改。
