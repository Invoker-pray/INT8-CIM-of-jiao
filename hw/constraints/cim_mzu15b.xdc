## ============================================================================
## cim_mzu15b.xdc — Constraints for CIM SoC on MZU15B (XCZU15EG)
## ============================================================================
## ARM-direct architecture: PS (A53) → CIM + axi_dma via AXI HPM0/HPM1 + HP0/HP1
## ============================================================================

## ============================================================================
## 1. CLOCK — pl_clk0 = 100 MHz
## ============================================================================
create_clock -name pl_clk0 -period 10.000 [get_ports -quiet pl_clk0]

## ============================================================================
## 2. BITSTREAM CONFIG
## ============================================================================
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLDOWN [current_design]
set_property CONFIG_VOLTAGE 1.8 [current_design]
