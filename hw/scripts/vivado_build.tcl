# ============================================================================
# vivado_build.tcl — Automated Vivado build for CIM SoC on PYNQ-Z2
# ============================================================================
# Usage: vivado -mode batch -source hw/scripts/vivado_build.tcl
#    or: bash hw/scripts/vivado_build.sh  (which calls this)
#
# What it does:
#   1. Create project targeting xc7z020clg400-1 (PYNQ-Z2)
#   2. Add all RTL sources
#   3. Create Block Design: Zynq PS + AXI Interconnect + CIM IP
#   4. Connect clocks, resets, AXI, interrupt
#   5. Run synth → impl → write_bitstream
#   6. Export .bit + .hwh for PYNQ
# ============================================================================

# --- Configuration ---
# NOTE: Pipeline-optimized cim_accel_core.sv now splits the post-accumulation
# path into 4 stages (BIAS_ADD → ACTIVATE → REQUANT → STORE) to meet 125MHz.
set PROJ_NAME  "cim_soc"
set PART       "xc7z020clg400-1"
set BOARD_PART "tul.com.tw:pynq-z2:part0:1.0"
set FCLK_MHZ   60
set N_JOBS     4

# --- Paths (relative to where vivado is invoked, typically project root) ---
set HW_DIR     "hw"
set OUT_DIR    "vivado_proj"

# ============================================================================
# 1. Create project
# ============================================================================
create_project ${PROJ_NAME} ./${OUT_DIR} -part ${PART} -force

# Try to set board part (if board file is installed)
if {![catch {set_property board_part ${BOARD_PART} [current_project]}]} {
    puts "INFO: Board part ${BOARD_PART} applied."
} else {
    puts "WARN: Board part not found. Using manual part ${PART}."
}

# ============================================================================
# 2. Add RTL sources
# ============================================================================
set rtl_files [list \
    ${HW_DIR}/rtl/pkg/cim_pkg.sv \
    ${HW_DIR}/rtl/core/cim_tile.sv \
    ${HW_DIR}/rtl/core/psum_accum.sv \
    ${HW_DIR}/rtl/mem/weight_sram.sv \
    ${HW_DIR}/rtl/mem/bias_sram.sv \
    ${HW_DIR}/rtl/mem/input_buffer.sv \
    ${HW_DIR}/rtl/mem/output_buffer.sv \
    ${HW_DIR}/rtl/core/cim_accel_core.sv \
    ${HW_DIR}/rtl/axi/cim_axi_lite_slave.sv \
    ${HW_DIR}/rtl/axi/cim_axi_lite_slave_wrapper.v \
]

add_files -norecurse ${rtl_files}
add_files -fileset constrs_1 -norecurse ${HW_DIR}/constraints/cim_soc.xdc
# Ensure cim_pkg.sv compiles first
set_property file_type SystemVerilog [get_files *.sv]
update_compile_order -fileset sources_1

puts "INFO: Added [llength ${rtl_files}] RTL source files."

# ============================================================================
# 3. Create Block Design
# ============================================================================
create_bd_design "system"

# --- 3a. Zynq PS ---
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7

