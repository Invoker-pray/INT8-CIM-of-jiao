# sw/ 目录文件说明与 API 参考

本文档描述 `sw/` 下所有文件的作用、用法和公共 API。**文件发生变化时请同步更新本文档。**

---

## 目录结构概览

```
sw/
├── golden_model.py          # bit-accurate RTL参考模型 + hex生成
├── golden_model_torch.py    # PyTorch交叉验证 + hex生成
├── mnist_quantize.py        # 真实MLP训练/量化/导出
├── lenet5_quantize.py       # LeNet-5训练/量化/导出
├── model_zoo.py             # 统一多模型训练/量化/推理/导出 API
├── cim_driver.py            # PYNQ板端 Python 驱动 API
├── full_cim_test_pynq.ipynb       # PYNQ: 综合功能验证（随机权重）
├── mnist_real_test_pynq.ipynb     # PYNQ: 真实MNIST MLP验证
├── lenet5_test_pynq.ipynb         # PYNQ: LeNet-5验证
├── generate_mnist_data.ipynb      # 宿主机: 生成MLP测试数据
├── generate_universal_data.ipynb  # 宿主机: 生成任意模型测试数据
├── universal_model_test_pynq.ipynb # PYNQ: 通用模型验证
├── prepare_picorv32_env.ipynb     # 宿主机: PicoRV32固件准备
├── pynq_verify_rv32.ipynb         # PYNQ: PicoRV32推理验证
└── scripts/set_up.sh              # 环境安装脚本（pip方式）
```

---

## 环境配置

```bash
cd sw
rye pin 3.13 && rye sync   # 推荐
# 或
bash scripts/set_up.sh     # pip 方式
```

依赖见 `pyproject.toml`：torch, torchvision, numpy, jupyter, pyserial。

---

## golden_model.py

**定位**：RTL行为的bit-accurate参考模型，是验证硬件正确性的单一事实来源。

完全复刻硬件计算流程：UINT8输入 → 减zero-point → INT8权重MVM → 加INT32 bias → ReLU → multiply-shift重量化 → INT8输出。

### 命令行用法

```bash
python golden_model.py                        # 打印用法
python golden_model.py --self-test            # 单层FC自测
python golden_model.py --mnist-e2e            # 生成784→128→10 MNIST hex数据
python golden_model.py --mnist-e2e --output-dir ../hw/sim/tb_mnist_e2e/data_e2e
python golden_model.py --mnist-e2e --seed 42  # 可复现
python golden_model.py --im2col-demo          # Conv im2col演示（explicit+implicit双路对比）
python golden_model.py --im2col-demo --im2col-mode explicit
```

**选项**：
- `--output-dir DIR`：hex输出目录（默认 `data_e2e`）
- `--seed N`：随机种子（默认None=全随机）
- `--im2col-mode`：`explicit` | `implicit` | `both`

**输出文件**（`--mnist-e2e`）：
```
output_dir/
  fc1_weight_tiles.hex   # FC1权重，tile打包32-bit chunk
  fc2_weight_tiles.hex
  fc1_bias.hex           # INT32 bias
  fc2_bias.hex
  input_image.hex        # UINT8输入
  fc1_output.hex         # 期望FC1输出 INT8
  fc2_output.hex         # 期望FC2输出 INT8
  expected_class.hex     # argmax分类结果
  quant_params.hex       # fc1_mult, fc1_shift, fc2_mult, fc2_shift
```

### Python API

```python
from golden_model import (
    apply_zero_point, cim_mvm, add_bias, relu, requantize_int32_to_int8,
    infer_layer, infer_mlp,
    weight_to_chunk_hex, bias_to_hex, input_to_hex, int8_to_hex, save_hex,
    im2col_explicit, im2col_implicit_addr_gen, im2col_apply_implicit,
    infer_conv_layer,
)
```

#### 核心函数

