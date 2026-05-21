#!/bin/bash
# ============================================================================
# vivado_build.sh — ARM-direct CIM SoC bitstream for MZU15B (XCZU15EG)
# ============================================================================
# Usage: cd <project_root> && bash hw/scripts/vivado_build.sh
#
# Architecture:
#   PS (A53) → M_AXI_GP0 → CIM CSR + DMA CSR
#            ← S_AXI_HP0_FPD ← DMA MM2S
#            ← S_AXI_HP1_FPD ← DMA S2MM
#
# Output:
#   vivado_proj/deploy/cim_soc_mzu15b.bit
#   vivado_proj/deploy/cim_soc_mzu15b.hwh
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "============================================================"
echo "CIM SoC — MZU15B ARM-direct Build"
echo "  Project root: ${PROJECT_ROOT}"
echo "============================================================"

# Find vivado
if command -v vivado &>/dev/null; then
    VIVADO_BIN="vivado"
elif [ -f "/tools/Xilinx/Vivado/2022.2/bin/vivado" ]; then
    VIVADO_BIN="/tools/Xilinx/Vivado/2022.2/bin/vivado"
elif [ -f "/opt/Xilinx/Vivado/2022.2/bin/vivado" ]; then
    VIVADO_BIN="/opt/Xilinx/Vivado/2022.2/bin/vivado"
else
    echo "ERROR: vivado not found. Source settings64.sh or add Vivado to PATH."
    echo "  Example: source /tools/Xilinx/Vivado/2022.2/settings64.sh"
    exit 1
fi

echo "  Vivado: $(${VIVADO_BIN} -version 2>/dev/null | head -1 || echo ${VIVADO_BIN})"

cd "${PROJECT_ROOT}"

rm -rf vivado_proj .Xil
mkdir -p vivado_proj

${VIVADO_BIN} -mode batch \
    -source hw/scripts/vivado_build.tcl \
    -log vivado_proj/vivado_build.log \
    -journal vivado_proj/vivado_build.jou
BUILD_STATUS=$?

if [ $BUILD_STATUS -ne 0 ]; then
    echo ""
    echo "============================================================"
    echo "Build FAILED (exit code ${BUILD_STATUS})"
    echo "Check vivado_proj/vivado_build.log for details."
    echo "============================================================"
    exit $BUILD_STATUS
fi

echo ""
echo "============================================================"
echo "Build finished."
echo "  Bitstream: vivado_proj/deploy/cim_soc_mzu15b.bit"
echo "============================================================"
