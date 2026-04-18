# C3 — AXI4-Stream + axi_dma 数据通路重构设计文档

> 本文档为 README.md "step 8" 的详细实现规范。所有数字均基于 PYNQ-Z2 (xc7z020clg400-1)、60 MHz fabric、当前 LeNet-5 / MNIST-MLP 模型规模实测或一阶推算。
>
> **作用对象**：实现者按本文 Decision 1-9 的具体方案落地，验证者按 Phase 4 / Phase 6 的判据接收。

---

## 0. 背景与动机（量化）

A2 profiler 在 60 MHz baseline 上测得：

| 模型 | 单图墙钟 | 硬件 compute | MMIO weight load | MMIO input/bias |
|---|---|---|---|---|
| LeNet-5 (200 张) | **1696 ms/img** | ~4 ms | ~700 ms (Conv1+Conv2+FC3) | ~30 ms |
| MNIST-MLP | ~30 ms/img | ~0.05 ms | ~25 ms | ~3 ms |

LeNet-5 端到端 99.4% 时间花在 AXI4-Lite 32-bit 逐字 MMIO 上。本质原因：

1. PYNQ `MMIO.write()` 是 syscall，单次开销 ~2-5 µs（Python → libc → /dev/mem mmap → AXI 事务）
2. LeNet-5 单图 weight 数据量 ~170 KB（packed）= ~42500 个 32-bit 字 → ~120-200 ms 纯 Python 循环开销
3. 真正的 AXI4-Lite 单事务硬件耗时仅 ~50 ns，软件循环放大了 ~50 倍

**修复策略**：换一条数据通路。CSR 控制保留 AXI4-Lite（量小、对延迟敏感、Python `mmio.write` 适合），数据搬运改 AXI4-Stream + Xilinx `axi_dma` IP（量大、批量、PYNQ `pynq.lib.dma` 一行调用）。

**理论收益**：

- HP 端口峰值带宽：1.2 GB/s（UG585 §22.6.5，64-bit @ 150 MHz）
- 实际受 fabric 60 MHz × 64-bit 限制：480 MB/s
- 单图 170 KB / 480 MB/s = **354 µs** （仅 weight）
- 加 Python 设置开销 ~50 µs/层 × 5 层 = 250 µs
- 硬件 compute 仍 ~4 ms（不变）
- **预测端到端：~5-6 ms/img，270× 加速**

---

## 1. 设计原则

1. **bit-exact 是硬约束**：写入 weight_sram / input_buffer / bias_sram 的字必须与现行 AXI4-Lite 路径在每一拍都相同。pytest 与 e2e TB 必须全 GREEN。
2. **CIM 计算核心零改动**：`cim_tile.sv / psum_accum.sv / cim_accel_core.sv` 不动一行。改动局限在 axi/ 目录与新增顶层。
3. **dual-path 共存**：legacy MMIO 路径保留（CSR_CTRL[3]=0 切回），用于上板 A/B 对照与回归隔离。直到 Phase 4 上板 200 张 bit-exact 验证通过，才在独立 commit 中删除 legacy 代码。
4. **失败可回退**：每一阶段 commit 都可单独构建与测试，commit 4 (BD 改动) 前打 git tag `pre-c3-bd`。

---

## 2. 系统架构

### 2.1 PS-PL 接口拓扑

