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
    ${HW_DIR}/rtl/axi/cim_axi_stream_sink.sv \
    ${HW_DIR}/rtl/cim_top.sv \
    ${HW_DIR}/rtl/cim_top_wrapper.v \
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

# Configure PS: enable M_AXI_GP0/GP1, S_AXI_HP0, fabric interrupts (2-bit)
# C3: GP1 carries axi_dma CSR to avoid GP0 contention with CIM CSR;
#     HP0 carries the DMA MM2S traffic (64-bit, 1.2 GB/s ceiling per UG585 §22.6).
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0             {1} \
    CONFIG.PCW_USE_M_AXI_GP1             {1} \
    CONFIG.PCW_USE_S_AXI_HP0             {1} \
    CONFIG.PCW_S_AXI_HP0_DATA_WIDTH      {64} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT      {1} \
    CONFIG.PCW_IRQ_F2P_INTR              {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ  ${FCLK_MHZ} \
] [get_bd_cells ps7]

# --- 3b. CIM Accelerator IP (C3: cim_top_wrapper = slave + stream sink) ---
create_bd_cell -type module -reference cim_top_wrapper cim_0

# --- 3b.1 axi_dma (MM2S only, Direct Register mode, 64→32 dwidth) ---
# PG021 §3.1.1: the Data Realignment Engine does 64→32 for free; we keep the
# PS-side 64-bit to stay at HP0's 1.2 GB/s peak, and narrow inside the DMA to
# match cim_axi_stream_sink's 32-bit AXIS.
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_0
set_property -dict [list \
    CONFIG.c_include_sg              {0} \
    CONFIG.c_include_s2mm            {0} \
    CONFIG.c_sg_include_stscntrl_strm {0} \
    CONFIG.c_m_axi_mm2s_data_width   {64} \
    CONFIG.c_m_axis_mm2s_tdata_width {32} \
    CONFIG.c_mm2s_burst_size         {16} \
] [get_bd_cells axi_dma_0]

# --- 3c. AXI Connection Automation ---
# GP0 → cim_0/S_AXI (CIM CSR, 14-bit address space)
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

# GP1 → axi_dma_0/S_AXI_LITE (DMA CSR, separate interconnect to avoid GP0 stalls)
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config [list \
        Clk_master {/ps7/FCLK_CLK0} \
        Clk_slave  {Auto} \
        Clk_xbar   {Auto} \
        Master     {/ps7/M_AXI_GP1} \
        Slave      {/axi_dma_0/S_AXI_LITE} \
        ddr_seg    {Auto} \
        intc_ip    {Auto} \
        master_apm {0} \
    ] [get_bd_intf_pins axi_dma_0/S_AXI_LITE]

# axi_dma_0/M_AXI_MM2S → ps7/S_AXI_HP0 (DDR read, 64-bit)
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config [list \
        Clk_master {/ps7/FCLK_CLK0} \
        Clk_slave  {Auto} \
        Clk_xbar   {Auto} \
        Master     {/axi_dma_0/M_AXI_MM2S} \
        Slave      {/ps7/S_AXI_HP0} \
        ddr_seg    {Auto} \
        intc_ip    {New AXI Interconnect} \
        master_apm {0} \
    ] [get_bd_intf_pins ps7/S_AXI_HP0]

# axi_dma_0/M_AXIS_MM2S → cim_0/S_AXIS (direct, no clock conversion — shared FCLK_CLK0)
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S] \
                    [get_bd_intf_pins cim_0/S_AXIS]

# --- 3d. Interrupt concatenation: {dma.mm2s_introut, cim.irq_done} → ps7 IRQ_F2P ---
# Must reconfigure PS IRQ_F2P width to 2 before wiring.
set_property -dict [list CONFIG.PCW_IRQ_F2P_INTR {1} CONFIG.PCW_NUM_F2P_INTR_INPUTS {2}] \
    [get_bd_cells ps7]
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 xlconcat_0
set_property -dict [list CONFIG.NUM_PORTS {2} CONFIG.IN0_WIDTH {1} CONFIG.IN1_WIDTH {1}] \
    [get_bd_cells xlconcat_0]
