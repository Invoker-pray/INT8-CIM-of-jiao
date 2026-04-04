# ============================================================================
# vivado_build_rv32_kv260.tcl — PicoRV32 + CIM SoC on Kria KV260
# ============================================================================
# Port of picorv32/hw/scripts/vivado_build.tcl from PYNQ-Z2 to KV260.
# PicoRV32 runs in PL, PS only provides clock and AXI access to BRAM/GPIO.
#
# Usage: vivado -mode batch -source kv260/hw/scripts/vivado_build_rv32_kv260.tcl
#
# PS AXI address map (M_AXI_HPM0_FPD):
#   0xA000_0000 (32KB) : FW BRAM port B    — PS writes firmware here
#   0xA200_0000 (4KB)  : Result BRAM port B — PS reads inference results
#   0xA300_0000 (4KB)  : AXI GPIO          — bit[0] = cpu_rst_n (0=hold,1=run)
#
# Workflow (PYNQ Python):
#   gpio.write(0, 0)        # hold CPU
#   fw_mmio.write(i*4, w)   # write firmware words
#   gpio.write(0, 1)        # release CPU
#   while res_mmio.read(0) != 0xC1AA0001: sleep
#   pred = res_mmio.read(4) # read result
# ============================================================================

# --- Configuration ---
set PROJ_NAME  "cim_rv32_kv260"
set PART       "xck26-sfvc784-2LV-c"
set BOARD_PART "xilinx.com:kv260_som:part0:1.4"
set FCLK_MHZ   100
set N_JOBS     4
set CIM_HW     "hw"
set RV_HW      "picorv32/hw"
set OUT_DIR    "kv260/vivado_rv32_proj"

puts "============================================================"
puts "CIM SoC — KV260 Build (PicoRV32 control)"
puts "============================================================"

# ============================================================================
# 1. Create project
# ============================================================================
create_project ${PROJ_NAME} ./${OUT_DIR} -part ${PART} -force

if {![catch {set_property board_part ${BOARD_PART} [current_project]}]} {
    puts "INFO: KV260 board part applied."
} else {
    puts "WARN: Board part not found. Install KV260 board files."
    puts "  https://github.com/Xilinx/XilinxBoardStore"
}

# ============================================================================
# 2. Add RTL sources
# ============================================================================
set all_files [list \
    ${CIM_HW}/rtl/pkg/cim_pkg.sv \
    ${CIM_HW}/rtl/core/cim_tile.sv \
    ${CIM_HW}/rtl/core/psum_accum.sv \
    ${CIM_HW}/rtl/mem/weight_sram.sv \
    ${CIM_HW}/rtl/mem/bias_sram.sv \
    ${CIM_HW}/rtl/mem/input_buffer.sv \
    ${CIM_HW}/rtl/mem/output_buffer.sv \
    ${CIM_HW}/rtl/core/cim_accel_core.sv \
    ${CIM_HW}/rtl/axi/cim_axi_lite_slave.sv \
    ${CIM_HW}/rtl/axi/cim_axi_lite_slave_wrapper.v \
    ${RV_HW}/rtl/riscv/picorv32.v \
    ${RV_HW}/rtl/riscv/uart_tx.sv \
    ${RV_HW}/rtl/riscv/picorv32_cim_bridge.sv \
    ${RV_HW}/rtl/riscv/cim_rv32_top.sv \
    ${RV_HW}/rtl/riscv/cim_rv32_top_wrapper.v \
]
add_files -norecurse ${all_files}
add_files -fileset constrs_1 -norecurse kv260/hw/constraints/cim_kv260.xdc

set_property file_type SystemVerilog [get_files *.sv]
set_property file_type Verilog       [get_files *.v]
update_compile_order -fileset sources_1

puts "INFO: Added [llength ${all_files}] RTL source files."

# ============================================================================
# 3. Block Design
# ============================================================================
create_bd_design "system"

# ---- 3a. Zynq UltraScale+ MPSoC ----
create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.5 ps_e

