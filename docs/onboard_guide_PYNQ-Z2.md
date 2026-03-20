# onboard guide PYNQ-Z2

这次的设计是用PS(ARM)驱动的，并不使用PYNQ-Z2板子上的按键和开关，操作会通过Jupyter Notebook里面的代码完成，ARM通过AXI总线直接读写PL里面的CIM加速器硬件。

## 前置条件

1. 需要PYNQ image（从[TUL 网站](https://www.tulembedded.com/fpga/ProductsPYNQ-Z2.html)下载）

2. 完成从SD卡的PYNQ image启动。

3. 使用Jupyter Notebook实现后续操作。

### image烧录

这个大家应该都挺熟悉，但是还是简单说一下。

首先下载好镜像，我这里使用的是`pynq_z2_v3.0.1`镜像。下载之后，用读卡器将SD卡连接到电脑USB口，通过烧录软件将镜像烧录到SD卡中，此处我使用的是balena etcher.

![balenaetcher](../img/balenaetcher.png)

将镜像烧录好之后，把板子的跳线设置为SD卡启动，上电方式根据具体情况选择，如果是选择适配器供电则将跳线设置为`REG`，如果是USB-uart供电则是设置为`USB`. 初次启动可能用时较长，等到闪烁蓝灯就说明已经从SD卡启动了。

### PYNQ连接到PC

连接有两种方式，一种是uart，一种是网线连接。

这里两个方法都有坑。首先是uart，一定要选择micro-USB(A)数据线，而不是充电线。充电线只能供电，不能实现串口传输。接上之后，通过`sudo dmesg | grep "tty"`找到新增接口，应该类似`ttyUSBx`，找到接口之后，我们就可以通过minicom或者是putty进行串口连接。我这里使用的是`minicom`，连接方式是：`minicom -D /dev/ttyUSBx -b 115200`，看到有相关信息，则说明启动成功（如果错误了启动信息，输入`ls`有回应即可）。

第二个是通过网线连接。如果有路由器，直接让电脑连接路由器网络然后板子网线连接路由器是最简单的解法，但是有些时候没有路由器，只能使用电脑的网卡，这个就需要配置好IP.

对于laptop来说，我们需要首先将有线网卡IP手动设置为`192.168.2.1`，子网掩码`255.255.255.0`，网关留空。

可以通过`ip link`找到网卡，一般来说，网卡是`enp`开头，wifi是`wlp`开头，`lo`,`docker0`等不要理会。找到之后，手动设置ip：

```bash
sudo ip addr flush dev enpxxx

sudo ip addr add 192.168.2.1/24 dev enpxxx

sudo ip link set enpxxx up
```

不过这个设置重启之后会丢失。如果持久修改，使用NetworkManager:

```bash
nmcli con add type ethernet ifname enpxxx con-name pynq ip4 192.168.2.1/24 method manual
nmcli con up pynq
```

不过一般不建议持久化，因为持久化修改可能会影响电脑平时的网络配置（配置过虚拟机EDA软件的都知道，即使是改了网卡名字也要改好多配置文件不然就会连不上网）。

PYNQ启动后，默认IP是`192.1688.2.99`，如果没有的话可以通过`ip a`来查询；在浏览器中打开`http://129.168.2.99:9090`即可登录，默认账号和密码都是`xilinx`.

_如果是路由器连接，直接ip a找到板子ip就好了。如果ip a找不到，默认IP也不对，可以先用串口连接，进入PYNQ镜像之后，在串口中输入ip a查询板子的IP._

## 使用流程（有线网卡或路由）

### 上传部署文件

将`cim_soc.bit`和`cim_soc.hwh`上传到PYNQ的Jupyter同一目录下。（两个文件除后缀必须同名）

### python code: load overlay，完成推理

```python
from pynq import Overlay, MMIO
import numpy as np

# ---- 加载 bitstream ----
ol = Overlay("cim_soc.bit")

# ---- MMIO：基地址 0x40000000，范围 4KB ----
BASE = 0x40000000
mmio = MMIO(BASE, 0x1000)

# ---- CSR 地址偏移（与 cim_pkg.sv 完全对应）----
CTRL         = 0x000    # [0]=start [1]=clear_done [2]=soft_rst
STATUS       = 0x004    # [0]=busy [1]=done
IN_DIM       = 0x010
OUT_DIM      = 0x014
N_IB         = 0x018
N_OB         = 0x01C
REQUANT_MULT = 0x020
REQUANT_SHIFT= 0x024
INPUT_ZP     = 0x028
ACT_MODE     = 0x02C
WDMA_ADDR    = 0x044
WDMA_DATA    = 0x048
WDMA_CTRL    = 0x04C
PRED_CLASS   = 0x040
LOGIT_BASE   = 0x080
MEM_INPUT    = 0x400
MEM_BIAS     = 0x800

# ---- 软复位 ----
mmio.write(CTRL, 0x4)  # bit[2] = soft_rst

# ========== FC1: 784 → 128, ReLU ==========
mmio.write(IN_DIM,  784)
mmio.write(OUT_DIM, 128)
mmio.write(N_IB,    49)       # ceil(784/16)
mmio.write(N_OB,    8)        # ceil(128/16)
mmio.write(REQUANT_MULT,  fc1_mult)   # 从量化模型获取
mmio.write(REQUANT_SHIFT, fc1_shift)
mmio.write(INPUT_ZP, 0xFFFFFF80)       # -128 的补码
mmio.write(ACT_MODE, 1)                # 1 = ReLU

# 加载权重（burst 模式）
mmio.write(WDMA_ADDR, 0)
mmio.write(WDMA_CTRL, 0x02)           # bit[1]=burst enable
for chunk in fc1_weight_chunks:        # 每个 32-bit
    mmio.write(WDMA_DATA, int(chunk))  # 自动递增 chunk/tile

# 加载偏置
for i, b in enumerate(fc1_bias):
    mmio.write(MEM_BIAS + 4*i, int(b) & 0xFFFFFFFF)

# 写入输入（uint8 图像像素）
for i, x in enumerate(input_image):
    mmio.write(MEM_INPUT + 4*i, int(x))

# 启动推理
mmio.write(CTRL, 0x1)

# 等待完成
while not (mmio.read(STATUS) & 0x2):
    pass

# 读取 FC1 输出（128 个 int8 logit）
fc1_out = []
for i in range(128):
    v = mmio.read(LOGIT_BASE + 4*i)
    fc1_out.append(np.int8(v & 0xFF))

# 清除 done 标志
mmio.write(CTRL, 0x2)

# ========== FC2: 128 → 10, None (no activation) ==========
mmio.write(IN_DIM,  128)
mmio.write(OUT_DIM, 10)
mmio.write(N_IB,    8)
mmio.write(N_OB,    1)
mmio.write(REQUANT_MULT,  fc2_mult)
mmio.write(REQUANT_SHIFT, fc2_shift)
mmio.write(INPUT_ZP, 0x00000000)       # FC2 输入 zp = 0
mmio.write(ACT_MODE, 0)                # 0 = None

# 加载 FC2 权重、偏置（同上方式）...

# FC1 的输出作为 FC2 的输入
for i, x in enumerate(fc1_out):
    mmio.write(MEM_INPUT + 4*i, int(x) & 0xFF)

mmio.write(CTRL, 0x1)
while not (mmio.read(STATUS) & 0x2):
    pass

# ---- 最终结果 ----
pred = mmio.read(PRED_CLASS)
print(f"Predicted digit: {pred}")

```

## 使用流程（纯串口）

把`cim_soc.bit`和`cim_soc.hwh`，权重文件等，放入SD卡的`/home/xilinx/`也可以，通过串口终端的`python3`运行脚本，不过换文件需要插拔SD卡，比较麻烦。
