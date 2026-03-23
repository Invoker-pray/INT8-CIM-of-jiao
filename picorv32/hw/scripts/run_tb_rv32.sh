#!/bin/bash
# ============================================================================
# run_tb_rv32_batch.sh — VCS 批量仿真 20 张 MNIST 图片
# ============================================================================
# 在只有 VCS 的虚拟机上运行。
# 前置条件: 宿主机已运行 build_all_firmware.sh 生成 fw_hex_batch/
#
# 目录结构 (相对于项目根 INT8-CIM-of-jiao/):
#   hw/rtl/                         CIM IP RTL
#   picorv32/hw/rtl/riscv/          PicoRV32 SoC RTL
#   picorv32/hw/tb/                 Testbench
#   picorv32/fw/fw_hex_batch/       预编译固件 (从宿主机复制)
#
# Usage:
#   cd picorv32/
#   bash hw/scripts/run_tb_rv32_batch.sh
#
#   # 或指定 hex 目录和数量:
#   HEX_DIR=fw/fw_hex_batch N_IMAGES=5 bash hw/scripts/run_tb_rv32_batch.sh
# ============================================================================

set -euo pipefail

# ---- 路径 ----
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PICORV32_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CIM_RTL_DIR="${PICORV32_ROOT}/../hw/rtl"
RV_RTL_DIR="${PICORV32_ROOT}/hw/rtl/riscv"
TB_DIR="${PICORV32_ROOT}/hw/tb"
SIM_DIR="${PICORV32_ROOT}/hw/sim/batch"
HEX_DIR="${HEX_DIR:-${PICORV32_ROOT}/fw/fw_hex_batch}"
N_IMAGES="${N_IMAGES:-20}"

echo "=============================================="
echo " PicoRV32 + CIM SoC — VCS 批量仿真"
echo "=============================================="
echo "HEX_DIR  : ${HEX_DIR}"
echo "SIM_DIR  : ${SIM_DIR}"
echo "N_IMAGES : ${N_IMAGES}"
echo ""

# ---- 检查 ----
command -v vcs &>/dev/null || {
	echo "ERROR: vcs not found"
	exit 1
}

if [ ! -d "${HEX_DIR}" ]; then
	echo "ERROR: ${HEX_DIR} 不存在!"
	echo "  请先在宿主机运行: cd fw && bash build_all_firmware.sh"
	echo "  然后将 fw_hex_batch/ 复制到此机器"
	exit 1
fi

# 检查 hex 文件
for i in $(seq 0 $((N_IMAGES - 1))); do
	idx=$(printf '%04d' $i)
	if [ ! -f "${HEX_DIR}/firmware_${idx}.hex" ]; then
		echo "ERROR: ${HEX_DIR}/firmware_${idx}.hex 不存在"
		exit 1
	fi
done
echo "预编译固件 OK: ${N_IMAGES} 个 hex 文件"

# 检查 picorv32.v
if [ ! -f "${RV_RTL_DIR}/picorv32.v" ]; then
	echo "ERROR: picorv32.v not found in ${RV_RTL_DIR}/"
	echo "  Run: wget -O ${RV_RTL_DIR}/picorv32.v \\"
	echo "       https://raw.githubusercontent.com/YosysHQ/picorv32/main/picorv32.v"
	exit 1
fi

# 读取标签文件
LABEL_FILE="${HEX_DIR}/labels.txt"
declare -A LABELS
if [ -f "${LABEL_FILE}" ]; then
	while read -r idx label; do
		[[ "$idx" == "#"* ]] && continue
		LABELS[$idx]=$label
	done <"${LABEL_FILE}"
	echo "标签文件 OK: ${#LABELS[@]} 条"
else
	echo "WARNING: labels.txt 未找到, 将不显示 label 信息"
fi

# ============================================================
# Step 1: VCS 编译 (一次)
# ============================================================
mkdir -p "${SIM_DIR}"
cd "${SIM_DIR}"

# 放一个 dummy firmware.hex 让编译通过
echo "00000013" >firmware.hex

echo ""
echo "=== VCS 编译 ==="

