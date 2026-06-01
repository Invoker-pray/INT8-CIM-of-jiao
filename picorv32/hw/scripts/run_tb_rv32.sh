#!/bin/bash
# ============================================================================
# run_tb_rv32.sh — VCS simulate PicoRV32 + CIM SoC (single image)
# ============================================================================
# Usage:
#   cd picorv32/hw/tb
#   cp ../../fw/firmware.hex .
#   bash ../scripts/run_tb_rv32.sh
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PICORV32_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CIM_RTL="${PICORV32_ROOT}/../hw/rtl"
RV_RTL="${PICORV32_ROOT}/hw/rtl/riscv"
TB_DIR="${PICORV32_ROOT}/hw/tb"

cd "${TB_DIR}"

# Check — prefer patched firmware (with embedded test image)
FW_DIR="${PICORV32_ROOT}/fw"
if [ -f firmware.hex.patched ]; then
	echo "Using patched firmware.hex (with embedded test image)"
	cp firmware.hex.patched firmware.hex
elif [ -f firmware.hex ]; then
	echo "Using existing firmware.hex"
elif [ -f "${FW_DIR}/firmware.hex" ]; then
	echo "Using firmware.hex from ${FW_DIR}"
	cp "${FW_DIR}/firmware.hex" .
else
	echo "ERROR: firmware.hex not found. Build firmware first: cd ${FW_DIR} && make DATA_DIR=small_mlp_data IMAGE_IDX=0"
	echo "  Then patch with image: python3 patch_firmware.py firmware.hex small_mlp_data/test_images/img_0000.hex <label>"
	exit 1
fi
[ -f "${RV_RTL}/picorv32.v" ] || {
	echo "ERROR: picorv32.v missing"
	exit 1
}

# ------------------------------------------------------------
# gcc 15+ treats implicit function declarations as a hard error;
# VCS W-2024.09's generated rmapats.c relies on them. Inject a
# wrapper earlier on PATH that re-enables the old warning-only
# behavior. (Local to this script — does not leak to other tools.)
# ------------------------------------------------------------
WRAPPER_DIR="${TB_DIR}/.gcc_wrapper"
mkdir -p "${WRAPPER_DIR}"
REAL_GCC="$(command -v gcc)"
cat > "${WRAPPER_DIR}/gcc" <<EOF
#!/bin/bash
exec ${REAL_GCC} -Wno-error=implicit-function-declaration "\$@"
EOF
chmod +x "${WRAPPER_DIR}/gcc"
export PATH="${WRAPPER_DIR}:${PATH}"

echo "=== Compiling ==="
SRCS=(
	"${CIM_RTL}/pkg/cim_pkg.sv"
	"${CIM_RTL}/core/cim_tile.sv"
	"${CIM_RTL}/core/psum_accum.sv"
	"${CIM_RTL}/mem/weight_sram.sv"
	"${CIM_RTL}/mem/bias_sram.sv"
	"${CIM_RTL}/mem/input_buffer.sv"
	"${CIM_RTL}/mem/output_buffer.sv"
	"${CIM_RTL}/core/cim_accel_core.sv"
	"${CIM_RTL}/axi/cim_axi_lite_slave.sv"
	"${CIM_RTL}/axi/cim_axi_lite_slave_wrapper.v"
	"${CIM_RTL}/axi/cim_axi_stream_sink.sv"
	"${CIM_RTL}/axi/cim_axi_stream_source.sv"
	"${RV_RTL}/picorv32.v"
	"${RV_RTL}/uart_tx.sv"
	"${RV_RTL}/picorv32_cim_bridge.sv"
	"${RV_RTL}/cim_rv32_top.sv"
	"tb_cim_rv32.sv"
)

vcs -full64 -sverilog -timescale=1ns/1ps \
	+v2k +lint=all,noVCDE \
	-debug_access+all \
	"${SRCS[@]}" \
	-o simv 2>&1 | tee compile.log

[ -f simv ] || {
	echo "ERROR: Compilation failed!"
	exit 1
}

echo ""
echo "=== Running simulation ==="
./simv +TIMEOUT=60000 2>&1 | tee sim.log

echo ""
RESULT=$(grep "^RESULT:" sim.log | tail -1 | awk '{print $2}')
echo "=== Result: ${RESULT:-UNKNOWN} ==="
