# KV260 PetaLinux 上板指南

这是 KV260 移植的第二阶段——用 PetaLinux 替代 Ubuntu+Kria-PYNQ 方案，构建完整的嵌入式 Linux 系统，
将 CIM 加速器比特流直接集成到 BOOT.BIN 中，实现上电即用的推理平台。

## 背景

第一阶段（`kv260_migration.md`）使用了 Ubuntu 22.04 + Kria-PYNQ 方案：
- 在 Ubuntu 上安装 PYNQ，通过 `Overlay` 或 `fpgautil` 加载 PL 比特流
- 依赖 Ubuntu rootfs（~4GB SD 卡镜像）、Kria-PYNQ 安装脚本、网络下载
- 安装过程受网络环境影响大，PYNQ 版本与 Ubuntu 版本有兼容性约束

PetaLinux 方案的优势：
- **自包含**：BOOT.BIN（FSBL + PMU + ATF + U-Boot + bitstream）+ image.ub（kernel + DTB）+ rootfs 全部本地构建
- **确定性**：构建一次即可重复烧录，不依赖在线下载
- **快速启动**：精简的 rootfs，启动时间远小于 Ubuntu
- **与硬件匹配**：DTB 由 Vivado XSA 自动生成，确保 PL 外设地址映射正确

## 构建流程

### 1. 构建比特流（Vivado）

```bash
cd /home/jiao/git/INT8-CIM-of-jiao
bash kv260/hw/scripts/vivado_build.sh
```

输出：
- `kv260/deploy/cim_soc_kv260.bit` — PL 比特流
- `kv260/deploy/cim_soc_kv260.hwh` — 硬件描述（供软件解析寄存器地址）
- `kv260/deploy/cim_soc_kv260.xsa` — Vivado 硬件平台导出（供 PetaLinux 使用）

### 2. 构建 PetaLinux

```bash
cd kv260_petalinux/cim_kv260
petalinux-config --get-hw-description=../../kv260/deploy/cim_soc_kv260.xsa
petalinux-build          # 7761 个任务，约 30-60 分钟
petalinux-package --boot --u-boot --fsbl --fpga --force
```

输出（在 `images/linux/` 下）：

| 文件 | 大小 | 用途 |
|------|------|------|
| BOOT.BIN | 9.2 MB | FSBL + PMU + ATF + U-Boot + bitstream |
| image.ub | 10 MB | Kernel + device tree |
| rootfs.ext4 | 407 MB | 根文件系统 |
| system.dtb | 37 KB | 设备树二进制 |
| boot.scr | 3.7 KB | U-Boot 启动脚本 |

### 3. 烧录 SD 卡

```bash
# 假设 SD 卡为 /dev/sdX，有两个分区：
#   p1: FAT32 (boot, ~500MB)
#   p2: ext4  (root, ~4GB)

# 复制启动文件到 boot 分区
cp BOOT.BIN image.ub system.dtb boot.scr /mnt/boot/

# 解压根文件系统到 root 分区
sudo tar xzf rootfs.tar.gz -C /mnt/root/
```

### 4. 启动

插入 microSD 卡，连接 12V 电源和 microUSB（UART），上电。

**关键：连接 J4 口（标 UART），不是 J3（USB Hub）。**

串口设置：115200 8N1

**KV260 会同时创建 4 个 ttyUSB 设备。必须选择编号第二小的那个（不是 ttyUSB0 也不是 ttyUSB2/3）。**

```bash
# 插上 microUSB 线后查看
ls /dev/ttyUSB*
# 输出类似：ttyUSB0  ttyUSB1  ttyUSB2  ttyUSB3
# 第一个 (ttyUSB0) 是 JTAG
# 第二个 (ttyUSB1) 是 UART  ← 用这个
# 第三、四个 是 I2C/RP-Sync

# 连接（用你实际的编号，第二小的）
screen /dev/ttyUSB1 115200
# 或
picocom -b 115200 /dev/ttyUSB1
```

**如果上电后串口无输出，按住 FWUEN 按钮（靠近 microSD 卡槽）再上电，强制从 SD 卡启动。**

默认登录：`root` / `root`

## 地址映射

| 设备 | 地址 | 大小 | 说明 |
|------|------|------|------|
| CIM CSR | `0xA0000000` | 16 KB | 通过 `/dev/mem` 访问 |
| DMA CSR | `0xB0000000` | 64 KB | PS DMAC 控制寄存器 |
| PS DDR | `0x00000000` | 4 GB | 推理数据缓冲区 |

设备树自动从 Vivado XSA 生成（`pl.dtsi`）：

```dts
cim_0: cim_top_wrapper@a0000000 {
    compatible = "xlnx,cim-top-wrapper-1.0";
    reg = <0x0 0xa0000000 0x0 0x4000>;
    clock-names = "S_AXI_ACLK";
    clocks = <&zynqmp_clk 71>;
};
axi_dma_0: dma@b0000000 {
    compatible = "xlnx,axi-dma-7.1", "xlnx,axi-dma-1.00.a";
    reg = <0x0 0xb0000000 0x0 0x10000>;
    ...
};
```

## 验证方法

PetaLinux rootfs 自带 Python 3，无需安装 PYNQ 即可进行 MMIO 访问。

### 验证 1：MMIO 连通性

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

