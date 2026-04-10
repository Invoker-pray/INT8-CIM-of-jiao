## ============================================================================
## cim_soc_55mhz.xdc — Constraints for CIM SoC on PYNQ-Z2 at 55 MHz
## ============================================================================
## Identical to cim_soc.xdc except the clock period is 18.182 ns (55 MHz).
##
## Motivation: the 60 MHz build has WNS = -0.086 ns on 3 endpoints in the
## CIM Tile MAC chain. Dropping to 55 MHz gives ~1.5 ns positive margin on
## the same critical path, achieving clean timing closure.
## ============================================================================

## ============================================================================
## 1. TIMING CONSTRAINTS
## ============================================================================
## FCLK_CLK0 = 55 MHz → period = 18.182 ns
create_clock -name fclk0 -period 18.182 \
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