if {![catch {apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config {apply_board_preset "1"} [get_bd_cells ps_e]}]} {
    puts "INFO: MPSoC board automation applied."
}

set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0                   {1} \
    CONFIG.PSU__FPGA_PL0_ENABLE                  {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ  ${FCLK_MHZ} \
] [get_bd_cells ps_e]

# MPSoC requires explicit clock connection to AXI master port
connect_bd_net [get_bd_pins ps_e/pl_clk0] [get_bd_pins ps_e/maxihpm0_fpd_aclk]

# ---- 3b. rv32_soc (module reference) ----
create_bd_cell -type module -reference cim_rv32_top_wrapper rv32

# Set FREQ_HZ on rv32/clk so Vivado propagates clock for timing
set fclk_hz [expr {${FCLK_MHZ} * 1000000}]
set_property CONFIG.FREQ_HZ ${fclk_hz} [get_bd_pins rv32/clk]

# ---- 3c. Reset ----
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_ps
connect_bd_net [get_bd_pins ps_e/pl_clk0]              [get_bd_pins rst_ps/slowest_sync_clk]
connect_bd_net [get_bd_pins ps_e/pl_resetn0]            [get_bd_pins rst_ps/ext_reset_in]
connect_bd_net [get_bd_pins ps_e/pl_clk0]              [get_bd_pins rv32/clk]
connect_bd_net [get_bd_pins rst_ps/peripheral_aresetn]  [get_bd_pins rv32/rst_n]

# ---- 3d. AXI GPIO for cpu_rst_n ----
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 gpio_cpu_rst
set_property -dict [list \
    CONFIG.C_GPIO_WIDTH    {1} \
    CONFIG.C_ALL_OUTPUTS   {1} \
    CONFIG.C_DOUT_DEFAULT  {0x00000000} \
] [get_bd_cells gpio_cpu_rst]
connect_bd_net [get_bd_pins gpio_cpu_rst/gpio_io_o] [get_bd_pins rv32/cpu_rst_n]

# ---- 3e. FW BRAM Controller (32KB, port B) ----
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 fw_bram_ctrl
set_property -dict [list \
    CONFIG.SINGLE_PORT_BRAM {1} \
    CONFIG.DATA_WIDTH       {32} \
    CONFIG.PROTOCOL         {AXI4LITE} \
] [get_bd_cells fw_bram_ctrl]

connect_bd_net [get_bd_pins fw_bram_ctrl/bram_en_a]     [get_bd_pins rv32/fw_b_en]
connect_bd_net [get_bd_pins fw_bram_ctrl/bram_we_a]     [get_bd_pins rv32/fw_b_we]
connect_bd_net [get_bd_pins fw_bram_ctrl/bram_wrdata_a] [get_bd_pins rv32/fw_b_wdata]
connect_bd_net [get_bd_pins fw_bram_ctrl/bram_rddata_a] [get_bd_pins rv32/fw_b_rdata]

# Address slice: extract [14:0] from BRAM ctrl's wider address bus
create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 fw_addr_slice
set_property -dict [list \
    CONFIG.DIN_WIDTH  {32} \
    CONFIG.DIN_FROM   {14} \
    CONFIG.DIN_TO     {0} \
    CONFIG.DOUT_WIDTH {15} \
] [get_bd_cells fw_addr_slice]
connect_bd_net [get_bd_pins fw_bram_ctrl/bram_addr_a] [get_bd_pins fw_addr_slice/Din]
connect_bd_net [get_bd_pins fw_addr_slice/Dout]       [get_bd_pins rv32/fw_b_addr]

# ---- 3f. Result BRAM Controller (256B, port B) ----
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 res_bram_ctrl
set_property -dict [list \
    CONFIG.SINGLE_PORT_BRAM {1} \
    CONFIG.DATA_WIDTH       {32} \
    CONFIG.PROTOCOL         {AXI4LITE} \
] [get_bd_cells res_bram_ctrl]