```
                      ┌─── M_AXI_GP0 (32-bit, 控制, 600 MB/s) ──┐
              ┌────┐  │                                          │
              │ PS │──┤                                          │
              │ 7  │  └─── S_AXI_HP0  (64-bit, 数据, 1.2 GB/s) ─┐│
              │    │                                            ││
              │    │◀───── IRQ_F2P[1:0] (xlconcat) ──────────┐  ││
              └────┘                                          │  ││
                                                              │  ││
        ┌─── AXI Interconnect (CSR bus, 32-bit) ────────────┐ │  ││
        │                                                    │ │  ││
        │   ┌──────────────────┐                            │ │  ││
        │   │ axi_dma_0        │                            │ │  ││
        │   │  S_AXI_LITE  ◀───┼─── (DMA 控制 CSR)          │ │  ││
        │   │  M_AXI_MM2S  ─◀──┼──────────────────────────────  ││ (DDR 读)
        │   │  M_AXIS_MM2S ─┐  │                            │ │  ││
        │   │  mm2s_introut─┼──┼──────────────────────────  │ │  ││
        │   └──────────────┬┘  │                            │ │  ││
        │                  │   │                            │ │  ││
        │   ┌──────────────▼───┴──────────────────────────┐ │ │  ││
        │   │ cim_top                                      │ │ │  ││
        │   │  ┌─────────────────────┐                    │ │ │  ││
        │   │  │ cim_axi_lite_slave  │◀───────────────────┼─┘ │  ││
        │   │  │  (CSR + legacy MMIO │ CSR_CTRL[3]=0      │   │  ││
        │   │  │   staging path)     │ → legacy enable    │   │  ││
        │   │  └─────────┬───────────┘                    │   │  ││
        │   │            │                                │   │  ││
        │   │  ┌─────────▼───────────┐                    │   │  ││
        │   │  │ cim_axi_stream_sink │◀── M_AXIS_MM2S ────┼───┘  ││
        │   │  │  (4-beat → 128-bit  │ CSR_CTRL[3]=1      │      ││
        │   │  │   row assembler)    │ → stream enable    │      ││
        │   │  └─────────┬───────────┘                    │      ││
        │   │            │                                │      ││
        │   │   MUX (CSR_CTRL[3])                         │      ││
        │   │            │                                │      ││
        │   │            ▼                                │      ││
        │   │  weight_sram / input_buffer / bias_sram     │      ││
        │   │            │                                │      ││
        │   │  cim_accel_core (unchanged)                 │      ││
        │   │            │                                │      ││
        │   │            └─── irq_done ───────────────────┼──┐   ││
        │   └──────────────────────────────────────────────┘  │   ││
        │                                                     │   ││
        └─────────────────────────────────────────────────────┘   ││
                                                                  ││
            xlconcat: {mm2s_introut, irq_done} ───────────────────┘│
                                                                   │
                                       Clock: ps7/FCLK_CLK0 60 MHz │
                                       Reset:                      │
                                         proc_sys_reset_0 → cim_0  │
                                            (aux_reset = CTRL[2])  │
                                         proc_sys_reset_1 → axi_dma│
                                            (PS reset only)        │
```

### 2.2 数据流（Python 视角）

```python
# 当前 layer 的 packed weight 已在 CIMModel 构造时算好
chunks = layer["w_chunks"]               # list[int], 每个元素 32-bit

# 1. 把数据塞进 pinned CMA buffer (np.uint32 视图)
self._buf_w[:len(chunks)] = np.asarray(chunks, dtype=np.uint32)

# 2. 通过 CSR 告诉 sink "下一波数据是 weight, 共 N 个 32-bit 字"
self.mmio.write(CSR_STREAM_DEST, 0)      # 0=weight, 1=input, 2=bias
self.mmio.write(CSR_STREAM_LEN,  len(chunks))

# 3. 启动 DMA 传输（PS 拉 DDR → HP0 → axi_dma → AXIS → cim_axi_stream_sink）
self.dma.sendchannel.transfer(self._buf_w[:len(chunks)])
self.dma.sendchannel.wait()              # 阻塞直到 mm2s_introut 拉高

# 4. （可选）轮询 CSR_STREAM_STATUS[1] 确认 sink 也声明 done
assert self.mmio.read(CSR_STREAM_STATUS) & 0x2, "sink did not finish"
```

---

## 3. 接口规范

### 3.1 cim_axi_stream_sink.sv 端口表