SRCS=(
	"${CIM_RTL_DIR}/pkg/cim_pkg.sv"
	"${CIM_RTL_DIR}/core/cim_tile.sv"
	"${CIM_RTL_DIR}/core/psum_accum.sv"
	"${CIM_RTL_DIR}/mem/weight_sram.sv"
	"${CIM_RTL_DIR}/mem/bias_sram.sv"
	"${CIM_RTL_DIR}/mem/input_buffer.sv"
	"${CIM_RTL_DIR}/mem/output_buffer.sv"
	"${CIM_RTL_DIR}/core/cim_accel_core.sv"
	"${CIM_RTL_DIR}/axi/cim_axi_lite_slave.sv"
	"${CIM_RTL_DIR}/axi/cim_axi_lite_slave_wrapper.v"
	"${RV_RTL_DIR}/picorv32.v"
	"${RV_RTL_DIR}/uart_tx.sv"
	"${RV_RTL_DIR}/picorv32_cim_bridge.sv"
	"${RV_RTL_DIR}/cim_rv32_top.sv"
	"${TB_DIR}/tb_cim_rv32.sv"
)

vcs -full64 -sverilog -timescale=1ns/1ps \
	+v2k +lint=all,noVCDE \
	-debug_access+all \
	"${SRCS[@]}" \
	-o simv \
	2>&1 | tee compile.log

if [ ! -f simv ]; then
	echo "ERROR: VCS 编译失败!"
	exit 1
fi
echo "VCS 编译 OK"

# ============================================================
# Step 2: 逐图仿真
# ============================================================
echo ""
echo "=== 开始仿真 (${N_IMAGES} 张图) ==="

PASS=0
WRONG=0
FAIL=0
declare -a RESULT_TABLE

for i in $(seq 0 $((N_IMAGES - 1))); do
	idx=$(printf '%04d' $i)
	label="${LABELS[$idx]:-?}"

	# 替换 firmware.hex
	cp "${HEX_DIR}/firmware_${idx}.hex" "${SIM_DIR}/firmware.hex"

	echo ""
	echo "--- Image ${idx} (label=${label}) ---"

	# 运行仿真
	./simv +TIMEOUT=60000 2>&1 | tee "sim_img${idx}.log"

	# 解析结果
	RESULT=$(grep "^RESULT:" "sim_img${idx}.log" 2>/dev/null | tail -1 | awk '{print $2}')
	if [ -z "$RESULT" ]; then
		RESULT="FAIL"
	fi

	RESULT_TABLE+=("${idx} ${label} ${RESULT}")

	case "$RESULT" in
	PASS) PASS=$((PASS + 1)) ;;
	WRONG) WRONG=$((WRONG + 1)) ;;
	TIMEOUT) FAIL=$((FAIL + 1)) ;;
	*) FAIL=$((FAIL + 1)) ;;
	esac
done

# ============================================================
# Step 3: 汇总
# ============================================================
echo ""
echo "=============================================="
echo " 批量仿真结果"
echo "=============================================="
printf "%-8s %-8s %-12s\n" "Image" "Label" "Result"
printf "%-8s %-8s %-12s\n" "------" "------" "------------"

for entry in "${RESULT_TABLE[@]}"; do
	read -r img lbl res <<<"$entry"
	printf "%-8s %-8s %-12s\n" "$img" "$lbl" "$res"
done

TOTAL=$((PASS + WRONG + FAIL))
echo "----------------------------------------------"
echo "PASS: ${PASS}/${TOTAL}  WRONG: ${WRONG}/${TOTAL}  FAIL: ${FAIL}/${TOTAL}"
echo ""

if [ "$FAIL" -eq 0 ]; then
	echo "硬件验证: 全部 ${TOTAL} 张图仿真完成 (无超时/崩溃)"
	echo "模型准确率: ${PASS}/${TOTAL}"
	echo ""
	echo "EXIT: SUCCESS"
	exit 0
else
	echo "EXIT: FAILURE (${FAIL} 张图仿真未完成)"
	exit 1
fi
