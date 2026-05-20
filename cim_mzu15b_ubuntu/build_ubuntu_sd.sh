#!/bin/bash
# ============================================================================
# build_ubuntu_sd.sh — Create bootable Ubuntu 22.04 SD card for MZU15B
# ============================================================================
# MZU15B is a non-Xilinx official board (XCZU15EG-FFVB1156-2-I).
# Since no board support package exists, we use PetaLinux-generated boot
# components (FSBL, PMU, ATF, U-Boot, DTB, kernel) and combine them with
# a generic Ubuntu ARM64 rootfs.
#
# Boot flow: CSU ROM → FSBL → PMU+ATF → U-Boot → Linux kernel → Ubuntu rootfs
# Boot mode: SD card (DIP SW1: OFF-OFF-OFF-ON)
#
# Usage:
#   1. Build PetaLinux first: cd cim_mzu15b && bash petalinux_build.sh
#   2. Run this script: cd cim_mzu15b_ubuntu && bash build_ubuntu_sd.sh
#
# Output:
#   cim_mzu15b_ubuntu/output/mzu15b_ubuntu_sd.img  (SD card image)
#   Or: cim_mzu15b_ubuntu/output/boot/ + root/     (partition contents)
# ============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/output"
PETALINUX_IMAGES="$PROJECT_ROOT/cim_mzu15b/images/linux"
UBUNTU_RELEASE="22.04"
UBUNTU_MIRROR="https://cdimage.ubuntu.com/ubuntu-base/releases/${UBUNTU_RELEASE}/release"
UBUNTU_TARBALL="ubuntu-base-${UBUNTU_RELEASE}-base-arm64.tar.gz"

echo "============================================================"
echo "  MZU15B Ubuntu ${UBUNTU_RELEASE} SD Card Builder"
echo "============================================================"

# ---- Check prerequisites ----
if [ ! -f "$PETALINUX_IMAGES/BOOT.BIN" ]; then
    echo "ERROR: PetaLinux BOOT.BIN not found at $PETALINUX_IMAGES/BOOT.BIN"
    echo "  Build PetaLinux first: cd cim_mzu15b && bash petalinux_build.sh"
    exit 1
fi

REQUIRED_FILES=(
    "$PETALINUX_IMAGES/BOOT.BIN"
    "$PETALINUX_IMAGES/Image"
    "$PETALINUX_IMAGES/system.dtb"
    "$PETALINUX_IMAGES/boot.scr"
)
for f in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: Required file not found: $f"
        echo "  Make sure PetaLinux build completed successfully."
        exit 1
    fi
done

# ---- Download Ubuntu base rootfs if needed ----
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

if [ ! -f "$OUTPUT_DIR/$UBUNTU_TARBALL" ]; then
    echo "--- Downloading Ubuntu ${UBUNTU_RELEASE} ARM64 base rootfs..."
    UBUNTU_URL="${UBUNTU_MIRROR}/${UBUNTU_TARBALL}"
    wget -q --show-progress -O "$OUTPUT_DIR/$UBUNTU_TARBALL" "$UBUNTU_URL" || {
        echo "ERROR: Failed to download $UBUNTU_URL"
        echo "  Check network or try a different mirror."
        exit 1
    }
else
    echo "--- Using cached $UBUNTU_TARBALL ---"
fi

# ---- Extract and configure Ubuntu rootfs ----
echo "--- Extracting Ubuntu rootfs ---"
ROOTFS_DIR="$OUTPUT_DIR/rootfs"
rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"
tar -xzf "$OUTPUT_DIR/$UBUNTU_TARBALL" -C "$ROOTFS_DIR"

echo "--- Configuring Ubuntu rootfs ---"

# Write hostname
echo "cim-mzu15b" > "$ROOTFS_DIR/etc/hostname"

# Write /etc/hosts
cat > "$ROOTFS_DIR/etc/hosts" << 'HOSTS'
127.0.0.1   localhost
127.0.1.1   cim-mzu15b
HOSTS

# Write /etc/fstab (SD card: mmcblk0p1=boot, mmcblk0p2=root)
cat > "$ROOTFS_DIR/etc/fstab" << 'FSTAB'
/dev/mmcblk0p1  /boot           vfat    defaults    0 2
/dev/mmcblk0p2  /               ext4    defaults    0 1
proc            /proc           proc    defaults    0 0
sysfs           /sys            sysfs   defaults    0 0
tmpfs           /tmp            tmpfs   defaults    0 0
FSTAB

