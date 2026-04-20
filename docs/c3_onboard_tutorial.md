# C3 上板验证 Tutorial — 今晚照着做

> 对应 README step 8 commit 6 的剩余动作。四条验收标准：
> 1. `pytest sw/tests/` 22/22 PASS
> 2. LeNet-5 200 张 accuracy = 99.5%（bit-exact with 60 MHz baseline）
> 3. LeNet-5 单张延迟 ≤ 25 ms（目标 ~6 ms）
> 4. A2 profiler `load_w_ms` 占比 < 5%
>
> 不满足任一条 → 回滚到 `use_dma=False` 默认（见 §8 回退）。

---

## 0. 预检（5 min，host 侧）

先跑一遍 pytest 确认软件端 regression 没动：

```bash
cd /home/jiao/git/INT8-CIM-of-jiao/sw
pytest tests/ -v
# 期望: 22 passed
```

确认当前 HEAD 是 C3 commit 6：

```bash
cd /home/jiao/git/INT8-CIM-of-jiao
git log --oneline -1
# 期望: a930a57 feat: enable DMA path by default + track step 8 landing (C3 commit 6)
```

打 tag 作为回退锚点（c3_dma_design §9 commit 4 要求的 `pre-c3-bd` 现在补打上）：

```bash
git tag pre-c3-onboard
git tag --list pre-c3-onboard  # 确认打上
```

---

## 1. 构建 bitstream（host 侧 Vivado，耗时 ~15-25 min）

```bash
cd /home/jiao/git/INT8-CIM-of-jiao
bash hw/scripts/vivado_build.sh 2>&1 | tee vivado_build_c3.log
```

**等待期间**观察日志末尾。构建完成后必检三行：

```
INFO: axi_dma_0 address segments verified: ...    # §5.5 assertion 过
INFO: BRAM primitives inferred: NNN               # 期望 ~60-90 个
TIMING SUMMARY
  WNS (setup) : X.XXX ns
  STATUS      : CLEAN / MARGINAL / REGRESSION
```

**决策**：
- `STATUS: CLEAN` 或 `MARGINAL`（WNS ≥ -0.5 ns）→ 继续 §2
- `STATUS: REGRESSION`（WNS < -0.5 ns）→ axi_dma 引入了时序退化，两个选择：
  - (a) 改走 55 MHz 变体：`bash hw/scripts/vivado_build_55mhz.sh`，然后 §2 起用 `cim_soc_55mhz.bit`
  - (b) 在 `cim_top.sv` 的 S_AXIS 输入前加一级 `axis_register_slice` 隔离（需改 BD tcl，~1h 工作量），重跑

产物路径：
```
vivado_proj/pynq_deploy/cim_soc.bit
vivado_proj/pynq_deploy/cim_soc.hwh
```

---

## 2. 传文件到 PYNQ-Z2（2 min）

PYNQ-Z2 上电、网线或 USB-ETH 接好，记下板子 IP（默认 `192.168.2.99`）。

```bash
cd /home/jiao/git/INT8-CIM-of-jiao/vivado_proj/pynq_deploy
scp cim_soc.bit cim_soc.hwh xilinx@192.168.2.99:/home/xilinx/jupyter_notebooks/cim/
```

（路径按你 PYNQ 现有 notebook 目录调整。密码默认 `xilinx`。）

**同步 sw 代码**（如果 `cim_driver.py` 自上次上板后改过）：

```bash
cd /home/jiao/git/INT8-CIM-of-jiao/sw
scp cim_driver.py scripts/benchmark_e2e.py xilinx@192.168.2.99:/home/xilinx/jupyter_notebooks/cim/
scp -r lenet5_data xilinx@192.168.2.99:/home/xilinx/jupyter_notebooks/cim/
```

---

## 3. 烟测 — 单张图 DMA 路径通不通（5 min，PYNQ 侧）

ssh 上板，先跑一张图验证 DMA 基本不挂：

```bash
ssh xilinx@192.168.2.99
cd /home/xilinx/jupyter_notebooks/cim
sudo -E python3 <<'EOF'
from cim_driver import CIMDriver, CIMModel
import numpy as np, os

drv = CIMDriver("cim_soc.bit", use_dma=True)   # use_dma 默认就是 True
print(f"overlay loaded, dma present: {hasattr(drv, 'dma')}")
assert hasattr(drv, 'dma'), "axi_dma_0 不在 .hwh 里 — 重建 bitstream"

# 加载一个小模型跑一张图
d = np.load("lenet5_data/lenet5_qparams.npz")
model = CIMModel(drv)
# ... 按 lenet5_test_pynq.ipynb 的 setup cell 构建 model.layers ...
# 这里简化为：直接打开 notebook 跑前两个 cell

print("[smoke] PASS if no exception")
EOF
```

**如果报错 `axi_dma_0 not found`** → .hwh 出错，回 §1 检查 Vivado log 末尾的 `axi_dma_0 address segments verified` 行。

