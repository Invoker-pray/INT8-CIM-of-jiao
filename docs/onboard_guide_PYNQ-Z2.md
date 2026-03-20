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

![login](../img/login.png)

## 使用流程（有线网卡或路由）

### 上传部署文件

将`cim_soc.bit`和`cim_soc.hwh`上传到PYNQ的Jupyter同一目录下。（两个文件除后缀必须同名）

### cim_basic_test

新建一个ipynb(cim_basic_test.ipynb)，进行基本测试。

```python
from pynq import Overlay, MMIO
import numpy as np

# ---- 加载 bitstream ----
ol = Overlay("cim_soc.bit")
print("Overlay loaded!")

# ---- MMIO ----
BASE = 0x40000000
mmio = MMIO(BASE, 0x1000)

# ---- CSR 地址 ----
CTRL   = 0x000
STATUS = 0x004
IN_DIM = 0x010

# ---- 测试1: 读 STATUS 寄存器 ----
status = mmio.read(STATUS)
print(f"STATUS = 0x{status:08x}  (expect: busy=0, done=0)")

# ---- 测试2: 写再读 IN_DIM ----
mmio.write(IN_DIM, 784)
readback = mmio.read(IN_DIM)
print(f"IN_DIM write=784, readback={readback}  {'PASS' if readback == 784 else 'FAIL'}")

# ---- 测试3: 软复位 ----
mmio.write(CTRL, 0x4)
status = mmio.read(STATUS)
print(f"After soft_rst: STATUS = 0x{status:08x}")

print("\n=== AXI connectivity test done ===")
```

以上内容如果正确，说明PS<-->PL通路正常，接下来可以跑完整推理。

### full_cim_test

然后可以进行完整推理。首先在PC生成数据：

```bash
cd sw/
python3 golden_model.py --mnist-e2e --output-dir mnist_data
```

然后把mnist_data上传到PYNQ，在notebook(full_test.ipynb)里面跑完整推理代码：

