# sw

这里是软件环境配置和相关代码设计。

## env prepare

我使用`rye`来进行python管理，当然用`uv`也是可以的。

你可以通过`rye sync`（+`rye pin 3.13`）来进行环境准备，或者是删除所有rye配置文件之后`bash scripts/set_up.sh`.

也可以用`pip`或者是`conda`对照`pyproject.toml`下载需要的package.

## function & usage

golden_model.py用于模拟设计出的硬件电路的计算行为，确认设计出的电路计算结果符合预期；

golden_model_torch.py用来进行torch交叉验证，确认计算结果是（逻辑上）正确的；

mnist_quantize.py用于生成真实测试数据，确认功能正常。

具体可见`/docs/sw_filearch.md`.
