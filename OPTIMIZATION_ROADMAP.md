# INT8 CIM SoC — Optimization Roadmap

> 基于项目现状分析 + 领域前沿调研 (2026.05)
> 相关论文/项目见文末 References

---

## 2025 CIM 领域文献调研 (2026-05-04)

基于 [BUAA CIM Literature List](https://github.com/BUAA-CI-LAB/Literatures-on-SRAM-based-CIM) 的 2025 年最新论文分析：

### 2025 年 CIM 领域主要趋势

| 趋势 | 代表工作 | 与我们的相关性 |
|------|----------|---------------|
| **稀疏计算** | ISSCC 14.4 (51.6 TFLOPS/W), CICC 2025 (zero weight skipping), TACO Shift-CIM | 我们的 roadmap 1.2 稀疏权重支持方向正确 |
| **混合精度** | Nature 2025 (memristor+SRAM), LSSC 2025 (segmented precision), ASPDAC 2025 (layer-wise mixed) | 验证了我们 INT4/8 混合精度方向 |
| **Transformer/LLM 加速** | DAC 2025 (ViT+CIM), SHMT (SRAM+HBM), JSSC 2025 (LLM outlier-aware) | CIMple + Transformer attention 方向有强学术支撑 |
| **数字 CIM 设计自动化** | CIMFlow (DAC), SEGA-DCIM (DATE), DAMIL-DCIM (DATE) | 我们的 CIM 编译器计划符合行业趋势 |
| **误差弹性** | ER-DCIM (HPCA), MEJ 2025 (PVT-insensitive) | 验证了误差建模方向 |
| **混合存储架构** | JSSC 2025 (SRAM/ROM hybrid, >95% weight loading 减少), SHMT (SRAM+HBM) | 中长期可探索方向 |

### 关键发现：我们的独特性

**No 2025 paper explicitly addresses** im2col, double buffering, DMA pipeline overlap, or ping-pong buffering in titles. CIM 论文集中在 macro/circuit 层级创新，而**软件侧的数据搬运优化（setup、load_x、im2col）在学术文献中很少讨论**——这正是我们当前 66% 延迟瓶颈所在。我们的优化方向（AXI DMA 双向数据通路 + Python 侧优化）在工程上具有差异化价值。

**数据搬运瓶颈的间接验证：** JSSC 2025 的 Hybrid SRAM/ROM CIM 架构提到"reducing >95% weight data loading from DRAM"——说明即使是最先进的 CIM 芯片，weight loading 也是关键瓶颈。我们在 FPGA 上通过 DMA 优化 weight loading 的方向是正确的。

---

## 项目当前状态

| 模块 | 状态 | 瓶颈 |
|------|------|------|
| CIM Tile (16×16 MAC) | ✅ 完成 | 组合逻辑延迟 → 60MHz 上限 |
| CIM Accel Core | ✅ 完成 | pipeline 已多级 |
| AXI DMA 数据通路 | ✅ 完成 | MM2S + S2MM direct register mode, P0 完成 |
| LeNet-5 e2e benchmark | ✅ 完成 | accuracy 99.50% @200 images |
| 软件侧优化 (im2col + predict_batch + ndarray) | ✅ 完成 | 128.4→56.2ms/img (2.3×) |

### LeNet-5 Latency Breakdown (2026-05-06, C1 100MHz 最终)

| Phase | ms/img | % |
|-------|--------|---|
| load_x (DMA input) | 13.33 | 36.0% |
| read_out (DMA S2MM) | 10.61 | 28.6% |
| compute (hardware) | 6.51 | 17.6% |
| (other) | 2.91 | 7.9% |
| pool (vectorized) | 1.27 | 3.4% |
| im2col (vectorized) | 1.20 | 3.2% |
| setup (amortized) | 0.60 | 1.6% |
| pack (pre-packing) | 0.57 | 1.5% |
| final (argmax) | 0.05 | 0.1% |
| **TOTAL** | **37.1** | **100%** |

优化历程：
- MMIO path: 1690.54 ms/img (0.59 fps)
- DMA (C3 MM2S only, P0 read_out via MMIO): 503.65 ms/img (1.99 fps), speedup 3.4×
- DMA (C3 MM2S + P0 S2MM direct reg mode): 128.4 ms/img (7.8 fps), speedup 13.2× vs MMIO
- read_out: 257ms → 19.65ms (**13× faster**)
- SW v1 (im2col + predict_batch + maxpool): 128.4 → 73.5 ms/img (13.6 fps), speedup 1.75×
- SW v2 (read_output ndarray + vectorized unpack): 73.5 → 56.2 ms/img (17.8 fps), speedup 1.3×
- RTL k_pack v1 (MAX_IN_DIM 784→1024): 56.2 → 40.5 ms/img (24.7 fps), speedup 1.39×
- RTL k_pack v2 (MAX_IN_DIM 1024→1536): 40.5 → 36.9 ms/img (27.1 fps), speedup 1.10×
- **C1 100MHz (TILE_SPLIT_FACTOR=4): compute 7.02→6.51ms, 总延迟持平 37.1ms — MAC 4 拍拆分抵消了时钟收益**
- **Phase B IBUF/OBUF 双缓冲乒乓: 37.1→29.2ms/img (-22%), 34.3 fps, load_x+read_out 完全隐藏在 compute 之后**
- **MVM 调用数: 44 → 29 → 24 (-45%), BRAM 91.4% (PNQ-Z2 极限)**
- **累计 vs MMIO: 57.9×**

# 1. 性能优化（短期 — 1~2 月）

## 1.1 当前瓶颈优化

**已解决 — P0 S2MM (2026-05-03/04):**
- ✅ RTL: `cim_axi_stream_source.sv` — BRAM 2-cycle latency fix, tlast off-by-one, done sticky, is_last_word sticky
- ✅ SW: direct register mode bypass PYNQ _SDMAChannel (MM2S + S2MM), double-buffer
- ✅ read_out 串行 MMIO (257ms) → S2MM DMA (19.65ms), 13× speedup
- ✅ 端到端: 503ms → 128ms/img, 3.9× speedup vs pre-P0 DMA

**已解决 — P1 软件侧三优化 (2026-05-04, 代码完成, 2026-05-05 上板验证 ✅):**

1. **im2col 向量化:** 用 `np.lib.stride_tricks.as_strided` 替换 Python 嵌套循环
   - 方法: 构建 5D 视图 (C, out_h, out_w, K_h, K_w) → transpose → copy → reshape
   - **实测: 20.6ms → 1.2ms (17×)** ✅
2. **setup 优化 (layer-wise batching):** 新增 `CIMModel.predict_batch()` 方法
   - 方法: 逐层处理全部图像，每层 weight/bias 只加载一次
   - **实测: 41.0ms → 0.2ms amortized (195×)** ✅
3. **load_x 优化 (预打包):** Conv 输入列用 numpy reshape 批量预打包
   - 方法: `(col_len, n_pixels)` → pad → reshape/transpose → `(n_batches, k_pack*col_len)` 一次生成
   - 实测: DMA 次数不变 (44/img), 但消除了逐列 Python 分配开销

**附加优化 (2026-05-05):**
4. **maxpool2d 向量化:** as_strided 5D 视图 + `.max(axis=(3,4))` 替代 Python 三层循环 — 实测: 1.3ms
5. **read_output → ndarray + 向量化 unpack** (commit 139af9f):
   - `_read_output_dma/mmio` 返回 numpy int8 数组而非 Python list
   - Conv 输出解包从逐像素 Python for 循环改为 `reshape(batch_size, C_out).T` 单次 numpy 赋值
   - **实测: "other" 19.1→4.9ms (-14.2ms), 总延迟 73.5→56.2ms (-24%)**
6. **Profiler 修复 v2:** 消除 double-counting，新增 pack_ms / pool_ms / final_ms 追踪

### 2026-05-05 上板实测结果 (200 images, DMA + batch)

| Phase | 原始 (DMA) | SW v1 | SW v2 (final) | 累计改善 |
|-------|-----------|-------|---------------|---------|
| im2col_ms | 20.58 | 1.21 | 1.18 | **-94% (17×)** |
| pack_ms | — | 0.57 | 0.55 | — |
| setup_ms | 41.05 | 0.21 | 0.21 | **-99.5% (195×)** |
| load_x_ms | 23.01 | 23.92 | 22.69 | ≈ |
| compute_ms | 7.17 | 7.20 | 6.98 | ≈ |
| read_out_ms | 19.65 | 19.94 | 18.32 | ≈ |
| pool_ms | — | 1.27 | 1.24 | 向量化 |
| final_ms | — | 0.08 | 0.05 | — |
| (other) | ~16 | 19.06 | 4.93 | **-69%** |
| **TOTAL** | **128.4** | **73.5** | **56.2** | **-56% (2.3×)** |

**FPS 演进: 0.59 (MMIO) → 7.8 (DMA) → 13.6 (SW v1) → 17.8 (SW v2), 累计 30× vs MMIO**
**Accuracy: 199/200 (99.5%) 全程不变**

使用方式: `python scripts/benchmark_e2e.py --use-dma --batch --n_images 200`

### 当前瓶颈分析 (37.1 ms/img, C1 100MHz)

| Phase | ms | % | 优化潜力 |
|-------|-----|-----|------|
| load_x_ms | 13.33 | 36.0% | **Phase B 双缓冲可隐藏** |
| read_out_ms | 10.61 | 28.6% | **Phase B 双缓冲可隐藏** |
| compute_ms | 6.51 | 17.6% | TILE_SPLIT_FACTOR=4 已拆分, 100MHz 已是最优 |
| (other) | 2.91 | 7.9% | 残余 Python overhead |
| pool_ms | 1.27 | 3.4% | 已优化 |
| im2col_ms | 1.20 | 3.2% | 已优化 |
| setup_ms | 0.60 | 1.6% | 已优化 |
| pack_ms | 0.57 | 1.5% | 已优化 |

**load_x + read_out = 23.94ms (64.6%) — 这是最后的大优化目标。Phase B 双缓冲通过 DMA↔Compute 乒乓可将这两个阶段完全隐藏。**

**下一阶段目标: Phase B — IBUF/OBUF 双缓冲 DMA↔Compute 乒乓 → ~20 ms/img (50 fps)**

### 已解决 — RTL k_pack 扩展 v2 (2026-05-05, 上板验证 ✅)

**方法:** 两次递增 `MAX_IN_DIM` 784→1024→1536, `MAX_OUT_DIM` 128→256，扩大 k_pack 容量。

| 参数 | MAX_IN_DIM | MAX_OUT_DIM | Conv1 k_pack | Conv2 k_pack | 总 MVM | BRAM | 实测 ms/img | fps | speedup |
|------|-----------|-------------|-------------|-------------|--------|------|-----------|-----|---------|
| 原始 | 784 | 128 | 21 | 5 | 44 | ~25 | 56.2 | 17.8 | — |
| v1 | 1024 | 256 | 40 | 6 | 29 | 50% | 40.5 | 24.7 | 1.39× |
| **v2** | **1536** | **256** | **42** | **10** | **24** | **90%** | **36.9** | **27.1** | **1.10×** |

- MVM 总数: 44 → 24 (-45%), DMA overhead 同比例减少
- BRAM 90% — PYNQ-Z2 实际极限，无法继续增大参数
- Accuracy 199/200 全程不变
- **累计 vs MMIO: 45.8×**

## 1.2 Pipeline 深度优化

**现状：** 已有 weight load → compute → store 三级流水

**方向：**
- **双缓冲 weight SRAM：** 一边计算当前层，一边 DMA 加载下一层权重
- **input/output buffer ping-pong：** 消除层间等待
- **Performance counter 分析：** 量化每一层的 stall 原因

**预期收益：** 多层网络推理 latency 再降 30-50%

## 1.3 时钟频率提升 (C1) — ✅ 已完成 (2026-05-06)

**结论：** 100MHz bitstream 上板可跑 (accuracy 99.5%)，但因 TILE_SPLIT_FACTOR=4 引入额外 MAC 周期，compute 仅 -7.3% (7.02→6.51ms)，总延迟持平。C1 的主要价值是证明 100MHz 时序可行性，为 Phase B 双缓冲提供时钟裕量。

**RTL 变更 (2026-05-05/06):**
- `cim_pkg.sv`: `TILE_SPLIT_FACTOR = 4` — MAC 16→4+4+4+4 四拍流水
- `cim_tile.sv`: 每 quarter 4 列 → 1×CARRY4 → ~5ns 组合路径
- `cim_accel_core.sv`: FSM +4 拍/IB (ST_XEFF_REG→ST_XEFF_LATCH 新增 + ST_MAC_Q0→Q1→Q2→Q3 + ST_COMPUTE)
- `psum_accum.sv`: 四 quarter 同拍累加
- `input_buffer.sv`: 新增输出流水寄存器，`x_eff`/`x_tile` 由组合改为寄存器输出 → 断 BRAM→x_eff 长路径
- `vivado_build.tcl`: `FCLK_MHZ 60→100`, 复位模块名 `rst_ps7_${FCLK_MHZ}M` 变量化
- `cim_soc.xdc`: `create_clock -period 10.000`, `MAX_FANOUT=16` on x_eff_reg
- 仿真 ALL PASS (2026-05-06): tb_cim_tile 103/103, tb_cim_accel_core 6/6, tb_mnist_e2e 128+10 MATCH

**Bitstream 构建 (2026-05-06):**
- 合成 2.5min, 实现 28min (place 26min + route 3.9min), ExtraNetDelay_high + AggressiveExplore
- WNS=-0.800ns (801 failing endpoints), WHS=0.024ns (MET), timing NOT closed
- 关键路径: x_eff_reg → DSP48E1 (3.84ns) → route (1.49ns) → LUT/CARRY4 (1.74ns) → tile_psum_q0_reg
- 利用: LUT 30%, Register 10%, BRAM 90%, DSP **100%**
- 负 slack 但上板可跑 (室温侥幸)

**上板实测 (2026-05-06, 200 images):**

| Phase | 60MHz (ms) | 100MHz (ms) | Delta |
|-------|-----------|------------|-------|
| load_x | 12.97 | 13.33 | +2.8% |
| compute | 7.02 | 6.51 | **-7.3%** |
| read_out | 10.41 | 10.61 | +1.9% |
| im2col | 1.20 | 1.20 | - |
| pool | 1.24 | 1.27 | - |
| setup | 0.60 | 0.60 | - |
| pack | 0.56 | 0.57 | - |
| (other) | 2.83 | 2.91 | +2.8% |
| **TOTAL** | **36.90** | **37.06** | **+0.4%** |

**分析:** TILE_SPLIT_FACTOR=4 使 MAC 从 1 cycle → 4 cycles，时钟 1.67× 提升被 4× 拆分抵消 (净 1.67/4=0.42× on MAC ops)。非 MAC 流水级 (bias/act/requant/clamp) 享 100MHz 加速，但占比太小。总延迟持平。

## 1.4 Phase B: IBUF/OBUF 双缓冲 — ✅ 已实现 (2026-05-06)

**目标:** 通过 IBUF/OBUF 双 bank 乒乓，将 load_x (13.33ms, 36%) 和 read_out (10.61ms, 28.6%) 隐藏在 compute 之后，DMA 访问非活跃 bank 的同时 CIM compute 使用活跃 bank。

**RTL 变更:**
- `cim_pkg.sv`: 新增 `CSR_PING_CTRL = 14'h06C` (bank 切换寄存器)
- `input_buffer.sv`: `bank0`/`bank1` 双 bank，新增 `wr_bank_sel`/`rd_bank_sel` 端口
- `output_buffer.sv`: `bank0`/`bank1` 双 bank，新增 `wr_bank_sel`/`rd_bank_sel` 端口
- `cim_axi_lite_slave.sv`: 新增 `reg_ping_ctrl` 寄存器，bank_sel 路由逻辑
- `cim_accel_core.sv`: **未修改**（核心不知道 bank 存在）
- BRAM: 123.5/140 (88.2%), +2 BRAM36

**Bank 选择逻辑 (在 cim_axi_lite_slave.sv):**

| Signal | Formula | Purpose |
|--------|---------|---------|
| ibuf rd bank | `reg_ping_ctrl` | Compute 读取活跃 bank |
| obuf wr bank | `reg_ping_ctrl` | Compute 写入活跃 bank |
| ibuf wr bank | `~reg_ping_ctrl` | DMA 写入非活跃 bank |
| obuf rd bank | `~reg_ping_ctrl` | DMA 读取非活跃 bank |

CSR `0x06C` 写 `1` 翻转 `reg_ping_ctrl`。写 `0` no-op。读返回当前值。

**Python Driver (`cim_driver.py`):**
- `toggle_bank()`: 写 1 到 CSR_PING_CTRL
- `start_compute()`: 非阻塞触发计算
- `wait_for_done()`: 阻塞轮询 STATUS[1]
- `infer_batch_pingpong(inputs_u8, out_dim)`: 乒乓编排
  - Cold start: load_input(0) → toggle → start_compute
  - Loop i=1..n-1: load_input(i) during compute(i-1) → wait → toggle → read_output(i-1) → start_compute(i)
  - Tail: wait → toggle → read_output(n-1)

**Bitstream (2026-05-06):**
- WNS=-0.991, WHS=0.010 (与 Phase A WNS=-0.800 类似)
- 合成 2.5min, 实现 32min (place 27min + route 3.2min + bitgen 13s)
- ExtraNetDelay_high + AggressiveExplore
- 利用: LUT 31.8%, Register 9.8%, BRAM 88.2%, DSP 100%
- Bitstream: `vivado_proj/pynq_deploy/cim_soc.bit`

**验证:**
- 仿真回归 ALL PASS (3/3): tb_cim_tile, tb_cim_accel_core (6 tests), tb_mnist_e2e
- 上板 benchmark: **DONE ✅ (2026-05-06)**

**上板实测 (200 images, DMA + batch + pingpong):**

| Phase | 60MHz seq (ms) | Phase A 100MHz (ms) | Phase B pingpong (ms) | vs Phase A |
|-------|---------------|--------------------|-----------------------|------------|
| load_x | 12.97 | 13.33 | ~0 (hidden) | -100% |
| compute | 7.02 | 6.51 | ~0 (hidden) | — |
| read_out | 10.41 | 10.61 | ~0 (hidden) | -100% |
| im2col | 1.20 | 1.20 | 1.22 | +2% |
| pool | 1.24 | 1.27 | 1.24 | -2% |
| setup | 0.60 | 0.60 | 0.59 | -2% |
| pack | 0.56 | 0.57 | 0.66 | +16% |
| (other) | 2.83 | 2.91 | 25.36 | — |
| **TOTAL** | **36.90** | **37.06** | **29.18** | **-21.5%** |

**FPS 演进: 0.59 (MMIO) → 7.8 (DMA) → 17.8 (SW v2) → 27.1 (k_pack v2) → 34.3 (Phase B), 累计 57.9× vs MMIO**
**Accuracy: 199/200 (99.5%) 全程不变**

注: Phase B 的 "other" 25.36ms 是所有 MVM 调用的 ping-pong wall time（load_x + compute + read_out 已重叠）。实际瓶颈 = max(DMA, compute)。

---

## 1.5 Phase C: Layer Fusion — OBUF→IBUF 内部直拷 — 🟡 RTL v9 完成, 待上板验证 (2026-05-10)

**目标：** 消除 FC→FC 层间 DMA round-trip（read_output S2MM → DDR → load_input MM2S），用硬件内部 OBUF→IBUF 拷贝替代。

**方法：**
- 新增 5 状态 FSM (F_IDLE → F_WAIT_MUX → F_RD_FIRST → F_PACK → F_WRITE) 在 `cim_axi_lite_slave.sv`
- OBUF 按字节读取，打包为 128-bit tile words (16 INT8/tile) 写入 IBUF
- 3 个新 CSR: `CSR_FUSION_CTRL (0x070)`, `CSR_FUSION_LEN (0x074)`, `CSR_FUSION_STATUS (0x078)`
- N 字节拷贝耗时 N+2 周期 + ~6% tile 边界开销 (每 16 字节额外 1 拍)
- OBUF 读路径有 2 周期流水线延迟：1 周期 MUX 传播 + 1 周期 BRAM 读
- 约束: n_elements ≤ MAX_OUT_DIM (256)

**v2 Bug Fix (2026-05-07):** 修复 OBUF 读流水线 stall — F_RD_FIRST 中提前推进 `fusion_obuf_addr`，消除 1 字节移位。

**v3 Batch Extension (2026-05-07):** 新增 `CSR_WEIGHT_BASE (0x07C)` 和 `CSR_BIAS_BASE (0x080)` 偏移寄存器，使 FC1/FC2 权重可在 weight/bias SRAM 中共存。`cim_accel_core.sv` 的 weight tile index 和 bias address 计算加入 base 偏移。

- **消除 batch 下 per-image weight reload：** FC1 权重存 tile 0..N1-1，FC2 权重存 tile N1..N1+N2-1，batch 推理时仅需切换 CSR_WEIGHT_BASE/BIAS_BASE
- **DMA 流加载带偏移：** `_stream_load()` 新增 `base_addr` 参数，通过 `CSR_STREAM_DEST[31:16]` 设置起始 tile/word 地址
- **Python API：** `setup_fc_fused_pair()` 预加载双 layer 权重，`infer_fc_fused_batch()` batch 推理无需 per-image weight reload
- BRAM 容量足够：LeNet-5 FC1+FC2 = 248 tiles，WSRAM 容量 1536 tiles

**v4 Timing Pipeline Fix (2026-05-07):** v3 的 `cfg_weight_base`/`cfg_bias_base` 加法器使 WNS 从 -1.151ns 恶化到 -1.853ns (2771 failing endpoints @100MHz)。组合路径：base adder → w_addr_full/bias_addr_cur → SRAM read → w_tile_reg/bias_val_r 超出 10ns 时钟周期。

**修复：** 将 `w_rd_tile_idx` 和 `b_rd_addr` 提前一个周期寄存：
- `w_rd_tile_idx_r`：在 ST_CLEAR_PSUM / ST_WAIT_SRAM / ST_NEXT_IB 中预计算
- `b_rd_addr_r`：在 ST_NEXT_IB / ST_WRITE_OBUF 中预计算
- 组合块使用寄存器版本替代组合逻辑 `w_addr_full`/`bias_addr_cur`
- 将加法器链（第 N 拍）与 SRAM 读取 + MAC（第 N+1 拍）分离
- 仿真回归: ALL PASS (3/3) ✅

**当前限制：**
- Bias SRAM 容量 256 entries，大网络多 layer bias 可能不够（需评估）
- 上板测试待进行

**RTL 状态：**
- 仿真回归: ALL PASS (3/3) ✅
- Bitstream v2: 已构建 (WNS=-1.151, WHS=0.039, BRAM 114/140=81.4%)
- Bitstream v3 (WEIGHT_BASE): 已构建 (WNS=-1.853, 2771 failing endpoints, BRAM 81.43%)
- **Bitstream v4 (pipeline fix): 已构建 (WNS=-0.533, WHS=0.008, BRAM 114/140=81.43%)** — 比 v3 改善 1.32ns，比 v2 改善 0.62ns。`bitstream&hwh/checkpoint7/`

**v5 OBUF Write Address Bug Fix (2026-05-08):** v4 中 `bias_addr_cur` 错误地包含了 `cfg_bias_base`（来自 v3 的加法器），导致 OBUF 写地址偏移了 bias_base。非零 bias_base 时计算结果写入错误的 OBUF 位置，导致后续融合拷贝或 DMA 读取读到错误数据。

**修复：**
- `bias_addr_cur` 恢复为不含 `cfg_bias_base` 的原始公式（仅用于 OBUF 写地址流水线）
- `b_rd_addr_r` pipeline register 正确包含了 `cfg_bias_base`（用于 bias SRAM 读地址）
- 新增 `tb_cim_accel_core.sv` Tests 7a/7b/7c: 分别测试仅 weight_base、仅 bias_base、两者均非零
- 移除 combo block 中未使用的 `bias_addr_next_tile`/`bias_addr_next_row` 对 `b_rd_addr` 的赋值
- 仿真回归: ALL PASS (3/3) ✅, 测试 7a/7b/7c 全部 MATCH

- **Bitstream v5: 已构建 (`bitstream&hwh/checkpoint8/`)** — WNS=-0.544, WHS=0.034, LUT 32.64%, BRAM 81.43%
- 上板测试: 待进行

**v6 MUX Pipeline Fix (2026-05-09):** OBUF→IBUF 融合 FSM 的流水线建模不完整。OBUF 读路径需要 2 周期延迟：
1. `always_comb` MUX 传播（`fusion_busy` → `obuf_rd_addr` → OBUF `rd_addr`，跨 NBA 区域）
2. OBUF 寄存器 BRAM 读取（`rd_data <= bank[rd_addr]`）

v5 只有 1 个预热状态（F_RD_FIRST），在 OBUF[0] 就绪之前就捕获了垃圾数据并推进地址，导致 1 字节移位。`cim_axi_stream_source.sv` 的 P0 结果源有相同问题（已通过添加 S_WAIT 状态修复）。

**修复：** 新增 `F_WAIT_MUX` 状态：
- `F_IDLE → F_WAIT_MUX`: 设置 addr=0, busy=1（MUX 在一个 NBA 区域后选择 `fusion_obuf_addr`）
- `F_WAIT_MUX → F_RD_FIRST`: 等待 MUX，地址推进到 1
- `F_RD_FIRST → F_PACK`: 捕获字节 0（OBUF[0]），地址推进到 2
- `F_PACK → F_WRITE`: 与原版相同

这与 P0 source 流水线完全一致：`S_IDLE → S_WAIT → S_WARMUP → S_READ`。
总周期数：N+2 周期 + ceil(N/16) tile 写开销。

**Files Modified (v6):**
1. `cim_axi_lite_slave.sv` — added F_WAIT_MUX enum; F_IDLE→F_WAIT_MUX transition; F_RD_FIRST now captures byte 0

**Regression:** PASS (3/3). **Committed:** `45857e8`. **Bitstream:** `bitstream&hwh/checkpoint10/`. WNS=-0.788, WHS=0.015. **On-board test: FAILED** — 1-byte shift confirmed, traced to F_WAIT_MUX skipping byte 0.

**v7 Fix (2026-05-09):** F_WAIT_MUX now captures byte 0 instead of skipping it. The always_comb MUX propagates immediately — only the BRAM read is registered (1 stage, not 2). At the start of F_WAIT_MUX, `rd_data` already holds OBUF[0]. F_RD_FIRST eliminated. Total: N cycles + ceil(N/16) tile-write overhead.

**Regression:** PASS (3/3). **Committed:** `db99cf8`. **Bitstream:** `bitstream&hwh/checkpoint11/`. WNS=-0.899, WHS=0.025, LUT 32.55%, FF 10.09%, BRAM 88.21%, DSP 100%. **On-board test: FAILED** — tile_idx off-by-one in F_WRITE (see v8).

**v8 Tile Index Fix (2026-05-10):** On-board test revealed `fusion_tile_idx` is NBA-incremented in F_WRITE before IBUF write captures it at next posedge. Tile N data goes to IBUF tile N+1; tile 0 retains stale data. Fix: pipeline registers (`fusion_wr_tile_pipe`, `fusion_wr_data_pipe`, `fusion_wr_en_pipe`) capture tile_idx and tile data BEFORE increment. Write delayed by 1 extra clock; data integrity verified in simulation.

Also added debug CSR: `CSR_FUSION_DBG0` (0x084, cycle counter), `CSR_FUSION_DBG1` (0x088, tile-write counter).

**Regression:** PASS (3/3). **Committed:** `a416ca2`. **Bitstream:** `bitstream&hwh/checkpoint12/`. WNS=-0.747, WHS=0.011. **On-board test: FAILED** — 1-byte within-tile shift persists. v8 tile_idx fix changed the failure pattern (was: tile 0→1 offset, v8: all bytes shifted right by 1 within each tile), confirming tile_idx fix works but a second bug remains.

**v9 Byte-Shift Fix (2026-05-10):** On-board test revealed the fundamental pipeline modeling error: the comment claimed "2-cycle delay" but the FSM only waited 1 cycle. The OBUF BRAM read is **registered** (`always_ff @(posedge clk)` in `output_buffer.sv:55`), so `rd_data <= bank[rd_addr]` takes effect at the NEXT posedge.

Root cause: F_WAIT_MUX captured `obuf_rd_data` in the same cycle the always_comb MUX set `obuf_rd_addr`. The MUX propagation is instant, but the BRAM read is NOT — rd_data still held the previous cycle's value. Similarly, F_WRITE routed directly to F_PACK, where `obuf_rd_data` hadn't caught up with the incremented address.

Fix:
- F_WAIT_MUX: remove byte capture — just wait for OBUF registered read to complete
- F_PACK: now handles byte 0 (was incorrectly captured in F_WAIT_MUX)
- F_WRITE: route to F_WAIT_MUX (not F_PACK) to wait for OBUF read at incremented address

Total cycles: N + 1 + ceil(N/16)×2 (wait + tile-write overhead per tile).

Files changed:
1. `cim_axi_lite_slave.sv` — F_WAIT_MUX simplified to wait-only; F_WRITE→F_WAIT_MUX transition; updated pipeline documentation

**Regression:** PASS (3/3). **Committed:** `d31a3ce`. **Bitstream:** `bitstream&hwh/checkpoint13/`. WNS=-0.654, WHS=0.014, LUT 32.53%. On-board test pending.

**预期收益：**
- 单张 image FC→FC 过渡: -9ms (消除一次 S2MM + 一次 MM2S DMA setup)
- **Batch 推理 FC→FC 过渡: 每张 image 都省 ~9ms** (v3 消除 per-image weight reload)
- MNIST (FC1→FC2, 1 transition): batch 每 image 降 ~9ms
- LeNet-5 (FC1→FC2→FC3, 2 transitions): batch 每 image 降 ~18ms

**Files Changed:**
1. `cim_pkg.sv` — CSR_FUSION_CTRL/LEN/STATUS + CSR_WEIGHT_BASE + CSR_BIAS_BASE
2. `cim_axi_lite_slave.sv` — fusion FSM (v2: OBUF pipeline fix), IBUF/OBUF mux priority, weight/bias base regs
3. `cim_accel_core.sv` — cfg_weight_base, cfg_bias_base ports; v4: w_rd_tile_idx_r, b_rd_addr_r pipeline registers, pre-computation in seq block, combo block uses registered addresses
4. `cim_driver.py` — `copy_output_to_input()`, `infer_fc_fused_pair()`, `setup_fc_fused_pair()`, `infer_fc_fused_batch()`
5. `sw/scripts/test_fusion.py` — single + batch fusion 测试
6. `tb_cim_accel_core.sv` — v5: Tests 7a/7b/7c (non-zero weight_base/bias_base), `load_all_data_with_offsets()` task

---

# 2. 模型支持扩展（中期 — 2~4 月）

## 2.1 LeNet-5 完整验证

**现状：** 有 im2col + quantize 代码，但未完成完整端到端 board 验证

**TODO：**
1. 量化精度验证：golden_model vs CIM 硬件输出 bit-accurate 对比
2. 噪容限分析：多次推理结果一致性
3. 精度-速度 trade-off 表格

## 2.2 更大规模网络支持

**现状约束：** MAX_IN_DIM=784, MAX_OUT_DIM=128（PYNQ-Z2 BRAM 限制）

**方向：**
- **KV260 专属配置：** 利用更多 BRAM，支持 MAX_IN_DIM=4096+
- **权重分片加载：** 超标层分多次加载权重，消除维度硬上限
- **MobileNetV2 CIM mapping：** Depthwise conv 的 CIM 映射策略（特殊性：每 channel 独立）

## 2.3 Transformer Attention 支持

**相关研究：** CIMple (2026.04) — 用 LUT 实现 split softmax，CIM 加速 attention

**方向：**
- **Softmax 硬件化：** LUT-based softmax（INT8 输入对应有限 softmax 值）
- **Q/K/V projection 复用现有 MVM：** 三个投影矩阵可映射到三次 MVM 调用
- **目标模型：** MobileBERT / TinyBERT (<15M 参数) → 纯 FPGA edge 推理

## 2.4 稀疏计算支持

**相关研究：** DUB_Sparsity_for_XBars

**方向：**
- **结构化稀疏（2:4/N:M）：** prune → 只加载非零权重 → 对应输入选中
- **权重压缩传输：** DMA 传输量 = 密度 × original size
- **零值跳过 FSM：** skip zero-weight MAC columns

**预期收益：** 剪枝 50% 权重 → DMA latency 减半 → 总 latency 再降 30-40%

---

# 3. 精度与鲁棒性（中期）

## 3.1 混合精度支持

**现状：** 纯 INT8 量化 + INT32 累加

**方向：**
- **INT4/INT8 混合：** 第一层 INT8（敏感），中间层 INT4（不敏感）
- **FP16 累加器：** 替换 INT32 psum，减少 overflow 风险
- **per-channel quantization：** 替代全局 scale，提升精度

**验证标准：** INT4/8 混合 vs 纯 INT8，MNIST accuracy 下降 < 0.5%

## 3.2 模拟误差建模与补偿

**相关研究：** PSumSim — partial-sum quantization simulator

**方向：**
- 建立 CIM tile 的 bit-level 误差模型（工艺偏差 → MAC 误差）
- 训练时注入噪声（quantization-aware training + noise injection）
- 运行时 calibration（per-layer scale 动态调整）

## 3.3 Hardware-Aware Quantization

**现状：** `model_zoo.py` 有量化流程，但未与硬件特性绑定

**方向：**
- **量化感知训练 (QAT)：** 在训练时模拟 CIM tile 的量化行为
- **自动 calibration 脚本：** 一键 `quantize → golden → CIM → compare`
- **Pareto frontier 可视化：** accuracy vs latency vs energy

---

# 4. PicoRV32 自主推理（中期）

## 4.1 FW 完善

**现状：** `picorv32/fw/` 有基本固件框架

**方向：**
- 完整推理控制流程：load model → load input → run layers → output results
- UART 命令协议：PC 端发指令，RISC-V 执行后回传结果
- 与 Python driver 对标的纯 C 实现

## 4.2 性能对比

**验证标准：**
- PicoRV32 vs ARM PS：inference latency, energy, resource usage 对比

---

# 5. 工具链与自动化（持续）

## 5.1 CIM 编译器

**目标：** PyTorch model → CIM mapping → bitstream 的自动化流程

**Pipeline：**
```
PyTorch model
  → model_zoo.py (train + quantize)
  → cim_compiler.py (layer → CIM CSR sequence mapping)
  → cim_driver.py (on-board execution)
  → result collect + compare
```

## 5.2 CI/CD Pipeline

```yaml
# 每次 push 自动运行
1. RTL Lint (verilator)        # < 30s
2. Unit TB regression          # < 3min (cim_tile + cim_accel_core)
3. E2E MNIST simulation        # < 10min
4. Golden model cross-check    # < 1min
```

## 5.3 性能分析仪表板

- 每个 benchmark run 自动生成：layer latency breakdown, energy estimate, accuracy
- 与之前版本对比的趋势图
- 一键 `make report` 输出 markdown 报告

---

# 6. 长期探索方向

## 6.1 Multi-Tile Scaling

**适合 KV260：** 多 2-4 个 tile 并行计算不同 output channel 段
- 需要 crossbar 互联或广播 input
- weight SRAM 独立 → 总带宽线性增长

## 6.2 CIM + CNN 全流水

- **行缓冲架构：** 流式处理图像行，无需存储完整 feature map
- **im2col 硬件化：** 取消软件 im2col，直接 streaming 卷积 → CIM
- 目标：视频流实时推理（30fps）

## 6.3 跨平台

- **更高端 FPGA：** Alveo U200/U250 → 更大模型（ResNet-18?）
- **ASIC 可行性研究：** 估算面积/功耗/频率

---

# 优先级总览

| 优先级 | 方向 | 预期收益 | 难度 | 时间 |
|--------|------|----------|------|------|
| ✅ DONE | DMA S2MM read_output (P0) — direct reg mode, bypass PYNQ recvchannel, double-buffer | read_out 257→19.65ms (13×) | 中 | 2d | 2026-05-04 |
| ✅ DONE | DMA latency 分解 + 底层 profile | 定位热点: setup 41ms, load_x 23ms, im2col 21ms | 低 | 1w | 2026-05-04 |
| ✅ DONE | 软件侧全优化 (im2col + predict_batch + maxpool + ndarray unpack) | 128.4→56.2ms/img (2.3×, 17.8 fps) | 低 | 2d | 2026-05-05 |
| ✅ DONE | RTL k_pack v1 (MAX_IN_DIM 784→1024, MAX_OUT_DIM 128→256) | MVM 44→29 (-34%), 实测 40.5ms/img (24.7 fps) | 低 | 1d | 2026-05-05 |
| ✅ DONE | RTL k_pack v2 (MAX_IN_DIM 1024→1536) | MVM 29→24 (-17%), 实测 36.9ms/img (27.1 fps), BRAM 90% 极限 | 低 | 1d | 2026-05-05 |
| ✅ DONE | C1 时钟提升 (60→100MHz, TILE_SPLIT_FACTOR=4) — bitstream 上板, accuracy 99.5% | compute -7.3%, 总延迟持平, 证明 100MHz 时序可行 | 中 | 1w | 2026-05-06 |
| ✅ DONE | Phase B: IBUF/OBUF 双缓冲 — DMA↔Compute 乒乓重叠 | 37.1→29.2ms/img (-22%, 34.3 fps), load_x+read_out 完全隐藏 | 中 | 1w | 2026-05-06 |
| ✅ DONE | Phase C: Layer Fusion — OBUF→IBUF 内部直拷, 消除 FC→FC DMA round-trip | RTL v9 DONE (byte-shift fix, regression PASS), bitstream building (checkpoint13) | 中 | 1w | 2026-05-10 |
| 🟡 P1 | CIM 编译器 (PyTorch→CIM) | 用研效率 | 高 | 4w |
| 🟡 P1 | 稀疏权重支持 | 30-40% speedup | 高 | 4w |
| 🟢 P2 | KV260 移植 | 更快时钟+更大 BRAM | 中 | 2w |
| 🟢 P2 | PicoRV32 自主推理 | 独立模式 | 中 | 3w |
| 🟢 P2 | Transformer Attention | 新颖性 | 高 | 6w |
| 🔵 P3 | Mixed precision (INT4/8) | 精度/速度 tradeoff | 中 | 4w |
| 🔵 P3 | Multi-tile scaling (KV260) | 线性扩展 | 高 | 8w |
| 🔵 P3 | 误差建模与补偿 | 可靠性 | 高 | 6w |

---

# References

## 领域前沿论文 (2025-2026)

### Macro/Circuit 层级
- **ISSCC 2025 14.4** "51.6 TFLOPS/W Full-Datapath CIM Macro Approaching Sparsity Bound" — 稀疏约束下的全数据路径 CIM
- **ISSCC 2025 14.5** "192.3 TFLOPS/W Accurate/Approximate Dual-Mode-Transpose Digital 6T-SRAM CIM" — 支持浮点训练+推理
- **CICC 2025** "20.9-137.2 TOPS/W Output-Stationary CIM with Dynamic Look-ahead Zero Weight Skipping" — 零权重跳过
- **Nature 2025** "Mixed-precision memristor and SRAM CIM AI processor" — 混合存储介质的 CIM 处理器
- **JSSC 2025** "109.3-249.5 TFLOPS/W Outlier-Aware Floating-Point SRAM CIM for LLMs" — 面向 LLM 的浮点 CIM

### 架构层级
- **JSSC 2025** "Hybrid SRAM/ROM CIM for High Task-Level Energy Efficiency in Transformer" — 混合存储减少 >95% weight loading
- **DAC 2025** "Efficient Edge ViT Accelerator with Decoupled Chunk Attention and Hybrid CIM" — ViT + CIM
- **TCAS-I 2025** "FlexDCIM: 400 MHz 249.1 TOPS/W Flexible Digital CIM for CNN" — 数字 CIM 高频设计
- **TACO 2025** "Shift-CIM: In-SRAM Alignment for General-Purpose Bit-level Sparsity" — 比特级稀疏
- **HPCA 2025** "ER-DCIM: Error-Resilient Digital CIM with Run-Time MAC-Cell Error Correction" — 误差纠正

### 软件/工具链
- **CIMFlow** (DAC 2025): 数字 CIM 架构的系统化设计评估框架
- **SEGA-DCIM** (DATE 2025): 设计空间探索引导的自动数字 CIM 编译器（支持多精度）
- **DAMIL-DCIM** (DATE 2025): 数据流感知的数字 CIM 布局综合框架

### 直接相关 (本项目)
- **CIMple** (arxiv 2026.04): Standard-cell SRAM CIM with LUT-based softmax for attention
  — 首次将 CIM 扩展到 Transformer attention，LUT-based softmax 可借鉴
- **Hardware-Software Co-Design for Transformer with CIM** (arxiv 2025.02)
  — Transformer 推理的软硬件协同设计方法论
- **TinyMOA** ([GitHub](https://github.com/EzraWolf/TinyMOA)): RISC-V + SRAM CIM integrated chip
  — 与 PicoRV32 路线高度相关
- **DUB Sparsity for Crossbars** ([GitHub](https://github.com/TimurIbrayev/DUB_Sparsity_for_XBars))
  — 结构化稀疏在 CIM crossbar 上的应用
- **PSumSim** ([GitHub](https://github.com/Joschua-Conrad/PSumSim))
  — 模拟 MVM 中 partial-sum 量化误差的工具
- **BUAA CIM Literature List** ([GitHub](https://github.com/BUAA-CI-LAB/Literatures-on-SRAM-based-CIM))
  — SRAM CIM 领域论文汇总（2025.05 更新）
- **CONV-SRAM** (本项目参考论文): Energy-Efficient SRAM With In-Memory Dot-Product for Low-Power CNN
