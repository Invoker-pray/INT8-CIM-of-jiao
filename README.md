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

### [] step 3: extensions

- [x] Phase 1: 实现多层自动化推理(python driver做layer-by-layer循环) <-- cim_driver.py CIMModel
- [x] Phase 2: im2col展开Conv层：python侧做im2col变换后喂给MVM引擎 <-- LwNet-5, PASS
- [x] Phase 3: 尝试映射一个Conv网络(比如LeNet-5) <-- 20 pics, bit-exact 100%
- [] Phase 4: 尝试讨论bit-plane

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
