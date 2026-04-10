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
- **`axi/`** — AXI4-Lite slave wrapper. CSR address space is 14-bit (16KB).

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
- `cim_driver.py` — PYNQ Python driver (`CIMDriver` low-level MMIO, `CIMModel` high-level multi-layer inference with im2col and SQ-mapping packed MVM).
- Jupyter notebooks (`*_pynq.ipynb`) — On-board verification scripts; `generate_*.ipynb` run on host.

## Key Constraints

- **Max dimensions**: `MAX_IN_DIM=784`, `MAX_OUT_DIM=128` (limited by BRAM on PYNQ-Z2's 630KB). Conv im2col `col_len = C_in × K × K` must not exceed 784.
- **Clock**: 62.5 MHz on PYNQ-Z2 (critical path: `w_tile_reg → DSP48 → CARRY4 → tile_psum_reg`).
- **Weight SRAM**: Split into 16 banks (128-bit each) to enable BRAM inference. Whole-word writes required — bit-select causes Vivado to fall back to registers.
- **Vivado synthesizer limit**: Single variable must be under 1M bits.
- **PAR_OB** must divide `N_OB` of the target layer. Set to 1 for synthesis (area), 4 for simulation.

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
