## ============================================================================
## cim_soc_125mhz.xdc — Constraints for CIM SoC on PYNQ-Z2 at 125 MHz
## ============================================================================
## Identical to cim_soc.xdc except the clock period is 8.0 ns (125 MHz).
##
## Motivation: C1 (SPLIT_FACTOR=2) splits the 16-wide MAC chain into two
## 8-wide halves, each targeting ≤8 ns critical path. At 125 MHz (8 ns
## period) this is tight — margin is ~0.1 ns or less.
##
## If timing fails at 125 MHz, fall back to:
##   - 120 MHz (8.33 ns period): use cim_soc_120mhz.xdc (create if needed)
##   - 100 MHz (10.0 ns period): use cim_soc_100mhz.xdc
## ============================================================================

## ============================================================================
## 1. TIMING CONSTRAINTS
## ============================================================================
## FCLK_CLK0 = 125 MHz → period = 8.000 ns
create_clock -name fclk0 -period 8.0 \
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
