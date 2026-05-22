# 师兄 `cim_wzy` 项目对比与毕设启示

> 位于 `cim_wzy/` 目录下的项目由师兄提供，是一个面向数字 SRAM-CIM 的 NCNN + Chisel/Verilator 协同验证平台。本文记录对该项目的阅读分析，以及它对本毕设 (`hw/` + `sw/` + `picorv32/`) 的启示与可借鉴改进方向。

---

## 1. `cim_wzy` 项目概览

### 1.1 定位
一套 **NCNN + 自研 CIM 阵列协同的 SoC 级验证平台**。工程体量（`user/verilog/` 里 Chisel 生成的 SV 超过 12000 行）和支持的网络（YOLOv3/v3-tiny/v4-tiny、MobileNet-SSD/v2/v3、ShuffleNetV2、ResNet18、SqueezeNet、SimplePose、LH-YOLO …）均明显是研究组多年积累。

### 1.2 目录结构速览

```
cim_wzy/
├── simulation/              # Verilator C++ co-sim
│   ├── csrc/
│   │   ├── config.h         # 全局宏开关 (网络/路径选择/硬件尺度)
│   │   ├── veri.cpp         # main() 入口
│   │   ├── hw/hw_cim.{h,cpp}  # C++ ↔ Vtop DMA 交互封装
│   │   ├── layer/           # NCNN 全套 layer 源码 (convolution/pooling/...)
│   │   └── net/             # 各网络装配入口 (.param/.bin 读入)
│   ├── vsrc_hw/             # Chisel 生成的 SV (供 Verilator 编译)
│   └── models/              # yolov3-tiny-int8.{param,bin} 等
├── user/
│   ├── chisel/              # Chisel 硬件源码 (mainArray / ConV / buffers / AXI / DMA)
│   ├── verilog/             # Chisel → SV 产物 + top_wrapper.v (Vivado 友好)
│   ├── bd/                  # Vivado Block Design
│   └── const/               # 约束
├── vivado_prj/              # Vivado 2021.2 工程 TCL
├── vitis_prj/cim_app/       # 裸机 NCNN app (ARM PS 上跑)
└── model_simulation/        # 独立模型验证 (bit2plane/ifm_buffer 等)
```

### 1.3 软件栈：把完整 NCNN 搬进 Verilator
- `simulation/csrc/layer/` 放着 **NCNN 全套 layer 源码**：convolution / pooling / eltwise / batchnorm / concat / yolov3detectionoutput / ...
- `simulation/csrc/net/` 有 `yolov3_tiny.cpp`、`mobilenetssd.cpp`、`squeezenet.cpp` 等网络装配入口，直接读 `net.param/.bin`。
- `config.h` 宏开关分派三条计算路径：
  - `FORWARD_ON_CPU` — 纯 CPU 推理
  - `FORWARD_ON_NPU` — 所有层走硬件
  - `FORWARD_ON_CIM`（默认）— 只把 Conv 走硬件，Pool/ALU 留给 CPU
- **关键挂钩点**：`layer/convolution.cpp::forward_int8_npu()`（第 542-810 行）。把 ncnn 的 INT8 卷积按 im2col 展开，调用 `hw_cim::weight_update()` / `forward()` 送进 `Vtop`。
- `hw/hw_cim.cpp` 直接操作 Verilator 生成的 `top->io_dma_chX_*` 端口，**主机侧没有真 AXI 主机，DMA 就是 C++ 指针 + `dma_wait()`**。

### 1.4 硬件栈：Chisel 描述的 bit-serial digital CIM

| 层级 | 规模 | 文件 |
|---|---|---|
| `line_cell` | 128 行 × 1 列 bit-cell, `Vout(i) = IN(i) & data(i)` | `chisel/.../mainArray/line_cell.scala` |
| `Array_8x128` | 8 列 cell + `AdderTree` 做 128-row popcount | `mainArray/Array_8x128.scala` |
| `Array` (128×128) | 16 个 `Array_8x128` 拼出 64 个有效列 (`NUM_COL=64`) | `mainArray/Array.scala` |
| `Tile / PE mesh` | `tile_num=2 · tile2pe_num=2 · pe2array_num=2` | `mainArray/Tile.scala` |
| `ConV_8x8` | 8 bit-plane 的 shift-add 状态机，补码符号位修正 | `ConV/ConV_8x8.scala` |

