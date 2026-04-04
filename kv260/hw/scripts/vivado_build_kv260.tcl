# ============================================================================
# vivado_build_kv260.tcl — CIM SoC on Kria KV260 (ARM PS control)
# ============================================================================
# Port of hw/scripts/vivado_build.tcl from PYNQ-Z2 to KV260.
# Same CIM IP RTL, only PS block and pin constraints differ.
#
# Usage: vivado -mode batch -source kv260/hw/scripts/vivado_build_kv260.tcl
# ============================================================================

set PROJ_NAME  "cim_soc_kv260"
set PART       "xck26-sfvc784-2LV-c"
set BOARD_PART "xilinx.com:kv260_som:part0:1.4"
set FCLK_MHZ   100    ;# KV260 can easily do 100MHz+
set N_JOBS     4

set HW_DIR     "hw"
set OUT_DIR    "kv260/vivado_proj"

puts "============================================================"
puts "CIM SoC — KV260 Build (ARM PS control)"
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
# 2. Add CIM IP RTL
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
set_property file_type SystemVerilog [get_files *.sv]
set_property file_type Verilog       [get_files *.v]
# Ensure cim_pkg.sv compiles first
update_compile_order -fileset sources_1

# Constraints
add_files -fileset constrs_1 -norecurse kv260/hw/constraints/cim_kv260.xdc

puts "INFO: Added [llength ${rtl_files}] RTL files."

# ============================================================================
# 3. Block Design
# ============================================================================
create_bd_design "system"

# ---- Zynq UltraScale+ MPSoC ----
create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.5 ps_e

# Apply board automation (configures DDR4, PS peripherals for KV260)
# Note: MPSoC board automation differs from Zynq-7000 — no FIXED_IO/DDR params
if {![catch {apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config {apply_board_preset "1"} [get_bd_cells ps_e]}]} {
    puts "INFO: MPSoC board automation applied."
}

# Configure PS: enable AXI HPM0, set PL clock
set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0          {1} \
    CONFIG.PSU__FPGA_PL0_ENABLE         {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ ${FCLK_MHZ} \
    CONFIG.PSU__USE__IRQ0               {1} \
] [get_bd_cells ps_e]

# Connect pl_clk0 to AXI master clock (required for MPSoC)
connect_bd_net [get_bd_pins ps_e/pl_clk0] [get_bd_pins ps_e/maxihpm0_fpd_aclk]

# ---- CIM Accelerator IP ----
create_bd_cell -type module -reference cim_axi_lite_slave_wrapper cim_0

# ---- AXI Connection ----
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config [list \
        Clk_master {/ps_e/pl_clk0} \
        Clk_slave  {Auto} \
        Clk_xbar   {Auto} \
        Master     {/ps_e/M_AXI_HPM0_FPD} \
        Slave      {/cim_0/S_AXI} \
        ddr_seg    {Auto} \
        intc_ip    {New AXI Interconnect} \
        master_apm {0} \
    ] [get_bd_intf_pins cim_0/S_AXI]

# ---- Interrupt ----
connect_bd_net [get_bd_pins cim_0/irq_done] [get_bd_pins ps_e/pl_ps_irq0]

# ---- Address mapping ----
# Note: MPSoC M_AXI_HPM0_FPD default base is 0xA000_0000
# We assign CIM at 0xA000_0000, 16KB range
# Use wildcard — segment name varies across Vivado versions for module references
assign_bd_address -offset 0xA0000000 -range 16K \
    [get_bd_addr_segs cim_0/S_AXI/*]

# ---- Validate ----
validate_bd_design
save_bd_design
puts "INFO: Block Design validated."

# ============================================================================
# 4. Build
# ============================================================================
make_wrapper -files [get_files system.bd] -top
set wf [glob -nocomplain ${OUT_DIR}/${PROJ_NAME}.gen/sources_1/bd/system/hdl/system_wrapper.v]
if {$wf eq ""} {
    set wf [glob ${OUT_DIR}/${PROJ_NAME}.srcs/sources_1/bd/system/hdl/system_wrapper.v]
}
add_files -norecurse $wf
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1

puts "INFO: Launching synthesis..."
set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
launch_runs synth_1 -jobs $N_JOBS
wait_on_run synth_1
if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
    puts "ERROR: Synthesis failed!"; exit 1
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

puts "INFO: Launching implementation + bitstream..."
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE ExtraNetDelay_high [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE AggressiveExplore  [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream -jobs $N_JOBS
wait_on_run impl_1
if {[get_property STATUS [get_runs impl_1]] ne "write_bitstream Complete!"} {
    puts "ERROR: Impl/bitstream failed!"; exit 1
}

# ============================================================================
# 5. Export
# ============================================================================
set impl_dir "${OUT_DIR}/${PROJ_NAME}.runs/impl_1"
file mkdir ${OUT_DIR}/deploy
file copy -force [glob ${impl_dir}/*.bit] ${OUT_DIR}/deploy/cim_soc_kv260.bit

write_hw_platform -fixed -include_bit -force ${OUT_DIR}/deploy/cim_soc_kv260.xsa
catch {exec unzip -o -j ${OUT_DIR}/deploy/cim_soc_kv260.xsa *.hwh -d ${OUT_DIR}/deploy/}
foreach h [glob -nocomplain ${OUT_DIR}/deploy/*.hwh] {
    file rename -force $h ${OUT_DIR}/deploy/cim_soc_kv260.hwh
    break
}

# Reports
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
puts "DONE"
puts "  Bitstream: ${OUT_DIR}/deploy/cim_soc_kv260.bit"
puts "  HWH:       ${OUT_DIR}/deploy/cim_soc_kv260.hwh"
puts "  FCLK:      ${FCLK_MHZ} MHz"
puts "  BRAM:      ${bram_count}"
puts "  WNS:       ${wns} ns"
puts ""
puts "  Upload to KV260 PYNQ Jupyter, then:"
puts "    ol = Overlay('cim_soc_kv260.bit')"
puts "    mmio = MMIO(0xA0000000, 0x4000)"
puts "============================================================"
