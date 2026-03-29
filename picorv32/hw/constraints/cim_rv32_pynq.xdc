## ============================================================================
## cim_rv32_pynq.xdc — Constraints for PicoRV32 + CIM SoC (Hybrid PS+PL)
## ============================================================================
## PS provides FCLK_CLK0 (50MHz), no external clock/MMCM needed.
## Only constrain PL I/O pins: UART TX + LEDs.
## ============================================================================

## ============================================================================
## 1. UART TX (PMOD-A pin 1)
## ============================================================================
set_property PACKAGE_PIN Y18 [get_ports uart_txd_0]
set_property IOSTANDARD LVCMOS33 [get_ports uart_txd_0]
set_property SLEW SLOW [get_ports uart_txd_0]
set_property DRIVE 12 [get_ports uart_txd_0]

## ============================================================================
## 2. LEDs
## ============================================================================
set_property PACKAGE_PIN R14 [get_ports cim_done_irq_0]
set_property IOSTANDARD LVCMOS33 [get_ports cim_done_irq_0]

## ============================================================================
## 3. BITSTREAM CONFIG
## ============================================================================
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLDOWN [current_design]
