#!/bin/bash
# ============================================================================
# run_par_ob_sweep.sh — recompile + run tb_par_ob_sweep for PAR_OB = 1,2,4,8,16
# ============================================================================
# For each PAR_OB value:
#   1. rewrite the "parameter int PAR_OB = N;" line in rtl/pkg/cim_pkg.sv
#   2. compile the core + memories + tb_par_ob_sweep.sv with VCS
#   3. run, capture the SWEEP_RESULT line (cycles / macs / bit-exact errors)
# Finally print a table and the speedup-vs-PAR_OB=1 ratios, and restore the
# original PAR_OB value in cim_pkg.sv.
#
# Usage (from project root):   cd hw && bash scripts/run_par_ob_sweep.sh
# Output:                      hw/sim/par_ob_sweep/  +  par_ob_sweep_results.csv
#
# -------------------------------------------------------------------------
# WHY NOT PAR_OB=32?
#   The current RTL caps PAR_OB at 16, for two independent reasons:
#     (a) fetch_cnt and tile_idx in cim_accel_core.sv are logic[3:0] (max 15),
#         and the FSM compares against PAR_OB[3:0]-1. PAR_OB=32 wraps -> wrong.
#     (b) MAX_OUT_DIM=256 => MAX_N_OB=16, so the weight/bias/output SRAMs cannot
#         hold a layer with N_OB>16, and PAR_OB cannot exceed N_OB.
#   To genuinely simulate PAR_OB=32 you must, in cim_pkg.sv + cim_accel_core.sv:
#     - widen fetch_cnt/tile_idx to logic[5:0] and the PAR_OB[3:0] slices to [5:0]
#     - raise MAX_OUT_DIM to >=512 (re-sizes the SRAMs)
#     - set this script's PAR_LIST to include 32 and OUT_DIM=512 in the TB
#   That is a real RTL change, not a parameter flip. This sweep deliberately
#   stays within the architecture's current envelope (1..16) so the numbers are
#   honest. The thesis can state PAR_OB=16 as the verified scalability point and
#   note 32 needs counter/SRAM widening as future work.
# -------------------------------------------------------------------------

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HW_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PKG="${HW_DIR}/rtl/pkg/cim_pkg.sv"
SIM_DIR="${HW_DIR}/sim/par_ob_sweep"
CSV="${HW_DIR}/par_ob_sweep_results.csv"

PAR_LIST=(1 2 4 8 16)

mkdir -p "${SIM_DIR}"

# --- remember original PAR_OB to restore later ---
ORIG_PAR_LINE="$(grep -nE 'parameter int PAR_OB = [0-9]+;' "${PKG}" | head -1)"
ORIG_PAR_VAL="$(echo "${ORIG_PAR_LINE}" | grep -oE '= [0-9]+;' | grep -oE '[0-9]+')"
echo "Original PAR_OB in cim_pkg.sv = ${ORIG_PAR_VAL}  (will restore at end)"

restore_pkg() {
	sed -i -E "s/parameter int PAR_OB = [0-9]+;/parameter int PAR_OB = ${ORIG_PAR_VAL};/" "${PKG}"
	echo "Restored PAR_OB = ${ORIG_PAR_VAL} in cim_pkg.sv"
}
trap restore_pkg EXIT

# --- gcc wrapper (VCS-generated C relies on implicit decls; gcc15 errors) ---
WRAPPER_DIR="${SIM_DIR}/.gcc_wrapper"
mkdir -p "${WRAPPER_DIR}"
REAL_GCC="$(command -v gcc)"
cat >"${WRAPPER_DIR}/gcc" <<EOF
#!/bin/bash
exec ${REAL_GCC} -Wno-error=implicit-function-declaration "\$@"
EOF
chmod +x "${WRAPPER_DIR}/gcc"
export PATH="${WRAPPER_DIR}:${PATH}"

