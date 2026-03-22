# sw file archtecture

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