| 端口 | 方向 | 宽度 | 含义 |
|---|---|---|---|
| `clk` | in | 1 | FCLK_CLK0, 60 MHz |
| `rst_n` | in | 1 | 来自 proc_sys_reset_0 |
| **AXI Stream slave** | | | |
| `s_axis_tdata` | in | 32 | 数据 |
| `s_axis_tvalid` | in | 1 | DMA 提供有效数据 |
| `s_axis_tready` | out | 1 | 恒为 1（详见 §3.4 反压） |
| `s_axis_tlast` | in | 1 | DMA 在最后一拍拉高 |
| **来自 CSR 的配置** | | | |
| `cfg_dest[1:0]` | in | 2 | 目的地：0=weight, 1=input, 2=bias |
| `cfg_len[15:0]` | in | 16 | 期望 beat 数 |
| `cfg_start` | in | 1 | 启动一次接收（write 1 to CSR_CTRL[0] 触发？或自启动？见 §3.5） |
| **状态回报** | | | |
| `busy` | out | 1 | 接收过程中拉高 |
| `done` | out | 1 | 一拍脉冲，最后一个字写入 BRAM 完成 |
| `overflow` | out | 1 | beat_count > cfg_len 或 tlast 早于预期 |
| `underflow` | out | 1 | tlast 时 beat_count < cfg_len |
| **写入 weight_sram (whole-row 接口)** | | | |
| `wsram_wr_en` | out | 1 | 写使能 |
| `wsram_wr_row[3:0]` | out | 4 | 行号 0-15 |
| `wsram_wr_tile_idx[N-1:0]` | out | clog2(WSRAM_DEPTH) | tile 号 |
| `wsram_wr_row_data[127:0]` | out | 128 | 整行数据 |
| **写入 input_buffer (whole-tile 接口)** | | | |
| `ibuf_wr_en` | out | 1 | |
| `ibuf_wr_tile_idx[M-1:0]` | out | clog2(MAX_IN_DIM/TILE_COLS) | |
| `ibuf_wr_tile_data[127:0]` | out | 128 | |
| **写入 bias_sram (whole-word 接口)** | | | |
| `bsram_wr_en` | out | 1 | |
| `bsram_wr_addr[K-1:0]` | out | clog2(BSRAM_DEPTH) | |
| `bsram_wr_data[31:0]` | out | 32 | |

**注**：weight/input/bias 三组写信号在 `cim_top.sv` 里与 legacy 路径的同名信号做 MUX，由 `CSR_CTRL[3]` 选择。

### 3.2 内部状态机

```
state ∈ { IDLE, RECV_WEIGHT, RECV_INPUT, RECV_BIAS, DONE_PULSE, ERROR }

IDLE:
  if (cfg_start) → state = case(cfg_dest)
                     0 → RECV_WEIGHT
                     1 → RECV_INPUT
                     2 → RECV_BIAS
                   beat_count = 0
                   reset shift register, busy = 1

RECV_WEIGHT:
  if (s_axis_tvalid && s_axis_tready):
    shift_reg[31:0] ← shift_reg[63:32]  // 移位
    shift_reg[63:32] ← shift_reg[95:64]
    shift_reg[95:64] ← shift_reg[127:96]
    shift_reg[127:96] ← s_axis_tdata
    chunk_in_row ← chunk_in_row + 1
    beat_count ← beat_count + 1
    if (chunk_in_row == 3):  // 4th chunk → 整行
      wsram_wr_en ← 1 (1拍脉冲)
      wsram_wr_row_data ← {s_axis_tdata, shift_reg[95:0]}
      wsram_wr_row ← row_counter[3:0]
      wsram_wr_tile_idx ← tile_counter
      chunk_in_row ← 0
      row_counter ← row_counter + 1
      if (row_counter == 15):  // 整 tile 写完
        tile_counter ← tile_counter + 1
    if (beat_count == cfg_len - 1):
      if (s_axis_tlast) → state = DONE_PULSE
      else              → state = ERROR (overflow)
    else:
      if (s_axis_tlast) → state = ERROR (underflow)

RECV_INPUT:  // 类似，每 4 拍组成一个 128-bit input tile
RECV_BIAS:   // 每 1 拍直接写 bsram

DONE_PULSE:
  done ← 1 (1拍)
  busy ← 0
  state ← IDLE

ERROR:
  overflow / underflow ← 1 (sticky until soft reset)
  busy ← 0
  忽略后续输入直到 soft reset
```

### 3.3 cfg_start 触发方式（设计选择）

**方案 A（推荐）**：写 `CSR_STREAM_LEN` 自动启动。原子化，避免 PS 写两次 CSR 之间的竞态。
**方案 B**：单独 `CSR_STREAM_CTRL[0]=1` 写脉冲。明确，可调试性更好。

**采纳方案 A**。理由：Python 端必须先写 LEN 再发 DMA `transfer()`，sink 在 LEN 写入瞬间就该 ready。少一个 CSR 写也少一次 1.5 µs 开销 × 15 次/img = 22 µs 节省（小但白送的）。

### 3.4 反压策略

`s_axis_tready` **恒为 1**。理由：

- BRAM 写是 1 cycle 完成的，sink 内部不需要排队
- 唯一可能的反压源是 `chunk_in_row == 3` 时同时来 commit + 收下一拍数据 → 通过 1 级寄存器流水化即可避免
- DMA 端能产生反压（DDR busy / SmartConnect 仲裁），但反压沿向 PS 而非沿向 sink