connect_bd_net [get_bd_pins cim_0/irq_done]        [get_bd_pins xlconcat_0/In0]
connect_bd_net [get_bd_pins axi_dma_0/mm2s_introut] [get_bd_pins xlconcat_0/In1]
connect_bd_net [get_bd_pins xlconcat_0/dout]        [get_bd_pins ps7/IRQ_F2P]

# --- 3d.1 Dedicated proc_sys_reset for axi_dma ---
# Isolates DMA reset from CIM's soft_reset (CSR_CTRL[2]). If CIM soft-resets
# mid-layer, axi_dma must keep servicing the in-flight MM2S descriptor — a
# shared psr would abort the burst and desync PS-side state.
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 psr_dma
connect_bd_net [get_bd_pins ps7/FCLK_CLK0]       [get_bd_pins psr_dma/slowest_sync_clk]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N]   [get_bd_pins psr_dma/ext_reset_in]

# Helper: reconnect a reset source to one or more pins, overriding any stale
# or missing automation result. C3's module-reference top (`cim_top_wrapper`)
# caused Vivado automation to leave several ARESETN pins floating, which made
# MMIO accesses hang on-board even though Overlay() itself succeeded.
proc reconnect_reset_pins {src_pin dst_pins} {
    foreach dst_pin $dst_pins {
        set old_net [get_bd_nets -quiet -of_objects $dst_pin]
        if {$old_net ne ""} {
            delete_bd_objs $old_net
        }
        connect_bd_net $src_pin $dst_pin
    }
}

# Main GP0/CIM control path reset. Without these explicit connections the
# generated .hwh showed cim_0/S_AXI_ARESETN and ps7_axi_periph ARESETN pins
# unconnected, and board MMIO read/write would hard-hang.
reconnect_reset_pins [get_bd_pins rst_ps7_60M/peripheral_aresetn] [list \
    [get_bd_pins cim_0/S_AXI_ARESETN] \
    [get_bd_pins ps7_axi_periph/ARESETN] \
    [get_bd_pins ps7_axi_periph/M00_ARESETN] \
    [get_bd_pins ps7_axi_periph/S00_ARESETN] \
]

# DMA data/control path reset. Keep axi_dma and its interconnects on the
# dedicated proc_sys_reset so CSR_CTRL[2] soft-reset inside CIM never couples
# into an in-flight MM2S transfer.
reconnect_reset_pins [get_bd_pins psr_dma/peripheral_aresetn] [list \
    [get_bd_pins axi_dma_0/axi_resetn] \
    [get_bd_pins ps7_axi_periph_1/ARESETN] \
    [get_bd_pins ps7_axi_periph_1/M00_ARESETN] \
    [get_bd_pins ps7_axi_periph_1/S00_ARESETN] \
    [get_bd_pins axi_mem_intercon/ARESETN] \
    [get_bd_pins axi_mem_intercon/M00_ARESETN] \
    [get_bd_pins axi_mem_intercon/S00_ARESETN] \
]

# --- 3e. Address mapping ---
# CIM CSR: 0x40000000, 16 KB (14-bit address space, via M_AXI_GP0, aperture 0x4000_0000[1G])
# axi_dma CSR: 0x80400000, 64 KB (via M_AXI_GP1, aperture 0x8000_0000[1G])
# DDR seen by DMA MM2S via HP0: full 512 MB LOWOCM window
assign_bd_address -offset 0x40000000 -range 16K \
    [get_bd_addr_segs {cim_0/S_AXI/reg0}]
assign_bd_address -offset 0x80400000 -range 64K \
    [get_bd_addr_segs {axi_dma_0/S_AXI_LITE/Reg}]
assign_bd_address -offset 0x00000000 -range 512M \
    [get_bd_addr_segs {ps7/S_AXI_HP0/HP0_DDR_LOWOCM}]

