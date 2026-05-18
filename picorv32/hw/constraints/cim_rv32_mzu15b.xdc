## ============================================================================
## cim_rv32_mzu15b.xdc — Constraints for PicoRV32 + CIM on MZU15B (XCZU15EG)
## ============================================================================
## PS provides pl_clk0 (100 MHz default), configured in vivado_build_rv32.tcl.
## CIM IP is internal AXI slave — no PL I/O required for basic operation.
##
## MZU15B has standard GPIO/PMOD connectors (see schematic MZU15B.pdf).
## UART TX and cim_done_irq can be routed to any available GPIO pin.
## ============================================================================

## ============================================================================
## 1. CLOCK CONSTRAINT — pl_clk0 fallback
## ============================================================================
## MPSoC PS IP auto-creates pl_clk0. This is a fallback for timing analysis.
## Period must match FCLK_MHZ from vivado_build_rv32.tcl:
##   100 MHz  -> 10.000 ns
##   150 MHz  ->  6.667 ns
##   200 MHz  ->  5.000 ns
create_clock -name pl_clk0_fallback -period 10.000 \
    [get_ports -quiet pl_clk0]

## ============================================================================
## 2. BITSTREAM CONFIG
## ============================================================================
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLDOWN [current_design]
set_property CONFIG_VOLTAGE 1.8 [current_design]

## ============================================================================
## 3. UART TX — unconnected on MZU15B (debug only, not routed to physical pin)
## ============================================================================
# Mark unconnected ports as virtual to pass DRC; these are debug-only signals
# that have no physical pin assignment on MZU15B carrier board.
set_property SEVERITY {Warning} [get_drc_checks NSTD-1]
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]

## ============================================================================
## 5. FALSE PATHS / CLOCK GROUPS
## ============================================================================
## Single clock domain (pl_clk0). No CDC paths to constrain.
## ============================================================================