connect_bd_net [get_bd_pins res_bram_ctrl/bram_en_a]     [get_bd_pins rv32/res_b_en]
connect_bd_net [get_bd_pins res_bram_ctrl/bram_we_a]     [get_bd_pins rv32/res_b_we]
connect_bd_net [get_bd_pins res_bram_ctrl/bram_wrdata_a] [get_bd_pins rv32/res_b_wdata]
connect_bd_net [get_bd_pins res_bram_ctrl/bram_rddata_a] [get_bd_pins rv32/res_b_rdata]

create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 res_addr_slice
set_property -dict [list \
    CONFIG.DIN_WIDTH  {32} \
    CONFIG.DIN_FROM   {7} \
    CONFIG.DIN_TO     {0} \
    CONFIG.DOUT_WIDTH {8} \
] [get_bd_cells res_addr_slice]
connect_bd_net [get_bd_pins res_bram_ctrl/bram_addr_a] [get_bd_pins res_addr_slice/Din]
connect_bd_net [get_bd_pins res_addr_slice/Dout]       [get_bd_pins rv32/res_b_addr]

# ---- 3g. AXI connections (PS HPM0_FPD -> all 3 slaves via interconnect) ----
# First slave creates the interconnect; subsequent slaves reuse it.
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
    Clk_master {/ps_e/pl_clk0} Clk_slave {Auto} Clk_xbar {Auto} \
    Master {/ps_e/M_AXI_HPM0_FPD} Slave {/fw_bram_ctrl/S_AXI} \
    intc_ip {New AXI Interconnect} master_apm {0}] \
    [get_bd_intf_pins fw_bram_ctrl/S_AXI]

# Dynamically find the interconnect that was just created
set intc_cell [get_bd_cells -quiet -filter {VLNV =~ *:axi_interconnect:* || VLNV =~ *:smartconnect:*}]
if {$intc_cell eq ""} {
    puts "ERROR: Cannot find AXI interconnect after first apply_bd_automation!"
    exit 1
}
puts "INFO: Found AXI interconnect: ${intc_cell}"

apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
    Clk_master {/ps_e/pl_clk0} Clk_slave {Auto} Clk_xbar {Auto} \
    Master {/ps_e/M_AXI_HPM0_FPD} Slave {/res_bram_ctrl/S_AXI} \
    intc_ip ${intc_cell} master_apm {0}] \
    [get_bd_intf_pins res_bram_ctrl/S_AXI]

apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
    Clk_master {/ps_e/pl_clk0} Clk_slave {Auto} Clk_xbar {Auto} \
    Master {/ps_e/M_AXI_HPM0_FPD} Slave {/gpio_cpu_rst/S_AXI} \
    intc_ip ${intc_cell} master_apm {0}] \
    [get_bd_intf_pins gpio_cpu_rst/S_AXI]

# ---- 3h. External pins (optional UART TX + IRQ to PMOD) ----
make_bd_pins_external [get_bd_pins rv32/uart_txd]
make_bd_pins_external [get_bd_pins rv32/cim_done_irq]