- **存储单元是 1-bit**：`line_cell.scala` 的 `data` 就是一位 `Bool()`，`Vout(i) = IN(i) & data(i)` —— 典型的 **digital SRAM-CIM 的 AND + popcount** 模型。
- **INT8 MVM = 8 次 1-bit popcount + 移位累加**：`ConV_8x8.scala` 是一个 `Current_state` 有限状态机，把输入的 8 个 bit-plane 逐次送进阵列，每次把结果左移对应位数累加（例如第 0 位移 7、第 7 位不移）。权重符号位通过 `d_out_sign_fix = (d_out_sign<<(RESULT_WIDTH+1)) - d_out_sign` 修正为补码表示。
- **总规模**：`2048 × 128 = 262144` 个 1-bit cell；每 8 列对应一个 INT8 数字，一次权重映射可容纳 `512 × 64` 的 INT8 权重矩阵。
- **SQ_MAPPING（关键软件映射优化）**：`convolution.cpp` 第 683 行，当某一层 `maxk*channels < 512` 时，按 `stride_sq = kernel_h*stride_w*channels` 沿对角线把权重复制多份到空闲行，**一次 forward 同时产生多个空间位置的输出**。这是针对 CIM 阵列的 "空间展开 / 权重复制" 优化。
- **双通道 DMA**：`DMA_DATA_WIDTH=128, DMA_CH_WIDTH=2`，权重/输入/输出都走 ch0 + ch1 两路并行。`bit2plane.sv` 在 RTL 内部做 bit-plane 展开，减少软件侧打包开销。
- **流水气泡隐藏**：`PIPELINE_CNT` 为真时，先发起 `get_output` 读空上一次气泡，再让下一次 `forward` 的 DMA 与之重叠 —— 软件侧 double-buffer。

### 1.5 使用方式

```bash
# 仿真
cd cim_wzy/simulation
make all                 # Verilator 编译 + 自动运行，默认 TEST_YOLOV4_TINY
gtkwave wave.vcd         # WAVE_LOG 开着时会生成

# 换网络 / 换算子
# 在 simulation/csrc/config.h 切换宏 (TEST_YOLOV3_TINY / TEST_RESNET18 / ...)

# 上板
# vivado_prj/cim_wzy_project.tcl 构建 bitstream
# vitis_prj/cim_app/ 裸机 NCNN 应用 (支持 ENABLE_SW_INFERENCE_CHECK 做 sw/hw 比对)
```

### 1.6 主要创新点

1. **1-bit SRAM-CIM + bit-serial INT8 全数字架构**：cell 只存 1 位，INT8 精度靠时间维度的 8-step shift-add 拼出来 —— 避开了 DSP48，在 ASIC 下能获得真正的 CIM 面积/功耗收益。
2. **NCNN 当 runtime**：不自己造推理框架，直接"盗用"成熟框架把硬件作为 NPU 后端注入，一次性获得数十个主流目标检测/分类网络支持。
3. **Chisel 参数化 + Verilator co-sim**：`cim_config` trait 定义 tile/pe/array 层级，改参数即可重新 elaborate；`SIM_MODE` 开关让同一份 Chisel 源码既出仿真版本又出 FPGA 版本。
4. **SQ_MAPPING 空间展开**：针对小 `maxk*C_in` 的层，自动把空间滑窗并行化到硬件多列，不浪费 cell。是 CIM 架构少见的软件映射优化。
5. **软硬一致性调试机制**：仿真端 `SIM-MATCH/UNMATCH` 打印、裸机端 `ENABLE_SW_INFERENCE_CHECK`、`log/accmem, ifmbuf, im2col, wgtbuf` 分门别类的 dump 目录，每一级 buffer 的数据都能落盘便于定位。

---

## 2. 与本毕设项目的对比