这样设计的代价：sink 永远不能"暂停" PS 端流量。但因为流量都是预算内的，无需暂停。

### 3.5 tlast / cfg_len 交叉校验

- 计数器：`beat_count` 每拍 `tvalid && tready` 时 +1
- 退出条件优先级：
  1. `beat_count == cfg_len` 且 `tlast=1` → 正常结束 → DONE
  2. `beat_count == cfg_len` 且 `tlast=0` → 软件 LEN 配少了 / DMA 配多了 → OVERFLOW，halt
  3. `beat_count < cfg_len` 且 `tlast=1` → DMA 配少了 / 软件 LEN 配多了 → UNDERFLOW，halt
- `OVERFLOW / UNDERFLOW` 是 sticky 的，写 `CSR_STREAM_STATUS[2/3]=1` 清除（或 soft reset）

---

## 4. 文件改动清单

### 4.1 新增

| 文件 | 行数估计 | 说明 |
|---|---|---|
| `hw/rtl/axi/cim_axi_stream_sink.sv` | ~250 | §3 规范的实现 |
| `hw/rtl/cim_top.sv` | ~200 | 顶层 wrapper, 实例化 lite_slave + stream_sink + MUX |
| `hw/tb/tb_cim_stream_sink.sv` | ~150 | SV stream master BFM + 与 legacy 比对 |
| `hw/scripts/run_tb_cim_stream_sink.sh` | ~30 | VCS 运行脚本 |
| `docs/c3_dma_design.md` | 本文 | |

### 4.2 修改

| 文件 | 修改要点 |
|---|---|
| `hw/rtl/pkg/cim_pkg.sv` | 新增 `CSR_STREAM_DEST=14'h050`, `CSR_STREAM_LEN=14'h054`, `CSR_STREAM_STATUS=14'h058`；新增 typedef `stream_dest_t` |
| `hw/rtl/axi/cim_axi_lite_slave.sv` | 新增 CSR 写解码（DEST/LEN/STATUS）；CTRL[3] 寄存；新增端口暴露 `cfg_dest/cfg_len/cfg_start` 给 stream_sink；新增端口接收 `stream_busy/done/overflow/underflow` 写入 STATUS；**legacy staging 逻辑保留不动** |
| `hw/scripts/vivado_build.tcl` | 启用 PS S_AXI_HP0 + M_AXI_GP1；实例化 axi_dma_0 + xlconcat + 第二个 proc_sys_reset；BD 自动布线；assertion 检查 axi_dma 进 .hwh |
| `hw/scripts/vivado_build_55mhz.tcl` | 同步上述改动 |
| `hw/constraints/cim_soc.xdc` | 无需改动（未引入新 IO） |
| `sw/cim_driver.py` | `__init__` 增加 `use_dma=True` 参数；新增 `_stream_load(payload, dest, buf)` 方法；`load_weights/load_input/load_bias` 在 `use_dma` 时走 DMA 路径，否则走原 MMIO 路径 |
| `sw/tests/test_cim_driver_offline.py` | 新增 `test_dma_path_bit_exact` 用例：mock `pynq.lib.dma`，断言 buffer 内容与 legacy MMIO 字序一致 |

### 4.3 不动

- `cim_tile.sv / psum_accum.sv / cim_accel_core.sv`（计算核心）
- `weight_sram.sv / input_buffer.sv / bias_sram.sv / output_buffer.sv`（存储模块的端口规范不变，只是写入信号源换了）
- `golden_model.py`（参考模型与硬件路径无关）
- `cim_axi_lite_slave_wrapper.v`（如果改名为 `cim_top_wrapper.v` 是次要修订）

---

## 5. Vivado Block Design 增量

### 5.1 PS 端口启用

```tcl
set_property -dict [list \
    CONFIG.PCW_USE_S_AXI_HP0     {1} \
    CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {64} \
    CONFIG.PCW_USE_M_AXI_GP1     {1} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {1} \
    CONFIG.PCW_IRQ_F2P_INTR      {1} \
] [get_bd_cells ps7]
```

### 5.2 axi_dma 实例化

```tcl
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_0
set_property -dict [list \
    CONFIG.c_include_sg          {0}  \
    CONFIG.c_include_s2mm        {0}  \
    CONFIG.c_sg_include_stscntrl_strm {0} \
    CONFIG.c_m_axi_mm2s_data_width {64} \
    CONFIG.c_m_axis_mm2s_tdata_width {32} \
    CONFIG.c_mm2s_burst_size     {16} \
] [get_bd_cells axi_dma_0]
```

