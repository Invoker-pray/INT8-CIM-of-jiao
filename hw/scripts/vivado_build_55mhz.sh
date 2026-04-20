#!/bin/bash
# ============================================================================
# vivado_build_55mhz.sh — Build CIM SoC bitstream at 55 MHz (timing clean)
# ============================================================================
# Usage: cd <project_root> && bash hw/scripts/vivado_build_55mhz.sh
#
# Output:
#   vivado_proj_55mhz/pynq_deploy/cim_soc_55mhz.bit
#   vivado_proj_55mhz/pynq_deploy/cim_soc_55mhz.hwh
#
# Why 55 MHz:
#   The 60 MHz build has WNS = -0.086 ns (3 failing endpoints in CIM Tile
#   MAC chain). At 55 MHz the same path has ~1.5 ns slack. Inference latency
#   increases by ~9% (54.7 μs → 59.7 μs for MLP), which is negligible.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "============================================================"
echo "CIM SoC — Vivado Build (55 MHz, timing clean)"
echo "  Project root: ${PROJECT_ROOT}"
echo "============================================================"

if command -v vivado &>/dev/null; then
    VIVADO_BIN="vivado"
elif [ -f "/tools/Xilinx/Vivado/2022.2/bin/vivado" ]; then
    VIVADO_BIN="/tools/Xilinx/Vivado/2022.2/bin/vivado"
elif [ -f "/opt/Xilinx/Vivado/2022.2/bin/vivado" ]; then
    VIVADO_BIN="/opt/Xilinx/Vivado/2022.2/bin/vivado"
else
    echo "ERROR: vivado not found. Source settings64.sh or add Vivado to PATH."
    exit 1
fi

echo "  Vivado: $(${VIVADO_BIN} -version 2>/dev/null | head -1 || echo ${VIVADO_BIN})"

cd "${PROJECT_ROOT}"

# --- PAR_OB must be 1 for synthesis (PAR_OB=4 is simulation-only) ---
CURRENT_PAR=$(grep "parameter int PAR_OB = " hw/rtl/pkg/cim_pkg.sv | head -1)
if echo "$CURRENT_PAR" | grep -q "PAR_OB = 1"; then
	echo "  PAR_OB already = 1 (OK for synthesis)"
	NEEDS_RESTORE=0
elif echo "$CURRENT_PAR" | grep -q "PAR_OB = 4"; then
	echo "  PAR_OB = 4, changing to 1 for synthesis..."
	sed -i 's/parameter int PAR_OB = 4;/parameter int PAR_OB = 1;/' hw/rtl/pkg/cim_pkg.sv
	NEEDS_RESTORE=1
else
	echo "  WARNING: PAR_OB = $CURRENT_PAR (unexpected)"
	NEEDS_RESTORE=0
fi

rm -rf vivado_proj_55mhz .Xil

${VIVADO_BIN} -mode batch \
    -source hw/scripts/vivado_build_55mhz.tcl \
    -log vivado_proj_55mhz/vivado_build.log \
    -journal vivado_proj_55mhz/vivado_build.jou
BUILD_STATUS=$?

# --- Restore PAR_OB for simulation (only if we changed it) ---
if [ "$NEEDS_RESTORE" = "1" ]; then
	sed -i 's/parameter int PAR_OB = 1;/parameter int PAR_OB = 4;/' hw/rtl/pkg/cim_pkg.sv
fi

if [ $BUILD_STATUS -ne 0 ]; then
	echo ""
	echo "============================================================"
	echo "Build FAILED (exit code ${BUILD_STATUS})"
	echo "PAR_OB has been restored. Check logs above."
	echo "============================================================"
	exit $BUILD_STATUS
fi

echo ""
echo "============================================================"
echo "Build finished. Check vivado_proj_55mhz/vivado_build.log"
echo "Deploy files: vivado_proj_55mhz/pynq_deploy/"
echo "============================================================"
