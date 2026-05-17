## ============================================================================
## cim_mzu15b.xdc — Constraints for CIM SoC on MZU15B (XCZU15EG)
## ============================================================================
## ARM-direct architecture: PS (A53) → CIM + axi_dma via AXI HPM0/HPM1 + HP0/HP1
## ============================================================================

## ============================================================================
## 1. CLOCK — pl_clk0 = 100 MHz
## ============================================================================
## Clock auto-propagated from PS: CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ=100

## ============================================================================
## 2. BITSTREAM CONFIG
## ============================================================================
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLDOWN [current_design]
## CONFIG_VOLTAGE not supported on XCZU15EG — removed