关键参数解释：
- `c_include_sg=0`：用 Direct Register 模式（每次只发一个描述符），软件简单。
- `c_include_s2mm=0`：只需要 MM2S 方向（DDR→PL），结果回读用 CSR_LOGIT_BASE 即可（128 字节，不值得走 DMA）。
- `c_m_axi_mm2s_data_width=64`：与 HP 端口宽度匹配，避免 SmartConnect 自动加 width converter。
- `c_m_axis_mm2s_tdata_width=32`：与 sink 端宽度匹配，DMA 内部做 64→32 dwidth 转换（PG021 §3.1.1 "Data Realignment"，免费）。
- `c_mm2s_burst_size=16`：单次 burst 16 beats × 8 bytes = 128 bytes，匹配 DDR3 行大小。

### 5.3 互联

```tcl
# CSR 总线: PS GP0 → CIM (cim_top)，PS GP1 → axi_dma_0
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config [list Master /ps7/M_AXI_GP0 Slave /cim_top_0/S_AXI_LITE \
             intc_ip {New AXI Interconnect} Clk_xbar Auto Clk_master Auto Clk_slave Auto] \
    [get_bd_intf_pins cim_top_0/S_AXI_LITE]

apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config [list Master /ps7/M_AXI_GP1 Slave /axi_dma_0/S_AXI_LITE \
             intc_ip {Auto} Clk_xbar Auto Clk_master Auto Clk_slave Auto] \
    [get_bd_intf_pins axi_dma_0/S_AXI_LITE]

# 数据总线: axi_dma → PS HP0
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config [list Master /axi_dma_0/M_AXI_MM2S Slave /ps7/S_AXI_HP0 \
             intc_ip {New AXI Interconnect} Clk_xbar Auto Clk_master Auto Clk_slave Auto] \
    [get_bd_intf_pins ps7/S_AXI_HP0]

# AXIS 直连: axi_dma → cim_top
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S] \
                    [get_bd_intf_pins cim_top_0/S_AXIS_DATA]

# 中断合并
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 xlconcat_0
set_property CONFIG.NUM_PORTS {2} [get_bd_cells xlconcat_0]
connect_bd_net [get_bd_pins cim_top_0/irq_done]      [get_bd_pins xlconcat_0/In0]
connect_bd_net [get_bd_pins axi_dma_0/mm2s_introut] [get_bd_pins xlconcat_0/In1]
connect_bd_net [get_bd_pins xlconcat_0/dout]         [get_bd_pins ps7/IRQ_F2P]

# 第二个 proc_sys_reset (DMA 专用，不受 CSR_CTRL[2] 影响)
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 psr_dma
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins psr_dma/ext_reset_in]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0]     [get_bd_pins psr_dma/slowest_sync_clk]
# 把 axi_dma 的 reset 改接到 psr_dma 而非默认的 psr_0
disconnect_bd_net /psr_0_peripheral_aresetn [get_bd_pins axi_dma_0/axi_resetn]
connect_bd_net [get_bd_pins psr_dma/peripheral_aresetn] [get_bd_pins axi_dma_0/axi_resetn]
```

### 5.4 地址分配

```tcl
assign_bd_address -offset 0x40000000 -range 16K \
    [get_bd_addr_segs {cim_top_0/S_AXI_LITE/reg0}]
assign_bd_address -offset 0x40400000 -range 64K \
    [get_bd_addr_segs {axi_dma_0/S_AXI_LITE/Reg}]
assign_bd_address -offset 0x00000000 -range 512M \
    [get_bd_addr_segs {ps7/S_AXI_HP0/HP0_DDR_LOWOCM}]
```

### 5.5 .hwh 完整性检查（构建末尾）

```tcl
set addr_segs [get_bd_addr_segs */axi_dma_0/*]
if {[llength $addr_segs] < 2} {
    puts "ERROR: axi_dma_0 not fully exposed in address map. Aborting."
    exit 1
}
puts "INFO: axi_dma_0 address segments: $addr_segs"
```

---

## 6. 软件驱动改动 (sw/cim_driver.py)

### 6.1 类初始化

