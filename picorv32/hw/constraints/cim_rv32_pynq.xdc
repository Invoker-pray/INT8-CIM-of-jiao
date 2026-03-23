## ============================================================================
## cim_rv32_pynq.xdc — Constraints for PicoRV32 + CIM SoC on PYNQ-Z2
## ============================================================================
## Pure PL design (no Zynq PS). Top module: cim_rv32_fpga_top
##
## Pin map:
##   sys_clk_125   : H16  (125MHz oscillator)
##   btn_rst       : D19  (BTN0, active-high)
##   uart_txd      : Y18  (PMODA pin 1 → connect USB-TTL RXD here)
##   led_done      : R14  (LED0, CIM done_irq)
##   led_heartbeat : P14  (LED1, ~1Hz blink)
## ============================================================================

## ============================================================================
## 1. CLOCK
## ============================================================================
## PYNQ-Z2 board has a 125MHz oscillator connected to H16 (LVCMOS33).
## The MMCM inside cim_rv32_fpga_top derives 60MHz from this.

set_property PACKAGE_PIN H16 [get_ports sys_clk_125]
set_property IOSTANDARD LVCMOS33 [get_ports sys_clk_125]
create_clock -name sys_clk -period 8.000 [get_ports sys_clk_125]

## ============================================================================
## 2. RESET BUTTON
## ============================================================================
## BTN0 active-high push button

set_property PACKAGE_PIN D19 [get_ports btn_rst]
set_property IOSTANDARD LVCMOS33 [get_ports btn_rst]

## ============================================================================
## 3. UART TX (PMOD-A pin 1)
## ============================================================================
## Connect a USB-TTL adapter to this pin (adapter RXD ← FPGA TXD).
## Settings: 115200 baud, 8N1, no flow control.

set_property PACKAGE_PIN Y18 [get_ports uart_txd]
set_property IOSTANDARD LVCMOS33 [get_ports uart_txd]
set_property SLEW SLOW [get_ports uart_txd]
set_property DRIVE 12 [get_ports uart_txd]

## ============================================================================
## 4. LEDs
## ============================================================================

set_property PACKAGE_PIN R14 [get_ports led_done]
set_property IOSTANDARD LVCMOS33 [get_ports led_done]

set_property PACKAGE_PIN P14 [get_ports led_heartbeat]
set_property IOSTANDARD LVCMOS33 [get_ports led_heartbeat]

## ============================================================================
## 5. TIMING
## ============================================================================
## The MMCM generates the 60MHz clock internally.
## Vivado auto-propagates MMCM output clocks, so no additional create_clock
## is needed for clk_60m. We only set false paths on the async reset.

set_false_path -from [get_ports btn_rst]

## ============================================================================
## 6. BITSTREAM CONFIG
## ============================================================================

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLDOWN [current_design]
