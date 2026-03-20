# Vivado Block Design 搭建指南 — CIM SoC on PYNQ-Z2

## 概览

这里是一个在 Vivado 中搭建 Zynq PS + CIM 加速器 IP 的完整 SoC 系统的指南。

最终的 Block Design 架构如下：

```
┌─────────────────────────────────────────────────────────┐
│                     ZYNQ PS (ARM A9)                    │
│                                                         │
│  M_AXI_GP0 ──────┐                    FCLK_CLK0 (100M) │
│                   │                          │          │
│  IRQ_F2P[0] ◄────│──────────┐               │          │
└───────────────────│──────────│───────────────│──────────┘
                    ▼          │               ▼
           ┌────────────────┐  │      ┌──────────────┐
           │ AXI Interconnect│  │      │ Proc Sys Reset│
           │ (1 master,      │  │      └──────────────┘
           │  1 slave)       │  │
           └───────┬────────┘  │
                   │           │
                   ▼           │
        ┌──────────────────┐   │
        │ cim_axi_lite_slave│───┘
        │                  │  irq_done
        │  (your CIM IP)   │
        │                  │
        │  addr: 0x4000_0000│
        └──────────────────┘
```

## 前置条件

1. **Vivado 2024.2+**（免费 Standard Edition 支持 xc7z020）
2. **PYNQ-Z2 board file**（从 [TUL 网站](https://www.tulembedded.com/fpga/ProductsPYNQ-Z2.html) 下载）
3. **本项目 RTL 文件**（hw/rtl/ 下全部 .sv）

4. 装好PYNQ-Z2 board file.
   没有装的话会有`apply_bd_automation`失败，因为PS的DDR/MIO配置不会自动填。

5. 装法：把board file文件夹放到`<Vivado_install_path>/data/boards/board_files/pynq-z2/`下。

## 运行文件

直接在项目根目录下运行`bash hw/scripts/vivado_build.sh`，就可以完成block desgin.

## 手动配置

如果想要手动配置，也可以：

### 步骤 1：创建工程

```
1. File → New Project → Next
2. Project name: cim_soc
3. Project type: RTL Project, 勾选 "Do not specify sources at this time"
4. Part: 选择 Boards → PYNQ-Z2（如果装了 board file）
   或手动选择 xc7z020clg400-1
5. Finish
```

### 步骤 2：添加 RTL 源文件

```
1. 在 Sources 面板右键 → Add Sources → Add or create design sources
2. Add Files → 选择以下文件（按顺序）:
   - hw/rtl/pkg/cim_pkg.sv          ← 必须第一个
   - hw/rtl/core/cim_tile.sv
   - hw/rtl/core/psum_accum.sv
   - hw/rtl/core/activation_unit.sv
   - hw/rtl/mem/weight_sram.sv
   - hw/rtl/mem/bias_sram.sv
   - hw/rtl/mem/input_buffer.sv
   - hw/rtl/mem/output_buffer.sv
   - hw/rtl/core/cim_accel_core.sv
   - hw/rtl/axi/cim_axi_lite_slave.sv
3. 确保 cim_pkg.sv 的 Library 设置为 xil_defaultlib
4. 确保 cim_axi_lite_slave 被设为 top module（或让 Vivado 自动推断）
```

### 步骤 3：将 CIM 模块打包为 IP

为了在 Block Design 中使用，需要把 `cim_axi_lite_slave` 打包成 AXI IP。

#### 方法 A：手动使用 IP Packager（推荐）

```
1. Tools → Create and Package New IP → Next
2. 选择 "Package your current project" → Next → Finish
3. 在 Package IP 界面:
   a. Identification: 填写名称 "cim_accel" 版本 "1.0"
   b. File Groups: 自动检测
   c. Ports and Interfaces:
      - 选择 S_AXI_* 端口 → 右键 → Auto Infer Interface
      - 应自动识别为 AXI4-Lite Slave
      - 选择 S_AXI_ACLK → 关联为 clock
      - 选择 S_AXI_ARESETN → 关联为 reset (active low)
      - 选择 irq_done → 设置为 interrupt
   d. Addressing and Memory:
      - 设置 AXI slave 地址范围: 4K (0x1000)
   e. Review and Package → Package IP
```

#### 方法 B：直接在 BD 中使用 RTL Module（快捷）

```
1. Create Block Design → 命名 "system"
2. 在 BD 画布右键 → Add Module
3. 选择 cim_axi_lite_slave → 它会自动出现为一个模块
4. Vivado 会自动识别 AXI 接口（如果端口命名规范的话）
```

### 步骤 4：搭建 Block Design

#### 4.1 添加 Zynq PS

```
1. 在 BD 中 "+" 搜索 → ZYNQ7 Processing System → 双击添加
2. 双击 Zynq PS 进入配置:
   a. 如果用了 board file，点击 "Run Block Automation" → 自动配置 DDR/MIO
   b. 手动配置要点:
      - PS-PL Configuration → HP Slave AXI Interface → 取消全部（暂不需要）
      - PS-PL Configuration → GP Master AXI Interface → 启用 M_AXI_GP0
      - Clock Configuration → PL Fabric Clocks → FCLK_CLK0 = 100 MHz
      - Interrupts → Fabric Interrupts → 启用 IRQ_F2P[0]
   c. OK
```

#### 4.2 添加 CIM IP

```
1. 如果用方法 A: "+" 搜索 "cim_accel" → 添加
   如果用方法 B: 右键 → Add Module → 选择 cim_axi_lite_slave
```

#### 4.3 连接

```
1. 点击 "Run Connection Automation" → 勾选全部 → OK
   Vivado 会自动添加:
   - AXI Interconnect（连接 PS M_AXI_GP0 到 CIM S_AXI）
   - Processor System Reset（生成同步复位）
   - 时钟连接

2. 手动连接中断:
   - 从 CIM IP 的 irq_done 端口拖线到 Zynq PS 的 IRQ_F2P[0:0]

3. 设置地址映射:
   - Address Editor 标签页
   - CIM IP: 基址 0x4000_0000, Range 4K
   - 这个地址在 PYNQ Python 中通过 MMIO 访问
```

#### 4.4 验证设计

```
1. Tools → Validate Design (F6)
2. 确保没有 Critical Warning 或 Error
3. 常见问题:
   - 时钟没连: 确保所有 aclk 都连到 FCLK_CLK0
   - 复位没连: 确保 aresetn 连到 proc_sys_reset 的 peripheral_aresetn
   - 地址冲突: 在 Address Editor 中确认没有重叠
```

### 步骤 5：生成 Bitstream

```
1. 在 BD 上右键 → Generate Output Products → Generate
2. 在 BD 上右键 → Create HDL Wrapper → Let Vivado manage → OK
3. Flow Navigator → Generate Bitstream → 等待完成

输出文件:
  - .bit 文件: vivado_proj/cim_soc.runs/impl_1/system_wrapper.bit
  - .hwh 文件: vivado_proj/cim_soc.gen/sources_1/bd/system/hw_handoff/system.hwh
```

### 步骤 6：在 PYNQ 上运行

#### 6.1 上传文件到 PYNQ

将以下两个文件上传到 PYNQ 板上的 Jupyter 同一目录下，**且文件名必须一致**:

```
cim_soc.bit    ← 重命名 system_wrapper.bit
cim_soc.hwh    ← 重命名 system.hwh
```

#### 6.2 Python 驱动代码

```python
from pynq import Overlay, MMIO
import numpy as np

# 加载 overlay
ol = Overlay("cim_soc.bit")
print("Overlay loaded!")

# CIM IP 的基地址和地址空间大小
CIM_BASE = 0x4000_0000
CIM_SIZE = 0x1000  # 4KB

mmio = MMIO(CIM_BASE, CIM_SIZE)

# =============================================
# CSR 地址定义（和 cim_pkg.sv 一致）
# =============================================
CSR_CTRL         = 0x000
CSR_STATUS       = 0x004
CSR_IN_DIM       = 0x010
CSR_OUT_DIM      = 0x014
CSR_N_IB         = 0x018
CSR_N_OB         = 0x01C
CSR_REQUANT_MULT = 0x020
CSR_REQUANT_SHIFT= 0x024
CSR_INPUT_ZP     = 0x028
CSR_ACT_MODE     = 0x02C
CSR_CYCLE_CNT_LO = 0x030
CSR_MAC_CNT_LO   = 0x038
CSR_PRED_CLASS   = 0x040
CSR_LOGIT_BASE   = 0x080
CSR_WDMA_ADDR    = 0x044
CSR_WDMA_DATA    = 0x048
CSR_WDMA_CTRL    = 0x04C
MEM_INPUT_BASE   = 0x400
MEM_BIAS_BASE    = 0x800

# =============================================
# 辅助函数
# =============================================
def write_csr(offset, value):
    mmio.write(offset, int(value) & 0xFFFFFFFF)

def read_csr(offset):
    return mmio.read(offset)

def wait_done():
    """Polling wait for done."""
    while True:
        status = read_csr(CSR_STATUS)
        if status & 0x2:  # done bit
            return status

def configure_layer(in_dim, out_dim, zp=-128, mult=1, shift=0, act=1):
    """Configure CIM for a layer."""
    n_ib = (in_dim + 15) // 16
    n_ob = (out_dim + 15) // 16
    write_csr(CSR_IN_DIM, in_dim)
    write_csr(CSR_OUT_DIM, out_dim)
    write_csr(CSR_N_IB, n_ib)
    write_csr(CSR_N_OB, n_ob)
    write_csr(CSR_INPUT_ZP, zp & 0xFFFFFFFF)
    write_csr(CSR_REQUANT_MULT, mult)
    write_csr(CSR_REQUANT_SHIFT, shift)
    write_csr(CSR_ACT_MODE, act)
    print(f"  Configured: {in_dim}→{out_dim}, n_ib={n_ib}, n_ob={n_ob}")

def load_input(data_uint8):
    """Write input data to input buffer."""
    for i, val in enumerate(data_uint8):
        mmio.write(MEM_INPUT_BASE + i * 4, int(val))
    print(f"  Loaded {len(data_uint8)} input elements")

def load_bias(bias_int32):
    """Write bias to bias SRAM."""
    for i, val in enumerate(bias_int32):
        mmio.write(MEM_BIAS_BASE + i * 4, int(val) & 0xFFFFFFFF)
    print(f"  Loaded {len(bias_int32)} bias values")

def load_weight_tile(tile_idx, tile_data_bytes):
    """Write one weight tile (256 bytes for 16x16 INT8) via DMA registers."""
    # tile_data_bytes: flat array of 256 INT8 values
    CHUNKS = 256 * 8 // 32  # = 64 chunks of 32 bits
    for chunk in range(CHUNKS):
        # Pack 4 INT8 values into one 32-bit word
        word = 0
        for b in range(4):
            idx = chunk * 4 + b
            if idx < len(tile_data_bytes):
                word |= (int(tile_data_bytes[idx]) & 0xFF) << (b * 8)
        write_csr(CSR_WDMA_ADDR, tile_idx)
        write_csr(CSR_WDMA_DATA, word)
        write_csr(CSR_WDMA_CTRL, (chunk << 4) | 0x1)  # chunk_idx + wr_en

def load_weights(weight_int8, tile_rows=16, tile_cols=16):
    """Load full weight matrix into weight SRAM."""
    out_dim, in_dim = weight_int8.shape
    n_ob = (out_dim + tile_rows - 1) // tile_rows
    n_ib = (in_dim + tile_cols - 1) // tile_cols
    for ob in range(n_ob):
        for ib in range(n_ib):
            tile_idx = ob * n_ib + ib
            tile_flat = []
            for r in range(tile_rows):
                for c in range(tile_cols):
                    oi = ob * tile_rows + r
                    ii = ib * tile_cols + c
                    if oi < out_dim and ii < in_dim:
                        tile_flat.append(weight_int8[oi, ii])
                    else:
                        tile_flat.append(0)
            load_weight_tile(tile_idx, tile_flat)
    print(f"  Loaded {n_ob * n_ib} weight tiles ({out_dim}×{in_dim})")

def run_inference():
    """Trigger CIM computation and wait."""
    write_csr(CSR_CTRL, 0x3)  # bit0=start, bit1=clear_done
    status = wait_done()
    cycles = read_csr(CSR_CYCLE_CNT_LO)
    macs = read_csr(CSR_MAC_CNT_LO)
    pred = read_csr(CSR_PRED_CLASS)
    print(f"  Done! cycles={cycles}, MACs={macs}, pred={pred}")
    return pred

def read_output(out_dim):
    """Read output logits."""
    out = np.zeros(out_dim, dtype=np.int8)
    for i in range(out_dim):
        val = read_csr(CSR_LOGIT_BASE + i * 4)
        out[i] = np.int8(val & 0xFF)  # sign extend handled by numpy
    return out

# =============================================
# MNIST Demo: 784 → 128 → 10
# =============================================
def mnist_demo():
    """Run a 2-layer MLP inference."""
    # --- 在这里加载你的量化模型权重 ---
    # w1 = np.load("fc1_weight.npy")  # shape (128, 784), int8
    # b1 = np.load("fc1_bias.npy")    # shape (128,), int32
    # w2 = np.load("fc2_weight.npy")  # shape (10, 128), int8
    # b2 = np.load("fc2_bias.npy")    # shape (10,), int32
    # quant_params = np.load("quant.npz")  # mult, shift for each layer
    # test_image = np.load("test_img.npy")  # shape (784,), uint8

    # --- Layer 1: 784 → 128 ---
    print("=== Layer 1: FC 784→128 (ReLU) ===")
    # load_weights(w1)
    # load_bias(b1)
    # load_input(test_image)
    # configure_layer(784, 128, zp=-128, mult=quant_params['fc1_mult'],
    #                 shift=quant_params['fc1_shift'], act=1)
    # run_inference()
    # fc1_output = read_output(128)

    # --- Layer 2: 128 → 10 ---
    print("=== Layer 2: FC 128→10 (None) ===")
    # load_weights(w2)
    # load_bias(b2)
    # load_input(fc1_output.view(np.uint8))
    # configure_layer(128, 10, zp=0, mult=quant_params['fc2_mult'],
    #                 shift=quant_params['fc2_shift'], act=0)
    # pred = run_inference()
    # logits = read_output(10)

    # print(f"\\nLogits: {logits}")
    # print(f"Prediction: {pred}")
    pass

if __name__ == "__main__":
    mnist_demo()
```

## 关于xdc

上一个项目[_MNIST-CIM-FPGA_](https://github.com/Invoker-pray/MNIST-CIM-FPGA)是纯PL设计，顶层直接接时钟、按钮、LED、UART 等物理引脚，所以需要逐个用 `set_property PACKAGE_PIN` 告诉 Vivado 每个信号对应 FPGA 的哪个管脚。

这次写的CIM SoC是Zynq PS + PL设计，架构不同；

顶层是`cim_axi_lite_slave_wrapper.v`是vivado自动生成的，已经有了外部端口`DDR`和`FIXED_IO`；这两组端口都是 PS 侧的硬连线引脚，在 Zynq 芯片内部就已经固定了物理位置，不经过 PL 可编程 IO，当你在 TCL 里用 apply_bd_automation 配合 PYNQ-Z2 board file 时，Vivado 自动把 DDR 时序、MIO 配置等全部写入 PS7 IP 内部，不需要也不允许在 XDC 里手动约束这些引脚。CIM 加速器通过 AXI 总线和 PS 通信，所有数据从 Python/PYNQ 经 MMIO 读写，没有任何 PL 侧的物理 IO，Zynq设计中手动写反而会有DRC错误，交给board automation处理就好了。

这次的xdc只有：时钟约束，bistream配置。

如果想要单独调试，应该在block design里把信号make_external，然后在官方XDC中取消对应行的注释。

## 常见问题

**Q: AXI 接口没被自动识别怎么办？**
A: 确保端口命名严格遵循 `S_AXI_AWADDR`, `S_AXI_WDATA` 等。如果不行，手动在 IP Packager 中关联。

**Q: 综合报错 cim_pkg 找不到？**
A: 确保 cim_pkg.sv 在 compile order 中排第一。在 Sources 面板中右键 → Set File Type → SystemVerilog。

**Q: PYNQ MMIO 读写没反应？**
A: 检查地址映射是否为 0x4000_0000。用 `mmio.read(0x004)` 读 STATUS 寄存器验证连接。

**Q: 时序不收敛？**
A: 100MHz 对于 Zynq-7020 上的 CIM 设计应该没问题。如果关键路径在 CIM tile 的组合乘加逻辑，可以降到 50MHz 或在 cim_tile 和 psum_accum 之间插入一级流水。
