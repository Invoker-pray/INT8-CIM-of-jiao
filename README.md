# KV260 分支 — CIM SoC 移植到 Kria KV260

> **这是 `kv260` 分支。** 如果你刚 clone 项目，请先阅读 [`master` 分支的 README](https://github.com/Invoker-pray/INT8-CIM-of-jiao/blob/master/README.md) 了解 CIM SoC 的架构设计、RTL 模块、开发历史和各 Phase 的演进过程。本 README 只描述 KV260 分支与 master (PYNQ-Z2) 的差异和分支特有的内容。

## 分支概述

将 CIM SoC 从 PYNQ-Z2 (Zynq-7020, 220 DSP) 移植到 **Kria KV260** (K26 SOM, xck26-sfvc784-2LV-c, Zynq UltraScale+ MPSoC, ~1248 DSP)，用 **PetaLinux** 替代 Ubuntu+Kria-PYNQ 方案，构建自包含的嵌入式 Linux 推理平台。

### 与 master (PYNQ-Z2) 的关键差异

| 维度 | master (PYNQ-Z2) | kv260 分支 |
|------|------------------|-----------|
| 芯片 | xc7z020 (Zynq-7020) | xck26 (ZynqMP UltraScale+) |
| DSP 数量 | 220 | ~1248 |
| PAR_OB | 4 (仿真) / 1 (综合) | **4** (~1024 DSP, 82%) |
| TILE_SPLIT_FACTOR | 4 | 4 |
| 时钟 | 100 MHz (WNS=-0.8ns) | 100 MHz |
| 操作系统 | PYNQ Linux (Ubuntu) | **PetaLinux** (Yocto) |
| Python 环境 | Jupyter + PYNQ 库 | 命令行 Python + `/dev/mem` MMIO |
| 比特流加载 | `Overlay("cim_soc.bit")` | 嵌入 BOOT.BIN，上电自动加载 |
| CIM CSR 基地址 | `0x40000000` | `0xA0000000` |
| DMA CSR 基地址 | `0x40400000` | `0xB0000000` |
| PS 接口 | GP0 + HP0/HP1 | HPM0_FPD + HPM1_FPD + HP0/HP1_FPD |

### 保留自 master 的内容

本分支**不改动**以下模块（与 master 的 Phase C checkpoint 5 一致）：

- `hw/rtl/core/` — cim_tile, psum_accum, cim_accel_core（含 Phase A 的 TILE_SPLIT_FACTOR=4 拆分和 Phase C v10 的 weight_base/bias_base 支持）
- `hw/rtl/mem/` — weight_sram, bias_sram, input_buffer, output_buffer（含 Phase B 双缓冲和 Phase C 的 OBUF→IBUF fusion FSM）
- `hw/rtl/axi/` — cim_axi_lite_slave, cim_axi_stream_sink, cim_axi_stream_source（C3 DMA 数据通路 + P0 S2MM 全部保留）
- `sw/golden_model.py`, `sw/model_zoo.py` — 软件栈不变
- `picorv32/` — PicoRV32 软核在 KV260 上不启用（ARM PS 已足够）

## 分支目录结构

仅列出分支新增/变更的目录，其余与 master 相同：

```
cim_soc/
├── kv260/                              # KV260 分支新增
│   ├── hw/
│   │   ├── constraints/
│   │   │   └── cim_kv260.xdc           # PL 约束（比特流压缩，无外部引脚）
│   │   ├── rtl ⇒ ../../hw/rtl          # 符号链接到共享 RTL
│   │   └── scripts/
│   │       ├── vivado_build.tcl         # Vivado Block Design TCL（ZynqMP PS 配置）
│   │       └── vivado_build.sh          # 一键构建脚本
│   └── deploy/                         # 构建产物
│       ├── cim_soc_kv260.bit           # PL 比特流 (7.4 MB)
│       ├── cim_soc_kv260.hwh           # 硬件描述 (416 KB)
│       └── cim_soc_kv260.xsa           # Vivado 硬件平台导出 (1.6 MB)
│
├── kv260_petalinux/                    # PetaLinux 工程
│   └── cim_kv260/
│       ├── project-spec/               # 工程配置（metadata, hw-description, configs）
│       └── build/ / images/ / components/  # 构建输出（gitignored）
│
└── docs/
    └── kv260_petalinux_onboard.md      # PetaLinux 上板详细指南
```

## 构建流程

### 1. 构建比特流（Vivado 2024.2）

```bash
cd /home/jiao/git/INT8-CIM-of-jiao
bash kv260/hw/scripts/vivado_build.sh
```

输出：`kv260/deploy/cim_soc_kv260.{bit, hwh, xsa}`

注意：KV260 的 PAR_OB=4 固定使用（K26 有 1248 DSP，PAR_OB>4 会溢出到 LUT），**不需要**像 PYNQ-Z2 那样在综合前临时改 PAR_OB=1（`vivado_build.sh` 已移除此逻辑）。

### 2. 构建 PetaLinux

```bash
cd kv260_petalinux/cim_kv260
petalinux-config --get-hw-description=../../kv260/deploy/cim_soc_kv260.xsa
petalinux-build          # ~30-60 分钟
petalinux-package --boot --u-boot --fsbl --fpga --force
```

输出（`images/linux/`）：

| 文件 | 大小 | 说明 |
|------|------|------|
| BOOT.BIN | 9.2 MB | FSBL + PMU + ATF + U-Boot + bitstream |
| image.ub | 10 MB | Kernel + device tree |
| rootfs.ext4 | 407 MB | 根文件系统 |

### 3. 上板验证

详见 [`docs/kv260_petalinux_onboard.md`](docs/kv260_petalinux_onboard.md)。

**重要：KV260 上电后产生 4 个 /dev/ttyUSB 设备，串口是编号第二小的那个（如 ttyUSB1），不是 ttyUSB0。** 详细连接说明见上板文档第 4 节。

核心验证方法：通过 Python `/dev/mem` MMIO 直接访问 CIM 寄存器（无需 PYNQ 库）：

```python
import mmap, os, struct

class MMIO:
    def __init__(self, base_addr, length=0x4000):
        f = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
        self.mem = mmap.mmap(f, length, offset=base_addr)
        os.close(f)
    def read(self, offset):
        self.mem.seek(offset)
        return struct.unpack("<I", self.mem.read(4))[0]
    def write(self, offset, value):
        self.mem.seek(offset)
        self.mem.write(struct.pack("<I", value))

cim = MMIO(0xA0000000, 0x4000)
status = cim.read(0x004)  # CSR_STATUS
print(f"busy={status & 1}")
```

## 地址映射

| 设备 | 地址 | 大小 | 说明 |
|------|------|------|------|
| CIM CSR | `0xA0000000` | 16 KB | AXI4-Lite, PS HPM0_FPD → cim_top/S_AXI |
| DMA CSR | `0xB0000000` | 64 KB | PS HPM1_FPD → axi_dma/S_AXI_LITE |
| DDR (PS) | `0x00000000` | 4 GB | 推理数据缓冲区，PS HP0/HP1_FPD ↔ axi_dma |

设备树（由 Vivado XSA 自动生成 `pl.dtsi`）：

```dts
cim_0: cim_top_wrapper@a0000000 {
    compatible = "xlnx,cim-top-wrapper-1.0";
    reg = <0x0 0xa0000000 0x0 0x4000>;
};
axi_dma_0: dma@b0000000 {
    compatible = "xlnx,axi-dma-7.1", "xlnx,axi-dma-1.00.a";
    reg = <0x0 0xb0000000 0x0 0x10000>;
};
```

## 性能参考

以下数据来自 PYNQ-Z2 (Phase C checkpoint 5, 100MHz, PAR_OB=4 仿真/1 综合)，KV260 板上实测待补充：

| 指标 | PYNQ-Z2 (master) | KV260 预期 | 提升来源 |
|------|-------------------|-----------|---------|
| MLP FC1 (784→128) | ~45 μs | ~10-12 μs | PAR_OB 4× vs PYNQ-Z2 综合 PAR_OB=1 |
| MLP 端到端 | 29.2 ms/img (34.3 fps) | 7-15 ms/img | PAR_OB 4× + 100MHz |
| LeNet-5 | 29.2 ms/img (34.3 fps) | 7-15 ms/img | 同上 |

KV260 板上基准测试方法：PetaLinux rootfs 自带 Python 3，使用 `time.perf_counter()` 测量各阶段延迟，运行 `benchmark_e2e.py`（需适配 `/dev/mem` 驱动替代 PYNQ DMA 库）。

## 与 master 的关系

- 本分支从 master 分出（commit `c1719892`），保留所有 RTL 核心和软件栈
- master 上的后续 bug 修复应 cherry-pick 到本分支
- 本分支的 KV260 特定修改（PAR_OB=8、PS 配置、PetaLinux）不适合合回 master，master 保持 PYNQ-Z2 定位
- 两个分支长期并行维护

## 参考

- [`master` 分支 README](https://github.com/Invoker-pray/INT8-CIM-of-jiao/blob/master/README.md) — CIM SoC 架构、RTL 模块、Phase A/B/C 优化历史
- [`docs/kv260_petalinux_onboard.md`](docs/kv260_petalinux_onboard.md) — PetaLinux 构建、烧录、验证的详细步骤
- [`docs/kv260_migration.md`](docs/kv260_migration.md) — KV260 硬件对比与 Ubuntu+Kria-PYNQ 第一阶段方案
- [`docs/c3_dma_design.md`](docs/c3_dma_design.md) — DMA 数据通路设计规范
- `kv260_petalinux/cim_kv260/project-spec/` — PetaLinux 工程源文件
