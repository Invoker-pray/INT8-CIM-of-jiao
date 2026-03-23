#!/usr/bin/env python3
"""
Convert `objcopy -O verilog` byte-hex to $readmemh 32-bit word-hex.

objcopy output format (bytes):
    @00000000
    37 81 00 00 13 01 C1 FF ...

Required $readmemh format (32-bit LE words):
    @00000000
    00008137
    FFC10113
    ...
"""

import sys, re


def convert(in_path, out_path):
    bytes_dict = {}  # byte_addr -> byte_value

    with open(in_path, "r") as f:
        addr = 0
        for line in f:
            line = line.strip().replace("\r", "")
            if not line:
                continue
            if line.startswith("@"):
                addr = int(line[1:], 16)
                continue
            tokens = line.split()
            for tok in tokens:
                tok = tok.strip()
                if re.fullmatch(r"[0-9A-Fa-f]{1,2}", tok):
                    bytes_dict[addr] = int(tok, 16)
                    addr += 1

    if not bytes_dict:
        print("WARNING: no data found in input file", file=sys.stderr)
        return

    max_addr = max(bytes_dict.keys())

    with open(out_path, "w") as f:
        # Process in 4-byte (word) chunks, little-endian
        word_addr = 0
        byte_addr = 0
        while byte_addr <= max_addr:
            # Check if we need an @address marker (for non-contiguous segments)
            b0 = bytes_dict.get(byte_addr, 0)
            b1 = bytes_dict.get(byte_addr + 1, 0)
            b2 = bytes_dict.get(byte_addr + 2, 0)
            b3 = bytes_dict.get(byte_addr + 3, 0)
            # Little-endian: byte 0 is LSB
            word = (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
            f.write(f"{word:08X}\n")
            byte_addr += 4
            word_addr += 1

    print(
        f"Converted {word_addr} words ({word_addr * 4} bytes) -> {out_path}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} input.hex output.hex", file=sys.stderr)
        sys.exit(1)
    convert(sys.argv[1], sys.argv[2])