# Write network config (DHCP, enx + predictable name from MAC)
cat > "$ROOTFS_DIR/etc/netplan/01-netcfg.yaml" << 'NETPLAN'
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      dhcp4: true
      optional: true
NETPLAN

# Create ttyPS0 getty for UART console (MZU15B J2)
mkdir -p "$ROOTFS_DIR/etc/systemd/system/getty@ttyPS0.service.d"
cat > "$ROOTFS_DIR/etc/systemd/system/getty@ttyPS0.service.d/override.conf" << 'TTYPS0'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -- \\u' --keep-baud 115200,57600,38400,9600 - $TERM
TTYPS0

# ---- Copy boot components ----
echo "--- Copying boot components ---"
BOOT_DIR="$OUTPUT_DIR/boot"
mkdir -p "$BOOT_DIR"
cp "$PETALINUX_IMAGES/BOOT.BIN"    "$BOOT_DIR/"
cp "$PETALINUX_IMAGES/Image"       "$BOOT_DIR/"
cp "$PETALINUX_IMAGES/system.dtb"  "$BOOT_DIR/"
cp "$PETALINUX_IMAGES/boot.scr"    "$BOOT_DIR/"

# ---- Create SD card image ----
echo "--- Creating SD card image ---"
SD_IMG="$OUTPUT_DIR/mzu15b_ubuntu_sd.img"
BOOT_SIZE_MB=256              # 256 MB FAT32 boot partition
ROOT_SIZE_MB=2048             # 2 GB ext4 root partition

# Calculate image size (2 partitions + 1MB for partition table)
IMG_SIZE=$((BOOT_SIZE_MB + ROOT_SIZE_MB + 1))

dd if=/dev/zero of="$SD_IMG" bs=1M count="$IMG_SIZE" status=none

# Partition table
sfdisk "$SD_IMG" << EOF
label: dos
1: type=c, start=2048, size=$((BOOT_SIZE_MB * 2048))
2: type=83, start=$((BOOT_SIZE_MB * 2048 + 2048)), size=$((ROOT_SIZE_MB * 2048))
EOF

# Create loop devices
LOOP_DEV=$(losetup -Pf --show "$SD_IMG")
trap "losetup -d $LOOP_DEV 2>/dev/null; echo 'Cleanup done.'" EXIT

# Format partitions
mkfs.vfat -F32 -n BOOT "${LOOP_DEV}p1"
mkfs.ext4 -F -L rootfs -q "${LOOP_DEV}p2"

# Mount and copy boot
BOOT_MNT="$OUTPUT_DIR/mnt_boot"
ROOT_MNT="$OUTPUT_DIR/mnt_root"
mkdir -p "$BOOT_MNT" "$ROOT_MNT"

mount "${LOOP_DEV}p1" "$BOOT_MNT"
cp -r "$BOOT_DIR"/* "$BOOT_MNT/"

# Mount and copy root
mount "${LOOP_DEV}p2" "$ROOT_MNT"
rsync -a "$ROOTFS_DIR/" "$ROOT_MNT/"

# Copy kernel modules from PetaLinux if available
if [ -d "$PETALINUX_IMAGES/../modules" ]; then
    rsync -a "$PETALINUX_IMAGES/../modules/" "$ROOT_MNT/lib/modules/"
fi

umount "$BOOT_MNT"
umount "$ROOT_MNT"
losetup -d "$LOOP_DEV"
trap - EXIT

# ---- Report ----
SD_SIZE=$(du -h "$SD_IMG" | cut -f1)
echo ""
echo "============================================================"
echo "  Ubuntu ${UBUNTU_RELEASE} SD card image built"
echo ""
echo "  Image:  $SD_IMG  ($SD_SIZE)"
echo ""
echo "  To flash:"
echo "    sudo dd if=$SD_IMG of=/dev/sdX bs=4M status=progress"
echo ""
echo "  Boot mode (DIP SW1): OFF-OFF-OFF-ON (SD card)"
echo "  UART console: J2 (CP2104), 115200 8N1"
echo ""
echo "  After boot, install extra packages:"
echo "    apt-get update"
echo "    apt-get install -y python3 python3-numpy python3-pip"
echo "    pip3 install pynq  # if PYNQ overlay API desired"
echo ""
echo "  CIM driver (Plan C /dev/mem approach):"
echo "    python3 -c \""
echo "    import os, mmap, struct"
echo "    fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)"
echo "    cim = mmap.mmap(fd, 0x4000, offset=0xA0000000)"
echo "    # write weights, inputs, trigger CIM..."
echo "    \""
echo "============================================================"