更靠谱的做法：直接 Jupyter 浏览器打开 `lenet5_test_pynq.ipynb`，跑前 3-4 个 cell 到"单张图预测正确"为止。

---

## 4. 200 张 MNIST 功能验证（~1-30 min，视加速比）

在 PYNQ 上：

```bash
cd /home/xilinx/jupyter_notebooks/cim
sudo -E python3 scripts/benchmark_e2e.py \
    --model lenet5 \
    --n_images 200 \
    --data_dir lenet5_data \
    --bitstream cim_soc.bit \
    --out_dir results_c3 \
    2>&1 | tee results_c3/run.log
```

**期望输出**（脑补，实测对照）：

```
Model: lenet5  n_images: 200
total_s: X.X                ← 基线 325.1 s；目标 ≤ 5 s (~65×)；合格 ≤ 25 s × 200 = 5s
ms_per_img: X.X             ← 基线 1625 ms；目标 ≤ 6 ms；合格 ≤ 25 ms
fps: X                      ← 基线 0.6；目标 ~170
accuracy: 0.995             ← 必须 = 0.995 (199/200) bit-exact
```

**决策**（四条验收中的第 2、3 条）：
| 指标 | 合格阈值 | 目标 |
|---|---|---|
| accuracy | = 0.995 | = 0.995 |
| ms_per_img | ≤ 25 | ≈ 6 |

- accuracy ≠ 0.995 → **立刻停止**，走 §8 回退。可能原因：DMA buffer 字序与 MMIO 不一致（检 `cim_axi_stream_sink` FSM 行装配顺序）
- ms_per_img 在 [6, 25] 区间 → 合格但未达目标，继续 §5 跑 profiler 看瓶颈在哪
- ms_per_img > 25 → 不合格，先看 §5 profiler 定位问题再决定是否回退

CSV 会自动写到 `results_c3/benchmark_lenet5_<timestamp>.csv`，**scp 下来留作论文数据**：

```bash
# 回 host 侧
scp xilinx@192.168.2.99:/home/xilinx/jupyter_notebooks/cim/results_c3/benchmark_lenet5_*.csv \
    /home/jiao/git/INT8-CIM-of-jiao/Thesis/middle/data/benchmark/
```

---

## 5. A2 profiler 重跑 — 验 `load_w_ms` < 5%（~2 min）

在 PYNQ 上跑带 profile 的推理：

```bash
cd /home/xilinx/jupyter_notebooks/cim
sudo -E python3 <<'EOF' | tee results_c3/profile_c3.txt
from cim_driver import CIMDriver, CIMModel
import numpy as np, os

drv = CIMDriver("cim_soc.bit", use_dma=True)
d = np.load("lenet5_data/lenet5_qparams.npz")

# 构造 model — 复用 benchmark_e2e.py::load_lenet5_model 的逻辑
# 简化：直接用 lenet5_test_pynq.ipynb 里的 setup cell 代码

# 跑 10 张图取均值（profile=True 开销大，不跑 200 张）
import time
from collections import defaultdict
agg = defaultdict(float)
for i in range(10):
    x = read_image(f"lenet5_data/img_{i:03d}.hex")   # 按 notebook 里的函数
    pred, logits, prof = model.predict(x, profile=True)
    for layer_prof in prof["layers"]:
        for k, v in layer_prof.items():
            if k.endswith("_ms"):
                agg[k] += v

total = sum(agg.values())
print(f"\n=== Latency breakdown (avg over 10 images) ===")
for k, v in sorted(agg.items(), key=lambda kv: -kv[1]):
    pct = v / total * 100
    print(f"  {k:20s} {v/10:8.3f} ms  ({pct:5.2f}%)")

load_w_pct = agg.get("load_w_ms", 0) / total * 100
print(f"\nload_w_ms share: {load_w_pct:.2f}%  (目标 < 5%)")
EOF
```

**决策**（验收条件 4）：
- `load_w_ms < 5%` → PASS，四条全过，走 §6
- `load_w_ms` 在 5%–15% → **部分合格**。accuracy 和 ms_per_img 已过的前提下可以接受，在论文里如实写
- `load_w_ms ≥ 15%` → DMA path 没真正生效，`use_dma` 可能在某些 load 调用里没触发。看 `cim_driver.py::load_weights/load_input/load_bias` 是否都走了 `_stream_load`

把 `profile_c3.txt` scp 下来：

```bash
scp xilinx@192.168.2.99:/home/xilinx/jupyter_notebooks/cim/results_c3/profile_c3.txt \
    /home/jiao/git/INT8-CIM-of-jiao/Thesis/middle/data/benchmark/
```

---

## 6. 画新的 latency breakdown 图（host 侧，5 min）

更新论文 figure：

```bash
cd /home/jiao/git/INT8-CIM-of-jiao/sw
python3 scripts/plot_latency_breakdown.py \
    --input Thesis/middle/data/benchmark/profile_c3.txt \
    --output Thesis/middle/paper/fig/latency_breakdown_c3.pdf
```