```python
# 单层FC推理，返回所有中间结果
result = infer_layer(
    input_uint8,       # [in_dim] UINT8 ndarray
    weight_int8,       # [out_dim, in_dim] INT8 ndarray
    bias_int32,        # [out_dim] INT32 ndarray
    zero_point=-128,   # 硬件零点
    requant_mult=1,
    requant_shift=0,
    activation="relu", # "relu" or "none"
)
# result: dict 含 x_eff, acc, acc_bias, activated, output, pred_class

# 多层MLP推理
result = infer_mlp(
    input_uint8,       # 输入图像
    layers=[           # 每层dict: weight, bias, zp, mult, shift, act
        {"weight": w1, "bias": b1, "zp": -128, "mult": m, "shift": s, "act": "relu"},
        ...
    ]
)
# result: dict 含 layers, final_output, pred_class

# Conv层推理（im2col + 逐像素MVM）
output_map, info = infer_conv_layer(
    feature_map,       # [C_in, H, W] UINT8
    weight_4d,         # [C_out, C_in, K_h, K_w] INT8
    bias_int32,        # [C_out] INT32
    stride=1, padding=0,
    zero_point=-128, requant_mult=1, requant_shift=0,
    activation="relu",
    mode="explicit",   # "explicit" 或 "implicit"
)
# output_map: [C_out, out_h, out_w] INT8

# 权重打包为hex（用于RTL $readmemh）
lines = weight_to_chunk_hex(weight_int8)   # → list of "xxxxxxxx" hex字符串
lines = bias_to_hex(bias_int32)
lines = input_to_hex(input_uint8)
lines = int8_to_hex(arr_int8)
save_hex(lines, "path/to/file.hex")
```

---

## golden_model_torch.py

**定位**：基于PyTorch的交叉验证。验证INT8定点推理流程在数学上是否与PyTorch浮点推理等价（允许量化误差）。输出格式与`golden_model.py`完全相同，可作为RTL testbench的drop-in替代。

### 命令行用法

```bash
python golden_model_torch.py                        # 打印用法
python golden_model_torch.py --self-test            # numpy vs torch交叉验证
python golden_model_torch.py --mnist-e2e            # 随机权重生成（与golden_model.py相同格式）
python golden_model_torch.py --mnist-e2e --fixed    # 固定模式权重（易调试）
python golden_model_torch.py --mnist-e2e --seed 42
python golden_model_torch.py --mnist-e2e --output-dir DIR
```

**输出文件**：格式与`golden_model.py`完全相同（见上）。

### Python API

```python
from golden_model_torch import (
    apply_zero_point, requantize, infer_layer_int32,
    calibrate_requant, torch_cross_validate,
    weight_to_chunk_hex, bias_to_hex, input_to_hex, int8_to_hex, save_hex,
)

# 单层推理（bit-accurate）
out, acc = infer_layer_int32(x_uint8, w_int8, b_int32, zp, mult, shift, relu=True)

# PyTorch交叉验证（float32方向验证，非bit-exact）
acc_torch, out_float = torch_cross_validate(w_np, b_np, x_np, zp, mult, shift, relu, "FC1")

# 校准量化参数
mult, shift = calibrate_requant(acc_values, shift=16)
```

---

## mnist_quantize.py

**定位**：完整MLP（784→128→10）训练→PTQ量化→bit-accurate INT8推理→hex导出流水线。生成真实MNIST测试数据，用于板端准确率验证。

### 命令行用法

```bash
python mnist_quantize.py                            # 训练+量化+导出（默认20张测试图）
python mnist_quantize.py --pretrained mlp.pt        # 加载已有模型
python mnist_quantize.py --num-test 100             # 导出100张测试图
python mnist_quantize.py --output-dir mnist_real_data
python mnist_quantize.py --seed 42
```

**输出目录结构**（默认 `mnist_real_data/`）：
```
mnist_real_data/
  model_info.txt           # 模型摘要+准确率
  fc1_weight_tiles.hex
  fc2_weight_tiles.hex
  fc1_bias.hex
  fc2_bias.hex
  quant_params.hex         # fc1_mult, fc1_shift, fc2_mult, fc2_shift
  test_images/
    img_0000.hex           # UINT8测试图像
    img_0000_label.txt     # 真实标签
    img_0000_pred.txt      # Python INT8预测
    img_0000_fc1.hex       # FC1输出（golden）
    img_0000_fc2.hex       # FC2输出（golden）
    ...
```

### 关键函数（内部使用，可import）

