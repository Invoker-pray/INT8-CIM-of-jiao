#!/bin/bash
# ============================================================================
# vivado_build.sh — Build CIM SoC bitstream for KV260 (ARM-direct, AXI DMA)
# ============================================================================
# Usage: cd <project_root> && bash kv260/hw/scripts/vivado_build.sh
#
# Prerequisites:
#   - Vivado 2024.2 in PATH (source settings64.sh)
#   - KV260 board file installed
#
# Output:
#   kv260/deploy/cim_soc_kv260.bit
#   kv260/deploy/cim_soc_kv260.hwh
#   kv260/deploy/cim_soc_kv260.xsa
#   kv260/deploy/cim_soc_kv260.dtbo
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

echo "============================================================"
echo "CIM SoC KV260 — Vivado Build"
echo "  Project root: ${PROJECT_ROOT}"
echo "============================================================"

# Find vivado
if command -v vivado &>/dev/null; then
    VIVADO_BIN="vivado"
else
    echo "ERROR: vivado not found. Source settings64.sh first."
    echo "  Example: source ~/xilinx/Vivado/2024.2/settings64.sh"
    exit 1
fi

echo "  Vivado: $(${VIVADO_BIN} -version 2>/dev/null | head -1 || echo ${VIVADO_BIN})"

cd "${PROJECT_ROOT}"

# KV260 (K26 SOM, xck26) has ~1248 DSPs — PAR_OB is set in cim_pkg.sv and kept as-is.
CURRENT_PAR=$(grep "parameter int PAR_OB = " hw/rtl/pkg/cim_pkg.sv | head -1)
echo "  PAR_OB = $CURRENT_PAR"

rm -rf vivado_proj .Xil

${VIVADO_BIN} -mode batch \
    -source kv260/hw/scripts/vivado_build.tcl \
    -log vivado_proj/vivado_build.log \
    -journal vivado_proj/vivado_build.jou
BUILD_STATUS=$?

if [ $BUILD_STATUS -ne 0 ]; then
    echo ""
    echo "============================================================"
    echo "Build FAILED (exit code ${BUILD_STATUS})"
    echo "============================================================"
    exit $BUILD_STATUS
fi

# -----------------------------------------------------------------------
# Generate Device Tree Overlay (.dtbo) for KV260
# ZynqMP requires a DT overlay to enable PS-PL AXI bridges after PL config.
# -----------------------------------------------------------------------
# Find dtc: prefer system version (supports -@ for DT overlays)
DTC_BIN=""
for candidate in /usr/bin/dtc /bin/dtc "$(dirname "$(which vivado 2>/dev/null)")/dtc"; do
    if [ -x "${candidate}" ]; then
        DTC_BIN="${candidate}"
        break
    fi
done

if [ -n "${DTC_BIN}" ] && [ -x "${DTC_BIN}" ]; then
    DTS_SRC="${SCRIPT_DIR}/cim_kv260_overlay.dts"
    DTBO_OUT="${PROJECT_ROOT}/kv260/deploy/cim_soc_kv260.dtbo"
    # -@ enables __symbols__ / __fixups__ for DT plugin overlay resolution
    if "${DTC_BIN}" -@ -I dts -O dtb -o "${DTBO_OUT}" "${DTS_SRC}" 2>/dev/null; then
        echo "  DT overlay: ${DTBO_OUT} ($(wc -c < "${DTBO_OUT}") bytes)"
    else
        # Fallback: try without -@ (older dtc)
        "${DTC_BIN}" -I dts -O dtb -o "${DTBO_OUT}" "${DTS_SRC}" 2>/dev/null && \
            echo "  DT overlay (no syms): ${DTBO_OUT} ($(wc -c < "${DTBO_OUT}") bytes)" || \
            echo "  WARNING: dtc failed — DT overlay not generated"
    fi
else
    echo "  WARNING: dtc not found — DT overlay not generated"
fi

echo ""
echo "============================================================"
echo "KV260 Build finished."
echo "Deploy: kv260/deploy/"
echo "============================================================"
