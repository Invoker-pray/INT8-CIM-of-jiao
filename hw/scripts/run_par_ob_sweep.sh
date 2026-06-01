#!/bin/bash
# ============================================================================
# run_par_ob_sweep.sh — recompile + run tb_par_ob_sweep for PAR_OB = 1,2,4,8,16
# ============================================================================
# This version mirrors the PROVEN run_tb_cim_accel_core.sh compile flow exactly
# (same gcc wrapper, same `tee` + `[ ! -f simv ]` success check) so that if that
# script compiles your RTL, so does this one. It does NOT use `set -e` (which
# silently aborts loops on any non-zero step) and it does NOT rely on VCS's exit
# code to detect success — it checks for the produced simv binary, just like the
# working script.
#
# For each PAR_OB value:
#   1. rewrite "parameter int PAR_OB = N;" in rtl/pkg/cim_pkg.sv
#   2. compile core + memories + tb_par_ob_sweep.sv with VCS
#   3. run, capture the SWEEP_RESULT line (cycles / macs / bit-exact errors)
# Finally print a table + speedup-vs-PAR_OB=1, and restore the original PAR_OB.
#
# Usage (from project root):   cd hw && bash scripts/run_par_ob_sweep.sh
# Output:                      hw/sim/par_ob_sweep/par_<P>/  + par_ob_sweep_results.csv
#
# -------------------------------------------------------------------------
# WHY PAR_OB stops at 16 (not 32): the current RTL caps it — fetch_cnt/tile_idx
# are logic[3:0] and MAX_OUT_DIM=256 (=> MAX_N_OB=16). PAR_OB=32 needs counter +
# SRAM widening; see notes at bottom. {1,2,4,8,16} is the honest, supported range.
# -------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HW_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PKG="${HW_DIR}/rtl/pkg/cim_pkg.sv"
SIM_ROOT="${HW_DIR}/sim/par_ob_sweep"
CSV="${HW_DIR}/par_ob_sweep_results.csv"

PAR_LIST=(1 2 4 8 16)

mkdir -p "${SIM_ROOT}"

# --- remember original PAR_OB to restore later ---
ORIG_PAR_VAL="$(grep -oE 'parameter int PAR_OB = [0-9]+;' "${PKG}" | grep -oE '[0-9]+' | head -1)"
echo "Original PAR_OB in cim_pkg.sv = ${ORIG_PAR_VAL}  (will restore at end)"

restore_pkg() {
	sed -i -E "s/parameter int PAR_OB = [0-9]+;/parameter int PAR_OB = ${ORIG_PAR_VAL};/" "${PKG}"
	echo ""
	echo "Restored PAR_OB = ${ORIG_PAR_VAL} in cim_pkg.sv"
}
trap restore_pkg EXIT

# --- gcc wrapper (byte-identical to run_tb_cim_accel_core.sh) ---
WRAPPER_DIR="${SIM_ROOT}/.gcc_wrapper"
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
	grep -E 'parameter int PAR_OB = [0-9]+;' "${PKG}" | sed 's/^[[:space:]]*//'

	RUN_DIR="${SIM_ROOT}/par_${P}"
	mkdir -p "${RUN_DIR}"
	cd "${RUN_DIR}" || {
		echo "cannot cd ${RUN_DIR}"
		continue
	}

	rm -f simv # clean any stale binary so the check is meaningful

	# 2. compile — SAME pattern as the proven script: tee, then check for simv
	echo "  compiling (VCS)..."
	vcs -full64 -sverilog \
		-debug_access+all \
		-timescale=1ns/1ps \
		+define+VCS \
		-assert svaext \
		+lint=TFIPC-L \
		-l compile_${P}.log \
		"${RTL_FILES[@]}" \
		-o simv 2>&1 | tee compile_stdout_${P}.log

	if [ ! -f simv ]; then
		echo "  COMPILE FAILED for PAR_OB=${P}. See ${RUN_DIR}/compile_${P}.log"
		echo "ALL,${P},256,256,COMPILE_FAIL,," >>"${CSV}"
		cd "${HW_DIR}"
		continue
	fi

	# 3. run — SAME pattern as the proven script
	echo "  running..."
	./simv -l sim_${P}.log +fsdbfile+"${RUN_DIR}/tb_par_ob_sweep.fsdb" 2>&1 | tee sim_stdout_${P}.log

	LINE="$(grep -h 'SWEEP_RESULT' sim_${P}.log 2>/dev/null | tail -1)"
	if [ -z "${LINE}" ]; then
		echo "  NO RESULT for PAR_OB=${P}. See ${RUN_DIR}/sim_${P}.log"
		echo "ALL,${P},256,256,NO_RESULT,," >>"${CSV}"
		cd "${HW_DIR}"
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
echo " PAR_OB scalability sweep — layer 256x256 (N_OB=16)"
echo "============================================================"
printf "  %-8s %-12s %-12s %-12s %-10s\n" "PAR_OB" "cycles" "speedup" "ideal(=PAR)" "bitexact"
printf "  %-8s %-12s %-12s %-12s %-10s\n" "------" "------" "-------" "-----------" "--------"
BASE=${CYC[1]:-0}
while IFS=, read -r model P IN OUT C M E; do
	[ "$model" = "sweep" ] || continue
	if [ "$BASE" -gt 0 ] 2>/dev/null && [ "$C" -gt 0 ] 2>/dev/null; then
		SP=$(awk "BEGIN{printf \"%.2fx\", $BASE/$C}")
	else
		SP="-"
	fi
	BE=$([ "$E" = "0" ] && echo "PASS" || echo "FAIL($E)")
	printf "  %-8s %-12s %-12s %-12s %-10s\n" "$P" "$C" "$SP" "${P}x" "$BE"
done <"${CSV}"
echo "============================================================"
echo "CSV: ${CSV}"
echo "(speedup = cycles(PAR_OB=1)/cycles(PAR_OB=P); ideal would be P x)"

# -------------------------------------------------------------------------
# To genuinely run PAR_OB=32 you must edit the RTL (not just this script):
#   - cim_accel_core.sv: widen fetch_cnt/tile_idx to logic[5:0]; change the
#     PAR_OB[3:0] slices to [5:0].
#   - cim_pkg.sv: raise MAX_OUT_DIM to >=512 (re-sizes weight/bias/out SRAMs).
#   - tb_par_ob_sweep.sv: set OUT_DIM=512 (N_OB=32); add 32 to PAR_LIST above.
# -------------------------------------------------------------------------