| 维度 | 本毕设 (`hw/` + `sw/`) | `cim_wzy` |
|---|---|---|
| **CIM 抽象层级** | 逻辑 CIM：`cim_tile.sv` 16×16 INT8×INT8 DSP48 MAC（行为级，一周期算完 MVM 子块） | 真 bit-cell CIM：1-bit AND + popcount + 8 cycle bit-serial shift-add，贴近 SRAM macro |
| **阵列规模** | 16×16 单 tile，`PAR_OB=1~4` | 2·2·2 mesh × 128×128 × 8 bit-plane, 262K cells |
| **参数化方式** | `cim_pkg.sv` SystemVerilog package | Chisel trait + FIRRTL 生成 SV |
| **软件栈** | 手写 `golden_model.py` + `cim_driver.py`，自定义 CSR | NCNN 整个推理栈搬进来 |
| **支持网络** | MNIST MLP 784→128→10 + LeNet-5 | YOLOv3/v4-tiny、MobileNet-SSD、ResNet18、SqueezeNet … |
| **FPGA 目标** | PYNQ-Z2 (7020) | Vivado 2021.2，面向更大器件 |
| **CPU 方案** | ARM PS / PicoRV32 软核 | ARM 裸机 (Vitis) |
| **仿真器** | VCS + SystemVerilog testbench | Verilator + C++ co-sim |
| **卷积映射** | 软件 im2col，硬件只做 MVM | 软件 im2col + SQ_MAPPING 权重复制 |
| **精度流** | 硬件内做 bias + ReLU + requantize | 硬件只出 INT32 部分积，bias/act/requant 全在 CPU |
| **调试手段** | testbench 对 golden 比对 + 上板 accuracy | 仿真 + 裸机 sw/hw 逐层 match/unmatch |

---

## 3. 对本毕设的启示 (按价值排序)

### 3.1 高价值、低改动

1. **NCNN as runtime 是极高回报的工程思路**
   当前 `cim_driver.py` 每加一层都要手写 im2col + 硬件调用，非常"一次性"。NCNN 作为 HAL 层引入后，只需要在 `Convolution::forward_int8_npu` 加一个 hook 就能让硬件支持 LeNet / MobileNet / SqueezeNet 整条链路。毕设里哪怕只做 LeNet-5，也能以"可扩展到 YOLO"作为论文亮点。

2. **逐层 bit-exact dump/verify 基础设施**
   当前项目缺少 `log/accmem, ifmbuf, im2col, wgtbuf` 这种分级 dump。哪怕只在 `cim_driver.py` 加一个 `--verify-per-layer` 开关，让每一层的 `x_int8 / w_int8 / bias / psum_int32 / y_int8` 都落盘，并与 golden 逐 bit 比对，答辩 demo 的说服力会大大增强。

3. **SQ_MAPPING 思想降维打击到 im2col**
   目前的 `col_len ≤ 784` 限制本质上是"一次 MVM 吃多少"。借鉴 SQ_MAPPING：当 `maxk*C_in < PAR_OB*N_IB` 时，把多组输出折叠到同一次硬件调用。对 LeNet 第一层 (`kernel=5, C_in=1 → 25`) 效果尤其明显，可以把利用率从 25/784 ≈ 3% 提升到接近 100%。

### 3.2 论文写作增益

4. **"bit-serial vs 行为级 MAC" 架构对比**
   论文第 2 章"CIM 架构综述"里把两种设计极端对比：
   - **bit-serial popcount**（以 `cim_wzy` 为代表）：贴近 ASIC 真 CIM，面积/功耗收益大，但时序拉长 8×；
   - **DSP48 行为级 MAC + 量化后处理硬件化**（本毕设）：是 **PYNQ-Z2 资源约束 + 教学级功能闭环** 下的最优取舍。

   这一节能让评审老师清楚看到你对 CIM 领域两条技术路线的认知深度。

5. **精度流拆分的设计哲学分歧**
   本毕设把 bias+ReLU+requantize 做进硬件是**好处**（减少 PS 往返），但引入了 `N_OB` 固定限制。论文里可以写清楚："毕设目标是端到端 MNIST 闭环，所以量化后处理硬件化是合理的取舍；对更大模型（参考 `cim_wzy`）则应留出量化后处理在 CPU/DSP 以保留灵活性。"

### 3.3 工程上可选的增量

