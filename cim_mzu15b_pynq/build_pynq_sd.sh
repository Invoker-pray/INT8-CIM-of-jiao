#!/bin/bash
# ============================================================================
# build_pynq_sd.sh — Create PYNQ-enabled SD card for MZU15B
# ============================================================================
# MZU15B is a non-Xilinx official board (XCZU15EG-FFVB1156-2-I).
# Without a board BSP, the standard approach is:
#   1. Use PetaLinux boot components (FSBL, PMU, ATF, U-Boot, DTB, kernel)
#      — these know our DDR, MIO, and PS peripherals
#   2. Install PYNQ Python framework into Ubuntu ARM64 rootfs via pip
#   3. CIM IP is accessed via /dev/mem (Plan C) — no overlay .bit needed at runtime
#
# Why pip-install PYNQ instead of using a board image:
#   - PYNQ board images have device trees specific to their target board
#   - Our DDR/MIO configuration differs from any official board
#   - Replacing boot components is fragile (kernel/DTB mismatch risks)
#   - pip-installed pynq works on any ARM64 Linux with /dev/mem access
#
# Boot mode: SD card (DIP SW1: OFF-OFF-OFF-ON)
#
# Usage:
#   1. Build PetaLinux first: cd cim_mzu15b && bash petalinux_build.sh
#   2. Run this script: cd cim_mzu15b_pynq && bash build_pynq_sd.sh
#
# Output:
#   cim_mzu15b_pynq/output/mzu15b_pynq_sd.img
# ============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UBUNTU_BUILDER="$PROJECT_ROOT/cim_mzu15b_ubuntu/build_ubuntu_sd.sh"
OUTPUT_DIR="$SCRIPT_DIR/output"

echo "============================================================"
echo "  MZU15B PYNQ SD Card Builder"
echo "============================================================"

# ---- Option A: Built on top of Ubuntu builder ----
if [ -f "$UBUNTU_BUILDER" ]; then
    echo "--- Building base Ubuntu image first (reuses cim_mzu15b_ubuntu) ---"

    # Run Ubuntu builder to get base image
    bash "$UBUNTU_BUILDER"

    # Copy Ubuntu output to PYNQ output
    UBUNTU_OUTPUT="$PROJECT_ROOT/cim_mzu15b_ubuntu/output"
    if [ -f "$UBUNTU_OUTPUT/mzu15b_ubuntu_sd.img" ]; then
        rm -rf "$OUTPUT_DIR"
        mkdir -p "$OUTPUT_DIR"
        cp "$UBUNTU_OUTPUT/mzu15b_ubuntu_sd.img" "$OUTPUT_DIR/mzu15b_pynq_sd.img"
        cp -r "$UBUNTU_OUTPUT/rootfs" "$OUTPUT_DIR/rootfs"
    else
        echo "WARNING: Ubuntu image not built. Proceeding with rootfs only."
    fi
fi

# ---- Check prerequisites ----
PETALINUX_IMAGES="$PROJECT_ROOT/cim_mzu15b/images/linux"
if [ ! -f "$PETALINUX_IMAGES/BOOT.BIN" ]; then
    echo "ERROR: PetaLinux boot components not found."
    echo "  Build PetaLinux first: cd cim_mzu15b && bash petalinux_build.sh"
    exit 1
fi

# ---- Create PYNQ customization overlay for rootfs ----
mkdir -p "$OUTPUT_DIR/rootfs_overlay"

# PYNQ setup script (runs on first boot)
cat > "$OUTPUT_DIR/rootfs_overlay/setup_pynq.sh" << 'SETUP'
#!/bin/bash
# MZU15B PYNQ first-boot setup
set -e

echo "=== MZU15B PYNQ Setup ==="

# Update package list
apt-get update

# Install PYNQ dependencies
apt-get install -y \
    python3 python3-pip python3-numpy python3-dev \
    i2c-tools usbutils pciutils \
    jupyter-notebook

# Install PYNQ framework (v3.x supports ZynqMP/UltraScale+)
pip3 install pynq

# Install Jupyter
pip3 install jupyter

# Create PYNQ configuration for MZU15B
cat > /etc/pynq.conf << 'PYNQCONF'
[default]
board = MZU15B
family = ZynqMP
target = cim_mzu15b

[device-tree]
# CIM IP at 0xA0000000 is discovered via /dev/mem (Plan C)
# No overlay needed — CIM is in the static bitstream
PYNQCONF

# Create CIM driver directory
mkdir -p /home/root/cim_driver

# Plan C /dev/mem CIM driver
cat > /home/root/cim_driver/cim_driver.py << 'CIMDRIVER'
"""
CIM Driver for MZU15B — /dev/mem based (Plan C)
Works without PYNQ overlay support.
"""
import os
import mmap
import struct
import time

