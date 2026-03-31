# PicoRV32 + CIM SoC 设计文档

## 1. 为什么选择 PicoRV32

Step 1-3 中，CIM 加速器由 Zynq PS (ARM Cortex-A9) 通过 AXI4-Lite 控制。这种架构的问题是：**CIM 依赖 PS 才能工作**。如果换到没有 ARM 的纯 FPGA 平台（比如 Artix-7），整个系统就无法运行（同时这也是毕设要求）。

Step 4 的目标：**用 RISC-V 软核替代 ARM**，让 CIM 加速器可以在纯 PL 中自主运行。

### 为什么是 PicoRV32 而不是其他软核

| 候选           | 特点                           | 选择理由              |
| -------------- | ------------------------------ | --------------------- |
| **PicoRV32**   | RV32IM, ~1500 LUT, MIT License | 极小、成熟、广泛使用  |
| VexRiscv       | RV32IM, SpinalHDL 生成         | 需要 SpinalHDL 工具链 |
| SERV           | RV32I, 串行, ~200 LUT          | 太慢（串行执行）      |
| Ibex (lowRISC) | RV32IMC, 工业级                | 偏大，配置复杂        |

PicoRV32 的优势：

- **单文件** (`picorv32.v`)，直接加入 Vivado 工程
- **native memory interface**：简单的 valid/ready/addr/wdata/rdata，不需要 AXI/Wishbone
- xc7z020 上只占 ~1500 LUT（总共 53200），不影响 CIM 资源
- 支持 RV32IM（乘法指令），足够跑 C 代码

## 2. 系统架构

### 2.1 地址映射

PicoRV32 的 32 位地址空间按高 8 位分区：

| PicoRV32 地址 | 设备               | PS AXI 地址   | 说明                      |
| ------------- | ------------------ | ------------- | ------------------------- |
| `0x0000_0000` | FW BRAM (32KB)     | `0x4000_0000` | 代码+数据，PS 可写        |
| `0x4000_0000` | CIM CSR (16KB)     | —             | 通过 mini AXI master 访问 |
| `0x8000_0000` | UART TX            | —             | Debug 输出                |
| `0xC000_0000` | Result BRAM (256B) | `0x4200_0000` | PS 可读推理结果           |
| —             | AXI GPIO           | `0x4300_0000` | PS 控制 cpu_rst_n         |

### 2.2 模块层次

```
cim_rv32_top
├── picorv32 (RV32IM CPU)
├── picorv32_cim_bridge (地址译码 → 4 个外设)
│   ├── FW BRAM port A (CPU 侧)
│   ├── CIM start_wr/start_rd → Mini AXI Master → cim_axi_lite_slave
│   ├── UART TX
│   └── Result BRAM port A
├── FW BRAM (32KB, 双端口)
│   └── port B → PS 通过 AXI BRAM Controller 写入
├── Result BRAM (256B, 双端口)
│   └── port B → PS 通过 AXI BRAM Controller 读取
├── uart_tx (8N1, 115200 baud)
└── cim_axi_lite_slave_wrapper → cim_accel_core (与 Step 2 完全相同)
```

### 2.3 Bus Bridge 设计

PicoRV32 的 native bus 是最简单的内存接口：

- CPU 拉高 `mem_valid`，给出 `addr/wdata/wstrb`
- 外设完成后拉高 `mem_ready` 一个周期
- CPU 采样 `mem_rdata`（读操作时）

Bridge 是一个 FSM，根据地址高位路由到不同外设：

```
S_IDLE → 地址译码
  sel_bram → S_BRAM_RD (读) 或 S_DONE (写)
  sel_cim  → S_CIM_WR_WAIT 或 S_CIM_RD_WAIT
  sel_uart → S_DONE (如果 ready) 或 stall
  sel_res  → S_RES_RD (读) 或 S_DONE (写)
→ S_DONE → mem_ready=1 → S_IDLE
```

### 2.4 Mini AXI Master

CIM IP 有一个 AXI4-Lite slave 接口（和 Step 2 完全相同的 `cim_axi_lite_slave_wrapper`）。PicoRV32 不能直接连 AXI，所以需要一个 mini AXI master 翻译：

```
Bridge: cim_start_wr → AXI Master: AWVALID+WVALID → AXI Slave: aw_received+w_received
                                    → BVALID → cim_wr_done → Bridge: mem_ready
```

这样 CIM IP 的 RTL **完全不需要修改**——它看到的就是标准的 AXI4-Lite 事务，和 PS ARM 发的一模一样。

## 3. 遇到的问题和解决方案

### 3.1 VCS 仿真：`always_ff` + `$readmemh` 冲突

**问题：** VCS 报 `Error-[ICPD] Illegal combination of procedural drivers`。
**原因：** `always_ff` 要求变量只有一个驱动源，但 `initial $readmemh` 算第二个。
**解决：** 改为 `always @(posedge clk)`。

### 3.2 firmware.hex 格式不匹配

**问题：** `objcopy -O verilog` 输出逐字节格式（`37 81 00 00`），但 `$readmemh` 期望 32 位 word（`00008137`）。
**解决：** 写了 `verilog_byte_to_word.py` 转换脚本，集成到 Makefile。