6. **Verilator 作为 VCS 备选**：`cim_wzy/simulation/csrc/hw/hw_cim.cpp` 直接 `reinterpret_cast<QData>` 送 DMA 的写法比 VCS PLI 便宜很多，跨平台、demo 友好。本毕设 VCS 已经够用，但论文可扩展性一节可以提。
7. **Chisel 参数化**：目前 `vivado_build.sh` 靠 sed 临时改 `PAR_OB` 其实也是同类事情，但 Chisel trait 更优雅 —— 不建议毕设阶段重构，但论文"未来工作"可以提。

---

## 4. 对毕设定位的积极影响

师兄的项目明显是**多年研究组积累**，不可能也不必完全复刻，但它提供了两样东西：

1. **技术路标**：让你清楚"毕设之后继续做，下一步该往哪走"—— 这正是毕设论文第 6 章"总结与展望"最希望看到的内容。
2. **代码血缘**：如果在论文里**如实声明**"借鉴了师兄 XXX 的 CIM SoC 验证平台的软件栈分层思想"，而非抄代码，会让答辩委员看到你在真实研究组环境中的协作能力。

> **重要**: 不要把 `cim_wzy/` 的代码直接拷贝进 `hw/` 或 `sw/`，现在作为独立目录放在 repo 里是对的 —— 论文里要明确划界。

---

## 5. 扩展的毕设优化菜单

> 第 3 节列出的是 `cim_wzy` 直接启示下的改进（对应 README `step 6`）。本节把视角扩大到整个毕设的工程健康度、性能、论文素材，给出一份完整的优化菜单，按投入产出比分五档 A/B/C/D/E，与 README `step 7` 互相对应。
> 本节**包含需要动 RTL 的改动**，这些 RTL 改动部分与本项目自身的"坑"章节中记录的待办 (critical path 拆分、双缓冲) 一脉相承，不仅仅来自 `cim_wzy` 启示。

### 5.1 Phase A: 立刻可做（<半天，纯 Python，零 RTL 风险）

#### A1. 权重常驻 + 批推理吞吐

**现象**：`CIMDriver.infer_fc()` 每次都 `load_weights()`。单张 MNIST 推理时，weight DMA 占相当大比例；批测 1000 张图时这是纯浪费。

**做法**：`CIMModel` 每个 layer 加 `w_loaded=False` 标志；`predict()` 如果连续两次推理同一个模型，跳过所有 `load_weights/load_bias`，只 `load_input + start`。

**收益**：批推理吞吐可能翻几倍。论文能给出 "MNIST: N FPS / image" 数字，比单张 ms 更有说服力。

#### A2. 端到端延迟分解 profiler

**现象**：当前 performance counter 只统计硬件 cycle。PS 侧的 `im2col / load_weights / load_input / read_output / Python overhead` 没有拆开，瓶颈定位不清。

**做法**：`cim_driver.py` 每个关键函数前后加 `time.perf_counter()`，`predict()` 返回 dict：

```python
{'im2col_ms': ..., 'load_w_ms': ..., 'load_x_ms': ...,
 'hw_compute_ms': ..., 'read_out_ms': ..., 'py_overhead_ms': ...}
```

跑一张 LeNet 图，画 pie chart 或 stacked bar。

**收益**：告诉你下一步该优化哪里（**很可能是 `load_weights` 或 Python 循环，而不是硬件本身**）。这是论文 benchmark 章节的核心支撑图。

#### A3. Bitstream + driver + git commit 三位一体指纹

**做法**：`cim_driver.py` 初始化时算 `hashlib.sha256(bit_file).hexdigest()[:8]` + `git rev-parse --short HEAD`，写入 step 6 Phase 1 的 dump 目录 `run_meta.json`。

**收益**：实验可追溯。答辩时被问"这张图来自哪次运行"能秒答。零成本。

### 5.2 Phase B: 本周可做（1-2 天，高论文价值）

#### B1. 资源/功耗/时序自动提取

**现象**：每次改完 RTL，手动翻 `*.rpt` 找 LUT/FF/BRAM/DSP 数字。费时且容易漏。

**做法**：`hw/scripts/extract_report.py`：跑完 `vivado_build.sh` 后 grep `utilization_*.rpt / timing_summary.rpt / power.rpt`，append 一行 CSV 到 `hw/build_history.csv`：

```
commit, freq_mhz, wns_ns, lut, ff, bram, dsp, power_w
```