RTL_FILES=(
	"${HW_DIR}/rtl/pkg/cim_pkg.sv"
	"${HW_DIR}/rtl/core/cim_tile.sv"
	"${HW_DIR}/rtl/core/psum_accum.sv"
	"${HW_DIR}/rtl/mem/weight_sram.sv"
	"${HW_DIR}/rtl/mem/bias_sram.sv"
	"${HW_DIR}/rtl/mem/input_buffer.sv"
	"${HW_DIR}/rtl/mem/output_buffer.sv"
	"${HW_DIR}/rtl/core/cim_accel_core.sv"
	"${HW_DIR}/tb/tb_par_ob_sweep.sv"
)

echo "model,PAR_OB,IN,OUT,cycles,macs,errors" >"${CSV}"

declare -A CYC
for P in "${PAR_LIST[@]}"; do
	echo ""
	echo "############################################################"
	echo "# PAR_OB = ${P}"
	echo "############################################################"

	# 1. set PAR_OB
	sed -i -E "s/parameter int PAR_OB = [0-9]+;/parameter int PAR_OB = ${P};/" "${PKG}"
	grep -E 'parameter int PAR_OB = [0-9]+;' "${PKG}"

	RUN_DIR="${SIM_DIR}/par_${P}"
	mkdir -p "${RUN_DIR}"
	cd "${RUN_DIR}"

	# 2. compile  (flags mirror the proven run_tb_cim_accel_core.sh)
	vcs -full64 -sverilog \
		-debug_access+all \
		-timescale=1ns/1ps \
		+define+VCS \
		-assert svaext \
		+lint=TFIPC-L \
		-l compile_${P}.log \
		"${RTL_FILES[@]}" \
		-o simv_${P} >compile_stdout_${P}.log 2>&1 || {
		echo "  COMPILE FAILED for PAR_OB=${P}. See ${RUN_DIR}/compile_${P}.log"
		echo "ALL,${P},256,256,COMPILE_FAIL,," >>"${CSV}"
		continue
	}

	# 3. run
	./simv_${P} -l sim_${P}.log >sim_stdout_${P}.log 2>&1 || true

	LINE="$(grep -h 'SWEEP_RESULT' sim_${P}.log 2>/dev/null | tail -1)"
	if [ -z "${LINE}" ]; then
		echo "  NO RESULT for PAR_OB=${P}. See ${RUN_DIR}/sim_${P}.log"
		echo "ALL,${P},256,256,NO_RESULT,," >>"${CSV}"
		continue
	fi
	echo "  ${LINE}"

	C=$(echo "${LINE}" | grep -oE 'CYCLES=[0-9]+' | cut -d= -f2)
	M=$(echo "${LINE}" | grep -oE 'MACS=[0-9]+' | cut -d= -f2)
	E=$(echo "${LINE}" | grep -oE 'ERRORS=[0-9]+' | cut -d= -f2)
	CYC[$P]=$C
	echo "sweep,${P},256,256,${C},${M},${E}" >>"${CSV}"

	cd "${HW_DIR}"
done

# --- summary table ---
echo ""
echo "============================================================"
echo " PAR_OB scalability sweep — layer 256x256 (N_OB=16) @ inline golden"
echo "============================================================"
printf "  %-8s %-12s %-12s %-12s %-8s\n" "PAR_OB" "cycles" "speedup" "ideal(=PAR)" "bitexact"
printf "  %-8s %-12s %-12s %-12s %-8s\n" "------" "------" "-------" "-----------" "--------"
BASE=${CYC[1]:-0}
while IFS=, read -r model P IN OUT C M E; do
	[ "$model" = "model" ] && continue
	[ "$model" = "sweep" ] || continue
	if [ "$BASE" -gt 0 ] 2>/dev/null && [ "$C" -gt 0 ] 2>/dev/null; then
		SP=$(python3 -c "print(f'{$BASE/$C:.2f}x')")
	else
		SP="-"
	fi
	BE=$([ "$E" = "0" ] && echo "PASS" || echo "FAIL($E)")
	printf "  %-8s %-12s %-12s %-12s %-8s\n" "$P" "$C" "$SP" "${P}x" "$BE"
done <"${CSV}"
echo "============================================================"
echo "CSV: ${CSV}"
echo "(speedup is cycles(PAR_OB=1)/cycles(PAR_OB=P); ideal would be P x)"