```python
class CIMDriver:
    def __init__(self, bitstream_path="cim_soc.bit", load=True,
                 use_dma=True, max_w_chunks=20000):
        if not _HAS_PYNQ:
            raise RuntimeError("pynq not available")
        if load:
            self.overlay = Overlay(bitstream_path)
        self.mmio = MMIO(_BASE, _MMIO_SIZE)
        self.use_dma = use_dma
        if use_dma:
            try:
                self.dma = self.overlay.axi_dma_0
            except AttributeError:
                raise RuntimeError(
                    "Bitstream does not expose axi_dma_0; "
                    "rebuild with vivado_build.sh after C3 BD update."
                )
            from pynq import allocate
            self._buf_w = allocate(shape=(max_w_chunks,), dtype=np.uint32)
            self._buf_x = allocate(shape=(MAX_IN_DIM // 4 + 4,), dtype=np.uint32)
            self._buf_b = allocate(shape=(MAX_OUT_DIM,), dtype=np.uint32)
            self.mmio.write(_CTRL, 0x8)  # CSR_CTRL[3]=1: stream path
        self.soft_reset()
```

### 6.2 `_stream_load` 通用方法

```python
    _DEST_WEIGHT, _DEST_INPUT, _DEST_BIAS = 0, 1, 2

    def _stream_load(self, words, dest, buf):
        """Push `words` (iterable of uint32) to the stream sink at `dest`.
        Synchronous: blocks until DMA + sink both report done.
        """
        n = len(words)
        if n > len(buf):
            raise ValueError(f"{n} words exceeds buffer cap {len(buf)}")
        buf[:n] = np.asarray(words, dtype=np.uint32)
        self.mmio.write(_CSR_STREAM_DEST, dest)
        self.mmio.write(_CSR_STREAM_LEN, n)   # 写 LEN 即 cfg_start (设计选择 §3.3)
        self.dma.sendchannel.transfer(buf[:n])
        self.dma.sendchannel.wait()
        # 二次校验 (可选, 调试用)
        status = self.mmio.read(_CSR_STREAM_STATUS)
        if status & 0x4:
            raise RuntimeError(f"stream sink overflow, status=0x{status:08x}")
        if status & 0x8:
            raise RuntimeError(f"stream sink underflow, status=0x{status:08x}")
```

### 6.3 三个 load 函数改写

```python
    def load_weights(self, chunks):
        if self.use_dma:
            self._stream_load(chunks, self._DEST_WEIGHT, self._buf_w)
        else:
            self._load_weights_legacy(chunks)  # 原 MMIO 循环

    def load_input(self, data_u8):
        if self.use_dma:
            # 先按 16 字节对齐, 再打包成 uint32
            padded = np.pad(np.asarray(data_u8, dtype=np.uint8),
                            (0, (-len(data_u8)) % 16))
            words = np.frombuffer(padded.tobytes(), dtype=np.uint32)
            self._stream_load(words.tolist(), self._DEST_INPUT, self._buf_x)
        else:
            self._load_input_legacy(data_u8)

    def load_bias(self, bias_u32):
        if self.use_dma:
            self._stream_load(bias_u32, self._DEST_BIAS, self._buf_b)
        else:
            self._load_bias_legacy(bias_u32)
```

### 6.4 `__init__` 之后任何时刻可切换路径

```python
drv.use_dma = False
drv.mmio.write(_CTRL, 0x0)   # CSR_CTRL[3]=0: legacy path
# 此时所有 load_* 走 MMIO，方便 A/B 对比 / 回归隔离
```

---

## 7. 验证策略

### 7.1 RTL 单元测试 (`tb_cim_stream_sink.sv`)

```systemverilog
// SV BFM: 简单的 stream master
task automatic axis_send(input logic [31:0] data, input logic last);
    @(posedge clk);
    s_axis_tdata  <= data;
    s_axis_tvalid <= 1'b1;
    s_axis_tlast  <= last;
    do @(posedge clk); while (!s_axis_tready);
    s_axis_tvalid <= 1'b0;
    s_axis_tlast  <= 1'b0;
endtask

initial begin
    // 1. 准备 reference: 一个 tile 的 64 个 32-bit 字
    logic [31:0] ref_words [64];
    for (int i = 0; i < 64; i++) ref_words[i] = $urandom;

    // 2. 配置 sink 为 weight 模式, len=64
    cfg_dest <= 2'd0;
    cfg_len  <= 16'd64;
    @(posedge clk); cfg_start <= 1; @(posedge clk); cfg_start <= 0;

    // 3. 喂数据
    for (int i = 0; i < 64; i++) axis_send(ref_words[i], i == 63);

    // 4. 等 done
    wait(done);

    // 5. 检查 weight_sram 内容 (通过 hierarchical reference)
    for (int row = 0; row < 16; row++) begin
        logic [127:0] expected;
        for (int chunk = 0; chunk < 4; chunk++)
            expected[chunk*32 +: 32] = ref_words[row*4 + chunk];
        assert (dut.u_wsram.GEN_BANK[row].bank_mem[0] == expected)
            else $fatal("row %0d mismatch", row);
    end

    $display("PASS");
end
```