**收益**：
- 论文"硬件资源与性能"表直接用这份 CSV 出图；
- 能看到 patch1/2/3 三次流水优化的趋势线，讲故事非常直观；
- 以后每次编译都自动 append，**patch 1/2/3 → C1 的完整优化曲线免费得到**。

#### B2. Pytest 回归（golden_model + cim_driver 离线模式）

**现象**：改 `golden_model.py` 或 quant 脚本时没有自动化 smoke test。`run_regression.sh` 只覆盖 RTL testbench。

**做法**：`sw/tests/`：
- `test_golden_bit_exact.py`：固定随机种子跑 MLP + LeNet，断言结果 bit-exact 匹配历史 snapshot；
- `test_quantize_roundtrip.py`：量化→反量化误差 < 阈值。

不需要 PYNQ，笔记本上 10 秒内跑完。

**收益**：未来任何一次 RTL 重构或量化脚本修改，`pytest sw/tests/` 立即告诉你有没有破坏 bit-exact。论文可写"持续集成测试覆盖率"。

#### B3. 多图 batch benchmark 脚本

**做法**：`sw/scripts/benchmark_e2e.py --n_images 1000 --batch_mode {single,resident}`，输出：

```
Model        | n_img | total_s | ms/img | fps   | accuracy
MNIST-MLP    | 1000  |  12.4   | 12.4   | 80.6  | 97.3%
LeNet-5      | 1000  |  35.2   | 35.2   | 28.4  | 99.0%
```

**收益**：论文第 5 章 benchmark 数据表，answer "你这个 CIM 到底有多快"。

### 5.3 Phase C: 时间充裕再做（**RTL 改动**，显著加速）

> ⚠️ 本节涉及硬件重构，需要重跑完整 VCS 回归 (`run_regression.sh`) 和重新综合时序收敛。

#### C1. 拆 cim_tile 16→2×8 打破 critical path

**现状**：README `坑` 章节 patch 3 明确 critical path 是 `w_tile_reg → DSP48 → CARRY4 → tile_psum_reg`，16-element 串行加法链。当前停在 62.5 MHz。这条 TODO 就在本项目自己的 patch 3 注释里：
> _"如果想要在 8ns 之内完成，需要把 16 个元素拆成 2×8 再合并。改动量会比较大，这里选择降频到 62.5 MHz，如果后面有时间再做进一步优化。"_

**做法**：把 `cim_tile.sv` 的 16-col `Σ(x_eff[c] * w[r][c])` 拆成前 8 + 后 8 两拍流水：
1. 第一拍 `partial_sum_lo = Σ(x_eff[0..7] * w[0..7])`
2. 第二拍 `partial_sum_hi = Σ(x_eff[8..15] * w[8..15])`，同拍做 `tile_psum_reg = partial_sum_lo + partial_sum_hi`
3. `cim_accel_core` compute 段多加一个 pipeline stage，ST_MAC 拆成 ST_MAC_LO + ST_MAC_HI

**收益**：
- 125 MHz unlock → 吞吐 **2×**；
- 论文硬件章节"流水线优化四阶段"故事完整（patch 1/2/3 + 这一步正好凑 4 次迭代，优化过程展示非常有说服力）；
- `cim_wzy` 的 bit-serial 架构天然就需要 8 拍循环，"我的 DSP48 架构通过深流水达到同样数量的 cycle 数" 是一个很好的论文对比点。

**风险**：动 `cim_tile.sv` 核心组合逻辑，必须重跑全部 VCS 回归 + 重新综合验证时序。

#### C2. Weight / Input SRAM 双缓冲 (ping-pong)

**现状**：当前 layer 算完才开始加载下一层的 weight/input，期间 PL 空转。

**做法**：`weight_sram` / `input_buffer` 双 bank 切换，加一个 `active_bank` 寄存器。Python 侧发起 layer N+1 weight DMA 到 inactive bank，与 layer N 的 compute 重叠。

**收益**：多层网络（MLP 2 层、LeNet 7 层）的层间延迟隐藏，吞吐再提升 20%~40%。

**风险**：RTL 改动中等，BRAM 占用翻倍。**PYNQ-Z2 很可能放不下（已经 140 块 BRAM 吃紧），更适合在更大器件上合并做**。

#### C3. AXI4-Full burst 代替 AXI4-Lite 逐字 ⚠️ 接口重写

