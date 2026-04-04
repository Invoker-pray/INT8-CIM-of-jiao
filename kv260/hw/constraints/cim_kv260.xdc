## ============================================================================
## cim_kv260.xdc — Constraints for CIM SoC on Kria KV260
## ============================================================================
## PS provides pl_clk0 (100MHz default). CIM IP is pure AXI slave,
## no PL I/O required for basic operation.
##
## KV260 has NO PL-connected LEDs (all LEDs are on PS MIO).
## UART TX and debug signals can optionally route to PMOD J2.
## ============================================================================

## ============================================================================
## 1. BITSTREAM CONFIG
## ============================================================================
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLDOWN [current_design]

## ============================================================================
## 2. PMOD J2 — Optional UART TX for PicoRV32 debug
## ============================================================================
## KV260 PMOD connector J2 pin mapping (Bank 45, LVCMOS33)
## Sources: Kria-PYNQ base.xdc, kria-vitis-platforms part0_pins.xml, UG1091
##
##   PMOD Pin   Signal      SOM Connector    FPGA Pin
##   --------   ---------   --------------   --------
##   Pin 1      HDA11       som240_1_a17     H12
##   Pin 2      HDA15       som240_1_b20     B10
##   Pin 3      HDA12       som240_1_d20     E10
##   Pin 4      HDA16_CC    som240_1_b21     E12
##   Pin 5      HDA13       som240_1_d21     D10
##   Pin 6      HDA17       som240_1_b22     D11
##   Pin 7      HDA14       som240_1_d22     C11
##   Pin 8      HDA18       som240_1_c22     B11
##   Pin 9      GND
##   Pin 10     GND
##   Pin 11     VCC3V3
##   Pin 12     VCC3V3
##
## Uncomment below if using UART TX / LED on PMOD:
##
# set_property PACKAGE_PIN H12 [get_ports uart_txd_0]
# set_property IOSTANDARD LVCMOS33 [get_ports uart_txd_0]
# set_property SLEW SLOW [get_ports uart_txd_0]
# set_property DRIVE 12 [get_ports uart_txd_0]
#
# set_property PACKAGE_PIN B10 [get_ports cim_done_irq_0]
# set_property IOSTANDARD LVCMOS33 [get_ports cim_done_irq_0]

## ============================================================================
## 3. NOTES
## ============================================================================
## - ARM-controlled CIM (Step 2 port): NO PL I/O needed at all.
##   All communication is via AXI. XDC only needs bitstream config.
##
## - PicoRV32 version (Step 4 port): UART TX goes to PMOD J2 pin 1.
##   Uncomment the pin constraints above.
##
## - If timing fails at 100MHz, try reducing to 75MHz in vivado_build.tcl
##   and update cim_rv32_top.sv CLK_FREQ parameter accordingly.
