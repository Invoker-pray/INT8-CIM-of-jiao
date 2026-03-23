#!/bin/bash
# ============================================================================
# vivado_build.sh — Build PicoRV32 + CIM SoC bitstream for PYNQ-Z2
# ============================================================================
# Usage (from any directory):
#   bash <path>/picorv32/hw/scripts/vivado_build.sh
#
# Prerequisites:
#   - Vivado 2022.2+ in PATH
#   - firmware.hex in picorv32/fw/ (run: cd fw && make DATA_DIR=small_mlp_data)
#   - picorv32.v in picorv32/hw/rtl/riscv/
#
# Output:
#   picorv32/vivado_proj/deploy/cim_rv32_soc.bit
# ============================================================================

set -e

# ---- Locate project root (parent of picorv32/) ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

echo "============================================================"
echo "PicoRV32 + CIM SoC — Vivado Build (Pure PL)"
echo "  Project root : ${PROJECT_ROOT}"
echo "  Script dir   : ${SCRIPT_DIR}"
echo "============================================================"

# ---- Find Vivado ----
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

# ---- Check prerequisites ----
if [ ! -f "${PROJECT_ROOT}/picorv32/hw/rtl/riscv/picorv32.v" ]; then
	echo "ERROR: picorv32.v not found!"
	echo "  wget -O picorv32/hw/rtl/riscv/picorv32.v \\"
	echo "    https://raw.githubusercontent.com/YosysHQ/picorv32/main/picorv32.v"
	exit 1
fi

if [ ! -f "${PROJECT_ROOT}/picorv32/fw/firmware.hex" ]; then
	echo "WARNING: picorv32/fw/firmware.hex not found!"
	echo "  BRAM will be empty. Build firmware first:"
	echo "  cd picorv32/fw && make DATA_DIR=small_mlp_data"
fi

# ---- Clean previous build ----
rm -rf "${PROJECT_ROOT}/picorv32/vivado_proj" "${PROJECT_ROOT}/.Xil"

# ---- Set PAR_OB=1 for FPGA (save area) ----
CIM_PKG="${PROJECT_ROOT}/hw/rtl/pkg/cim_pkg.sv"
if grep -q "parameter int PAR_OB = 4;" "${CIM_PKG}"; then
	sed -i 's/parameter int PAR_OB = 4;/parameter int PAR_OB = 1;/' "${CIM_PKG}"
	echo "  PAR_OB: 4 → 1 (area optimization for PYNQ-Z2)"
	PAR_OB_CHANGED=1
else
	PAR_OB_CHANGED=0
fi

# ---- Run Vivado ----
cd "${PROJECT_ROOT}"

mkdir -p picorv32/vivado_proj

${VIVADO_BIN} -mode batch \
	-source picorv32/hw/scripts/vivado_build.tcl \
	-log picorv32/vivado_proj/vivado_build.log \
	-journal picorv32/vivado_proj/vivado_build.jou

# ---- Restore PAR_OB ----
if [ "${PAR_OB_CHANGED}" -eq 1 ]; then
	sed -i 's/parameter int PAR_OB = 1;/parameter int PAR_OB = 4;/' "${CIM_PKG}"
	echo "  PAR_OB: 1 → 4 (restored)"
fi

echo ""
echo "============================================================"
echo "Build finished."
echo "  Log       : picorv32/vivado_proj/vivado_build.log"
echo "  Bitstream : picorv32/vivado_proj/deploy/cim_rv32_soc.bit"
echo ""
echo "Program FPGA:"
echo "  openFPGALoader -b pynq_z2 picorv32/vivado_proj/deploy/cim_rv32_soc.bit"
echo ""
echo "Connect USB-TTL adapter to PMODA pin 1 (Y18), then:"
echo "  minicom -D /dev/ttyUSBx -b 115200"
echo "============================================================"