```python
from mnist_quantize import hw_infer_layer, hw_infer_mlp, quantize_image

# bit-accurate单层推理
out = hw_infer_layer(x_uint8, w_int8, b_int32, zp, mult, shift, relu=True)

# 完整MLP推理
pred, fc1_out, fc2_out = hw_infer_mlp(image_uint8, qparams)
# qparams: full_ptq()的返回值，含w1,w2,b1,b2,fc1_mult等

# 图像量化 [0,1]float → UINT8
img_u8 = quantize_image(image_float)  # round(pixel * 255)
```

---

## lenet5_quantize.py

**定位**：LeNet-5完整流水线：训练→PTQ量化→bit-accurate INT8推理（im2col + hw_mvm）→hex导出→测试图像导出。

网络结构：
```
Conv1(1→6, 5×5) → Pool(2×2) → Conv2(6→16, 5×5) → Pool(2×2) → FC3(256→120) → FC4(120→84) → FC5(84→10)
```
所有层均在MAX_IN_DIM=784, MAX_OUT_DIM=128约束内。

### 命令行用法

```bash
python lenet5_quantize.py                           # 训练+量化+导出（20张测试图）
python lenet5_quantize.py --pretrained lenet5.pt    # 加载已有模型
python lenet5_quantize.py --num-test 50
python lenet5_quantize.py --output-dir lenet5_data
python lenet5_quantize.py --seed 42
```

**输出目录**（默认 `lenet5_data/`）：
```
lenet5_data/
  conv1_weight_tiles.hex  conv1_bias.hex
  conv2_weight_tiles.hex  conv2_bias.hex
  fc3_weight_tiles.hex    fc3_bias.hex
  fc4_weight_tiles.hex    fc4_bias.hex
  fc5_weight_tiles.hex    fc5_bias.hex
  quant_params.hex        # [conv1_mult, conv1_shift, conv2_mult, ..., fc5_mult, fc5_shift]
  zero_points.hex         # 各层zero point
  lenet5_qparams.npz      # numpy格式，供CIMModel直接加载
  layer_info.txt          # 各层参数文本摘要
  test_images/
    img_0000.hex          img_0000_fc5.hex  img_0000_label.txt  img_0000_pred.txt
    ...
```

### 关键函数

```python
from lenet5_quantize import int8_infer_lenet5, full_ptq_lenet5, hw_mvm, im2col, maxpool2d

# 完整LeNet-5 INT8推理
pred, intermediates = int8_infer_lenet5(image_u8_flat, qparams)
# image_u8_flat: [784] UINT8
# qparams: full_ptq_lenet5()的返回值（dict with 'layers'）
# intermediates: dict, key为层名(conv1/pool1/.../fc5)

# PTQ量化（需要已训练的LeNet5模型）
from lenet5_quantize import LeNet5, full_ptq_lenet5
model = LeNet5()
# ... load or train ...
qparams = full_ptq_lenet5(model, device="cpu")
```

---

## model_zoo.py

**定位**：统一多模型接口。支持 `mlp` 和 `lenet5`，新模型只需添加nn.Module子类+注册到`MODEL_REGISTRY`+在`_get_layer_descriptors`&`_calibrate`添加分支。

### 命令行用法

`model_zoo.py`本身无`__main__`入口，通过`generate_universal_data.ipynb`使用。

### Python API

```python
from model_zoo import build_model, train, quantize, int8_infer, export_hex

# 构建模型
model = build_model('mlp')     # 或 'lenet5'

# 训练
acc = train(model, epochs=10, lr=0.001, device='cpu', seed=42)

# PTQ量化
qparams = quantize(model, device='cpu')
# qparams: {"arch": "mlp"/"lenet5", "layers": [...]}

# bit-accurate INT8推理
pred, final_output, intermediates = int8_infer(image_u8, qparams)
# image_u8: [784] UINT8
# 返回: (预测类别int, 末层输出ndarray, 各层输出dict)

# 导出hex文件
export_hex(
    qparams,
    output_dir="output/",
    test_images=list_of_u8_arrays,  # 可选
    test_labels=list_of_ints,       # 可选
    num_test=20,
)
# 输出: {layer_name}_weight_tiles.hex, {layer_name}_bias.hex,
#       quant_params.hex, zero_points.hex, model_info.json,
#       test_images/img_XXXX.hex 等
```

