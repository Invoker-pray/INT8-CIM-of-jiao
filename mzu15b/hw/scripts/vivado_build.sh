#!/bin/bash
# ============================================================================
# vivado_build.sh — Build PicoRV32 + CIM SoC bitstream for MZU15B (XCZU15EG)
# ============================================================================
# Usage: cd <project_root> && bash mzu15b/hw/scripts/vivado_build.sh
#
# Prerequisites:
#   - Vivado 2022.2+ in PATH (source settings64.sh)
#   - RISC-V GCC toolchain (for firmware, see picorv32/fw/Makefile)
#   - picorv32/fw/firmware.hex (prebuilt firmware)
#
# Output:
#   mzu15b/vivado_rv32_proj/deploy/cim_rv32_mzu15b.bit
#
# Automated:
#   - PS DDR4 configuration for MT40A512M16LY-062E (64-bit + ECC, 4 GB)
#   - Synthesis + Implementation + Bitstream generation
#   - Utilization and timing reports
#
# If DDR training fails at boot, see TCL for manual tuning instructions.
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

echo "============================================================"
echo "PicoRV32 + CIM SoC — MZU15B (XCZU15EG) Build"
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
    echo "  cd picorv32/fw && make"
fi

# ---- Clean previous build ----
rm -rf "${PROJECT_ROOT}/mzu15b/vivado_rv32_proj" "${PROJECT_ROOT}/.Xil"

# ---- MZU15B: PAR_OB=8 is fine for synthesis (3528 DSP available) ----
# No PAR_OB tweak needed (unlike PYNQ-Z2 where PAR_OB=4→1 for area).
echo "  PAR_OB=8 (MZU15B has 3528 DSP → 8×256=2048 used, 58% headroom)"

# ---- Run Vivado ----
cd "${PROJECT_ROOT}"
mkdir -p mzu15b/vivado_rv32_proj

${VIVADO_BIN} -mode batch \
    -source mzu15b/hw/scripts/vivado_build_rv32.tcl \
    -log mzu15b/vivado_rv32_proj/vivado_build.log \
    -journal mzu15b/vivado_rv32_proj/vivado_build.jou

echo ""
echo "============================================================"
echo "Build finished."
echo "  Log       : mzu15b/vivado_rv32_proj/vivado_build.log"
echo "  Bitstream : mzu15b/vivado_rv32_proj/deploy/cim_rv32_mzu15b.bit"
echo ""
echo "Program FPGA (via JTAG / openFPGALoader):"
echo "  openFPGALoader -b <board> mzu15b/vivado_rv32_proj/deploy/cim_rv32_mzu15b.bit"
echo ""
echo "On-board test (Plan C — bare metal Linux):"
echo "  python3 -c \""
echo "  import os, mmap, struct, time"
echo "  fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)"
echo "  fw  = mmap.mmap(fd, 0x8000, offset=0xA0000000)"
echo "  res = mmap.mmap(fd, 0x1000, offset=0xA2000000)"
echo "  gpio= mmap.mmap(fd, 0x1000, offset=0xA3000000)"
echo "  gpio[0:4] = struct.pack('<I', 0)"
echo "  with open('fw_words.bin', 'rb') as f:"
echo "      fw[:len(data)] = f.read()"
echo "  gpio[0:4] = struct.pack('<I', 1)"
echo "  while struct.unpack('<I', res[0:4])[0] != 0xC1AA0001: time.sleep(0.001)"
echo "  print('Pred:', struct.unpack('<I', res[4:8])[0])"
echo "  \""
echo "============================================================"
