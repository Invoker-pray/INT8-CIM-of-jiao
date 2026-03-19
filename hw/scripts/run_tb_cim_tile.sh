#!/bin/bash
# ============================================================================
# run_tb_cim_tile.sh — VCS simulation for CIM tile unit test
# ============================================================================
# Usage: cd hw && bash scripts/run_tb_cim_tile.sh
# Output: sim/tb_cim_tile/
# ============================================================================

set -e

TB_NAME="tb_cim_tile"
SIM_DIR="sim/${TB_NAME}"
mkdir -p "${SIM_DIR}"

RTL_FILES=(
    rtl/pkg/cim_pkg.sv
    rtl/core/cim_tile.sv
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
echo "Done. Logs in ${SIM_DIR}/"
echo "  compile.log  — VCS compilation log"
echo "  sim.log      — simulation output"
echo "  ${TB_NAME}.fsdb — waveform (open with Verdi)"
echo "============================================================"
