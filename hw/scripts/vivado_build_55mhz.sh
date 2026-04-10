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

set -e

rm -rf vivado_proj_55mhz .Xil
# PAR_OB must be 1 for PYNQ-Z2 (220 DSP limit)
sed -i 's/parameter int PAR_OB = 4;/parameter int PAR_OB = 1;/' hw/rtl/pkg/cim_pkg.sv

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

${VIVADO_BIN} -mode batch \
    -source hw/scripts/vivado_build_55mhz.tcl \
    -log vivado_proj_55mhz/vivado_build.log \
    -journal vivado_proj_55mhz/vivado_build.jou

echo ""
echo "============================================================"
echo "Build finished. Check vivado_proj_55mhz/vivado_build.log"
echo "Deploy files: vivado_proj_55mhz/pynq_deploy/"
echo "============================================================"

sed -i 's/parameter int PAR_OB = 1;/parameter int PAR_OB = 4;/' hw/rtl/pkg/cim_pkg.sv
