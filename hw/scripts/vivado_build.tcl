# ============================================================================
# vivado_build.tcl — ARM-direct CIM SoC on MZU15B (XCZU15EG), MMIO-only
# ============================================================================
# Architecture: PS (A53, Linux) → AXI HPM0_FPD → CIM S_AXI (CSR + MMIO data)
# No DMA: MZU15B board preset does not expose HP ports (S_AXI_HP0/HP1_FPD).
# All weight/input/result transfer via MMIO through HPM0_FPD.
# DMA support pending: requires PS reconfiguration to enable HP slave ports.
#
# Usage: vivado -mode batch -source hw/scripts/vivado_build.tcl
#    or: bash hw/scripts/vivado_build.sh
# ============================================================================

set PROJ_NAME  "cim_soc_mzu15b"
set PART       "xczu15eg-ffvb1156-2-i"
set FCLK_MHZ   100
set N_JOBS     4
set HW_DIR     "hw"
set OUT_DIR    "vivado_proj"

# ============================================================================
# 1. Create project
# ============================================================================
create_project ${PROJ_NAME} ./${OUT_DIR} -part ${PART} -force

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
    ${HW_DIR}/rtl/axi/cim_axi_stream_sink.sv \
    ${HW_DIR}/rtl/axi/cim_axi_stream_source.sv \
    ${HW_DIR}/rtl/cim_top.sv \
    ${HW_DIR}/rtl/cim_top_wrapper.v \
]

add_files -norecurse ${rtl_files}
add_files -fileset constrs_1 -norecurse ${HW_DIR}/constraints/cim_mzu15b.xdc
set_property file_type SystemVerilog [get_files *.sv]
set_property VERILOG_DEFINE {MZU15B} [get_filesets sources_1]
update_compile_order -fileset sources_1

puts "INFO: Added [llength ${rtl_files}] RTL source files (MZU15B params)."

# ============================================================================
# 3. Block Design
# ============================================================================
create_bd_design "system"

# --- 3a. Zynq UltraScale+ MPSoC ---
create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.5 ps_e

# Try board automation first; fall back to manual PS config
set board_auto_ok 0
if {![catch {apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config {apply_board_preset "1"} [get_bd_cells ps_e]}]} {
    puts "INFO: MPSoC board automation applied."
    set board_auto_ok 1
}

# --- PS configuration ---
set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0                   {1} \
    CONFIG.PSU__FPGA_PL0_ENABLE                  {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ  ${FCLK_MHZ} \
] [get_bd_cells ps_e]

if {!$board_auto_ok} {
    puts "INFO: No board preset. Applying manual PS DDR4 configuration..."
    set_property -dict [list \
        CONFIG.PSU__USE__DDRC                        {1} \
        CONFIG.PSU__DDRC__DRAM_TYPE                  {DDR 4} \
        CONFIG.PSU__DDRC__BUS_WIDTH                  {64} \
        CONFIG.PSU__DDRC__ECC                        {1} \
        CONFIG.PSU__DDRC__DEVICE_CAPACITY            {8} \
        CONFIG.PSU__DDRC__SPEED_BIN                  {DDR4_3200T} \
        CONFIG.PSU__DDRC__ROW_ADDR_COUNT             {16} \
        CONFIG.PSU__DDRC__DEVICE_WIDTH               {16} \
        CONFIG.PSU__DDRC__BG_ADDR_COUNT              {2} \
        CONFIG.PSU__DDRC__BANK_ADDR_COUNT            {2} \
        CONFIG.PSU__DDR_PHY__INTERFACE               {DDR4} \
        CONFIG.PSU__DDR_PHY__BYTE_LANE_MAP           {0x2301} \
        CONFIG.PSU__CRL_APB__DDR_PLL_FBDIV           {80} \
        CONFIG.PSU__CRL_APB__DDR_PLL_CLKOUTDIV       {1} \
    ] [get_bd_cells ps_e]
    puts "WARN: Manual DDR4 config applied."
}

# MPSoC: connect pl_clk0 to HPM0 aclk (required for AXI master operation)
connect_bd_net [get_bd_pins ps_e/pl_clk0] [get_bd_pins ps_e/maxihpm0_fpd_aclk]
connect_bd_net [get_bd_pins ps_e/pl_clk0] [get_bd_pins ps_e/maxihpm0_lpd_aclk]

# --- 3b. CIM Accelerator IP ---
create_bd_cell -type module -reference cim_top_wrapper cim_0

# --- 3c. AXI Connection: HPM0_FPD → CIM (MMIO for CSR, weights, inputs, results) ---
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config [list \
        Clk_master {/ps_e/pl_clk0} Clk_slave {Auto} Clk_xbar {Auto} \
        Master {/ps_e/M_AXI_HPM0_FPD} Slave {/cim_0/S_AXI} \
        ddr_seg {Auto} intc_ip {New AXI SmartConnect} master_apm {0} \
    ] [get_bd_intf_pins cim_0/S_AXI]