（如果 `plot_latency_breakdown.py` 的 CLI 和上面不一样，对着它的 argparse 调。）

---

## 7. 填论文占位（host 侧，10 min）

打开 `Thesis/middle/paper/paper.tex`，搜索关键字 `c3-benchmark`，会找到 3 处占位：

```bash
cd /home/jiao/git/INT8-CIM-of-jiao/Thesis/middle/paper
grep -n "c3-benchmark\|待测\|TODO(c3" paper.tex
```

**要填的表**（§5 `sec:c3_benchmark`，`tab:c3_benchmark`）：

| 指标 | 重构前 | 重构后（填） | 加速比（填） |
|---|---|---|---|
| 总 wall time（200 张） | 325.1 s | **填 §4 的 total_s** | **填 325.1 / total_s** |
| 单张平均延迟 | 1625.3 ms | **填 §4 的 ms_per_img** | **填 1625.3 / ms_per_img** |
| 硬件 compute 占比 | 0.4% | **填 §5 profile 的 compute 占比** | — |
| weight load 占比 | ~40% | **填 §5 的 load_w_pct** | — |
| 分类准确率 | 99.5% | **填 §4 的 accuracy** | 不变 |

重编译 paper：

```bash
bash recompile.sh
# 或: xelatex paper && biber paper && xelatex paper && xelatex paper
```

确认 `paper.pdf` 新章节数字都填了，没有 `待测`。

---

## 8. git 提交策略

**全部通过**的话：

```bash
cd /home/jiao/git/INT8-CIM-of-jiao
git add hw/scripts/vivado_build.tcl hw/scripts/vivado_build_55mhz.tcl \
        Thesis/middle/paper/paper.tex \
        Thesis/middle/data/benchmark/ \
        README.md docs/c3_onboard_tutorial.md
git commit -m "$(cat <<'EOF'
feat: C3 on-board benchmark + paper §5.x + step 9/10 design

C3 commit 6 on-board validation PASS (all 4 criteria met):
- LeNet-5 200 imgs: XX.X s (vs 325.1 s baseline), XXX× speedup
- ms_per_img: X.X (vs 1625.3 baseline, target <25)
- profiler load_w_ms: X.X% (vs ~40% baseline, target <5%)
- accuracy: 99.5% (199/200) bit-exact with MMIO baseline

Paper §5.x sec:c3_dma placeholders replaced with measured data.
README step 9 (C1 cim_tile split) + step 10 (Option C DSP SIMD)
design proposals added for post-C3 work.

Build scripts: added post-impl WNS gate per c3_dma_design §7.4.
EOF
)"
```

然后考虑是否直接上 commit 7（删 legacy MMIO 代码）。c3_dma_design §9 建议"通过 1 周后"再做，保守起见留到下周。

**回退路径**（任一条硬失败）：

```bash
cd /home/jiao/git/INT8-CIM-of-jiao
git checkout 9c7914f -- sw/cim_driver.py    # 恢复 use_dma=False 默认
git commit -m "revert: C3 default to use_dma=False pending on-board fix"
```

bitstream 保留两份（带 axi_dma 和不带），notebook 里通过 `CIMDriver("cim_soc.bit", use_dma=False)` 切回 legacy 路径。

---

## 9. 常见坑速查

| 症状 | 排查 |
|---|---|
| `AttributeError: 'Overlay' object has no attribute 'axi_dma_0'` | .hwh 没 axi_dma 段；回 §1 看 vivado log |
| `allocate` 报 CMA OOM | PYNQ 重启；或 `CIMDriver(..., max_w_chunks=10000)` 减少预分配 |
| accuracy 0.995 → 0.000 | stream sink 字序错。dump `drv._buf_w[:10]` 和 MMIO 路径前 10 个字对比 |
| accuracy 0.995 → 0.99 | 单图失配；大概率 hazard，不是 bit-exact 破坏。看 sink 的 `overflow/underflow` 标志 |
| WNS REGRESSION | §1 决策点 (a)/(b) |
| 200 张跑到一半 hang | soft_reset 与 DMA 竞态（c3_dma_design §8 risk 6）。检查 `CIMDriver.soft_reset()` 内部是否 `dma.sendchannel.wait()` 了 |

---

## 10. 预计时间表

| 步骤 | 估时 |
|---|---|
| §0 预检 | 5 min |
| §1 Vivado 构建 | 15-25 min（并行做别的事） |
| §2 传文件 | 2 min |
| §3 烟测 | 5 min |
| §4 200 张 benchmark | 1-5 min（取决于加速比） |
| §5 profiler | 2 min |
| §6 画图 | 5 min |
| §7 填论文 | 10 min |
| §8 git 提交 | 5 min |
| **合计** | **~1 小时**（Vivado 那段可以开着干别的） |

祝顺利。
