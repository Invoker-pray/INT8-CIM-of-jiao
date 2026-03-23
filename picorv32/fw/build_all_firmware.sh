#!/bin/bash
# ============================================================================
# build_all_firmware.sh — 在宿主机上为 20 张图片预编译所有 firmware.hex
# ============================================================================
# 在有 RISC-V GCC + Python 的宿主机上运行。
# 生成 fw_hex_batch/firmware_0000.hex ~ firmware_0019.hex
# 然后把整个 fw_hex_batch/ 目录复制到 VCS 虚拟机上。
#
# Usage:
#   cd picorv32/fw
#   bash build_all_firmware.sh
#
# 或指定数量:
#   N_IMAGES=5 bash build_all_firmware.sh
# ============================================================================

set -euo pipefail

DATA_DIR="${DATA_DIR:-small_mlp_data}"
N_IMAGES="${N_IMAGES:-20}"
OUT_DIR="fw_hex_batch"

echo "=============================================="
echo " 批量编译固件 (${N_IMAGES} 张图)"
echo "=============================================="

# ---- 检查工具链 ----
RV_GCC=""
for prefix in riscv64-elf- riscv64-unknown-elf- riscv32-unknown-elf-; do
	if command -v "${prefix}gcc" &>/dev/null; then
		RV_GCC="${prefix}gcc"
		CROSS_PREFIX="$prefix"
		break
	fi
done
if [ -z "$RV_GCC" ]; then
	echo "ERROR: RISC-V GCC 未找到"
	exit 1
fi
echo "RISC-V GCC: ${RV_GCC}"

# ---- 训练模型 (如果需要) ----
if [ ! -d "${DATA_DIR}" ]; then
	echo ""
	echo "=== 训练 small MLP ==="
	python3 small_mlp_quantize.py --output-dir "${DATA_DIR}" --num-test "${N_IMAGES}" --seed 42
fi

# ---- 检查测试数据 ----
for i in $(seq 0 $((N_IMAGES - 1))); do
	idx=$(printf '%04d' $i)
	if [ ! -f "${DATA_DIR}/test_images/img_${idx}.hex" ]; then
		echo "ERROR: ${DATA_DIR}/test_images/img_${idx}.hex 不存在"
		exit 1
	fi
done
echo "测试数据 OK: ${N_IMAGES} 张图"

# ---- 批量编译 ----
mkdir -p "${OUT_DIR}"

for i in $(seq 0 $((N_IMAGES - 1))); do
	idx=$(printf '%04d' $i)
	label=$(cat "${DATA_DIR}/test_images/img_${idx}_label.txt" | tr -d '[:space:]')

	echo -n "  [${idx}] label=${label} ... "

	make -s clean 2>/dev/null || true
	make -s DATA_DIR="${DATA_DIR}" IMAGE_IDX=$i CROSS="${CROSS_PREFIX}" 2>/dev/null

	if [ ! -f firmware.hex ]; then
		echo "FAILED"
		exit 1
	fi

	cp firmware.hex "${OUT_DIR}/firmware_${idx}.hex"

	# 记录元数据
	n_words=$(wc -l <firmware.hex)
	echo "OK (${n_words} words, label=${label})"
done

# ---- 生成标签文件 (供 VCS 脚本解析) ----
LABEL_FILE="${OUT_DIR}/labels.txt"
echo "# idx label" >"${LABEL_FILE}"
for i in $(seq 0 $((N_IMAGES - 1))); do
	idx=$(printf '%04d' $i)
	label=$(cat "${DATA_DIR}/test_images/img_${idx}_label.txt" | tr -d '[:space:]')
	echo "${idx} ${label}" >>"${LABEL_FILE}"
done

echo ""
echo "=============================================="
echo " 完成! 输出目录: ${OUT_DIR}/"
echo "=============================================="
ls -la "${OUT_DIR}/"
