# MZU15B 分支 — CIM SoC 移植到 MZU15B (XCZU15EG)

> **这是 `mzu15b` 分支。** 如果你刚 clone 项目，请先阅读 [`master` 分支的 README](https://github.com/Invoker-pray/INT8-CIM-of-jiao/blob/master/README.md) 了解 CIM SoC 的架构设计、RTL 模块、开发历史和各 Phase 的演进过程。本 README 只描述 MZU15B 分支与 master (PYNQ-Z2) 的差异和分支特有的内容。

## 分支概述

将 CIM SoC 从 PYNQ-Z2 (Zynq-7020, 220 DSP) 移植到 **MZU15B-488A** (XCZU15EG-ffvb1156-2-i, Zynq UltraScale+ MPSoC, 3528 DSP, 26.2 Mb BRAM + 31.2 Mb URAM)，用 **PetaLinux** 构建自包含的嵌入式 Linux 推理平台。

MZU15B 是本项目的终极上板平台，利用 UltraScale+ 的大规模逻辑资源将 PAR_OB 推到 13（3328 DSP, 94.5% 占用），同时提升 MAX_IN_DIM→3072、MAX_OUT_DIM→1024，支持更大的网络。

### 与 master (PYNQ-Z2) 的关键差异

| 维度 | master (PYNQ-Z2) | mzu15b 分支 |
|------|------------------|------------|
| 芯片 | xc7z020 (Zynq-7020) | xczu15eg (ZynqMP UltraScale+) |
| DSP 数量 | 220 | 3528 |
| BRAM | 4.9 Mb (630 KB) | 26.2 Mb + URAM 31.2 Mb |
| PAR_OB | 4 (仿真) / 1 (综合) | **13** (3328 DSP, 94.5%) |
| TILE_SPLIT_FACTOR | 4 | 4 |
| MAX_IN_DIM | 1536 | **3072** |
| MAX_OUT_DIM | 256 | **1024** |
| 时钟 | 100 MHz | 100 MHz |
| 操作系统 | PYNQ Linux (Ubuntu) | **PetaLinux** (Yocto) |
| 比特流加载 | `Overlay("cim_soc.bit")` | 嵌入 BOOT.BIN，上电自动加载 |
| 参数选择 | 固定值 | `` `ifdef MZU15B`` 条件编译 |

### 保留自 master 的内容

本分支**不改动**以下 RTL 核心（与 master Phase C checkpoint 5 一致）：

- `hw/rtl/core/` — cim_tile, psum_accum, cim_accel_core
- `hw/rtl/mem/` — weight_sram, bias_sram, input_buffer (Phase B 双缓冲), output_buffer (Phase C OBUF→IBUF fusion FSM)
- `hw/rtl/axi/` — cim_axi_lite_slave, cim_axi_stream_sink, cim_axi_stream_source（C3 DMA + P0 S2MM）
- `sw/` — 软件栈不变（golden_model, model_zoo, cim_driver, benchmark）

参数通过 `` `ifdef MZU15B `` 在 `cim_pkg.sv` 中条件切换，非 MZU15B 路径保留 master 原值。

## 两种构建模式

本分支提供两种 bitstream 变体：

### 模式 1：PicoRV32 控制（纯 PL 自主推理）

PicoRV32 RISC-V 软核替代 ARM PS 控制 CIM，实现纯 PL 自主推理。PS 仅提供时钟 + 加载固件 + 读取结果。

**构建：**
```bash
cd picorv32/hw
bash scripts/vivado_build_mzu15b.sh
```

**输出：** `picorv32/vivado_mzu15b_proj/deploy/`
**Bitstream：** `checkpoint1-picorv32/cim_soc_mzu15b.bit`

**相关文件：**
- `picorv32/hw/rtl/riscv/` — PicoRV32 + cim_rv32_top + bridge
- `picorv32/fw/` — RISC-V 固件（C，riscv64-unknown-elf-gcc 编译）
- `picorv32/hw/constraints/cim_rv32_mzu15b.xdc` — 引脚约束

### 模式 2：ARM 直接控制

ARM PS 通过 `/dev/mem` MMIO 直接控制 CIM，与 master 的 PYNQ Python 驱动方式对应（但使用 `/dev/mem` 而非 PYNQ 库）。

**构建：**
```bash
cd /home/jiao/git/INT8-CIM-of-jiao
bash hw/scripts/vivado_build.sh   # MZU15B TCL，AltSpreadLogic_high 布局
```

**输出：** `vivado_proj/deploy/`
**Bitstream：** `checkpoint2-arm/cim_soc_mzu15b.bit`（WNS=+0.602ns，时序收敛）

## 分支目录结构

仅列出分支新增/变更的目录，其余与 master 相同：

```
cim_soc/
├── hw/
│   ├── constraints/
│   │   └── cim_mzu15b.xdc            # ARM-direct 版本的 PL 约束
│   └── scripts/
│       └── vivado_build.{sh,tcl}      # ARM-direct 构建脚本（MZU15B PS 配置）
│
├── picorv32/                          # PicoRV32 控制版本
│   ├── hw/
│   │   ├── constraints/
│   │   │   └── cim_rv32_mzu15b.xdc   # PicoRV32 变体引脚约束
│   │   ├── rtl/riscv/                # cim_rv32_top, bridge, PicoRV32 源码
│   │   └── scripts/
│   │       └── vivado_build_mzu15b.{sh,tcl}
│   └── fw/                           # RISC-V 固件（C）
│
├── cim_mzu15b/                        # PetaLinux 工程（ARM-direct）
│   ├── project-spec/                  # 工程配置
│   ├── build/ / images/ / components/ # 构建输出（gitignored）
│   ├── petalinux_build.sh             # 一键构建脚本
│   └── Dockerfile / run.sh / clean.sh # Docker 构建环境
│
├── checkpoint1-picorv32/              # PicoRV32 bitstream 产物
│   └── cim_soc_mzu15b.{bit, hwh, xsa}
│
└── checkpoint2-arm/                   # ARM-direct bitstream + PetaLinux 产物
    ├── cim_soc_mzu15b.{bit, hwh, xsa}
    ├── BOOT.BIN
    └── image.ub
```

## 构建流程

### 1. 构建比特流

```bash
# ARM-direct 版本
cd /home/jiao/git/INT8-CIM-of-jiao
bash hw/scripts/vivado_build.sh

# PicoRV32 版本
cd picorv32/hw
bash scripts/vivado_build_mzu15b.sh
```

构建脚本会自动定义 `` `define MZU15B ``，使 `cim_pkg.sv` 选择 PAR_OB=13 / MAX_IN_DIM=3072 / MAX_OUT_DIM=1024。

### 2. 构建 PetaLinux

```bash
cd cim_mzu15b
bash petalinux_build.sh   # 内部调用 petalinux-config → petalinux-build → petalinux-package
```

Docker 构建（无需本地安装 PetaLinux）：
```bash
cd cim_mzu15b
bash run.sh   # 启动 Docker 容器，执行 petalinux_build.sh
```

### 3. 上板验证

PetaLinux rootfs 自带 Python 3。通过 `/dev/mem` MMIO 直接访问 CIM 寄存器（0xA0000000），无需 PYNQ 库：

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
status = cim.read(0x004)
print(f"busy={status & 1}")
```

## 地址映射

与 kv260 分支相同（ZYQNMP 统一地址空间）：

| 设备 | 地址 | 大小 | 说明 |
|------|------|------|------|
| CIM CSR | `0xA0000000` | 16 KB | AXI4-Lite through HPM0_FPD |
| DMA CSR | `0xB0000000` | 64 KB | AXI DMA through HPM1_FPD |
| PS DDR | `0x00000000` | 4 GB | 推理数据缓冲区 |

## 参数对比：PYNQ-Z2 vs MZU15B

| 参数 | PYNQ-Z2 (master) | MZU15B (本分支) | 提升 |
|------|-------------------|-----------------|------|
| PAR_OB | 1 (综合) | 13 | **13×** |
| MAX_IN_DIM | 1536 | 3072 | 2× |
| MAX_OUT_DIM | 256 | 1024 | 4× |
| DSP 使用 | 224/220 (100%) | 3328/3528 (94.5%) | — |
| WNS (100MHz) | -0.8 ns | +0.602 ns | 收敛 vs 不收敛 |

## 当前状态

| 模式 | Bitstream | PetaLinux | 上板验证 |
|------|-----------|-----------|---------|
| PicoRV32 | ✅ checkpoint1-picorv32 | 不需要（PS 仅时钟） | 待测 |
| ARM-direct | ✅ checkpoint2-arm | ✅ cim_mzu15b/ | 待测 |

ARM-direct bitstream 时序收敛（WNS=+0.602ns, AltSpreadLogic_high 布局策略），PetaLinux 镜像构建完成（BOOT.BIN + image.ub）。

## 与 master 的关系

- 从 master 分出，保留所有 RTL 核心和软件栈
- 使用 `` `ifdef MZU15B `` 条件编译切换参数，不破坏 master 路径
- 本分支参数（PAR_OB=13, 大 MAX 维度）不适合合回 master，两个分支长期并行维护
- 后续 MZU15B 的 benchmar 数据应提交到本分支

## 参考

- [`master` 分支 README](https://github.com/Invoker-pray/INT8-CIM-of-jiao/blob/master/README.md) — CIM SoC 架构、RTL 模块、Phase 优化历史
- [`docs/picorv32_design.md`](docs/picorv32_design.md) — PicoRV32 集成设计文档
- `picorv32/README_MZU15B.md` — PicoRV32 变体的 MZU15B 说明
- `cim_mzu15b/project-spec/` — PetaLinux 工程源文件
- [MZU15B 官方产品页](https://www.mymir.com/Xilinx/XILINX-XCZU15EG-FFVB1156) — 板卡规格