# 读取 CSR_STATUS（偏移 0x004），期望 bit[0]（busy）= 0
status = cim.read(0x004)
print(f"CSR_STATUS = 0x{status:08X}  (busy={status & 1})")
```

预期：`busy=0`，说明 CIM 处于空闲状态。

### 验证 2：单层推理（FC1: 784→128）

1. 通过 DMA 加载权重（weight_sram）和偏置（bias_sram）
2. 通过 DMA 加载 MNIST 输入数据（input_buffer）
3. 配置 CSR（IN_DIM=784, OUT_DIM=128, N_IB=49, N_OB=8, requant 参数）
4. 写 CSR_CTRL[0]=1 启动计算
5. 轮询 CSR_STATUS[1]（done）
6. 通过 DMA 读回 output_buffer（128 个 INT8 logits）
7. 计算 argmax 得到预测类别

### 验证 3：端到端 MNIST 推理（200 张图片）

```python
correct = 0
for i, (img, label) in enumerate(test_loader):
    # 加载图片到 input_buffer
    load_input_via_dma(img)
    # 推理
    run_layer_fc1()
    run_layer_fc2()
    # 读取结果
    logits = read_output_via_dma()
    pred = logits.argmax()
    if pred == label:
        correct += 1
print(f"Accuracy: {correct}/200 = {correct/200*100:.2f}%")
```

### 验证 4：LeNet-5 端到端推理

1. 导出 LeNet-5 INT8 量化权重（`sw/lenet5_quantize.py`）
2. 对每一层配置 CSR，启动 CIM 计算
3. Conv 层：软件 im2col 后通过 FC 方式计算
4. FC 层：直接使用 CIM 计算
5. 统计总延迟和精度

## 性能验证

### Profiling 工具

使用 Python `time.perf_counter()` 测量各阶段延迟：

```python
import time

t0 = time.perf_counter()
load_weights()        # DMA MM2S weight → CIM
t1 = time.perf_counter()
load_input(img)       # DMA MM2S input → CIM  
t2 = time.perf_counter()
start_compute()       # CSR_CTRL[0]=1
wait_done()           # 轮询 CSR_STATUS[1]
t3 = time.perf_counter()
read_output()         # DMA S2MM output → DDR
t4 = time.perf_counter()

print(f"load_w: {t1-t0:.1f}ms, load_x: {t2-t1:.1f}ms, "
      f"compute: {t3-t2:.1f}ms, read_out: {t4-t3:.1f}ms, "
      f"total: {t4-t0:.1f}ms")
```

### 预期性能（PAR_OB=8, 100MHz）

| 指标 | PYNQ-Z2 (60MHz, PAR_OB=1) | KV260 (100MHz, PAR_OB=8, 预期) | 提升 |
|------|---------------------------|-------------------------------|------|
| MLP FC1 (784→128) | ~45 μs | ~3-4 μs | ~12× |
| MLP FC2 (128→10) | ~8 μs | ~1 μs | ~8× |
| MLP 端到端延迟 | ~37 ms/img | ~5-10 ms/img | ~4-7× |
| LeNet-5 端到端延迟 | ~29 ms/img | ~5-10 ms/img | ~3-6× |
| 推理吞吐量 | ~27 fps | ~100-200 fps | ~4-7× |

注：端到端延迟包含软件 im2col（Conv 层）和 DMA 传输时间。纯硬件计算部分的加速比约 12-16×（PAR_OB 8× + 时钟 1.67×）。

### 瓶颈分析

当前瓶颈（按占比排序）：
1. **软件 im2col**（Conv 层）：约占总延迟 30-40%
2. **DMA 传输**（weight + input + output）：约占总延迟 20-30%
3. **CIM 计算**：约占总延迟 15-20%

后续优化方向：
- Phase D：预加载所有权重到 BRAM，仅切换输入/输出
- Phase E：Conv 硬件加速（硬件 im2col）
- 使用 URAM 扩展 BRAM 容量，支持更大网络

### 与 PYNQ-Z2 上板流程的关键区别

| 项目 | PYNQ-Z2 | KV260 PetaLinux |
|------|---------|-----------------|
| 操作系统 | PYNQ Linux (基于 Ubuntu) | PetaLinux (Yocto) |
| Python 环境 | Jupyter Notebook (PYNQ) | 命令行 Python（/dev/mem MMIO） |
| 比特流加载 | `Overlay("cim_soc.bit")` | 已嵌入 BOOT.BIN（上电自动加载） |
| CIM 基地址 | `0x40000000` | `0xA0000000` |
| DMA 基地址 | `0x40400000` | `0xB0000000` |
| 网络 | 以太网 + WiFi | 仅以太网 |
| 存储 | SD 卡（PYNQ 镜像） | SD 卡（PetaLinux 构建） |
| 驱动方式 | PYNQ DMA 库 | /dev/mem + 自定义 DMA 驱动或 UIO |

## DTS 修复记录

构建过程中发现并修复的设备树问题：

### 1. Memory reg（system-user.dtsi）

KV260 在 device tree 中使用 `#size-cells=2`，因此 4GB 内存需要表示为 `<0x0 0x0 0x1 0x0>`（即地址 0，大小 1×4GB）：

```dts
memory {
    device_type = "memory";
    reg = <0x0 0x0 0x1 0x0>;
};
```

### 2. GEM3 PHY（system-user.dtsi）

板卡预设生成的 DTS 缺少 GEM3 的 PHY 节点定义，需手动添加：

```dts
&gem3 {
    status = "okay";
    phy-mode = "rgmii-id";
    phy-handle = <&phy0>;
    mdio {
        #address-cells = <1>;
        #size-cells = <0>;
        phy0: ethernet-phy@0 {
            reg = <0>;
        };
    };
};
```

## 参考资料

- `docs/kv260_migration.md` — KV260 硬件对比与第一阶段的 Ubuntu+Kria-PYNQ 上板方案
- `docs/c3_dma_design.md` — DMA 数据通路设计
- `docs/c3_onboard_tutorial.md` — C3 DMA 上板教程
- `kv260_petalinux/cim_kv260/` — PetaLinux 工程目录
