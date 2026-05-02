# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

INT8 Compute-in-Memory (CIM) SoC verification platform targeting PYNQ-Z2 (Zynq-7020) and Kria KV260. Supports INT8 quantized inference for MLP/CNN networks. Hardware computes MVM (matrix-vector multiply) + bias + ReLU + requantize; software handles im2col for Conv layers (heterogeneous approach — no Conv-specific hardware).

Two control modes: (1) ARM PS via Python/MMIO, (2) PicoRV32 RISC-V soft-core replacing ARM for pure-PL autonomous inference.

## Build & Simulation Commands

### RTL Simulation (VCS)

All simulation scripts assume `cd hw` first:

```bash
# Single testbench
cd hw && bash scripts/run_tb_cim_tile.sh          # CIM tile unit test (103 random vectors)
cd hw && bash scripts/run_tb_cim_accel_core.sh     # System MVM + edge/boundary tests
cd hw && bash scripts/run_tb_mnist_e2e.sh          # Full MNIST 784→128→10 end-to-end

# Full regression (runs all 3 above + generates golden data if missing)
cd hw && bash scripts/run_regression.sh
```

### PicoRV32 Simulation

```bash
cd picorv32/hw/tb
cp ../../fw/firmware.hex .
bash ../scripts/run_tb_rv32.sh
```

### Vivado Bitstream Build

```bash
# PYNQ-Z2 (from project root)
bash hw/scripts/vivado_build.sh          # outputs vivado_proj/pynq_deploy/{cim_soc.bit,.hwh}

# PicoRV32 variant
bash picorv32/hw/scripts/vivado_build.sh

# KV260
bash kv260/hw/scripts/vivado_build.sh
```

Note: `vivado_build.sh` temporarily patches `PAR_OB=1` in `cim_pkg.sv` for synthesis (PYNQ-Z2 area constraint) and restores `PAR_OB=4` after.

### Python Environment (sw/)

```bash
cd sw
rye pin 3.13 && rye sync    # or: bash scripts/set_up.sh
# or: pip install per pyproject.toml (torch, torchvision, jupyter, pyserial)
```

### Golden Model

```bash
cd sw && python3 golden_model.py --mnist-e2e --output-dir <dir>   # generate hex test data for e2e TB
```

## Architecture

### Hardware (`hw/rtl/`)

- **`pkg/cim_pkg.sv`** — Single source of truth for all parameters: tile geometry (16×16), parallelism (`PAR_OB`), data widths (INT8/INT32), CSR address map, FSM states, requantize function. No magic numbers in RTL modules.
- **`core/`** — `cim_tile.sv` (16×16 MAC, combinational) → `psum_accum.sv` (partial-sum accumulator) → `cim_accel_core.sv` (main FSM engine, configurable parallelism, multi-stage pipeline, performance counters). One unified engine handles arbitrary layers via CSR configuration.
- **`mem/`** — `weight_sram.sv` (16 independent banks for BRAM inference, AXI DMA-style 32-bit chunk writes), `bias_sram.sv`, `input_buffer.sv` (with zero-point subtraction), `output_buffer.sv` (with argmax).
- **`axi/`** + **`cim_top.sv`** — AXI4-Lite slave (CSR + legacy MMIO staging) and cim_axi_stream_sink (AXIS data path) are MUXed inside `cim_axi_lite_slave.sv` on `CSR_CTRL[3]`. `cim_top.sv` wires them together and exposes S_AXI + S_AXIS + irq_done to BD via `cim_top_wrapper.v`. PS data path: S_AXI_HP0 → axi_dma_0 → M_AXIS_MM2S (32-bit) → cim_top/S_AXIS → sink → BRAM; CSR still goes PS M_AXI_GP0 → cim_top/S_AXI. **Spec: `docs/c3_dma_design.md`**. DMA 已实现并 benchmark 完成：200-image LeNet-5 @60MHz → DMA 503.65 ms/img (1.99 fps), MMIO 1690.54 ms/img (0.59 fps), speedup 3.4×。下一步优化见 `OPTIMIZATION_ROADMAP.md`。

### PicoRV32 Integration (`picorv32/hw/rtl/riscv/`)

- `cim_rv32_top.sv` — Top-level: PicoRV32 → `picorv32_cim_bridge.sv` → {FW BRAM, CIM IP (same AXI slave), UART TX, Result BRAM}
- PS provides clock, loads firmware into FW BRAM port B, reads results from Result BRAM port B, controls `cpu_rst_n` via AXI GPIO.
- CIM IP is **unmodified** from the ARM-controlled version.

### Software (`sw/`)

See **`docs/sw_usage.md`** for full file descriptions, CLI usage, and Python API reference. Summary:

- `golden_model.py` — Bit-accurate INT8 reference model; generates hex files for testbenches.
- `golden_model_torch.py` — PyTorch cross-validation.
- `mnist_quantize.py` — Train/quantize/export MLP (784→128→10) for real MNIST testing.
- `lenet5_quantize.py` — Train/quantize/export LeNet-5 with im2col support.
- `model_zoo.py` — Unified multi-model API: `build_model`, `train`, `quantize`, `int8_infer`, `export_hex`.
- **`sw/`** — Python driver + benchmark。`cim_driver.py` 支持 DMA（默认）和 legacy MMIO 两种数据通路。DMA path uses `pynq.allocate` + `pynq.lib.dma.sendchannel.transfer()`; legacy per-word MMIO retained behind `use_dma=False`.
- DMA benchmark 已跑通：LeNet-5 200-image @60MHz: DMA 503.65 ms/img (1.99 fps) vs MMIO 1690.54 ms/img (0.59 fps)，speedup ~3.4×。Accuracy 99.50%。
- benchmark CSV 在 `sw/benchmark_e2e_60mhz_dma.csv` 和 `sw/benchmark_e2e_60mhz_mmio.csv`
- Jupyter notebooks (`*_pynq.ipynb`) — On-board verification scripts; `generate_*.ipynb` run on host.

## Key Constraints

- **Max dimensions**: `MAX_IN_DIM=784`, `MAX_OUT_DIM=128` (limited by BRAM on PYNQ-Z2's 630KB). Conv im2col `col_len = C_in × K × K` must not exceed 784.
- **Clock**: 60 MHz on PYNQ-Z2 (critical path: `w_tile_reg → DSP48 → CARRY4 → tile_psum_reg`).
- **Weight SRAM**: Split into 16 banks (128-bit each) to enable BRAM inference. Whole-word writes required — bit-select causes Vivado to fall back to registers.
- **Vivado synthesizer limit**: Single variable must be under 1M bits.
- **PAR_OB** must divide `N_OB` of the target layer. Set to 1 for synthesis (area), 4 for simulation.
- **Profiled bottleneck**: LeNet-5 DMA 模式下 ~504 ms/image。DMA 已将数据搬运加速 3.4×，当前瓶颈待进一步 profile（compute vs DMA latency 分解）。

## Language

Project documentation and comments are primarily in Chinese. Code identifiers and commit messages use English.

# user's requirement

- Think before acting. Read existing files before writing code.
- Be concise in output but thorough in reasoning.
- Prefer editing over rewriting whole files.
- Do not re-read files you have already read.
- Test your code before declaring done.
- No sycophantic openers or closing fluff.
- Keep solutions simple and direct.

# CLAUDE.md

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.
