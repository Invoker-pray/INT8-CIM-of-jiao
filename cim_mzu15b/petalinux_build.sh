#!/bin/bash
set -e

echo "=== PetaLinux Build Environment ==="
echo "OS: $(cat /etc/os-release | head -1)"
echo "GCC: $(gcc --version | head -1)"
echo "SHELL: $SHELL"

PETALINUX=/home/jiao/xilinx/petalinux
if [ ! -f "$PETALINUX/settings.sh" ]; then
    echo "ERROR: PetaLinux not found at $PETALINUX"
    echo "Mount it with: -v /path/to/petalinux:$PETALINUX:ro"
    exit 1
fi

source "$PETALINUX/settings.sh"

# Add gen-machineconf to PATH (it lives in the project's yocto layers, not in the PetaLinux install)
export PATH="${PWD}/components/yocto/layers/meta-xilinx/meta-xilinx-core/gen-machine-conf:$PATH"

echo "=== Starting build ==="
petalinux-build

echo "=== Packaging BOOT.BIN ==="
petalinux-package --boot --fsbl images/linux/zynqmp_fsbl.elf --fpga images/linux/system.bit --u-boot images/linux/u-boot.elf --force

echo "=== Build complete ==="
