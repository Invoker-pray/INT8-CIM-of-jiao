#!/bin/bash
# ============================================================================
# run_tb_rv32_batch.sh — Batch-test 20 MNIST images through PicoRV32+CIM SoC
# ============================================================================
# Compiles VCS once, then loops through 20 images:
#   rebuild firmware → swap firmware.hex → re-run simv → parse result
#
# Prerequisites:
#   1. VCS simulator
#   2. RISC-V GCC toolchain (riscv64-elf-gcc or riscv64-unknown-elf-gcc)
#   3. Python 3 with PyTorch + torchvision (for model training)
#   4. picorv32.v in hw/rtl/riscv/
#
# Usage:
#   cd picorv32/
#   bash hw/scripts/run_tb_rv32_batch.sh
#
# Or specify number of images:
#   N_IMAGES=5 bash hw/scripts/run_tb_rv32_batch.sh
# ============================================================================

set -euo pipefail

# ---- Paths (relative to picorv32/) ----
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
FW_DIR="${PROJ_ROOT}/fw"
HW_DIR="${PROJ_ROOT}/hw"
CIM_RTL_DIR="${PROJ_ROOT}/../hw/rtl" # shared CIM IP
RV_RTL_DIR="${HW_DIR}/rtl/riscv"
TB_DIR="${HW_DIR}/tb"
SIM_DIR="${HW_DIR}/sim/batch"

DATA_DIR="small_mlp_data"
N_IMAGES="${N_IMAGES:-20}"

echo "=============================================="
echo " PicoRV32 + CIM SoC — Batch Test (${N_IMAGES} images)"
echo "=============================================="
echo "Project root : ${PROJ_ROOT}"
echo "Firmware dir : ${FW_DIR}"
echo "Sim dir      : ${SIM_DIR}"
echo ""

# ============================================================
# Step 0: Check prerequisites
# ============================================================
check_tool() { command -v "$1" &>/dev/null || {
	echo "ERROR: $1 not found"
	exit 1
}; }
check_tool vcs
check_tool python3

# Check RISC-V GCC — try common prefixes
RV_GCC=""
for prefix in riscv64-elf- riscv64-unknown-elf- riscv32-unknown-elf-; do
	if command -v "${prefix}gcc" &>/dev/null; then
		RV_GCC="${prefix}gcc"
		break
	fi
done
if [ -z "$RV_GCC" ]; then
	echo "ERROR: RISC-V GCC toolchain not found"
	echo "  Install: sudo pacman -S riscv64-elf-gcc  (Arch)"
	echo "       or: sudo apt install gcc-riscv64-unknown-elf  (Debian/Ubuntu)"
	exit 1
fi
echo "RISC-V GCC: ${RV_GCC}"

# Check picorv32.v
if [ ! -f "${RV_RTL_DIR}/picorv32.v" ]; then
	echo "ERROR: picorv32.v not found in ${RV_RTL_DIR}/"
	echo "  Run: wget -O ${RV_RTL_DIR}/picorv32.v \\"
	echo "       https://raw.githubusercontent.com/YosysHQ/picorv32/main/picorv32.v"
	exit 1
fi

# ============================================================
# Step 1: Train model & generate test data (if needed)
# ============================================================
if [ ! -d "${FW_DIR}/${DATA_DIR}" ]; then
	echo ""
	echo "=== Generating ${DATA_DIR} (training small MLP) ==="
	cd "${FW_DIR}"
	python3 small_mlp_quantize.py --output-dir "${DATA_DIR}" --num-test "${N_IMAGES}" --seed 42
fi

# Verify test images exist
for i in $(seq 0 $((N_IMAGES - 1))); do
	img_hex="${FW_DIR}/${DATA_DIR}/test_images/img_$(printf '%04d' $i).hex"
	if [ ! -f "$img_hex" ]; then
		echo "ERROR: ${img_hex} not found"
		echo "  Re-run: cd fw && python3 small_mlp_quantize.py --num-test ${N_IMAGES}"
		exit 1
	fi
done
echo "Test data OK: ${N_IMAGES} images in ${DATA_DIR}"

# ============================================================
# Step 2: Compile VCS (once)
# ============================================================
mkdir -p "${SIM_DIR}"
cd "${SIM_DIR}"

# Build a dummy firmware.hex so VCS compile doesn't warn about missing file
# (actual firmware gets swapped per-image before each run)
echo "00000013" >firmware.hex

echo ""
echo "=== Compiling VCS ==="

