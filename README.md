# CIM SoC — 存算一体 AI 芯片 FPGA 验证系统（施工ing）

## 项目概述

~预计是~基于 PYNQ-Z2 (Zynq-7020)/kria kv260 的存算一体 (CIM) SoC 验证平台。
支持 INT8 量化推理，可运行 MLP/CNN 神经网络（以后还可能再扩展）。

和之前的项目设计题目*[MNIST-CIM-FPGA](https://github.com/Invoker-pray/MNIST-CIM-FPGA)*有相似之处。有一些进步如下：

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

### [] step 1: 逻辑设计 + 仿真

- [x] Phase 0: 参数体系 + CSR 地址映射
- [x] Phase 1: CIM 核心重写 (lint clean)
- [x] Phase 1: AXI4-Lite slave wrapper
- [x] Phase 1: Golden model + Testbench
- [] Phase 2: 完成MNIST端到端testbench
- [] Phase 2.5 : 实现对CNN支持
- [] Phase 3: `cim_pkg`中增加Conv层im2col映射支持
- [] Phase 4: 完成边界测试
- [] Phase 5: 完成所有testbench和regression脚本自动化。

### [] step 2: PYNQ-Z2 + ZYNQ PS部署

- [ ] Phase 1: Vivado Block Design 实际搭建
- [ ] Phase 2: PYNQ 上板验证 MNIST
- [ ] Phase 3: 多层网络调度 (FC1→FC2 软件循环)
- [ ] Phase 3: im2col Conv 上板验证支持

### [] step 3: extensions

- [ ] Phase 1: 实现多层自动化推理(python driver做layer-by-layer循环)
- [ ] Phase 2: im2col展开Conv层：python侧做im2col变换后喂给MVM引擎
- [ ] Phase 3: 尝试映射一个Conv网络(比如LeNet-5)
- [] Phase 4: 尝试讨论bit-plane

### [] step 4: PicoRV32替换ARM控制

- [] Phase 1: 集成PicoRV32开源RISC-V软核到PL
- [] Phase 2: 写 Wishbone→CSR bridge（或直接用 PicoRV32 native memory interface 映射到 CSR 地址空间）
- [] Phase 3: RISC-V 固件（C）完成：weight DMA 加载、层配置、推理触发、结果读取
- [] Phase 4: 用 riscv64-unknown-elf-gcc 交叉编译，固件存 BRAM
- [] Phase 5: 仿真 + 上板验证功能等价

### [] step 5: Kria KV 260移植

- [] Phase 1: 更换 board file（xck26-sfvc784），重新搭建 Block Design
- [] Phase 1:测试更大并行度
- [] Phase 2: Zynq UltraScale+ 的 PS 是 Cortex-A53（AXI 接口兼容，驱动几乎不改），综合 + 时序收敛 + 上板验证
- [] Phase 3: 性能对比报告：PYNQ-Z2 vs KV260（资源、频率、吞吐）
