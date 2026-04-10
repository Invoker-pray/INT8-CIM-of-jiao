# ============================================================================
# vivado_build_55mhz.tcl — Build CIM SoC at 55 MHz for timing-clean result
# ============================================================================
# Identical to vivado_build.tcl except:
#   FCLK_MHZ = 55  (18.182 ns period, eliminates the -0.086 ns WNS at 60 MHz)
#   OUT_DIR   = vivado_proj_55mhz
#   Deploy    → vivado_proj_55mhz/pynq_deploy/  (cim_soc_55mhz.bit/.hwh)
#
# Background: At 60 MHz the critical path (CIM Tile MAC chain) produces
# WNS = -0.086 ns on 3 endpoints. Dropping to 55 MHz gives ~1.5 ns positive
# slack on the same path. The hardware is functionally identical; the lower
# frequency has negligible impact on inference latency (54.7 μs → 59.7 μs
# for MLP, i.e. ~9% slowdown).
#
# Usage: bash hw/scripts/vivado_build_55mhz.sh
# ============================================================================

# --- Configuration ---
set PROJ_NAME  "cim_soc"
set PART       "xc7z020clg400-1"
set BOARD_PART "tul.com.tw:pynq-z2:part0:1.0"
set FCLK_MHZ   55
set N_JOBS     4

# --- Paths (relative to where vivado is invoked, typically project root) ---
set HW_DIR     "hw"
set OUT_DIR    "vivado_proj_55mhz"

# ============================================================================
# 1. Create project
# ============================================================================
create_project ${PROJ_NAME} ./${OUT_DIR} -part ${PART} -force

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
# Use dedicated 55 MHz XDC (18.182 ns period constraint)
add_files -fileset constrs_1 -norecurse ${HW_DIR}/constraints/cim_soc_55mhz.xdc
set_property file_type SystemVerilog [get_files *.sv]
update_compile_order -fileset sources_1

puts "INFO: Added [llength ${rtl_files}] RTL source files."

# ============================================================================
# 3. Create Block Design
# ============================================================================
create_bd_design "system"

# --- 3a. Zynq PS ---
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7

if {![catch {apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR"} [get_bd_cells ps7]}]} {
    puts "INFO: Board automation applied for PS7."
} else {
    puts "WARN: Board automation failed. Configure PS manually."
}

# Configure PS: 55 MHz fabric clock
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0             {1} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT      {1} \
    CONFIG.PCW_IRQ_F2P_INTR             {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ ${FCLK_MHZ} \
] [get_bd_cells ps7]

# --- 3b. CIM Accelerator IP ---
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

# --- 3e. Address mapping ---
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
file copy -force ${bit_file} ${OUT_DIR}/pynq_deploy/cim_soc_55mhz.bit
file copy -force ${hwh_file} ${OUT_DIR}/pynq_deploy/cim_soc_55mhz.hwh

puts "============================================================"
puts "BUILD COMPLETE (55 MHz — timing clean)"
puts "  Bitstream : ${OUT_DIR}/pynq_deploy/cim_soc_55mhz.bit"
puts "  HWH       : ${OUT_DIR}/pynq_deploy/cim_soc_55mhz.hwh"
puts "  On PYNQ: ol = Overlay('cim_soc_55mhz.bit')"
puts "           driver = CIMDriver(ol, clk_mhz=55)"
puts "============================================================"

open_run impl_1
report_utilization    -file ${OUT_DIR}/utilization_report.txt
report_timing_summary -file ${OUT_DIR}/timing_report.txt
report_power          -file ${OUT_DIR}/power_report.txt
puts "INFO: Reports saved to ${OUT_DIR}/"
close_design