# --- 3e'. Associate S_AXIS with S_AXI_ACLK (wrapper lacks X_INTERFACE_INFO) ---
# Without this, Vivado defaults S_AXIS FREQ_HZ to 100 MHz while DMA's
# M_AXIS_MM2S is at 60 MHz (tied to FCLK_CLK0) → validate_bd_design fails
# with BD 41-237 FREQ_HZ mismatch.
set_property CONFIG.ASSOCIATED_BUSIF {S_AXI:S_AXIS} [get_bd_pins cim_0/S_AXI_ACLK]
set_property CONFIG.FREQ_HZ [expr {${FCLK_MHZ}*1000000}] [get_bd_intf_pins cim_0/S_AXIS]

# --- 3f. Validate ---
validate_bd_design
save_bd_design
puts "INFO: Block Design validated and saved."

# --- 3g. Post-validation: .hwh sanity check (docs/c3_dma_design.md §5.5) ---
# PYNQ Overlay reads the .hwh to discover IPs. If axi_dma's address segment
# is missing, `overlay.axi_dma_0` will fail at runtime. Fail fast here.
set dma_segs [get_bd_addr_segs -of_objects [get_bd_cells axi_dma_0]]
if {[llength $dma_segs] < 1} {
    puts "ERROR: axi_dma_0 has no address segment assigned. Aborting — the"
    puts "       generated .hwh will miss axi_dma and PYNQ driver will break."
    exit 1
}
puts "INFO: axi_dma_0 address segments verified: $dma_segs"

# Reset wiring sanity check — fail fast instead of shipping a bitstream whose
# AXI peripherals can be discovered by Overlay() but hang on the first MMIO.
set required_reset_pins [list \
    [get_bd_pins cim_0/S_AXI_ARESETN] \
    [get_bd_pins ps7_axi_periph/ARESETN] \
    [get_bd_pins ps7_axi_periph/M00_ARESETN] \
    [get_bd_pins ps7_axi_periph/S00_ARESETN] \
    [get_bd_pins axi_dma_0/axi_resetn] \
    [get_bd_pins ps7_axi_periph_1/ARESETN] \
    [get_bd_pins ps7_axi_periph_1/M00_ARESETN] \
    [get_bd_pins ps7_axi_periph_1/S00_ARESETN] \
    [get_bd_pins axi_mem_intercon/ARESETN] \
    [get_bd_pins axi_mem_intercon/M00_ARESETN] \
    [get_bd_pins axi_mem_intercon/S00_ARESETN] \
]
foreach pin $required_reset_pins {
    set net [get_bd_nets -quiet -of_objects $pin]
    if {$net eq ""} {
        puts "ERROR: required reset pin is unconnected: $pin"
        exit 1
    }
}
puts "INFO: reset wiring verified for CIM + AXI interconnects"

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
report_power -file ${OUT_DIR}/power_report.txt
puts "INFO: Reports saved to ${OUT_DIR}/"

# --- Post-impl WNS gate (docs/c3_dma_design.md §7.4, §8 risk #5) ---
# axi_dma + extra Interconnect may regress critical path. Print prominently so
# the author can decide whether to accept (60 MHz baseline is known -0.086 ns),
# retry with axis_register_slice isolation, or fall back to the 55 MHz variant.
set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
puts "============================================================"
puts "TIMING SUMMARY"
puts "  WNS (setup) : ${wns} ns"
puts "  WHS (hold)  : ${whs} ns"
if {${wns} < -0.5} {
    puts "  STATUS      : REGRESSION — WNS below -0.5 ns threshold."
    puts "                Consider axis_register_slice between axi_dma and"
    puts "                cim_0/S_AXIS, or use vivado_build_55mhz.sh instead."
} elseif {${wns} < 0.0} {
    puts "  STATUS      : MARGINAL — negative slack (expected at 60 MHz)."
} else {
    puts "  STATUS      : CLEAN — positive slack."
}
puts "============================================================"
close_design