**`qparams["layers"]`结构**（各层dict）：
- `type="fc"`：含 `name, weight(INT8 ndarray), bias(INT32 ndarray), zp, mult, shift, relu, in_dim, out_dim`
- `type="conv"`：含 `name, weight(4D INT8), bias, zp, mult, shift, relu, C_out, C_in, K_h, K_w, stride, padding`
- `type="pool"`：含 `name, kernel, stride`

---

## cim_driver.py

**定位**：PYNQ板端Python驱动。提供低级MMIO封装(`CIMDriver`)和高级多层推理接口(`CIMModel`)，仅在PYNQ-Z2/KV260上运行。

### 硬件常量（与cim_pkg.sv一致）

| 常量 | 值 | 含义 |
|------|-----|------|
| `TILE_ROWS` | 16 | tile行数 |
| `TILE_COLS` | 16 | tile列数 |
| `MAX_IN_DIM` | 784 | 最大输入维度 |
| `MAX_OUT_DIM` | 128 | 最大输出维度 |
| `ELEMS_PER_CHUNK` | 4 | 每个32-bit chunk含4字节 |

### 辅助函数

```python
from cim_driver import weight_to_chunks, bias_to_u32, im2col, maxpool2d

# INT8权重 → 32-bit chunk列表（送给load_weights）
chunks = weight_to_chunks(weight_int8)  # weight_int8: [out_dim, in_dim]

# INT32 bias → uint32列表
b_u32 = bias_to_u32(bias_int32)

# im2col: [C_in,H,W] → [C_in*Kh*Kw, out_h*out_w]
col_matrix, out_h, out_w = im2col(feature_map, kernel_h, kernel_w, stride=1, padding=0)

# max pooling（纯Python，INT8输入）
out = maxpool2d(feat, kernel=2, stride=2)  # feat: [C,H,W] INT8
```

### CIMDriver — 低级MMIO驱动

```python
from cim_driver import CIMDriver

drv = CIMDriver('cim_soc.bit')  # 加载bitstream，初始化MMIO

drv.soft_reset()
drv.configure(in_dim, out_dim, zp, mult, shift, relu)
drv.load_weights(chunks)       # chunks: weight_to_chunks()的输出
drv.load_bias(bias_u32)        # bias_u32: bias_to_u32()的输出
drv.load_input(data_u8)        # data_u8: UINT8 list/array，自动pad到16的倍数
cycles, macs = drv.start_and_wait()
output = drv.read_output(out_dim)   # → list of signed INT8
pred = drv.read_pred_class()        # 硬件argmax结果

# 一步完成单FC层推理
output, cycles = drv.infer_fc(
    input_u8,     # UINT8 list/array
    w_chunks,     # weight_to_chunks()输出
    bias_u32,     # bias_to_u32()输出
    zp, mult, shift,
    relu=True,
    _timings=None,  # 传list则追加per-phase耗时dict
)

# 仅输入变化时复用已加载的权重/bias（Conv的每个像素）
output, cycles = drv.infer_fc_input_only(
    input_u8, out_dim,
    _timings=None,
)
```

### CIMModel — 高级多层推理

```python
from cim_driver import CIMDriver, CIMModel, weight_to_chunks, bias_to_u32

drv = CIMDriver('cim_soc.bit')
model = CIMModel(drv)

# 添加FC层
model.add_fc(
    in_dim, out_dim,
    w_chunks,    # weight_to_chunks()输出
    bias_u32,    # bias_to_u32()输出
    zp, mult, shift,
    relu=True,
    weight_int8=None,   # 可选，供verify模式bit-exact对比
    bias_int32=None,
)

# 添加Conv层（im2col在Python侧，MVM在PL侧）
model.add_conv(
    weight_4d_int8,   # [C_out, C_in, K_h, K_w] INT8 ndarray
    bias_int32,       # [C_out] INT32 ndarray
    zp, mult, shift,
    stride=1, padding=0, relu=True,
)

# 添加MaxPool层（纯Python）
model.add_pool(kernel=2, stride=2)

# 运行推理
pred, final_output = model.predict(
    input_data,      # FC-first: [784] UINT8; Conv-first: [C,H,W] UINT8
    verbose=False,
    verify=False,    # True则逐层与golden_model对比
    run_id=None,     # verify时的dump目录标识，None自动生成
    dump_dir="sw/logs",
    profile=False,
)
# profile=True时返回 (pred, final_output, profile_data)
# profile_data: {"layers": [...], "total_ms": float}

model.clear()  # 清空所有层
```