class CIMDriver:
    """Direct /dev/mem access to CIM accelerator at 0xA0000000."""

    CIM_BASE  = 0xA0000000
    CIM_SIZE  = 0x4000  # 16KB

    # CSR offsets (from cim_pkg.sv)
    CSR_CTRL       = 0x000
    CSR_STATUS     = 0x004
    CSR_IN_DIM     = 0x010
    CSR_OUT_DIM    = 0x014
    CSR_N_IB       = 0x018
    CSR_N_OB       = 0x01C
    CSR_PRED_CLASS = 0x040
    CSR_LOGIT_BASE = 0x100
    MEM_INPUT_BASE = 0x1000
    MEM_BIAS_BASE  = 0x2000
    CSR_WDMA_ADDR  = 0x044
    CSR_WDMA_DATA  = 0x048
    CSR_WDMA_CTRL  = 0x04C

    def __init__(self):
        self.fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
        self.mm = mmap.mmap(self.fd, self.CIM_SIZE, offset=self.CIM_BASE)

    def _rd(self, offset):
        return struct.unpack('<I', self.mm[offset:offset+4])[0]

    def _wr(self, offset, value):
        self.mm[offset:offset+4] = struct.pack('<I', value)

    def configure(self, in_dim, out_dim):
        n_ib = (in_dim + 15) // 16
        n_ob = (out_dim + 15) // 16
        self._wr(self.CSR_IN_DIM, in_dim)
        self._wr(self.CSR_OUT_DIM, out_dim)
        self._wr(self.CSR_N_IB, n_ib)
        self._wr(self.CSR_N_OB, n_ob)

    def write_weights(self, tiles):
        """Write weight tiles via WDMA interface."""
        for i, tile_bytes in enumerate(tiles):
            self._wr(self.CSR_WDMA_ADDR, i)
            for j in range(0, len(tile_bytes), 4):
                chunk = tile_bytes[j:j+4]
                val = struct.unpack('<I', chunk.ljust(4, b'\x00'))[0]
                self._wr(self.CSR_WDMA_DATA, val)
            self._wr(self.CSR_WDMA_CTRL, (j//4 - 1) << 4 | 1)

    def write_inputs(self, inputs):
        for i, val in enumerate(inputs):
            self._wr(self.MEM_INPUT_BASE + 4*i, val & 0xFF)

    def write_biases(self, biases):
        for i, val in enumerate(biases):
            self._wr(self.MEM_BIAS_BASE + 4*i, val)

    def start(self):
        self._wr(self.CSR_CTRL, 1)

    def wait_done(self, timeout=1.0):
        t0 = time.time()
        while not (self._rd(self.CSR_STATUS) & 2):
            if time.time() - t0 > timeout:
                raise TimeoutError("CIM did not finish")
            time.sleep(0.0001)

    def read_prediction(self):
        return self._rd(self.CSR_PRED_CLASS)

    def close(self):
        self.mm.close()
        os.close(self.fd)

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()

# Test on import
if __name__ == '__main__':
    with CIMDriver() as cim:
        print(f"CIM status: 0x{cim._rd(CIMDriver.CSR_STATUS):08x}")
        print("CIM driver ready.")
CIMDRIVER

# Create first-boot marker
touch /home/root/.mzu15b_pynq_setup_done

echo "PYNQ setup complete. CIM driver at /home/root/cim_driver/cim_driver.py"
SETUP

chmod +x "$OUTPUT_DIR/rootfs_overlay/setup_pynq.sh"

# ---- Install overlay into rootfs if available ----
if [ -d "$OUTPUT_DIR/rootfs" ]; then
    echo "--- Injecting PYNQ overlay into rootfs ---"
    cp "$OUTPUT_DIR/rootfs_overlay/setup_pynq.sh" "$OUTPUT_DIR/rootfs/home/"

    # Add PYNQ systemd service for first-boot setup
    mkdir -p "$OUTPUT_DIR/rootfs/etc/systemd/system"
    cat > "$OUTPUT_DIR/rootfs/etc/systemd/system/pynq-firstboot.service" << 'SERVICE'
[Unit]
Description=PYNQ First-Boot Setup for MZU15B
After=network.target

[Service]
Type=oneshot
ExecStart=/home/setup_pynq.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE
fi

# ---- Report ----
echo ""
echo "============================================================"
echo "  MZU15B PYNQ SD card ready"
echo ""
echo "  Approach: Ubuntu rootfs + pip-installed pynq"
echo "  Why: MZU15B has no Xilinx board BSP; standard PYNQ images"
echo "       have wrong DDR/device-tree config for this board."
echo ""
echo "  CIM access: /dev/mem at 0xA0000000 (Plan C)"
echo "  PYNQ overlay API: not used (CIM is in static bitstream)"
echo ""
echo "  To flash SD card:"
echo "    sudo dd if=$OUTPUT_DIR/mzu15b_pynq_sd.img of=/dev/sdX bs=4M"
echo ""
echo "  After boot:"
echo "    1. Login as root (no password on first boot)"
echo "    2. Setup runs automatically (systemd pynq-firstboot.service)"
echo "    3. Or manually: python3 /home/root/cim_driver/cim_driver.py"
echo "============================================================"