SRCS=(
	"${CIM_RTL_DIR}/pkg/cim_pkg.sv"
	"${CIM_RTL_DIR}/core/cim_tile.sv"
	"${CIM_RTL_DIR}/core/psum_accum.sv"
	"${CIM_RTL_DIR}/mem/weight_sram.sv"
	"${CIM_RTL_DIR}/mem/bias_sram.sv"
	"${CIM_RTL_DIR}/mem/input_buffer.sv"
	"${CIM_RTL_DIR}/mem/output_buffer.sv"
	"${CIM_RTL_DIR}/core/cim_accel_core.sv"
	"${CIM_RTL_DIR}/axi/cim_axi_lite_slave.sv"
	"${CIM_RTL_DIR}/axi/cim_axi_lite_slave_wrapper.v"
	"${RV_RTL_DIR}/picorv32.v"
	"${RV_RTL_DIR}/uart_tx.sv"
	"${RV_RTL_DIR}/picorv32_cim_bridge.sv"
	"${RV_RTL_DIR}/cim_rv32_top.sv"
	"${TB_DIR}/tb_cim_rv32.sv"
)

vcs -full64 -sverilog -timescale=1ns/1ps \
	+v2k +lint=all,noVCDE \
	-debug_access+all \
	"${SRCS[@]}" \
	-o simv \
	2>&1 | tee compile.log

if [ ! -f simv ]; then
	echo "ERROR: VCS compilation failed!"
	exit 1
fi
echo "VCS compile OK"

# ============================================================
# Step 3: Loop through images
# ============================================================
echo ""
echo "=== Running ${N_IMAGES} simulations ==="

RESULTS=()
PASS=0
WRONG=0
FAIL=0

# Determine Makefile CROSS prefix (match whatever we found earlier)
CROSS_PREFIX=$(echo "$RV_GCC" | sed 's/gcc$//')

for i in $(seq 0 $((N_IMAGES - 1))); do
	IDX=$(printf '%04d' $i)
	LABEL=$(cat "${FW_DIR}/${DATA_DIR}/test_images/img_${IDX}_label.txt" | tr -d '[:space:]')

	echo ""
	echo "--- Image ${IDX} (label=${LABEL}) ---"

	# Rebuild firmware for this image
	cd "${FW_DIR}"
	make -s clean 2>/dev/null || true
	make -s DATA_DIR="${DATA_DIR}" IMAGE_IDX=$i CROSS="${CROSS_PREFIX}" 2>&1 | tail -2

	# Copy firmware.hex to sim directory
	cp "${FW_DIR}/firmware.hex" "${SIM_DIR}/firmware.hex"

	# Run simulation
	cd "${SIM_DIR}"
	./simv +TIMEOUT=60000 2>&1 | tee "sim_img${IDX}.log" | grep -E "^(Predicted|Expected|>>>|RESULT:)" || true

	# Parse result
	RESULT=$(grep "^RESULT:" "sim_img${IDX}.log" 2>/dev/null | tail -1 | awk '{print $2}')
	if [ -z "$RESULT" ]; then
		RESULT="FAIL"
	fi

	RESULTS+=("${IDX}:${LABEL}:${RESULT}")

	case "$RESULT" in
	PASS) PASS=$((PASS + 1)) ;;
	WRONG) WRONG=$((WRONG + 1)) ;;
	*) FAIL=$((FAIL + 1)) ;;
	esac

	echo "  -> ${RESULT}"
done

# ============================================================
# Step 4: Summary
# ============================================================
echo ""
echo "=============================================="
echo " BATCH TEST SUMMARY"
echo "=============================================="
printf "%-6s %-6s %-10s\n" "Image" "Label" "Result"
printf "%-6s %-6s %-10s\n" "-----" "-----" "----------"

for entry in "${RESULTS[@]}"; do
	IFS=: read -r img lbl res <<<"$entry"
	printf "%-6s %-6s %-10s\n" "$img" "$lbl" "$res"
done

echo "----------------------------------------------"
echo "PASS: ${PASS}/${N_IMAGES}  WRONG: ${WRONG}/${N_IMAGES}  FAIL: ${FAIL}/${N_IMAGES}"
echo ""

if [ "$FAIL" -eq 0 ]; then
	echo "Hardware verification: ALL ${N_IMAGES} images completed successfully."
	echo "Model accuracy: ${PASS}/${N_IMAGES} correct predictions."
	echo ""
	echo "EXIT: SUCCESS"
	exit 0
else
	echo "EXIT: FAILURE (${FAIL} images did not complete)"
	exit 1
fi
