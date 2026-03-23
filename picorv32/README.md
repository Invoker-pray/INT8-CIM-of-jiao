# PicoRV32 + CIM SoC

## 架构

```
┌─────────────────────────────────────────────────┐
│                 PL (FPGA)                        │
│                                                   │
│  ┌────────────┐  native bus  ┌────────────────┐  │
│  │ PicoRV32   │◄────────────►│ Bus Bridge     │  │
│  │ RV32IM     │              │ (addr decode)  │  │
│  │ @60MHz     │              └───┬────┬────┬──┘  │
│  └────────────┘                  │    │    │      │
│                                  ▼    ▼    ▼      │
│                   ┌──────┐  ┌──────┐  ┌──────┐   │
│                   │ FW   │  │ CIM  │  │ UART │   │
│                   │ BRAM │  │ IP   │  │ TX   │   │
│                   │ 32KB │  │(现有) │  │115200│   │
│                   └──────┘  └──────┘  └──┬───┘   │
│                                          │       │
└──────────────────────────────────────────┼───────┘
                                           │
                                      UART TXD pin
                                      (串口终端)
```

## 地址映射

| 地址范围                  | 设备           | 说明                      |
| ------------------------- | -------------- | ------------------------- |
| 0x0000_0000 - 0x0000_7FFF | Firmware BRAM  | 32KB, RW, 存放代码+数据   |
| 0x4000_0000 - 0x4000_3FFF | CIM CSR        | 16KB, 和 AXI 版本完全一致 |
| 0x8000_0000               | UART TX Data   | 写一个字节                |
| 0x8000_0004               | UART TX Status | bit[0]=ready              |

## 文件清单

### RTL (hw/rtl/riscv/)

| 文件                     | 说明                                        |
| ------------------------ | ------------------------------------------- |
| `cim_rv32_top.sv`        | 顶层：PicoRV32 + Bridge + BRAM + UART + CIM |
| `picorv32_cim_bridge.sv` | 总线桥：地址译码 → BRAM/CIM/UART            |
| `uart_tx.sv`             | 简单 8N1 UART 发送器                        |
| `picorv32.v`             | **需要从 GitHub 下载** (见下方)             |

### 固件 (fw/)

| 文件             | 说明                                           |
| ---------------- | ---------------------------------------------- |
| `firmware.c`     | 主程序：配置 CIM → 加载权重 → 推理 → UART 输出 |
| `start.S`        | 启动汇编：设 SP、清 BSS、跳 main               |
| `firmware.lds`   | 链接脚本：32KB BRAM 布局                       |
| `gen_fw_data.py` | 把 hex 文件转成 C 数组                         |
| `Makefile`       | 一键编译                                       |

## 构建步骤

### 1. 安装 RISC-V 工具链

```bash
# arch
sudo pacman -S riscv64-elf-gcc
# sudo pacman -S riscv64-elf-binutils riscv64-elf-newlib

# Ubuntu/Debian
sudo apt install gcc-riscv64-unknown-elf

# 或者从 SiFive 下载预编译工具链
# https://github.com/sifive/freedom-tools/releases
```

_这里有坑，不同distro的约定不一样，archlinux的前缀是`riscv64-elf-`，官方GNU toolchain一般是`riscv64-unknown-elf-`，如果在你的系统报错，修改`Makefile`的前缀就好。_
验证安装成功：

```bash
riscv64-elf-gcc --version
```

### 2. 训练生成测试数据（宿主机）

```bash
cd fw/
python3 small_mlp_quantize.py --seed 42
#-> small_mlp_data

# generate c array.
python3 gen_fw_data.py --data-dir small_mlp_data --image-idx0
```

### 3. 获取　PicoRV32

```bash
wget -O ../hw/rtl/riscv/picorv32.v \
    https://raw.githubusercontent.com/YosysHQ/picorv32/main/picorv32.v
```

### 4. 编译固件

```bash
cd fw/
make DATA_DIR=small_mlp_data IMAGE_IDX=0
# 产出: firmware.hex (Verilog $readmemh 格式)
```

### 5. 仿真（VCS 或 Verilator）

```bash
# 把 firmware.hex 放到仿真目录
# cim_rv32_top 的 FW_HEX 参数指向它
# 观察 UART TXD 输出
```

### 6. Vivado 综合

```tcl
# 在 vivado_build.tcl 中添加新的 RTL 文件
# 或者单独建项目, 顶层设为 cim_rv32_top
# BRAM 初始化: set_property INIT_FILE firmware.hex [get_cells u_fw_bram]
```

## 已知限制

### BRAM 容量问题

32KB BRAM 放不下 MLP 784→128→10 的全部权重：

| 数据                         | 大小                |
| ---------------------------- | ------------------- |
| FC1 权重 (25088 chunks × 4B) | 100,352 B           |
| FC2 权重 (512 chunks × 4B)   | 2,048 B             |
| FC1 bias (128 × 4B)          | 512 B               |
| FC2 bias (10 × 4B)           | 40 B                |
| 测试图片 (784 B)             | 784 B               |
| 代码 + 栈                    | ~4,000 B            |
| **Total**                    | **~107 KB >> 32KB** |

### 解决方案（任选一个）

1. **用小模型**: 784→16→10 (权重只有 ~13KB, 可以放进 BRAM)
2. **PS DDR 辅助**: 保留 Zynq PS, PicoRV32 通过 AXI 从 DDR 读权重
3. **分块加载**: 固件先从外部（SPI Flash/SD 卡）逐块加载权重到 CIM weight SRAM
4. **仅仿真验证**: 仿真时 BRAM 可以任意大, 验证功能正确即可

**推荐路径**: 先用小模型 (784→16→10) 在 BRAM 内跑通全流程,
证明 RISC-V 能控制 CIM。然后在论文中讨论大模型的权重加载方案。
