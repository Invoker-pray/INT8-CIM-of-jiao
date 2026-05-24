#!/bin/bash
# One-click PetaLinux build for KV260 CIM SoC
# Usage: bash petalinux_build.sh
set -e

PROJ_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$PROJ_DIR/.." && pwd)"
PETALINUX=/home/jiao/xilinx/petalinux
XSA_SRC="$REPO_ROOT/kv260/deploy/cim_soc_kv260.xsa"
XSA_DST="$PROJ_DIR/project-spec/hw-description/system.xsa"

echo "============================================================"
echo "  KV260 PetaLinux One-Click Build"
echo "  Project: $PROJ_DIR"
echo "============================================================"

cd "$PROJ_DIR"

# --- 1. Check PetaLinux installation ---
if [ ! -f "$PETALINUX/settings.sh" ]; then
    echo "ERROR: PetaLinux not found at $PETALINUX"
    exit 1
fi

# --- 2. Source PetaLinux environment ---
source "$PETALINUX/settings.sh"

# --- 3. Locate or stage XSA ---
XSA_CANDIDATES=(
    "$XSA_SRC"
    "$REPO_ROOT/bitstream&hwh_kv260/checkpoint1_arm/cim_soc_kv260.xsa"
    "$PROJ_DIR/project-spec/hw-description/system.xsa"
)

XSA_FOUND=""
for candidate in "${XSA_CANDIDATES[@]}"; do
    if [ -f "$candidate" ]; then
        XSA_FOUND="$candidate"
        break
    fi
done

if [ -z "$XSA_FOUND" ]; then
    echo "ERROR: No XSA found. Checked:"
    for candidate in "${XSA_CANDIDATES[@]}"; do
        echo "  - $candidate"
    done
    echo "Run 'bash kv260/hw/scripts/vivado_build.sh' first from repo root."
    exit 1
fi

# Copy XSA + bitstream to canonical location if not already there
if [ "$XSA_FOUND" != "$XSA_SRC" ]; then
    echo "--- Copying XSA + bitstream to kv260/deploy/ ---"
    mkdir -p "$(dirname "$XSA_SRC")"
    cp "$XSA_FOUND" "$XSA_SRC"
    XSA_DIR="$(dirname "$XSA_FOUND")"
    cp "$XSA_DIR"/*.bit "$(dirname "$XSA_SRC")/" 2>/dev/null || true
    cp "$XSA_DIR"/*.hwh "$(dirname "$XSA_SRC")/" 2>/dev/null || true
fi

# --- 4. Sync hardware description (run if new XSA or sha256 missing) ---
NEED_HW_UPDATE=0
if [ ! -d "$XSA_DST" ]; then
    NEED_HW_UPDATE=1
elif [ ! -f "$XSA_DST/cim_soc_kv260.xsa.sha256" ]; then
    echo "--- sha256 missing, re-ingesting XSA ---"
    NEED_HW_UPDATE=1
elif [ "$(stat -c %Y "$XSA_SRC")" -gt "$(stat -c %Y "$XSA_DST" 2>/dev/null || echo 0)" ]; then
    NEED_HW_UPDATE=1
fi

if [ "$NEED_HW_UPDATE" -eq 1 ]; then
    echo "--- Updating hardware description ---"
    petalinux-config --get-hw-description "$XSA_SRC" --silentconfig
else
    echo "--- Hardware description is up to date ---"
fi

# --- 5. Build ---
echo "--- Starting petalinux-build ---"
petalinux-build

# --- 6. Package BOOT.BIN ---
echo "--- Copying bitstream and packaging BOOT.BIN ---"
BIT_DIR="$(dirname "$XSA_SRC")"
BIT_FILE=$(ls "$BIT_DIR"/*.bit 2>/dev/null | head -1)
if [ -z "$BIT_FILE" ]; then
    echo "ERROR: No .bit file found alongside XSA at $BIT_DIR"
    echo "Run 'bash kv260/hw/scripts/vivado_build.sh' first from repo root."
    exit 1
fi
cp "$BIT_FILE" "$PROJ_DIR/images/linux/system.bit"
echo "Using bitstream: $(basename "$BIT_FILE") ($(du -h "$BIT_FILE" | cut -f1))"
petalinux-package --boot \
    --fsbl images/linux/zynqmp_fsbl.elf \
    --fpga "$BIT_FILE" \
    --u-boot images/linux/u-boot.elf \
    --force

echo "============================================================"
echo "  Build complete"
echo "  BOOT.BIN: $PROJ_DIR/images/linux/BOOT.BIN"
echo "  image.ub: $PROJ_DIR/images/linux/image.ub"
echo "============================================================"
