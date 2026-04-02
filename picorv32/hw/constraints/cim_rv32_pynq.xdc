## ============================================================================
## cim_rv32_pynq.xdc — Constraints for PicoRV32 + CIM SoC (Hybrid PS+PL)
## ============================================================================
## PS provides FCLK_CLK0 (50 MHz), configured in vivado_build.tcl.
## This file must define the clock explicitly for correct timing analysis.
## ============================================================================

## ============================================================================
## 1. TIMING CONSTRAINT — FCLK_CLK0
## ============================================================================
## FCLK_CLK0 = 50 MHz -> period = 20.000 ns
##
## The PS7 IP auto-creates a clock object for FCLK_CLK0, but we define it
## explicitly to ensure timing analysis uses the correct period and to give
## the clock a readable name in timing reports.
##
## IMPORTANT: If you change PCW_FPGA0_PERIPHERAL_FREQMHZ in the TCL script,
## update the period here accordingly:
##   50 MHz  -> 20.000 ns
##   60 MHz  -> 16.667 ns
##   62.5MHz -> 16.000 ns
##
## The get_pins -quiet avoids errors if the exact pin path differs between
## Vivado versions; the PS7-generated clock will still be used as fallback.
create_clock -name fclk0 -period 20.000 \
    [get_pins -quiet system_i/ps7/inst/PS7_i/FCLKCLK[0]]

## ============================================================================
## 2. UART TX (PMOD-A pin 1)
## ============================================================================
set_property PACKAGE_PIN Y18 [get_ports uart_txd_0]
set_property IOSTANDARD LVCMOS33 [get_ports uart_txd_0]
set_property SLEW SLOW [get_ports uart_txd_0]
set_property DRIVE 12 [get_ports uart_txd_0]

## ============================================================================
## 3. LEDs (cim_done_irq -> LED0 for visual feedback)
## ============================================================================
set_property PACKAGE_PIN R14 [get_ports cim_done_irq_0]
set_property IOSTANDARD LVCMOS33 [get_ports cim_done_irq_0]

## ============================================================================
## 4. FALSE PATHS / ASYNC CROSSINGS
## ============================================================================
## Single clock domain (FCLK_CLK0), no CDC paths to constrain.
## cpu_rst_n comes from AXI GPIO (same clock domain), no false path needed.

## ============================================================================
## 5. BITSTREAM CONFIG
## ============================================================================
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLDOWN [current_design]