```python
from pynq import Overlay, MMIO
import numpy as np
import os

# ====================================================================
# 1. 加载 bitstream
# ====================================================================
ol = Overlay("cim_soc.bit")
print("Overlay loaded!")

BASE = 0x40000000
mmio = MMIO(BASE, 0x4000)   # 16KB address space

# ====================================================================
# 2. CSR 地址定义 (与 cim_pkg.sv 完全对应, 14-bit addr space)
# ====================================================================
CTRL          = 0x000
STATUS        = 0x004
CSR_IN_DIM    = 0x010
CSR_OUT_DIM   = 0x014
CSR_N_IB      = 0x018
CSR_N_OB      = 0x01C
REQUANT_MULT  = 0x020
REQUANT_SHIFT = 0x024
INPUT_ZP      = 0x028
ACT_MODE      = 0x02C
CYCLE_CNT_LO  = 0x030
MAC_CNT_LO    = 0x038
PRED_CLASS    = 0x040
WDMA_ADDR     = 0x044
WDMA_DATA     = 0x048
WDMA_CTRL     = 0x04C
LOGIT_BASE    = 0x100
MEM_INPUT     = 0x1000
MEM_BIAS      = 0x2000

# ====================================================================
# 3. 内嵌 Golden Model (不依赖外部 hex 文件)
# ====================================================================
TILE_ROWS = 16
TILE_COLS = 16
ELEMS_PER_CHUNK = 4   # 32 / 8
CHUNKS_PER_ROW  = 4   # TILE_COLS / ELEMS_PER_CHUNK

def apply_zero_point(x_uint8, zero_point):
    x_eff = x_uint8.astype(np.int32) - zero_point
    return np.clip(x_eff, 0, 511).astype(np.uint16)

def requantize_int32_to_int8(x, mult, rshift):
    result = np.zeros(len(x), dtype=np.int8)
    for i in range(len(x)):
        prod = int(x[i]) * int(mult)
        if rshift == 0:
            shifted = prod
        else:
            shifted = (prod + (1 << (rshift - 1))) >> rshift
        shifted = max(-128, min(127, shifted))
        result[i] = np.int8(shifted)
    return result

def infer_layer(input_uint8, weight_int8, bias_int32,
                zero_point=-128, requant_mult=1, requant_shift=0, activation="relu"):
    x_eff = apply_zero_point(input_uint8, zero_point)
    acc = weight_int8.astype(np.int32) @ x_eff.astype(np.int32)
    acc_bias = acc + bias_int32.astype(np.int32)
    if activation == "relu":
        activated = np.maximum(acc_bias, 0)
    else:
        activated = acc_bias
    output = requantize_int32_to_int8(activated, requant_mult, requant_shift)
    return output

def calibrate_requant(acc_values, shift=16):
    max_abs = max(abs(int(acc_values.max())), abs(int(acc_values.min())), 1)
    scale = 127.0 / max_abs
    mult = int(round(scale * (1 << shift)))
    return max(1, mult), shift

def weight_to_chunks(weight_int8):
    out_dim, in_dim = weight_int8.shape
    n_ob = (out_dim + TILE_ROWS - 1) // TILE_ROWS
    n_ib = (in_dim + TILE_COLS - 1) // TILE_COLS
    chunks = []
    for ob in range(n_ob):
        for ib in range(n_ib):
            for chunk in range(TILE_ROWS * CHUNKS_PER_ROW):
                row = chunk // CHUNKS_PER_ROW
                col_group = chunk % CHUNKS_PER_ROW
                word = 0
                for b in range(ELEMS_PER_CHUNK):
                    oi = ob * TILE_ROWS + row
                    ii = ib * TILE_COLS + col_group * ELEMS_PER_CHUNK + b
                    if oi < out_dim and ii < in_dim:
                        val = int(weight_int8[oi, ii]) & 0xFF
                    else:
                        val = 0
                    word |= val << (b * 8)
                chunks.append(word)
    return chunks

def bias_to_u32(bias_int32):
    return [int(b) & 0xFFFFFFFF for b in bias_int32]

print("Golden model functions loaded.")

# ====================================================================
# 4. 生成 Golden 数据 (与 golden_model.py --mnist-e2e --seed 42 完全一致)
# ====================================================================
np.random.seed(42)
w1 = np.random.randint(-128, 127, (128, 784), dtype=np.int8)
b1 = np.random.randint(-5000, 5000, 128, dtype=np.int32)
w2 = np.random.randint(-128, 127, (10, 128), dtype=np.int8)
b2 = np.random.randint(-5000, 5000, 10, dtype=np.int32)
img = np.random.randint(0, 255, 784, dtype=np.uint8)

# Calibrate FC1
x_eff1 = np.clip(img.astype(np.int32) - (-128), 0, 511).astype(np.int32)
acc1 = w1.astype(np.int32) @ x_eff1 + b1.astype(np.int32)
relu1 = np.maximum(acc1, 0)
fc1_mult, fc1_shift = calibrate_requant(relu1, shift=16)

# Run FC1 golden
fc1_golden = infer_layer(img, w1, b1, -128, fc1_mult, fc1_shift, "relu")

# Calibrate FC2
fc2_in = fc1_golden.view(np.uint8)
x_eff2 = np.clip(fc2_in.astype(np.int32) - 0, 0, 511).astype(np.int32)
acc2 = w2.astype(np.int32) @ x_eff2 + b2.astype(np.int32)
fc2_mult, fc2_shift = calibrate_requant(acc2, shift=16)

# Run FC2 golden
fc2_golden = infer_layer(fc2_in, w2, b2, 0, fc2_mult, fc2_shift, "none")
expected_class = int(np.argmax(fc2_golden))

# Pack data for hardware
fc1_weight_chunks = weight_to_chunks(w1)
fc2_weight_chunks = weight_to_chunks(w2)
fc1_bias_u32      = bias_to_u32(b1)
fc2_bias_u32      = bias_to_u32(b2)
input_image       = img.tolist()

print(f"FC1 weights: {len(fc1_weight_chunks)} chunks")
print(f"FC2 weights: {len(fc2_weight_chunks)} chunks")
print(f"Quant: fc1_mult={fc1_mult}, fc1_shift={fc1_shift}")
print(f"       fc2_mult={fc2_mult}, fc2_shift={fc2_shift}")
print(f"FC1 golden output (first 10): {fc1_golden[:10]}")
print(f"FC2 golden output: {fc2_golden}")
print(f"Expected class: {expected_class}")

# ====================================================================
# 4b. (可选) 对比 hex 文件数据与内嵌 golden model 的结果
# ====================================================================
DATA_DIR = "mnist_data"
try:
    def read_hex_u8(fn):
        with open(os.path.join(DATA_DIR, fn)) as f:
            return [int(l.strip(), 16) & 0xFF for l in f if l.strip()]

    hex_fc1 = np.array(read_hex_u8("fc1_output.hex"), dtype=np.uint8).view(np.int8)
    hex_fc2 = np.array(read_hex_u8("fc2_output.hex"), dtype=np.uint8).view(np.int8)

    fc1_hex_match = np.array_equal(fc1_golden, hex_fc1)
    fc2_hex_match = np.array_equal(fc2_golden, hex_fc2)
    print(f"Hex vs inline golden - FC1: {'MATCH ✓' if fc1_hex_match else 'MISMATCH ✗'}")
    print(f"Hex vs inline golden - FC2: {'MATCH ✓' if fc2_hex_match else 'MISMATCH ✗'}")
    if not fc1_hex_match:
        diffs = np.where(fc1_golden != hex_fc1)[0]
        print(f"  FC1 differs at {len(diffs)} indices: {diffs[:10].tolist()}...")
        for d in diffs[:5]:
            print(f"    [{d}] inline={fc1_golden[d]}, hex={hex_fc1[d]}")
    if not fc2_hex_match:
        diffs = np.where(fc2_golden != hex_fc2)[0]
        print(f"  FC2 differs at {len(diffs)} indices:")
        for d in diffs:
            print(f"    [{d}] inline={fc2_golden[d]}, hex={hex_fc2[d]}")
except Exception as e:
    print(f"(无法读取 hex 文件: {e} — 跳过对比)")


# ====================================================================
# 5. 硬件操作工具函数
# ====================================================================
def soft_reset():
    mmio.write(CTRL, 0x4)

def clear_done():
    mmio.write(CTRL, 0x2)

def configure_layer(in_dim, out_dim, zp, mult, shift, act, verify=True):
    """配置一层的 CSR 参数, 可选回读验证"""
    n_ib = (in_dim + 15) // 16
    n_ob = (out_dim + 15) // 16
    writes = [
        ("CSR_IN_DIM",    CSR_IN_DIM,    in_dim),
        ("CSR_OUT_DIM",   CSR_OUT_DIM,   out_dim),
        ("CSR_N_IB",      CSR_N_IB,      n_ib),
        ("CSR_N_OB",      CSR_N_OB,      n_ob),
        ("REQUANT_MULT",  REQUANT_MULT,  mult),
        ("REQUANT_SHIFT", REQUANT_SHIFT, shift),
        ("INPUT_ZP",      INPUT_ZP,      zp & 0xFFFFFFFF),
        ("ACT_MODE",      ACT_MODE,      act),
    ]
    for name, addr, val in writes:
        mmio.write(addr, val & 0xFFFFFFFF)
    if verify:
        for name, addr, val in writes:
            rb = mmio.read(addr)
            expected = val & 0xFFFFFFFF
            if rb != expected:
                print(f"  ✗ CSR MISMATCH: {name} wrote=0x{expected:08x} read=0x{rb:08x}")

def load_weights_burst(chunks):
    mmio.write(WDMA_ADDR, 0)
    mmio.write(WDMA_CTRL, 0x02)
    for c in chunks:
        mmio.write(WDMA_DATA, int(c))
    mmio.write(WDMA_CTRL, 0x00)

def load_bias(bias_list):
    for i, b in enumerate(bias_list):
        mmio.write(MEM_BIAS + 4*i, int(b) & 0xFFFFFFFF)

def load_input(data_u8):
    padded = list(data_u8)
    while len(padded) % 16 != 0:
        padded.append(0)
    for i, x in enumerate(padded):
        mmio.write(MEM_INPUT + 4*i, int(x) & 0xFF)

def run_inference():
    clear_done()
    mmio.write(CTRL, 0x1)
    while not (mmio.read(STATUS) & 0x2):
        pass
    cycles = mmio.read(CYCLE_CNT_LO)
    macs   = mmio.read(MAC_CNT_LO)
    return cycles, macs

def read_output(out_dim):
    out = []
    for i in range(out_dim):
        v = mmio.read(LOGIT_BASE + 4*i)
        out.append(np.uint8(v & 0xFF).view(np.int8))
    return out


# ====================================================================
# 6. 连通性测试
# ====================================================================
print("\n=== AXI Connectivity Test ===")
soft_reset()
status = mmio.read(STATUS)
print(f"  STATUS after reset: 0x{status:08x}")

mmio.write(CSR_IN_DIM, 784)
readback = mmio.read(CSR_IN_DIM)
print(f"  IN_DIM write=784, readback={readback}  {'PASS' if readback == 784 else 'FAIL'}")

if readback != 784:
    print("ERROR: AXI read/write failed! Check address mapping.")
    raise RuntimeError("AXI connectivity test failed")


# ====================================================================
# 6b. CSR 回读诊断 + 时序违例检测
# ====================================================================
# !! 你的 bitstream 有严重的时序违例 (WNS = -20.727ns) !!
# !! 这是所有计算错误的根本原因 !!
#
# 最差路径: row_idx_reg → 44级逻辑 → argmax (需要28.7ns, 时钟只有8ns)
# 关键瓶颈: cim_tile.sv 的16元素乘加链 + activation_unit + requantize
#           全部是组合逻辑, 路径太长无法在125MHz下收敛
#
# 修复方案 (任选其一):
#   1. 降频: vivado_build.tcl 中 FCLK_MHZ 从 125 改为 50 (或更低)
#   2. 流水线化 cim_tile: 把16列乘加拆成2-4级pipeline
#   3. 流水线化 activation_unit: requantize 拆成独立的流水级
#
# 以下测试验证 CSR 寄存器是否可读写 (不受时序违例影响):
print("\n=== CSR Readback Diagnostic ===")

test_cases = [
    ("CSR_IN_DIM",    CSR_IN_DIM,    784),
    ("CSR_OUT_DIM",   CSR_OUT_DIM,   128),
    ("CSR_N_IB",      CSR_N_IB,      49),
    ("CSR_N_OB",      CSR_N_OB,      8),
    ("REQUANT_MULT",  REQUANT_MULT,  10),
    ("REQUANT_SHIFT", REQUANT_SHIFT, 16),
    ("ACT_MODE",      ACT_MODE,      1),
]

csr_errors = 0
for name, addr, val in test_cases:
    mmio.write(addr, val & 0xFFFFFFFF)
    rb = mmio.read(addr)
    ok = "PASS" if rb == val else "FAIL"
    if rb != val:
        csr_errors += 1
        print(f"  {name:16s}: wrote={val}, readback={rb}  {ok} ✗")
    else:
        print(f"  {name:16s}: wrote={val}, readback={rb}  {ok}")

# Test INPUT_ZP (signed value)
mmio.write(INPUT_ZP, (-128) & 0xFFFFFFFF)
rb_zp = mmio.read(INPUT_ZP)
expected_zp = (-128) & 0xFFFFFFFF  # 0xFFFFFF80
ok_zp = "PASS" if rb_zp == expected_zp else "FAIL"
if rb_zp != expected_zp:
    csr_errors += 1
print(f"  {'INPUT_ZP':16s}: wrote=0x{expected_zp:08x}, readback=0x{rb_zp:08x}  {ok_zp}")

if csr_errors == 0:
    print("  CSR registers: ALL OK ✓")
    print("  (CSR 寄存器没问题, 如果有计算错误则来自 cim_tile/activation 的时序违例)")
else:
    print(f"  CSR registers: {csr_errors} FAILURES ✗")

# ====================================================================
# 7. FC1: 784 → 128, ReLU
# ====================================================================
print("\n=== Layer 1: FC1 784→128 ReLU ===")
soft_reset()

configure_layer(in_dim=784, out_dim=128, zp=-128, mult=fc1_mult, shift=fc1_shift, act=1)
print("  Loading weights...")
load_weights_burst(fc1_weight_chunks)
print("  Loading bias...")
load_bias(fc1_bias_u32)
print("  Loading input...")
load_input(input_image)

print("  Running inference...")
cycles, macs = run_inference()
print(f"  Done! cycles={cycles}, MACs={macs}")

fc1_out = read_output(128)

# 对比 FC1
fc1_err = 0
for i in range(128):
    if fc1_out[i] != fc1_golden[i]:
        print(f"  FC1 MISMATCH [{i}]: HW={fc1_out[i]}, Golden={fc1_golden[i]}")
        fc1_err += 1

if fc1_err == 0:
    print(f"  FC1: ALL 128 outputs MATCH ✓")
else:
    print(f"  FC1: {fc1_err}/128 MISMATCHES ✗")


# ====================================================================
# 8. FC2: 128 → 10, no activation
# ====================================================================
print("\n=== Layer 2: FC2 128→10 (no activation) ===")

configure_layer(in_dim=128, out_dim=10, zp=0, mult=fc2_mult, shift=fc2_shift, act=0)
print("  Loading weights...")
load_weights_burst(fc2_weight_chunks)
print("  Loading bias...")
load_bias(fc2_bias_u32)
print("  Loading FC1 output as input...")
fc1_out_u8 = [int(x) & 0xFF for x in fc1_out]
load_input(fc1_out_u8)

print("  Running inference...")
cycles, macs = run_inference()
print(f"  Done! cycles={cycles}, MACs={macs}")

fc2_out = read_output(10)

# 对比 FC2
fc2_err = 0
for i in range(10):
    status_str = "OK" if fc2_out[i] == fc2_golden[i] else "MISMATCH"
    print(f"  logit[{i}] = {fc2_out[i]:4d}  (golden={fc2_golden[i]:4d})  {status_str}")
    if fc2_out[i] != fc2_golden[i]:
        fc2_err += 1

if fc2_err == 0:
    print(f"  FC2: ALL 10 outputs MATCH ✓")
else:
    print(f"  FC2: {fc2_err}/10 MISMATCHES ✗")

# ====================================================================
# 9. Argmax 检查 + 总结
# ====================================================================
hw_pred = mmio.read(PRED_CLASS)
print(f"\n=== Result ===")
print(f"  HW predicted class: {hw_pred}")
print(f"  Golden expected:    {expected_class}")
print(f"  Argmax: {'MATCH ✓' if hw_pred == expected_class else 'MISMATCH ✗'}")

total_err = fc1_err + fc2_err + (0 if hw_pred == expected_class else 1)
print(f"\n{'='*60}")
if total_err == 0:
    print(">>> ALL ON-BOARD TESTS PASSED <<<")
else:
    print(f">>> {total_err} ERRORS DETECTED <<<")
print(f"{'='*60}")
```

## 使用流程（纯串口）

把`cim_soc.bit`和`cim_soc.hwh`，权重文件等，放入SD卡的`/home/xilinx/`也可以，通过串口终端的`python3`运行脚本，不过换文件需要插拔SD卡，比较麻烦。

```

```
