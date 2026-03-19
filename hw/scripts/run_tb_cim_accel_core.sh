#!/bin/bash
# ============================================================================
# run_tb_cim_accel_core.sh — VCS simulation for full CIM accelerator test
# ============================================================================
# Usage: cd hw && bash scripts/run_tb_cim_accel_core.sh
# ============================================================================

set -e

TB_NAME="tb_cim_accel_core"
SIM_DIR="sim/${TB_NAME}"
mkdir -p "${SIM_DIR}"

RTL_FILES=(
    rtl/pkg/cim_pkg.sv
    rtl/core/cim_tile.sv
    rtl/core/psum_accum.sv
    rtl/core/activation_unit.sv
    rtl/mem/weight_sram.sv
    rtl/mem/bias_sram.sv
    rtl/mem/input_buffer.sv
    rtl/mem/output_buffer.sv
    rtl/core/cim_accel_core.sv
    tb/${TB_NAME}.sv
)

echo "============================================================"
echo "Compiling ${TB_NAME} with VCS..."
echo "============================================================"

cd "${SIM_DIR}"

vcs -full64 -sverilog -debug_access+all \
    -timescale=1ns/1ps \
    +define+VCS \
    -l compile.log \
    "${RTL_FILES[@]/#/../../}" \
    -o simv

echo "============================================================"
echo "Running simulation..."
echo "============================================================"

./simv -l sim.log +fsdbfile+${TB_NAME}.fsdb

echo "============================================================"
echo "Done. Check sim.log for PASS/FAIL."
echo "Open waveform:  verdi -ssf ${TB_NAME}.fsdb &"
echo "============================================================"
