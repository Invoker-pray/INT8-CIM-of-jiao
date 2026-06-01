#!/bin/bash
# ============================================================================
# run_regression.sh — Run all CIM SoC testbenches, summarize results
# ============================================================================
# Usage: cd hw && bash scripts/run_regression.sh
#
# Runs:
#   1. tb_cim_tile          — CIM tile unit test (103 random vectors)
#   2. tb_cim_accel_core    — System MVM + edge cases (random + boundary)
#   3. tb_cim_stream_sink   — AXI4-Stream sink unit test (8 cases)
#   4. tb_mnist_e2e         — Full MNIST 784→128→10 end-to-end
#
# Output: PASS/FAIL per test + overall summary
# ============================================================================

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HW_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SW_DIR="$(cd "${HW_DIR}/../sw" && pwd)"

PASS_COUNT=0
FAIL_COUNT=0
RESULTS=()

run_test() {
	local name=$1
	local script=$2

	echo ""
	echo "============================================================"
	echo "  Running: ${name}"
	echo "============================================================"

	if bash "${script}" 2>&1; then
		RESULTS+=("  PASS  ${name}")
		((PASS_COUNT++))
	else
		RESULTS+=("  FAIL  ${name}")
		((FAIL_COUNT++))
	fi
}

echo "============================================================"
echo "CIM SoC — Regression Test Suite"
echo "  Date: $(date)"
echo "  HW dir: ${HW_DIR}"
echo "============================================================"

# --- Ensure mnist e2e golden data exists ---
E2E_DATA="${HW_DIR}/sim/tb_mnist_e2e/data_e2e"
if [ ! -d "${E2E_DATA}" ]; then
	echo "Generating MNIST E2E golden data..."
	cd "${SW_DIR}"
	python3 golden_model.py --mnist-e2e --output-dir "${E2E_DATA}"
	cd "${HW_DIR}"
fi

# --- Run tests ---
run_test "tb_cim_tile" "${SCRIPT_DIR}/run_tb_cim_tile.sh"
run_test "tb_cim_accel_core" "${SCRIPT_DIR}/run_tb_cim_accel_core.sh"
run_test "tb_cim_stream_sink" "${SCRIPT_DIR}/run_tb_cim_stream_sink.sh"
run_test "tb_mnist_e2e" "${SCRIPT_DIR}/run_tb_mnist_e2e.sh"

# --- Summary ---
echo ""
echo "============================================================"
echo "  REGRESSION SUMMARY"
echo "============================================================"
for r in "${RESULTS[@]}"; do
	echo "$r"
done
echo "------------------------------------------------------------"
echo "  Total: $((PASS_COUNT + FAIL_COUNT)) tests"
echo "  PASS:  ${PASS_COUNT}"
echo "  FAIL:  ${FAIL_COUNT}"
echo "============================================================"

if [ ${FAIL_COUNT} -gt 0 ]; then
	echo ">>> REGRESSION FAILED <<<"
	exit 1
else
	echo ">>> ALL REGRESSION TESTS PASSED <<<"
	exit 0
fi
