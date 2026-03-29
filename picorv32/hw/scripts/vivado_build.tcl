# ============================================================================
# vivado_build.tcl — PicoRV32 + CIM SoC with PS-readable Result BRAM
# ============================================================================
# Hybrid PS+PL: PicoRV32 runs inference in PL, PS reads results via AXI.
#
# Block Design:
#   PS7 → AXI Interconnect → AXI BRAM Controller → Result BRAM port B
#   cim_rv32_top (module ref) provides Result BRAM port B signals
#
# Usage: vivado -mode batch -source picorv32/hw/scripts/vivado_build.tcl
# ============================================================================

set PROJ_NAME  "cim_rv32_soc"
set PART       "xc7z020clg400-1"
set BOARD_PART "tul.com.tw:pynq-z2:part0:1.0"
set N_JOBS     4

set PROJ_ROOT  [pwd]
set CIM_HW     "hw"
set RV_HW      "picorv32/hw"
set FW_DIR     "picorv32/fw"
set OUT_DIR    "picorv32/vivado_proj"

puts "============================================================"
puts "PicoRV32 + CIM SoC — Hybrid PS+PL Build"
puts "============================================================"

# ============================================================================
# 1. Create project
# ============================================================================
create_project ${PROJ_NAME} ./${OUT_DIR} -part ${PART} -force
if {![catch {set_property board_part ${BOARD_PART} [current_project]}]} {
    puts "INFO: Board part applied."
}

# ============================================================================
# 2. Add RTL
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
]

add_files -norecurse ${all_files}
add_files -fileset constrs_1 -norecurse ${RV_HW}/constraints/cim_rv32_pynq.xdc

set_property file_type SystemVerilog [get_files *.sv]
set_property file_type Verilog       [get_files *.v]

# Firmware hex
set fw_hex "${FW_DIR}/firmware.hex"
if {[file exists ${fw_hex}]} {
    add_files -norecurse ${fw_hex}
    set_property file_type {Memory Initialization Files} [get_files firmware.hex]
    puts "INFO: firmware.hex added."
}

# ============================================================================
# 3. Block Design
# ============================================================================
create_bd_design "system"

# --- PS7 ---
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7
if {![catch {apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR"} [get_bd_cells ps7]}]} {
    puts "INFO: PS7 board automation applied."
}
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {50} \
] [get_bd_cells ps7]

# --- cim_rv32_top ---
create_bd_cell -type module -reference cim_rv32_top rv32_soc

# --- Reset ---
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_ps
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins rst_ps/slowest_sync_clk]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins rst_ps/ext_reset_in]

# Connect clock + reset to rv32_soc
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins rv32_soc/clk]
connect_bd_net [get_bd_pins rst_ps/peripheral_aresetn] [get_bd_pins rv32_soc/rst_n]

# --- AXI BRAM Controller ---
# Reads result BRAM port B (64 words = 256 bytes)
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 bram_ctrl
set_property -dict [list \
    CONFIG.SINGLE_PORT_BRAM {1} \
    CONFIG.DATA_WIDTH {32} \
    CONFIG.ECC_TYPE {0} \
    CONFIG.PROTOCOL {AXI4LITE} \
] [get_bd_cells bram_ctrl]

# PS AXI GP0 → BRAM Controller
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config [list \
        Clk_master {/ps7/FCLK_CLK0} \
        Clk_slave  {Auto} \
        Clk_xbar   {Auto} \
        Master     {/ps7/M_AXI_GP0} \
        Slave      {/bram_ctrl/S_AXI} \
        ddr_seg    {Auto} \
        intc_ip    {New AXI Interconnect} \
        master_apm {0} \
    ] [get_bd_intf_pins bram_ctrl/S_AXI]

# --- Connect BRAM Controller BRAM port → rv32_soc result BRAM port B ---
# AXI BRAM Controller exposes BRAM_PORTA intf with signals:
#   bram_addr_a, bram_clk_a, bram_en_a, bram_rst_a, bram_we_a, bram_wrdata_a, bram_rddata_a
# We connect these to rv32_soc's res_b_* ports manually.
#
# Note: bram_addr_a width from bram_ctrl may be wider than res_b_addr[7:0].
# The controller generates byte addresses; we just connect the low bits.

# First, disconnect the auto-generated BRAM port (if any)
# The bram_ctrl has a BRAM_PORTA interface - we'll connect its individual signals