# --- 3d. Interrupt: cim_0/irq_done → ps_e/pl_ps_irq0 (if available) ---
set irq_pin [get_bd_pins -quiet ps_e/pl_ps_irq0]
if {[llength $irq_pin] == 0} {
    set irq_pin [get_bd_pins -quiet ps_e/pl_ps_irq]
}
if {[llength $irq_pin] > 0} {
    connect_bd_net [get_bd_pins cim_0/irq_done] $irq_pin
    puts "INFO: CIM irq_done connected to $irq_pin"
} else {
    puts "WARN: No PL IRQ pin on ps_e — irq_done floating (polling mode OK)."
}

# --- 3e. Reset wiring ---
set rst_blocks [get_bd_cells -quiet -filter {VLNV =~ *:proc_sys_reset:*}]
puts "INFO: Found reset blocks: ${rst_blocks}"
set rst_main [lindex [lsort $rst_blocks] 0]
if {$rst_main ne ""} {
    set old_net [get_bd_nets -quiet -of_objects [get_bd_pins cim_0/S_AXI_ARESETN]]
    if {$old_net ne ""} { delete_bd_objs $old_net }
    connect_bd_net [get_bd_pins ${rst_main}/peripheral_aresetn] \
                   [get_bd_pins cim_0/S_AXI_ARESETN]
    puts "INFO: CIM reset connected to ${rst_main}/peripheral_aresetn"
}

# --- 3f. Address mapping ---
assign_bd_address -offset 0xA0000000 -range 16K \
    [get_bd_addr_segs {cim_0/S_AXI/reg0}]

# --- 3g. Validate ---
validate_bd_design
save_bd_design
puts "INFO: Block Design validated and saved."

# --- Post-validation: reset sanity check ---
set cim_rst_net [get_bd_nets -quiet -of_objects [get_bd_pins cim_0/S_AXI_ARESETN]]
if {$cim_rst_net eq ""} {
    puts "ERROR: CIM S_AXI_ARESETN is unconnected!"
    exit 1
}
puts "INFO: Reset wiring verified."

# ============================================================================
# 4. Generate wrapper + synthesis + impl + bitstream
# ============================================================================
make_wrapper -files [get_files system.bd] -top
set wrapper_file [glob -nocomplain ${OUT_DIR}/${PROJ_NAME}.gen/sources_1/bd/system/hdl/system_wrapper.v]
if {$wrapper_file eq ""} {
    set wrapper_file [glob ${OUT_DIR}/${PROJ_NAME}.srcs/sources_1/bd/system/hdl/system_wrapper.v]
}
add_files -norecurse ${wrapper_file}
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1
puts "INFO: Wrapper added: ${wrapper_file}"

# --- Synthesis ---
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

# --- Implementation + Bitstream ---
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE AltSpreadLogic_high [get_runs impl_1]
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
# 5. Export + Reports
# ============================================================================
file mkdir ${OUT_DIR}/deploy
set bit_file [glob ${OUT_DIR}/${PROJ_NAME}.runs/impl_1/system_wrapper.bit]
set hwh_file [glob ${OUT_DIR}/${PROJ_NAME}.gen/sources_1/bd/system/hw_handoff/system.hwh]

file copy -force ${bit_file} ${OUT_DIR}/deploy/cim_soc_mzu15b.bit
file copy -force ${hwh_file} ${OUT_DIR}/deploy/cim_soc_mzu15b.hwh

open_run impl_1
report_utilization   -file ${OUT_DIR}/utilization_report.txt
report_timing_summary -file ${OUT_DIR}/timing_report.txt

set wns [get_property STATS.WNS [get_runs impl_1]]
set whs [get_property STATS.WHS [get_runs impl_1]]
set lut_pct [get_property STATS.LUT_PERCENT [get_runs impl_1]]
set dsp_pct [get_property STATS.DSP_PERCENT [get_runs impl_1]]
set bram_pct [get_property STATS.BRAM_PERCENT [get_runs impl_1]]
close_design

puts "============================================================"
puts "BUILD COMPLETE"
puts "  Bitstream : ${OUT_DIR}/deploy/cim_soc_mzu15b.bit"
puts "  HWH       : ${OUT_DIR}/deploy/cim_soc_mzu15b.hwh"
puts "  Clock     : ${FCLK_MHZ} MHz"
puts "  PAR_OB    : 13 (MZU15B, 3528 DSP)"
puts "  Data path : MMIO (no DMA — HP ports unavailable on MZU15B preset)"
puts "  BRAM      : ${bram_count} primitives (${bram_pct}%)"
puts "  LUT/FF    : ${lut_pct}%"
puts "  DSP       : ${dsp_pct}%"
puts "  WNS/WHS   : ${wns} / ${whs} ns"
puts ""
puts "PS address map (M_AXI_HPM0_FPD):"
puts "  0xA0000000 (16K)  : CIM CSR + MMIO data"
puts "============================================================"
