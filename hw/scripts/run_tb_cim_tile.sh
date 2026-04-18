#!/bin/bash
# ============================================================================
# run_tb_cim_tile.sh — VCS simulation for CIM tile unit test
# ============================================================================
# Usage: cd hw && bash scripts/run_tb_cim_tile.sh
# Output: sim/tb_cim_tile/
# ============================================================================

set -e

TB_NAME="tb_cim_tile"
SIM_DIR="sim/${TB_NAME}"
mkdir -p "${SIM_DIR}"

# ------------------------------------------------------------
# gcc 15+ treats implicit function declarations as a hard error;
# VCS W-2024.09's generated rmapats.c relies on them. Inject a
# wrapper earlier on PATH that re-enables the old warning-only
# behavior. (Local to this script — does not leak to other tools.)
# ------------------------------------------------------------
WRAPPER_DIR="$(pwd)/${SIM_DIR}/.gcc_wrapper"
mkdir -p "${WRAPPER_DIR}"
REAL_GCC="$(command -v gcc)"
cat > "${WRAPPER_DIR}/gcc" <<EOF
#!/bin/bash
exec ${REAL_GCC} -Wno-error=implicit-function-declaration "\$@"
EOF
chmod +x "${WRAPPER_DIR}/gcc"
export PATH="${WRAPPER_DIR}:${PATH}"

RTL_FILES=(
    rtl/pkg/cim_pkg.sv
    rtl/core/cim_tile.sv
    tb/${TB_NAME}.sv
)

echo "============================================================"
echo "Compiling ${TB_NAME} with VCS..."
echo "============================================================"

cd "${SIM_DIR}"

vcs -full64 -sverilog -debug_access+all \
    -timescale=1ns/1ps \
    +define+VCS \
    -l compile.log \
    "${RTL_FILES[@]/#/../../}" \
    -o simv

echo "============================================================"
echo "Running simulation..."
echo "============================================================"

./simv -l sim.log +fsdbfile+${TB_NAME}.fsdb

echo "============================================================"
echo "Done. Logs in ${SIM_DIR}/"
echo "  compile.log  — VCS compilation log"
echo "  sim.log      — simulation output"
echo "  ${TB_NAME}.fsdb — waveform (open with Verdi)"
echo "============================================================"