**LeNet-5完整示例**：

```python
import numpy as np
from cim_driver import CIMDriver, CIMModel, weight_to_chunks, bias_to_u32

drv = CIMDriver('cim_soc.bit')
model = CIMModel(drv)

# 从lenet5_data/lenet5_qparams.npz加载
d = np.load('lenet5_data/lenet5_qparams.npz')
model.add_conv(d['conv1_weight'], d['conv1_bias'], zp=int(d['conv1_zp']),
               mult=int(d['conv1_mult']), shift=int(d['conv1_shift']),
               stride=1, padding=0, relu=True)
model.add_pool(2, 2)
model.add_conv(d['conv2_weight'], d['conv2_bias'], zp=int(d['conv2_zp']),
               mult=int(d['conv2_mult']), shift=int(d['conv2_shift']),
               stride=1, padding=0, relu=True)
model.add_pool(2, 2)
model.add_fc(256, 120, weight_to_chunks(d['fc3_weight']), bias_to_u32(d['fc3_bias']),
             zp=int(d['fc3_zp']), mult=int(d['fc3_mult']), shift=int(d['fc3_shift']), relu=True)
model.add_fc(120, 84, weight_to_chunks(d['fc4_weight']), bias_to_u32(d['fc4_bias']),
             zp=int(d['fc4_zp']), mult=int(d['fc4_mult']), shift=int(d['fc4_shift']), relu=True)
model.add_fc(84, 10, weight_to_chunks(d['fc5_weight']), bias_to_u32(d['fc5_bias']),
             zp=int(d['fc5_zp']), mult=int(d['fc5_mult']), shift=int(d['fc5_shift']), relu=False)

image_u8 = np.array(...)  # [784] UINT8，28x28展平
pred, logits = model.predict(image_u8.reshape(1, 28, 28), verbose=True)
```

---

## Jupyter Notebooks

| 文件 | 运行环境 | 用途 |
|------|----------|------|
| `generate_mnist_data.ipynb` | 宿主机 | 生成MLP测试数据（可选数量），训练模型检测准确率 |
| `generate_universal_data.ipynb` | 宿主机 | 通用数据生成，切换`ARCH='mlp'/'lenet5'`即可 |
| `full_cim_test_pynq.ipynb` | PYNQ | 综合功能验证（用golden_model/mnist_quantize生成的随机/合成数据） |
| `mnist_real_test_pynq.ipynb` | PYNQ | 真实MNIST MLP验证，测试实际准确率 |
| `lenet5_test_pynq.ipynb` | PYNQ | LeNet-5验证（conv+pool+fc全流程） |
| `universal_model_test_pynq.ipynb` | PYNQ | 通用模型验证，从`model_info.json`读取网络结构，无需硬编码 |
| `prepare_picorv32_env.ipynb` | 宿主机 | PicoRV32固件编译与打包 |
| `pynq_verify_rv32.ipynb` | PYNQ | PicoRV32软核推理验证 |

---

## 量化参数说明

所有文件使用统一的量化约定，与硬件RTL完全一致：

| 参数 | 说明 |
|------|------|
| `zero_point` / `zp` | 硬件输入零点，`x_eff = clip(x_u8 - zp, 0, 511)` |
| `mult` | 重量化乘数（整数） |
| `shift` | 重量化右移位数，`out = (acc * mult + (1<<(shift-1))) >> shift` |
| `weight` | INT8，对称量化，zero_point=0 |
| `bias` | INT32，scale = s_in × s_w |

**典型值**：输入scale=1/255，shift=16，mult由校准决定。

---

## 文件间依赖关系

```
mnist_quantize.py ──┐
lenet5_quantize.py ─┤──→ cim_driver.py ──→ PYNQ板（硬件）
model_zoo.py ───────┘

golden_model.py ────→ RTL仿真testbench hex数据
golden_model_torch.py → 交叉验证（验证算法正确性）

generate_*.ipynb ───→ *_test_pynq.ipynb
```

---

*最后更新：2026-04-10。sw/下文件发生接口变更时请同步更新本文档。*