### 3.3 UART 无法在 PYNQ 上读取

**问题：** PicoRV32 的 UART TXD 输出到 PMOD-A pin（PL 侧 Y18），但 PYNQ 的 USB 口连的是 PS UART（通过 FTDI），两者物理上完全独立。PYNQ 没有 pyserial，也不能从 USB 读 PL UART。
**尝试 1：** PC 外接 USB-TTL 读串口——需要额外硬件。
**尝试 2：** PYNQ 用 `/dev/ttyPS0` 读——不行，PL UART 和 PS UART 不连通。
**最终方案：** 加一块 **Result BRAM（双端口）**，PicoRV32 把推理结果写入 port A，PS 通过 AXI BRAM Controller 从 port B 读取。这样完全不需要串口。

### 3.4 纯 PL bitstream 无法在 PYNQ 加载

**问题：** 最初的设计是纯 PL（没有 Zynq PS block），bitstream 通过 `cim_rv32_fpga_top.v`（含 MMCM 生成 50MHz 时钟）打包。但 PYNQ 的 `Overlay()` 需要 `.hwh` 文件（只有 Block Design 才能生成），而纯 RTL 工程没有 `.hwh`。尝试了 `pynq.Bitstream()`、`/dev/xdevcfg`、`fpgautil` 都失败或不可用。
**解决：** 改为**混合 PS+PL 设计**——用 Vivado Block Design 包含 Zynq PS（只提供时钟和 AXI），PicoRV32 仍然在 PL 中自主运行。这样就能生成 `.hwh`，`Overlay()` 可以正常加载。

### 3.5 固件烧死在 BRAM 中

**问题：** 最初的设计用 `$readmemh` 在综合时把 firmware.hex 烧进 BRAM 初始值。每换一张测试图片就要重新编译固件 + 重新综合 bitstream（~10 分钟）。
**解决：** FW BRAM 改为双端口，PS 通过 AXI BRAM Controller 在运行时写入 firmware：

```python
# PYNQ 端：
gpio.write(0, 0)            # hold CPU
for addr, word in firmware:  # 写入 FW BRAM
    fw_mmio.write(addr, word)
gpio.write(0, 1)            # release CPU → 开始执行
```

这样一个 bitstream 可以跑所有 20 张测试图，每张只需 Python 端重新加载 hex 文件（几百毫秒）。

## 4. 文件结构

### 4.1 固件侧 (`picorv32/fw/`)

| 文件                      | 作用                                                |
| ------------------------- | --------------------------------------------------- |
| `firmware.c`              | 主程序：配置 CIM → 加载权重 → 推理 → 写 Result BRAM |
| `start.S`                 | 启动汇编：设 SP → 清 BSS → 跳 main                  |
| `firmware.lds`            | 链接脚本：32KB BRAM 布局                            |
| `gen_fw_data.py`          | hex → C 数组转换                                    |
| `small_mlp_quantize.py`   | 784→16→10 小模型训练+量化                           |
| `verilog_byte_to_word.py` | objcopy 输出格式转换                                |
| `build_all_firmware.sh`   | 批量编译 20 个 firmware hex                         |
| `Makefile`                | 编译流程自动化                                      |

### 4.2 硬件侧 (`picorv32/hw/`)

| 文件                               | 作用                                 |
| ---------------------------------- | ------------------------------------ |
| `rtl/riscv/cim_rv32_top.sv`        | 顶层 SoC（CPU+Bridge+BRAM+UART+CIM） |
| `rtl/riscv/cim_rv32_top_wrapper.v` | Verilog wrapper（Vivado BD 用）      |
| `rtl/riscv/picorv32_cim_bridge.sv` | 地址译码总线桥                       |
| `rtl/riscv/uart_tx.sv`             | UART 发送器                          |
| `rtl/riscv/picorv32.v`             | PicoRV32 CPU（开源，未修改）         |
| `tb/tb_cim_rv32.sv`                | 仿真 testbench                       |
| `scripts/vivado_build.tcl`         | Vivado 综合脚本（混合 PS+PL）        |
| `constraints/cim_rv32_pynq.xdc`    | PYNQ-Z2 引脚约束                     |

### 4.3 验证侧 (`sw/`)

| 文件                         | 作用                            |
| ---------------------------- | ------------------------------- |
| `prepare_picorv32_env.ipynb` | 宿主机：训练模型+编译 20 个 hex |
| `pynq_verify_rv32.ipynb`     | PYNQ：批量加载 hex+验证         |
| `fw_hex_batch/`              | 20 个预编译 firmware hex        |

## 5. 设计演进时间线

```
v1 (checkpoint1): 纯 PL 设计 + MMCM + UART 输出
   问题: PYNQ 无法加载（没有 .hwh），无法读 UART（没有 pyserial）
   ↓
v2 (checkpoint2): 混合 PS+PL + Result BRAM
   改进: PS 可以读推理结果
   问题: firmware 烧死在 BRAM，换图片要重新综合
   ↓
v3 (checkpoint3): + 双端口 FW BRAM + AXI GPIO (cpu_rst_n)
   改进: PS 运行时加载 firmware，一个 bitstream 跑 20 张图
   = 最终版本
```
