# ============================================================================
# Makefile — Build RISC-V firmware for CIM SoC
# ============================================================================
# Prerequisites:
#   - RISC-V GCC toolchain (riscv64-unknown-elf-gcc with rv32im support)
#   - Python 3 (for gen_fw_data.py)
#   - mnist_real_data/ directory (from generate_mnist_data.ipynb)
#
# Usage:
#   make                  # build firmware.hex (default test image 0)
#   make IMAGE_IDX=5      # use test image #5
#   make DATA_DIR=lenet5_data  # use different model data
#   make clean
# ============================================================================

# Toolchain prefix — adjust if your toolchain has a different name
CROSS   = riscv64-elf-
CC      = $(CROSS)gcc
OBJCOPY = $(CROSS)objcopy
OBJDUMP = $(CROSS)objdump
SIZE    = $(CROSS)size

# Architecture flags
ARCH    = -march=rv32im -mabi=ilp32

# Compiler flags
CFLAGS  = $(ARCH) -Os -Wall -nostdlib -ffreestanding
LDFLAGS = $(ARCH) -nostdlib -T firmware.lds -Wl,--no-relax

# Data source
DATA_DIR  ?= mnist_real_data
IMAGE_IDX ?= 0

# Source files
SRCS    = start.S firmware.c model_data.c
OBJS    = $(SRCS:.c=.o)
OBJS    := $(OBJS:.S=.o)

# Targets
.PHONY: all clean data

all: firmware.hex firmware.bin firmware.lst

# Generate C data file from hex exports
model_data.c: gen_fw_data.py
	python3 gen_fw_data.py --data-dir $(DATA_DIR) --image-idx $(IMAGE_IDX) --output $@

# Compile
%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

%.o: %.S
	$(CC) $(CFLAGS) -c -o $@ $<

# Link
firmware.elf: $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $^
	$(SIZE) $@

# Convert to Verilog hex (for $readmemh)
firmware.hex: firmware.elf
	$(OBJCOPY) -O verilog $< $@
	@echo "=== firmware.hex generated ==="
	@echo "Copy to RTL sim directory or Vivado project"

# Binary (for reference)
firmware.bin: firmware.elf
	$(OBJCOPY) -O binary $< $@

# Disassembly listing
firmware.lst: firmware.elf
	$(OBJDUMP) -d -S $< > $@

clean:
	rm -f *.o *.elf *.hex *.bin *.lst model_data.c
