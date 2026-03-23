#!/bin/bash
# ============================================================================
# run_tb_rv32.sh — Simulate PicoRV32 + CIM SoC testbench
# ============================================================================
# Prerequisites:
#   1. VCS or another SystemVerilog simulator
#   2. firmware.hex in current directory (from fw/Makefile)
#   3. picorv32.v downloaded from GitHub
#
# Usage:
#   cd hw/
#   bash scripts/run_tb_rv32.sh
# ============================================================================

set -e

# Paths (relative to hw/tb/)
RTL_DIR="../../../hw/rtl"
RV_DIR="../rtl/riscv"
TB="../tb/tb_cim_rv32.sv"
SIM="sim"

mkdir -p sim
cd ${SIM}

# Check firmware.hex exists
if [ ! -f ../tb/firmware.hex ]; then
	echo "ERROR: firmware.hex not found!"
	echo "  Run: cd ../../fw && make && cp firmware.hex ../../hw/tb/"
	exit 1
fi

# Copy firmware.hex to sim directory so $readmemh can find it
cp ../tb/firmware.hex .

# Check picorv32.v exists
if [ ! -f "${RV_DIR}/picorv32.v" ]; then
	echo "ERROR: picorv32.v not found in ${RV_DIR}/"
	echo "  Run: wget -O ${RV_DIR}/picorv32.v https://raw.githubusercontent.com/YosysHQ/picorv32/main/picorv32.v"
	exit 1
fi

echo "=== Compiling PicoRV32 + CIM SoC testbench ==="

# Source list
SRCS=(
	"${RTL_DIR}/pkg/cim_pkg.sv"
	"${RTL_DIR}/core/cim_tile.sv"
	"${RTL_DIR}/core/psum_accum.sv"
	"${RTL_DIR}/mem/weight_sram.sv"
	"${RTL_DIR}/mem/bias_sram.sv"
	"${RTL_DIR}/mem/input_buffer.sv"
	"${RTL_DIR}/mem/output_buffer.sv"
	"${RTL_DIR}/core/cim_accel_core.sv"
	"${RTL_DIR}/axi/cim_axi_lite_slave.sv"
	"${RTL_DIR}/axi/cim_axi_lite_slave_wrapper.v"
	"${RV_DIR}/picorv32.v"
	"${RV_DIR}/uart_tx.sv"
	"${RV_DIR}/picorv32_cim_bridge.sv"
	"${RV_DIR}/cim_rv32_top.sv"
	"${TB}"
)

# VCS compile
vcs -full64 -sverilog -timescale=1ns/1ps \
	+v2k +lint=all,noVCDE \
	-debug_access+all \
	"${SRCS[@]}" \
	-o simv \
	2>&1 | tee compile.log

if [ ! -f simv ]; then
	echo "ERROR: Compilation failed!"
	exit 1
fi

echo ""
echo "=== Running simulation ==="
./simv +VCD 2>&1 | tee sim.log

echo ""
echo "=== Simulation complete ==="
echo "Check sim.log for UART output and test result"
echo "VCD waveform: tb_cim_rv32.vcd"
