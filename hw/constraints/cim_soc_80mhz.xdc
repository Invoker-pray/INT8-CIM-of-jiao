## ============================================================================
## cim_soc_80mhz.xdc — Constraints for CIM SoC on PYNQ-Z2 at 80 MHz
## ============================================================================
## FCLK_CLK0 = 80 MHz → period = 12.5 ns
## Target: SPLIT=4 + barrel shifter pipeline split; address calc path ~10.2 ns
## should fit with ~2.3 ns margin.
## ============================================================================

create_clock -name fclk0 -period 12.5 \
    [get_pins -quiet system_i/ps7/inst/PS7_i/FCLKCLK[0]]

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLDOWN [current_design]