# Apply board automation if board file is present
if {![catch {apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR"} [get_bd_cells ps7]}]} {
    puts "INFO: Board automation applied for PS7."
} else {
    puts "WARN: Board automation failed. Configure PS manually."
}

# Configure PS: enable M_AXI_GP0, fabric interrupts, set FCLK
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0             {1} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT      {1} \
    CONFIG.PCW_IRQ_F2P_INTR             {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ ${FCLK_MHZ} \
] [get_bd_cells ps7]

# --- 3b. CIM Accelerator IP ---
#create_bd_cell -type module -reference cim_axi_lite_slave cim_0
create_bd_cell -type module -reference cim_axi_lite_slave_wrapper cim_0

# --- 3c. AXI Connection Automation ---
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config [list \
        Clk_master {/ps7/FCLK_CLK0} \
        Clk_slave  {Auto} \
        Clk_xbar   {Auto} \
        Master     {/ps7/M_AXI_GP0} \
        Slave      {/cim_0/S_AXI} \
        ddr_seg    {Auto} \
        intc_ip    {New AXI Interconnect} \
        master_apm {0} \
    ] [get_bd_intf_pins cim_0/S_AXI]

# --- 3d. Connect interrupt ---
connect_bd_net [get_bd_pins cim_0/irq_done] [get_bd_pins ps7/IRQ_F2P]

# --- 3e. Address mapping: 0x4000_0000, 4KB ---
assign_bd_address -offset 0x40000000 -range 16K \
    [get_bd_addr_segs {cim_0/S_AXI/reg0}]

# --- 3f. Validate ---
validate_bd_design
save_bd_design
puts "INFO: Block Design validated and saved."

# ============================================================================
# 4. Generate wrapper
# ============================================================================
make_wrapper -files [get_files system.bd] -top
set wrapper_file [glob -nocomplain ${OUT_DIR}/${PROJ_NAME}.gen/sources_1/bd/system/hdl/system_wrapper.v]
if {$wrapper_file eq ""} {
    set wrapper_file [glob ${OUT_DIR}/${PROJ_NAME}.srcs/sources_1/bd/system/hdl/system_wrapper.v]
}
add_files -norecurse ${wrapper_file}
update_compile_order -fileset sources_1

set_property top system_wrapper [current_fileset]
puts "INFO: Wrapper added: ${wrapper_file}"

# ============================================================================
# 5. Synthesis
# ============================================================================
puts "INFO: Launching synthesis..."
set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
launch_runs synth_1 -jobs ${N_JOBS}
wait_on_run synth_1

if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
    puts "ERROR: Synthesis failed!"
    exit 1
}
puts "INFO: Synthesis complete."

# Check BRAM inference
open_run synth_1
set bram_count [llength [get_cells -hierarchical -filter {PRIMITIVE_TYPE =~ BMEM.*}]]
puts "INFO: BRAM primitives inferred: ${bram_count}"
close_design

# ============================================================================
# 6. Implementation + Bitstream
# ============================================================================

set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE ExtraNetDelay_high [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE AggressiveExplore  [get_runs impl_1]

puts "INFO: Launching implementation + bitstream..."
launch_runs impl_1 -to_step write_bitstream -jobs ${N_JOBS}
wait_on_run impl_1

if {[get_property STATUS [get_runs impl_1]] ne "write_bitstream Complete!"} {
    puts "ERROR: Implementation/bitstream failed!"
    exit 1
}
puts "INFO: Bitstream generated."

# ============================================================================
# 7. Export for PYNQ
# ============================================================================
set bit_file [glob ${OUT_DIR}/${PROJ_NAME}.runs/impl_1/system_wrapper.bit]
set hwh_file [glob ${OUT_DIR}/${PROJ_NAME}.gen/sources_1/bd/system/hw_handoff/system.hwh]

file mkdir ${OUT_DIR}/pynq_deploy
file copy -force ${bit_file} ${OUT_DIR}/pynq_deploy/cim_soc.bit
file copy -force ${hwh_file} ${OUT_DIR}/pynq_deploy/cim_soc.hwh

puts "============================================================"
puts "BUILD COMPLETE"
puts "  Bitstream : ${OUT_DIR}/pynq_deploy/cim_soc.bit"
puts "  HWH       : ${OUT_DIR}/pynq_deploy/cim_soc.hwh"
puts "  Upload both to PYNQ Jupyter, same directory, same name."
puts "============================================================"

# Print utilization summary
open_run impl_1
report_utilization -file ${OUT_DIR}/utilization_report.txt
report_timing_summary -file ${OUT_DIR}/timing_report.txt
puts "INFO: Reports saved to ${OUT_DIR}/"
close_design
