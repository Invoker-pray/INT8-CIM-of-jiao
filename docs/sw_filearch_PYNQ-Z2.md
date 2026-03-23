# sw file archtecture(mnist 2 layers)

## .py

写了三个python文件，有不同的用途。

| file                  | function                                                            | verification layer    |
| --------------------- | ------------------------------------------------------------------- | --------------------- |
| golden_model.py       | bit-accurate ref model + hex gen                                    | RTL == spec           |
| golden_model_torch.py | torch cross verification + hex gen                                  | sepc == truth in math |
| mnist_quantize.py     | pytorch train/quant real mnist model, export INT8 weight + scale/zp | real accuracy         |

简单来说，`golden_model.py`就是完全复刻硬件电路设计的计算，等硬件计算完成之后比对结果，保证硬件计算的结果和预期一致；

`golden_model_torch.py`就是加入了pytorch的交叉验证，确认的是算法规格本身是否正确，也就是做出来的INT8定点推理流程是否和pytorch的浮点推理在数学上等价（允许量化误差的前提下）。

`mnist_quantize.py`做的是真正加载MNIST，训练一个MLP模型，导出量化后的INT8
weight, INT8 bias, scale/zero_point等，还有测试图片，把这些信息送给硬件，保证硬件真的可以完成手写数字识别，并且计算准确率。

## .ipynb

主要是有三个文件，`full_cim_test_pynq.ipynb`, `mnist_real_test_pynq.ipynb`, `generate_mnist_data.ipynb`.

`generate_mnist_data.ipynb`是运行于宿主机的，在这个文件中，可以（方便地）生成指定数量的测试数据，还可以通过训练模型检测硬件计算的（预测）准确率。

`full_cim_test_pynq.ipynb`和`mnist_real_test_pynq.ipynb`是运于pynq的，前者使用三个python文件生成的数据来验证硬件电路设计是否正确，后者通过测试`generate_mnist_data.ipynb`或者是`mnist_quantize.py`生成的真实数据，检测整体设计的实际性能和准确率。

# lenet5 + im2col

## .py

写了两个python文件。

`lenet5_quantize.py`，可以实现（选种子可复现的）训练，量化，导出，生成指定数量的测试数据。
在这个文件里，训练了LeNet-5，逐层PTQ，进行bit-accurate INT8推理(im2col + hw_mvm)，导出hex文件。

`cim_driver.py`，这是PYNQ侧的python API.
比如说想跑LeNet-5，只需要：

```python
from cim_driver import CIMDriver, CIMModel, weight_to_chunks, bias_to_u32

drv = CIMDriver('cim_soc.bit')
model = CIMModel(drv)

# 加载 LeNet-5 各层（从 hex 读取或直接传 numpy array）
model.add_conv(w_conv1_4d, b_conv1, zp=0, mult=m1, shift=16, stride=1, padding=0, relu=True)
# Pool1 在 Python 侧做（model.predict 内部自动处理需要手动加 pool）
model.add_conv(w_conv2_4d, b_conv2, zp=0, mult=m2, shift=16, stride=1, padding=0, relu=True)
model.add_fc(256, 120, w3_chunks, b3_u32, zp=0, mult=m3, shift=16, relu=True)
model.add_fc(120, 84,  w4_chunks, b4_u32, zp=0, mult=m4, shift=16, relu=True)
model.add_fc(84,  10,  w5_chunks, b5_u32, zp=0, mult=m5, shift=16, relu=False)

pred, output = model.predict(image_u8, verbose=True)
```

# universal test

## .py

这里写了`model_zoo.py`，作用是实现模型定义，训练，量化，bit-accurat-INT8推理（+im2col/maxpool），hex导出。支持`mlp`和`lenet5`，新模型只需要加`nn.Module`子类 + 注册到`MODEL_REGISTRY` + 在`_get_layer_descriptors`&`_calibrate`加分支。

## .ipynb

写了`generate_universal_data.ipynb`和`universal_model_test_pynq.ipynb`，一个用来生成测试数据，一个用来进行PYNQ测试。

在`generate_universal_data.ipynb`中，主要修改`ARCH = 'lenet5'`就可以完成切换模型。

在`universal_model_test_pynq.ipynb`中，会从`generate_universal_data.ipynb`中僧成的`model_info.json`读取网络结构，不需要硬编码层定义。支持Conv + Pool + FC的组合。在当前项目checkpoint 1中，PYNQ端的推理函数遍历，`layer_defs`遇到conv会做im2col + MVM，遇到pool会做maxpool，遇到fc做MVM.