### 7.2 端到端回归 (`tb_mnist_e2e.sv`)

新增 `+define+USE_STREAM_PATH`，构建时打开后 weight 通过 stream BFM 加载，其余流程不变。期望最终 logits / argmax 与 legacy 路径完全一致。

### 7.3 软件离线测试 (`test_cim_driver_offline.py`)

```python
def test_dma_path_bit_exact(monkeypatch, lenet5_model):
    """Verify that DMA path produces same SRAM-bound byte sequence as MMIO path."""

    # 1. Capture legacy MMIO sequence
    legacy_writes = []
    drv_legacy = MockCIMDriver(use_dma=False)
    monkeypatch.setattr(drv_legacy.mmio, "write",
                        lambda a, d: legacy_writes.append((a, d)))
    drv_legacy.load_weights(lenet5_model.layers[0]["w_chunks"])

    # 2. Capture DMA buffer
    dma_buf = []
    drv_dma = MockCIMDriver(use_dma=True)
    monkeypatch.setattr(drv_dma.dma.sendchannel, "transfer",
                        lambda buf: dma_buf.extend(buf.tolist()))
    monkeypatch.setattr(drv_dma.dma.sendchannel, "wait", lambda: None)
    drv_dma.load_weights(lenet5_model.layers[0]["w_chunks"])

    # 3. Reduce legacy writes to just the WDMA_DATA values
    legacy_words = [d for a, d in legacy_writes if a == _CSR_WDMA_DATA]

    assert dma_buf == legacy_words, "DMA buffer differs from MMIO word sequence"
```

### 7.4 上板验收（commit 6 提交前必须满足）

| 指标 | 当前 (60 MHz, MMIO) | 目标 (60 MHz, DMA) |
|---|---|---|
| LeNet-5 200 张 accuracy | 99.5% (199/200) | **必须 = 99.5% bit-exact** |
| LeNet-5 wall time | 325.1 s | ≤ 5 s （65× 安全边际） |
| LeNet-5 ms/img | 1625 ms | **≤ 25 ms** （目标 ≈ 6 ms） |
| A2 profiler `load_w_ms` 占比 | ~40% | **< 5%** |
| pytest sw/tests/ | 16/16 PASS | 16/16 + 新增 1 个用例全 PASS |

不满足任一条 → 不合并 commit 6，回滚到 commit 5（仍是 use_dma=False 默认）。

---

## 8. 风险登记

| # | 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|---|
| 1 | sink 在 BRAM commit 时与下一拍数据冲突 | 低 | 中 | `chunk_in_row==3` 时同时拉 `wsram_wr_en` 和接受新数据，1 cycle 内 BRAM 写 + 寄存器更新可并行；TB §7.1 反复验证 |
| 2 | `.hwh` 缺 axi_dma 段，`Overlay.axi_dma_0` 找不到 | 中 | 高 | 构建 TCL §5.5 末尾 assertion；驱动 §6.1 try/except 抛清晰错误 |
| 3 | CMA OOM 在低内存系统启动 | 极低 | 高 | __init__ pre-allocate, fail fast；80 KB << 128 MB 默认池 |
| 4 | 用户在 `transfer()` 后、`wait()` 前修改 buffer | 低 | 中 | docstring 警告；可选：内部 `np.copy()` 防御性拷贝（增加 ~50 µs/层 = 250 µs/img，仍可接受） |
| 5 | axi_dma + Interconnect 引入时序退化 | 低 | 高 | Phase 4 构建后强制检查 WNS ≥ 0；如失败先尝试 `axis_register_slice` 隔离，再考虑降频 |
| 6 | `soft_reset` (CSR_CTRL[2]) 与 in-flight DMA 竞态 | 中 | 中 | 两个独立 proc_sys_reset (BD §5.3)；驱动 `soft_reset()` 内部加 `dma.sendchannel.wait()` 兜底 |
| 7 | dual-path 共存导致 LUT 超预算 | 低 | 中 | 当前 11k LUT (20%)，预算 14k；stream sink ~250 LUT + 保留 legacy ~800 LUT = +1050 LUT，仍在预算内 |