connect_bd_net [get_bd_pins bram_ctrl/bram_en_a]     [get_bd_pins rv32_soc/res_b_en]
connect_bd_net [get_bd_pins bram_ctrl/bram_we_a]     [get_bd_pins rv32_soc/res_b_we]
connect_bd_net [get_bd_pins bram_ctrl/bram_wrdata_a] [get_bd_pins rv32_soc/res_b_wdata]
connect_bd_net [get_bd_pins bram_ctrl/bram_rddata_a] [get_bd_pins rv32_soc/res_b_rdata]

# Address: bram_ctrl outputs wider addr, rv32_soc expects [7:0]
# We use a Slice IP to extract bits [7:0] from the BRAM controller address
create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 addr_slice
set_property -dict [list \
    CONFIG.DIN_WIDTH {32} \
    CONFIG.DIN_FROM {7} \
    CONFIG.DIN_TO {0} \
    CONFIG.DOUT_WIDTH {8} \
] [get_bd_cells addr_slice]

connect_bd_net [get_bd_pins bram_ctrl/bram_addr_a] [get_bd_pins addr_slice/Din]
connect_bd_net [get_bd_pins addr_slice/Dout]       [get_bd_pins rv32_soc/res_b_addr]

# --- External pins ---
make_bd_pins_external [get_bd_pins rv32_soc/uart_txd]
make_bd_pins_external [get_bd_pins rv32_soc/cim_done_irq]

# --- Address map: PS sees BRAM Controller at 0x4000_0000 ---
assign_bd_address -offset 0x40000000 -range 4K \
    [get_bd_addr_segs {bram_ctrl/S_AXI/Mem0}]

validate_bd_design
save_bd_design
puts "INFO: Block Design complete."

# ============================================================================
# 4. Wrapper + Synth + Impl
# ============================================================================
make_wrapper -files [get_files system.bd] -top
set wrapper_file [glob -nocomplain ${OUT_DIR}/${PROJ_NAME}.gen/sources_1/bd/system/hdl/system_wrapper.v]
if {$wrapper_file eq ""} {
    set wrapper_file [glob ${OUT_DIR}/${PROJ_NAME}.srcs/sources_1/bd/system/hdl/system_wrapper.v]
}
add_files -norecurse ${wrapper_file}
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1

# Copy firmware.hex
if {[file exists ${fw_hex}]} {
    file copy -force ${fw_hex} ${OUT_DIR}/firmware.hex
}

puts "INFO: Launching synthesis..."
launch_runs synth_1 -jobs ${N_JOBS}
wait_on_run synth_1

if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
    puts "ERROR: Synthesis failed!"
    exit 1
}

# Copy firmware.hex to run dirs
set impl_dir "${OUT_DIR}/${PROJ_NAME}.runs/impl_1"
set synth_dir "${OUT_DIR}/${PROJ_NAME}.runs/synth_1"
file mkdir ${impl_dir}
if {[file exists ${fw_hex}]} {
    file copy -force ${fw_hex} ${impl_dir}/firmware.hex
    file copy -force ${fw_hex} ${synth_dir}/firmware.hex
}

puts "INFO: Launching implementation + bitstream..."
launch_runs impl_1 -to_step write_bitstream -jobs ${N_JOBS}
wait_on_run impl_1

if {[get_property STATUS [get_runs impl_1]] ne "write_bitstream Complete!"} {
    puts "ERROR: Implementation/bitstream failed!"
    exit 1
}

# ============================================================================
# 5. Export .bit + .hwh
# ============================================================================
set bit_file [glob ${impl_dir}/*.bit]
file mkdir ${OUT_DIR}/deploy
file copy -force ${bit_file} ${OUT_DIR}/deploy/cim_rv32_soc.bit

# Generate .hwh via XSA
write_hw_platform -fixed -include_bit -force ${OUT_DIR}/deploy/cim_rv32_soc.xsa
catch {exec unzip -o -j ${OUT_DIR}/deploy/cim_rv32_soc.xsa *.hwh -d ${OUT_DIR}/deploy/}

# Rename hwh
foreach hwh [glob -nocomplain ${OUT_DIR}/deploy/*.hwh] {
    file rename -force $hwh ${OUT_DIR}/deploy/cim_rv32_soc.hwh
    break
}

puts "============================================================"
puts "BUILD COMPLETE"
puts "  Bitstream: ${OUT_DIR}/deploy/cim_rv32_soc.bit"
puts "  HWH:       ${OUT_DIR}/deploy/cim_rv32_soc.hwh"
puts "============================================================"

# Reports
open_run impl_1
report_utilization -file ${OUT_DIR}/utilization_report.txt
report_timing_summary -file ${OUT_DIR}/timing_report.txt
close_design
