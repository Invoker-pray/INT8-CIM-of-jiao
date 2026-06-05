#!/bin/bash
# ============================================================================
# run_tb_mnist_e2e.sh — VCS simulation for MNIST end-to-end 2-layer MLP test
# ============================================================================
# Usage:
#   1. cd sw/ && python golden_model.py --mnist-e2e   (generate hex data)
#   2. cd hw/ && bash scripts/run_tb_mnist_e2e.sh
# ============================================================================

# Unset proxy to prevent VCS hang
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HW_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SW_DIR="$(cd "${HW_DIR}/../sw" && pwd)"

TB_NAME="tb_mnist_e2e"
SIM_DIR="${HW_DIR}/sim/${TB_NAME}"
mkdir -p "${SIM_DIR}"

# ------------------------------------------------------------
# gcc 15+ treats implicit function declarations as a hard error;
# VCS W-2024.09's generated rmapats.c relies on them. Inject a
# wrapper earlier on PATH that re-enables the old warning-only
# behavior. (Local to this script — does not leak to other tools.)
# ------------------------------------------------------------
WRAPPER_DIR="${SIM_DIR}/.gcc_wrapper"
mkdir -p "${WRAPPER_DIR}"
REAL_GCC="$(command -v gcc)"
cat > "${WRAPPER_DIR}/gcc" <<EOF
#!/bin/bash
exec ${REAL_GCC} -Wno-error=implicit-function-declaration "\$@"
EOF
chmod +x "${WRAPPER_DIR}/gcc"
export PATH="${WRAPPER_DIR}:${PATH}"

# ------------------------------------------------------------
# Generate golden data if not present
# ------------------------------------------------------------
if [ ! -d "${SIM_DIR}/data_e2e" ]; then
	echo "Generating golden data with Python..."
	cd "${SW_DIR}"
	python3 golden_model.py --mnist-e2e --output-dir "${SIM_DIR}/data_e2e"
	cd "${HW_DIR}"
fi

# ------------------------------------------------------------
# File list
# ------------------------------------------------------------
RTL_FILES=(
	"${HW_DIR}/rtl/pkg/cim_pkg.sv"
	"${HW_DIR}/rtl/core/cim_tile.sv"
	"${HW_DIR}/rtl/core/psum_accum.sv"
	"${HW_DIR}/rtl/mem/weight_sram.sv"
	"${HW_DIR}/rtl/mem/bias_sram.sv"
	"${HW_DIR}/rtl/mem/input_buffer.sv"
	"${HW_DIR}/rtl/mem/output_buffer.sv"
	"${HW_DIR}/rtl/core/cim_accel_core.sv"
	"${HW_DIR}/tb/${TB_NAME}.sv"
)

echo "============================================================"
echo "Compiling ${TB_NAME} with VCS..."
echo "============================================================"

cd "${SIM_DIR}"

vcs -full64 -sverilog \
	-debug_access+all \
	-timescale=1ns/1ps \
	+define+VCS \
	-assert svaext \
	+lint=TFIPC-L \
	-l compile.log \
	"${RTL_FILES[@]}" \
	-o simv 2>&1 | tee compile_stdout.log

if [ ! -f simv ]; then
	echo "ERROR: Compilation failed."
	exit 1
fi

echo "============================================================"
echo "Running simulation..."
echo "============================================================"

./simv -l sim.log +fsdbfile+"${SIM_DIR}/${TB_NAME}.fsdb" 2>&1 | tee sim_stdout.log

echo "============================================================"
echo "Done."
echo "  Sim log  : ${SIM_DIR}/sim.log"
echo "  Waveform : verdi -ssf ${SIM_DIR}/${TB_NAME}.fsdb &"
echo "============================================================"

if grep -q "SOME TESTS FAILED" "${SIM_DIR}/sim.log" 2>/dev/null; then
	echo "RESULT: FAIL"
	exit 1
else
	echo "RESULT: PASS"
	exit 0
fi
