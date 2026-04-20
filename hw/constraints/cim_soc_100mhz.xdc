## ============================================================================
## cim_soc_100mhz.xdc — Constraints for CIM SoC on PYNQ-Z2 at 100 MHz
## ============================================================================
## Identical to cim_soc.xdc except the clock period is 10.0 ns (100 MHz).
##
## Motivation: C1 (SPLIT_FACTOR=2) splits the 16-wide MAC chain into two
## 8-wide halves, each targeting ≤8 ns critical path. At 100 MHz (10 ns
## period) this gives ~2 ns margin — comfortably achievable.
##
## For 125 MHz (8 ns period), use cim_soc_125mhz.xdc instead.
## ============================================================================

## ============================================================================
## 1. TIMING CONSTRAINTS
## ============================================================================
## FCLK_CLK0 = 100 MHz → period = 10.000 ns
create_clock -name fclk0 -period 10.0 \
    [get_pins -quiet system_i/ps7/inst/PS7_i/FCLKCLK[0]]

## ============================================================================
## 2. FALSE PATHS / ASYNC CROSSINGS
## ============================================================================
## Single clock domain — no CDC paths.

## ============================================================================
## 3. BITSTREAM CONFIGURATION
## ============================================================================
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLDOWN [current_design]
