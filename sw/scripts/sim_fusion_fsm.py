#!/usr/bin/env python3
"""Cycle-accurate Python simulation of the fusion FSM from cim_axi_lite_slave.sv.

Models actual RTL behavior: part-select NBA assigns replace bytes without OR.
Pipeline: addr set at end of cycle N → OBUF BRAM captures at posedge N+1 →
          data valid at start of cycle N+2 → FSM captures during cycle N+2.

Usage: python3 sw/scripts/sim_fusion_fsm.py
"""

import numpy as np

N_BYTES = 128
TILE_COLS = 16


def set_byte(word, pos, val):
    """Replace byte at position `pos` in 128-bit word. Models Verilog part-select."""
    mask = ~(0xFF << (pos * 8)) & ((1 << 128) - 1)
    return (word & mask) | ((int(val) & 0xFF) << (pos * 8))


def sim_fusion_v7(obuf_data, n_bytes):
    """v7 FSM: F_WAIT_MUX captures byte 0, no F_RD_FIRST.

    Hardware pipeline (1-stage registered BRAM read):
      - End of cycle N (NBA): obuf_rd_addr set to X
      - Start of cycle N+1 (posedge): rd_data = bank[X] (registered)
      - MUX is always_comb — no extra pipeline stage.
    """
    state = "IDLE"
    cnt = 0; bit = 0; buf = 0; tidx = 0; oaddr = 0; busy = False
    rd = 0; rd_scheduled = 0

    tiles = {}
    cycle = 0; done = False

    while not done:
        # START of cycle: rd_data captured from address set at end of
        # PREVIOUS cycle (1-stage BRAM pipeline).
        rd = rd_scheduled

        last = (cnt + 1 >= n_bytes)
        full = (bit == 15)

        ns = state; nc = cnt; nb = bit; nbuf = buf
        nti = tidx; noa = oaddr; nbusy = busy; wr = False

        if state == "IDLE":
            if cycle == 0:
                nbusy = True; nc = 0; nb = 0; nbuf = 0; nti = 0; noa = 0
                ns = "WAIT_MUX"

        elif state == "WAIT_MUX":
            # At start of this cycle, OBUF captured bank[0] (addr=0 was set
            # in F_IDLE NBA). rd_data = OBUF[0]. Capture it.
            nbuf = set_byte(buf, 0, rd); nb = 1; nc = cnt + 1
            if last: ns = "WRITE"
            else: noa = oaddr + 1; ns = "PACK"

        elif state == "PACK":
            nbuf = set_byte(buf, bit, rd); nb = bit + 1; nc = cnt + 1
            if full or last: ns = "WRITE"
            else: noa = oaddr + 1

        elif state == "WRITE":
            wr = True; nb = 0; nti = tidx + 1
            if last: nbusy = False; ns = "IDLE"; done = True
            else: noa = oaddr + 1; ns = "PACK"

        if wr:
            tiles[tidx] = buf

        # Schedule OBUF read: address set in this cycle's NBA will produce
        # data at the START of the next cycle (1-stage BRAM pipeline).
        rd_scheduled = int(obuf_data[noa]) if noa < len(obuf_data) else 0

        state = ns; cnt = nc; bit = nb; buf = nbuf
        tidx = nti; oaddr = noa; busy = nbusy
        cycle += 1
        if cycle > 300: break

    return tiles, cycle


def sim_fusion_v5(obuf_data, n_bytes):
    """v5 FSM (no F_WAIT_MUX) — for comparison."""
    state = "IDLE"
    cnt = 0; bit = 0; buf = 0; tidx = 0; oaddr = 0; busy = False
    rd = 0; rd_scheduled = 0

    tiles = {}
    cycle = 0; done = False

    while not done:
        rd = rd_scheduled

        last = (cnt + 1 >= n_bytes)
        full = (bit == 15)

        ns = state; nc = cnt; nb = bit; nbuf = buf
        nti = tidx; noa = oaddr; nbusy = busy; wr = False

        if state == "IDLE":
            if cycle == 0:
                nbusy = True; nc = 0; nb = 0; nbuf = 0; nti = 0; noa = 0
                ns = "RD_FIRST"  # v5: skip WAIT_MUX
        elif state == "RD_FIRST":
            nbuf = set_byte(buf, 0, rd); nb = 1; nc = cnt + 1
            if last: ns = "WRITE"
            else: noa = oaddr + 1; ns = "PACK"
        elif state == "PACK":
            nbuf = set_byte(buf, bit, rd); nb = bit + 1; nc = cnt + 1
            if full or last: ns = "WRITE"
            else: noa = oaddr + 1
        elif state == "WRITE":
            wr = True; nb = 0; nti = tidx + 1
            if last: nbusy = False; ns = "IDLE"; done = True
            else: noa = oaddr + 1; ns = "PACK"

        if wr:
            tiles[tidx] = buf

        rd_scheduled = int(obuf_data[noa]) if noa < len(obuf_data) else 0

        state = ns; cnt = nc; bit = nb; buf = nbuf
        tidx = nti; oaddr = noa; busy = nbusy
        cycle += 1
        if cycle > 300: break

    return tiles, cycle


def expected_ibuf(obuf_data, n_bytes):
    tiles = [0] * ((n_bytes + TILE_COLS - 1) // TILE_COLS)
    for i in range(n_bytes):
        tiles[i // 16] |= int(obuf_data[i]) << ((i % 16) * 8)
    return tiles


# ============================================================================
obuf = np.arange(N_BYTES, dtype=np.uint8)
expected = expected_ibuf(obuf, N_BYTES)

print("=" * 70)
print("Fusion FSM Simulation (corrected part-select model)")
print("=" * 70)

tiles_v7, cycles_v7 = sim_fusion_v7(obuf, N_BYTES)
print(f"\n--- v7 (F_WAIT_MUX captures byte 0) — {cycles_v7} cycles ---")
all_ok = True
for i in range(len(expected)):
    if i in tiles_v7:
        b = [(tiles_v7[i] >> (j*8)) & 0xFF for j in range(16)]
        exp = [(expected[i] >> (j*8)) & 0xFF for j in range(16)]
        ok = b == exp
        if not ok: all_ok = False
        print(f"  Tile {i}: {b}  {'OK' if ok else f'BAD exp={exp}'}")
    else:
        print(f"  Tile {i}: NOT WRITTEN")
        all_ok = False
print(f"  Result: {'PASS' if all_ok else 'FAIL'}")

tiles_v5, cycles_v5 = sim_fusion_v5(obuf, N_BYTES)
print(f"\n--- v5 (no F_WAIT_MUX) — {cycles_v5} cycles ---")
all_ok5 = True
for i in range(len(expected)):
    if i in tiles_v5:
        b = [(tiles_v5[i] >> (j*8)) & 0xFF for j in range(16)]
        exp = [(expected[i] >> (j*8)) & 0xFF for j in range(16)]
        ok = b == exp
        if not ok: all_ok5 = False
        print(f"  Tile {i}: {b}  {'OK' if ok else f'BAD exp={exp}'}")
    else:
        print(f"  Tile {i}: NOT WRITTEN")
        all_ok5 = False
print(f"  Result: {'PASS' if all_ok5 else 'FAIL'}")

print(f"\nv7 cycles: {cycles_v7}, v5 cycles: {cycles_v5}")