**现状**：现在 weight/input 加载走 AXI4-Lite，32-bit per transaction。

**做法**：换 AXI4-Full slave + DMA engine（PYNQ `pynq.lib.dma`），单次 burst 几 KB 到 weight_sram。

**收益**：weight load 从 ms 级降到 μs 级，彻底消除 Python 侧的加载瓶颈。

**风险**：改动最大，接口重写。**不建议毕设阶段做**，论文"未来工作"提即可。

### 5.4 Phase E: 论文素材与工程健康度

- **E1. 层级 latency timeline 可视化**：从 step 6 Phase 1 的 dump 出发，写 `visualize_timeline.py` 用 matplotlib 画"Gantt 式"层级时间条。论文"Figure X: LeNet-5 逐层延迟分布"现成。
- **E2. 统一 CLI 入口**：`sw/scripts/cim.py run --model lenet5 --input foo.png --verify`，把散落在 notebook 里的验证代码统一成一个命令。答辩 demo 跑起来干净。
- **E3. 架构图自动生成**：`diagrams` Python 包或 `graphviz` 从 `cim_pkg.sv` 的参数驱动。论文每次改参数不用手画 block diagram。
- **E4. ONNX import 路径**：`onnxruntime` 提供 EP 接口，可以注册 `CIMExecutionProvider`。**不要在毕设里真的实现**，但论文 outlook 里点出来会让"可扩展性"看起来更严肃（`cim_wzy` 走的是 NCNN，你指向更开放的 ONNX 是一个差异化论点）。

### 5.6 Top 3 推荐

按 "毕设答辩收益 / 工作量" 排序：

| 排名 | 事项 | 工作量 | 答辩/论文价值 |
|---|---|---|---|
| 🥇 | **A2 + B3** 延迟分解 + batch benchmark | 合计 1 天 | 论文第 5 章核心数据。没这个，审稿人会说"benchmark 不完整"。 |
| 🥈 | **B1** 资源/时序自动提取 CSV | 半天 | 论文第 4 章硬件资源表。同时让 patch1/2/3 时序故事形成完整证据链。 |
| 🥉 | **A1** 权重常驻批推理 | 半天 | 单张 demo 给出的 ms 数字看起来会"真实许多"，FPS 数据也能讲得通。 |

合计 **2 天**，全部零 RTL 风险，却能把论文第 4、5 章数据支撑一次性补齐。

### 5.7 推进顺序建议

```
step 6 Phase 1 (per-layer verify)  ──┐
step 6 Phase 2 (SQ-mapping pack)   ──┼──→ Top 3 (A1+A2+B1+B3) ──→ C1 critical path
step 6 Phase 3 (thesis writing)    ──┘
                                         ↑
                                         |
                                        此处为 "毕设最小闭环" 完成点
                                        达到这里即可交毕设
```

**不贪多原则**：完成 `step 6 Phase 1+2` + `Top 3` 就已经是一份非常扎实的毕设工作量。剩下的 C2/C3/E* 全部放到论文"未来工作"章节里列出即可。

> 答辩委员看到一个能讲清楚"下一步该往哪走"的候选人，永远比看到一个"啥都做了一半"的候选人印象好。

---

## 6. 参考文件索引

| 关注点 | 路径 |
|---|---|
| bit-cell (1-bit CIM) | `cim_wzy/user/chisel/src/main/scala/mainArray/line_cell.scala` |
| 128-row popcount + AdderTree | `cim_wzy/user/chisel/src/main/scala/mainArray/Array_8x128.scala` |
| bit-serial shift-add FSM | `cim_wzy/user/chisel/src/main/scala/ConV/ConV_8x8.scala` |
| 参数定义 (tile/pe/array) | `cim_wzy/user/chisel/src/main/scala/configs_cim.scala` |
| C++ ↔ RTL DMA 封装 | `cim_wzy/simulation/csrc/hw/hw_cim.cpp` |
| NCNN Conv hook | `cim_wzy/simulation/csrc/layer/convolution.cpp` (L542-810) |
| 全局宏开关 | `cim_wzy/simulation/csrc/config.h` |
| 裸机 sw/hw 比对模式 | `cim_wzy/vitis_prj/README_软件推理开关.md` |