# ---- 3i. Address map ----
# KV260 M_AXI_HPM0_FPD default space starts at 0xA000_0000
assign_bd_address -offset 0xA0000000 -range 32K [get_bd_addr_segs fw_bram_ctrl/S_AXI/*]
assign_bd_address -offset 0xA2000000 -range 4K  [get_bd_addr_segs res_bram_ctrl/S_AXI/*]
assign_bd_address -offset 0xA3000000 -range 4K  [get_bd_addr_segs gpio_cpu_rst/S_AXI/*]

# ---- 3j. Validate ----
validate_bd_design
save_bd_design
puts "INFO: Block Design validated and saved."

# ============================================================================
# 4. Generate wrapper
# ============================================================================
make_wrapper -files [get_files system.bd] -top
set wf [glob -nocomplain ${OUT_DIR}/${PROJ_NAME}.gen/sources_1/bd/system/hdl/system_wrapper.v]
if {$wf eq ""} {
    set wf [glob ${OUT_DIR}/${PROJ_NAME}.srcs/sources_1/bd/system/hdl/system_wrapper.v]
}
add_files -norecurse $wf
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1
puts "INFO: Wrapper added: ${wf}"

# ============================================================================
# 5. Synthesis
# ============================================================================
puts "INFO: Launching synthesis..."
set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
launch_runs synth_1 -jobs $N_JOBS
wait_on_run synth_1

if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
    puts "ERROR: Synthesis failed! Check log for details."
    exit 1
}
puts "INFO: Synthesis complete."

# Check BRAM inference
open_run synth_1
set bram_count [llength [get_cells -hierarchical -filter {PRIMITIVE_TYPE =~ BMEM.*}]]
puts "INFO: BRAM primitives inferred: ${bram_count}"
if {${bram_count} == 0} {
    puts "WARN: No BRAM inferred! Weight/bias SRAM may have fallen back to registers."
    puts "      Check synthesis warnings for 'RAM mapped to registers'."
}
close_design

# ============================================================================
# 6. Implementation + Bitstream
# ============================================================================
puts "INFO: Launching implementation + bitstream..."
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE ExtraNetDelay_high [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE AggressiveExplore  [get_runs impl_1]

launch_runs impl_1 -to_step write_bitstream -jobs $N_JOBS
wait_on_run impl_1

if {[get_property STATUS [get_runs impl_1]] ne "write_bitstream Complete!"} {
    puts "ERROR: Implementation/bitstream failed! Check log."
    exit 1
}
puts "INFO: Bitstream generated."

# ============================================================================
# 7. Export for PYNQ
# ============================================================================
file mkdir ${OUT_DIR}/deploy
set bf [glob ${OUT_DIR}/${PROJ_NAME}.runs/impl_1/*.bit]
file copy -force $bf ${OUT_DIR}/deploy/cim_rv32_kv260.bit
write_hw_platform -fixed -include_bit -force ${OUT_DIR}/deploy/cim_rv32_kv260.xsa
catch {exec unzip -o -j ${OUT_DIR}/deploy/cim_rv32_kv260.xsa *.hwh -d ${OUT_DIR}/deploy/}
foreach h [glob -nocomplain ${OUT_DIR}/deploy/*.hwh] {
    file rename -force $h ${OUT_DIR}/deploy/cim_rv32_kv260.hwh
    break
}

# ============================================================================
# 8. Reports
# ============================================================================
open_run impl_1
report_utilization -file ${OUT_DIR}/utilization_report.txt
report_timing_summary -file ${OUT_DIR}/timing_report.txt

set wns [get_property STATS.WNS [get_runs impl_1]]
set tns [get_property STATS.TNS [get_runs impl_1]]
puts "INFO: WNS = ${wns} ns, TNS = ${tns} ns"
if {$wns < 0} {
    puts "WARN: Timing violation detected! WNS=${wns}ns"
    puts "      Consider reducing FCLK_MHZ or adding pipeline stages."
    puts "      See ${OUT_DIR}/timing_report.txt for details."
}
close_design

puts "============================================================"
puts "DONE: ${OUT_DIR}/deploy/cim_rv32_kv260.{bit,hwh}"
puts "PS address map:"
puts "  0xA000_0000 (32KB) : FW BRAM"
puts "  0xA200_0000 (4KB)  : Result BRAM"
puts "  0xA300_0000 (4KB)  : GPIO (bit0=cpu_rst_n)"
puts "FCLK = ${FCLK_MHZ} MHz"
puts "BRAM primitives: ${bram_count}"
puts "WNS: ${wns} ns"
puts ""
puts "PYNQ usage:"
puts "  ol = Overlay('cim_rv32_kv260.bit')"
puts "  fw_mmio   = MMIO(0xA0000000, 0x8000)"
puts "  res_mmio  = MMIO(0xA2000000, 0x1000)"
puts "  gpio_mmio = MMIO(0xA3000000, 0x1000)"
puts "============================================================"