---

## 9. Commit 推进计划

| # | 标题 | 文件 | 验证步骤 | 是否回退点 |
|---|---|---|---|---|
| 1 | feat(rtl): add cim_axi_stream_sink + standalone TB | 新增 sink.sv, tb_sink.sv, run_tb_sink.sh | `bash hw/scripts/run_tb_cim_stream_sink.sh` GREEN | 否 |
| 2 | feat(rtl): add CSR_STREAM_* + CTRL[3] gate to lite slave | cim_pkg.sv (+地址), cim_axi_lite_slave.sv (+解码) | `bash hw/scripts/run_regression.sh` 全 GREEN（CTRL[3]=0 默认 legacy） | 否 |
| 3 | feat(rtl): add cim_top wrapper with sink + lite-slave MUX | 新增 cim_top.sv | `bash hw/scripts/run_regression.sh` GREEN | 否 |
| 4 | **feat(bd): integrate axi_dma + S_AXI_HP0 + xlconcat** | vivado_build.tcl, vivado_build_55mhz.tcl | `bash hw/scripts/vivado_build.sh` 出 .bit + .hwh; .hwh 含 axi_dma; WNS ≥ 0 | **是 — git tag pre-c3-bd** |
| 5 | feat(sw): add DMA path behind use_dma flag | sw/cim_driver.py (+_stream_load), sw/tests/test_cim_driver_offline.py (+1 用例) | `pytest sw/tests/ -v` 17 PASS | 否 |
| 6 | feat: enable DMA path by default + benchmark + paper | sw/cim_driver.py (默认 True), sw/scripts/benchmark_e2e.py 新出 csv, paper §5.x | LeNet-5 200 张 99.5% acc, ≤25 ms/img, profiler load_w_ms <5% | 否 |
| 7 (后续) | refactor(rtl): remove legacy MMIO weight/input/bias path | cim_axi_lite_slave.sv (~-800 行), cim_pkg.sv (移除 WDMA/MEM_INPUT/MEM_BIAS) | 全部 TB + pytest GREEN; 资源报告 LUT 减少约 800 | 否（commit 6 通过 1 周后） |

---

## 10. 待确认事项（需作者输入）

1. **PYNQ 镜像版本**：v2.7 (Ubuntu 20.04) 还是 v3.0 (Ubuntu 22.04)？影响 `pynq.allocate` API 调用方式与是否使用 `xlnk`。
2. **Vivado 版本**：现有 build 在哪个版本？axi_dma 7.1 兼容 2018.1+，但 `apply_bd_automation` 在 2020.x 有 signature 变化。
3. **Phase 4 git tag 策略**：commit 4 前是否打 `pre-c3-bd` tag？建议是。
4. **论文 §5.x 节安排**：先占位（placeholder benchmarks）然后 Phase 6 填实数，还是 Phase 6 一次性写完？影响是否需要先在 `Thesis/middle/paper/fig/` 占位空图。
5. **是否一并升级到 64-bit AXIS**：本设计采纳 32-bit AXIS（与现有 `weight_to_chunks` 兼容），但若作者愿意改 Python 端 packing，64-bit 可省 ~30% 拍数。当前判断：不值。

---

## 11. 参考文献

- Xilinx UG585 — Zynq-7000 SoC Technical Reference Manual, §22 (PS-PL Interfaces)
- Xilinx PG021 — AXI DMA v7.1 LogiCORE IP Product Guide
- Xilinx PG059 — AXI Interconnect v2.1 Product Guide
- Xilinx PG085 — AXI4-Stream Infrastructure IP Suite Product Guide
- Xilinx XAPP1170 — A Zynq Accelerator for Floating Point Matrix Multiplication (DMA reference design pattern)
- T. Moreau et al., "VTA: An Open Hardware-Software Stack for Deep Learning," ArXiv:1807.04188, 2018
- Y. Umuroglu et al., "FINN: A Framework for Fast, Scalable Binarized Neural Network Inference," FPGA 2017
- PYNQ documentation — `pynq.lib.dma.DMA`, `pynq.allocate`
