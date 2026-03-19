#!/bin/bash
# ============================================================================
# vivado_build.sh — Build CIM SoC bitstream for PYNQ-Z2
# ============================================================================
# Usage: cd <project_root> && bash hw/scripts/vivado_build.sh
#
# Prerequisites:
#   - Vivado 2022.2+ in PATH (source settings64.sh or add to PATH)
#   - PYNQ-Z2 board file installed (optional but recommended)
#
# Output:
#   vivado_proj/pynq_deploy/cim_soc.bit
#   vivado_proj/pynq_deploy/cim_soc.hwh
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "============================================================"
echo "CIM SoC — Vivado Build"
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

${VIVADO_BIN} -mode batch \
	-source hw/scripts/vivado_build.tcl \
	-log vivado_proj/vivado_build.log \
	-journal vivado_proj/vivado_build.jou

echo ""
echo "============================================================"
echo "Build finished. Check vivado_proj/vivado_build.log for details."
echo "Deploy files: vivado_proj/pynq_deploy/"
echo "============================================================"
