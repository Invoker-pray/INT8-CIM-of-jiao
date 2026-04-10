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
- [] **B2 Pytest 回归**（golden_model + cim_driver 离线）
  `sw/tests/test_golden_bit_exact.py` snapshot-based + `test_quantize_roundtrip.py`。笔记本直接 `pytest sw/tests/` 10 秒。
  _收益_：未来 RTL 重构不会悄悄破坏 bit-exact；论文可写"CI 覆盖率"。
- [x] **B3 多图 batch benchmark 脚本**
  `sw/scripts/benchmark_e2e.py --model lenet5 --n_images 200`，输出表格 (Model / n_img / total_s / ms_per_img / fps / accuracy)，结果保存 `results/benchmark_*.csv`。
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
  **背景**：profiler 实测（A2）显示 Conv1 compute=4.1 ms，但 load_weights ≈250 ms，瓶颈完全在 MMIO 逐字写。LeNet-5 每张图 ~700 ms 用于搬权重，计算本身可忽略不计。A1（软件权重缓存）尝试跳过重复加载，但 weight SRAM 各层共享、后层覆盖前层，多层网络无法使用。根本解决方案是本条 C3：AXI4-Full 突发传输可将 weight load 从 ms 级降到 μs 级，彻底消除搬运瓶颈。
  _收益_：weight load 从 ~700 ms/张 降到 <1 ms，LeNet-5 吞吐理论 **100×+**。
  _风险_：改动最大（需重写 AXI slave、Vivado block design、Python driver 改用 `pynq.lib.dma`）。**不建议毕设阶段动 RTL**，论文"未来工作"章节直接引用 profiler 数据作为动机。

#### Phase D: KV260 专属（与 step 5 合并推进）

- [] **D1 UltraRAM 替代 BRAM 放大权重尺寸**
  UltraScale+ URAM (288 Kb/block vs BRAM 36 Kb) → `MAX_IN_DIM` 从 784 拉到 1024~2048。
- [] **D2 PAR_OB = 4 或 8 真并行**
  KV260 资源充足，吞吐 4-8×。
- [] **D3 200 MHz 目标时序**（配合 C1）
  UltraScale+ 时序容易收敛。
  **三条组合**：凑出论文"跨平台对比表" PYNQ-Z2 (62.5 MHz, PAR=1) vs KV260 (200 MHz, PAR=4)，吞吐/面积/功耗效率全对比。

#### Phase E: 论文素材与工程健康度

- [] **E1 层级 latency timeline 可视化** (matplotlib Gantt)
  从 step 6 Phase 1 dump 出发，画"Figure X: LeNet-5 逐层延迟分布"。
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

_patch 3: 新的critial path是ST_STORE，写obuf，requantize都耗时很多。这次把ST_STORE分成ST_STORE(64-bit multiply + reg `prod_r`), ST_SHIFT_CLAMP(shift + rounding + clamp, reg `requant_r`), ST_WRITE_OBUF(write output buffer). 当前进度是16.2ns. 调整到62.5MHZ可以实现16ns的周期。
布局之后的critial path: `w_tile_reg -> DSP48 -> CARRY4 -> tile_psum_reg`，如果想要在8ns之内完成，需要把16个元素拆成2x8再合并。cim_tile 做的是 16 列的 `Σ(x_eff[c] * w[r][c])`，这是一条 16 级串行加法链。需要把它拆成两拍：先算前 8 列，再算后 8 列。这样做的话改动量会比较大。这里选择降频到62.5MHZ，如果还不行的话再降一点（61.7MHZ或者是60MHZ）线完成任务再说。如果后面有时间的话，再做进一步优化。（到时候再开分支）_

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
