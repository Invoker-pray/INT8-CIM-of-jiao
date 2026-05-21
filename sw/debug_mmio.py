#!/usr/bin/env python3
"""Minimal /dev/mem MMIO test — isolate AXI bus hang on MZU15B."""

import os, struct, mmap, sys

def try_read(addr, label, size=0x1000):
    """Try to mmap and read from a physical address."""
    try:
        fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
        m = mmap.mmap(fd, size, offset=addr)
        # Read first 8 bytes and print
        val0 = struct.unpack("<I", m[0:4])[0]
        val4 = struct.unpack("<I", m[4:8])[0]
        print(f"[OK]  {label} @ 0x{addr:08X}: +0x00=0x{val0:08X}, +0x04=0x{val4:08X}")
        m.close()
        os.close(fd)
        return True
    except Exception as e:
        print(f"[FAIL] {label} @ 0x{addr:08X}: {e}")
        return False

if __name__ == "__main__":
    print("=== MZU15B MMIO Debug ===")

    # Test 1: PS register (should always work)
    # PL0_REF_CTRL @ 0xFF5E00C0 — configures PL clock 0
    print("\n--- PS registers (internal, should always work) ---")
    try_read(0xFF5E00C0, "PL0_REF_CTRL")

    # Test 2: GPIO register (PS, always accessible)
    try_read(0xFF0A0000, "GPIO_DATA_0")

    # Test 3: CIM @ 0xA0000000 — THE PROBLEM ADDRESS
    print("\n--- CIM PL register (0xA0000000) ---")
    print("WARNING: this may HANG the system if the bus locks up!")
    print("If you see this and the system hangs, issue is CIM/PL access.")
    sys.stdout.flush()
    try_read(0xA0000000, "CIM_CTRL")

    print("\nAll tests completed without hang.")
