## ============================================================================
## cim_soc_70mhz.xdc — Constraints for CIM SoC on PYNQ-Z2 at 70 MHz
## ============================================================================
## FCLK_CLK0 = 70 MHz → period = 14.286 ns
## Conservative target: requantize path (~14.8 ns) should fit with ~0.5 ns margin.
## ============================================================================

create_clock -name fclk0 -period 14.286 \
    [get_pins -quiet system_i/ps7/inst/PS7_i/FCLKCLK[0]]

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLDOWN [current_design]
