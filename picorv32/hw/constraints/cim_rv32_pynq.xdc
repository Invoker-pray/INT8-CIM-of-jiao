## ============================================================================
## cim_rv32_pynq.xdc — Constraints for PicoRV32 + CIM SoC (Hybrid PS+PL)
## ===========================================================================
## PS provides FCLK_CLK0, frequency configured in vivado_build_*.tcl via
## PCW_FPGA0_PERIPHERAL_FREQMHZ. Vivado auto-generates clock constraints
## from the Block Design. No manual create_clock needed — it would conflict
## with BD-generated constraints. Use vivado_build_<freq>.{sh,tcl}.
## ===========================================================================

## ===========================================================================
## 1. TIMING CONSTRAINT — PS7 auto-generated, no manual create_clock
## ===========================================================================
## Legacy create_clock (commented — PS7 BD provides clock):
## create_clock -name fclk0 -period 10.000 \
##     [get_pins -quiet system_i/ps7/inst/PS7_i/FCLKCLK[0]]

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
## 4. Max fanout constraint — reduce x_eff_reg fanout at 100MHz
## ============================================================================
## The x_eff_reg drives 16×PAR_OB DSP48 inputs; limiting fanout forces
## Vivado to replicate registers, reducing net delay on critical paths.
set_property MAX_FANOUT 16 [get_cells -hierarchical -filter {NAME =~ *x_eff_reg*}]

## ============================================================================
## 5. BITSTREAM CONFIG
## ============================================================================
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLDOWN [current_design]

## C4: limit fanout on phase-latched signals driving DSP48 inputs
set_property MAX_FANOUT 32 [get_cells -hier -filter {NAME =~ *x_eff_latched_reg*}]
set_property MAX_FANOUT 48 [get_cells -hier -filter {NAME =~ *w_tile_latched_reg*}]
