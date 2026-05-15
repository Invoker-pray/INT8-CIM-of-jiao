# MZU15B PicoRV32 Port

PicoRV32 + CIM SoC on MZU15B-488A development board (XCZU15EG-FFVB1156-2-I).

## Quick Start

```bash
# Build bitstream (Vivado 2024.2+)
vivado -mode batch -source mzu15b/hw/scripts/vivado_build_rv32.tcl

# Output: mzu15b/vivado_rv32_proj/deploy/cim_rv32_mzu15b.bit
```

### PS DDR Configuration

MZU15B has no official Vivado board_part. Before building, you MUST configure PS DDR:

1. Open in Vivado GUI: `vivado mzu15b/vivado_rv32_proj/cim_rv32_mzu15b.xpr`
2. Double-click `ps_e` → DDR Configuration
3. Configure DDR4 for the 5× MT40A512M16LY-062E chips (per schematic)
4. Save BD, generate bitstream

Alternatively, use a pre-configured PCW file from PetaLinux:

```tcl
# In Vivado TCL console:
source /path/to/ps_config.tcl  # sets PS DDR, MIO, clocks
```

## Parameters (vs PYNQ-Z2)

| Parameter | PYNQ-Z2 | MZU15B | Reason |
|-----------|---------|--------|--------|
| MAX_IN_DIM | 1536 | **4096** | YOLO im2col: 3×3×256=2304 |
| MAX_OUT_DIM | 256 | **1024** | Larger FC layers / more channels |
| PAR_OB | 4 | **8** | 3528 DSP → 2048 used (58%) |
| FCLK | 100 MHz | **100 MHz** (start) | Conservative; 150+ feasible |
| FW_DEPTH | 8192 (32KB) | 8192 (32KB, **configurable**) | Future: increase for larger models |

## Address Map

| Device | AXI HPM0_FPD Address | Size |
|--------|---------------------|------|
| FW BRAM | `0xA000_0000` | 32 KB |
| Result BRAM | `0xA200_0000` | 256 B |
| AXI GPIO | `0xA300_0000` | 4 KB |

## PS↔PL Communication (Plan C)

No PYNQ required. Uses `/dev/mem` for direct MMIO:

```python
import os, mmap, struct, time

fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)

# Map peripherals
fw  = mmap.mmap(fd, 0x8000, offset=0xA0000000)
res = mmap.mmap(fd, 0x1000, offset=0xA2000000)
gpio= mmap.mmap(fd, 0x1000, offset=0xA3000000)

# Hold CPU, load firmware, release
gpio[0:4] = struct.pack('<I', 0)
fw[:fw_size] = firmware_bytes
gpio[0:4] = struct.pack('<I', 1)

# Poll for completion
MAGIC = 0xC1AA0001
while struct.unpack('<I', res[0:4])[0] != MAGIC:
    time.sleep(0.001)

pred = struct.unpack('<I', res[4:8])[0]
print(f"Prediction: {pred}")
```

## PicoRV32 Firmware

Build firmware as on PYNQ-Z2:

```bash
cd picorv32/fw
make
python3 verilog_byte_to_word.py firmware.bin fw_words.bin
```

`fw_words.bin` is the binary to write to FW BRAM at `0xA000_0000`.

## Key Difference from PYNQ-Z2

- PYNQ-Z2 uses Zynq-7000 (PS7), MZU15B uses Zynq UltraScale+ MPSoC (zynq_ultra_ps_e)
- MPSoC uses `pl_clk0` (not `FCLK_CLK0`), `pl_resetn0` (not `FCLK_RESET0_N`)
- MPSoC AXI HPM0 default base is `0xA000_0000` (not `0x4000_0000`)
- MPSoC requires explicit `pl_clk0 → maxihpm0_fpd_aclk` connection
- IOSTANDARD likely LVCMOS18 on HP banks (not LVCMOS33 on HR banks)

## Files

```
mzu15b/
├── hw/
│   ├── scripts/
│   │   └── vivado_build_rv32.tcl    # PicoRV32 build
│   └── constraints/
│       └── cim_rv32_mzu15b.xdc      # Pin/timing constraints
├── sw/                               # Plan C Python driver (TODO)
└── README.md
```
