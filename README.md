# CIM SoC — 存算一体 AI 芯片 FPGA 验证系统

## 项目概述

基于 PYNQ-Z2 (Zynq-7020) 的存算一体 (CIM) SoC 验证平台。
支持 INT8 量化推理，可运行 MLP/CNN 神经网络。

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

## 快速开始

### 1. Lint 检查

```bash
verilator --lint-only --sv -Wall \
  -Wno-UNUSED -Wno-UNDRIVEN -Wno-DECLFILENAME \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE \
  -Wno-UNSIGNED -Wno-CASEINCOMPLETE -Wno-LATCH -Wno-BLKANDNBLK \
  hw/rtl/pkg/cim_pkg.sv hw/rtl/core/*.sv hw/rtl/mem/*.sv hw/rtl/axi/*.sv \
  --top-module cim_axi_lite_slave
```

### 2. 运行 Golden Model

```bash
cd sw && python3 golden_model.py
```

### 3. VCS 仿真

```bash
cd hw && bash scripts/run_tb_cim_tile.sh
cd hw && bash scripts/run_tb_cim_accel_core.sh
```

### 4. Vivado 综合上板

详见 `docs/vivado_block_design_guide.md`

## LaTeX 论文编译

```bash
cd paper && xelatex paper.tex && biber paper && xelatex paper.tex && xelatex paper.tex
```

## 开发路线

- [x] Phase 0: 参数体系 + CSR 地址映射
- [x] Phase 1: CIM 核心重写 (lint clean)
- [x] Phase 1: AXI4-Lite slave wrapper
- [x] Phase 1: Golden model + Testbench
- [ ] Phase 2: Vivado Block Design 实际搭建
- [ ] Phase 2: PYNQ 上板验证 MNIST
- [ ] Phase 3: 多层网络调度 (FC1→FC2 软件循环)
- [ ] Phase 3: im2col Conv 支持
- [ ] Phase 4: Bit-plane CIM (论文创新点)
- [ ] Phase 5: PicoRV32 RISC-V 近存控制器 (可选)
- [ ] Phase 5: KV260 移植 (可选)
