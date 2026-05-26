# ============================================================================
# vivado_build.tcl — CIM SoC KV260 ARM-direct build (AXI4-Stream DMA)
# ============================================================================
# Architecture: PS (A53, Linux) → HPM0_FPD → CIM S_AXI (CSR)
#                               → HPM1_FPD → axi_dma S_AXI_LITE (DMA CSR)
#               S_AXI_HPC0_FPD ← axi_dma M_AXI_MM2S (DDR read)
#               S_AXI_HPC1_FPD → axi_dma M_AXI_S2MM (DDR write)
#
# Usage: vivado -mode batch -source kv260/hw/scripts/vivado_build.tcl
#    or: bash kv260/hw/scripts/vivado_build.sh
# ============================================================================

set PROJ_NAME  "cim_soc_kv260"
set PART       "xck26-sfvc784-2LV-c"
set BOARD_PART "xilinx.com:kv260_som:part0:1.4"
set FCLK_MHZ   100
set N_JOBS     4
set HW_DIR     "hw"
set OUT_DIR    "vivado_proj"

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
# 2. Add RTL sources (from shared hw/rtl/)
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
add_files -fileset constrs_1 -norecurse "kv260/hw/constraints/cim_kv260.xdc"
set_property file_type SystemVerilog [get_files *.sv]
update_compile_order -fileset sources_1

puts "INFO: Added [llength ${rtl_files}] RTL source files."

# ============================================================================
# 3. Block Design
# ============================================================================
create_bd_design "system"

# --- 3a. Zynq UltraScale+ PS ---
create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.5 ps_e

# Board automation applies KV260 SOM preset (mpsoc_preset_vsom)
if {![catch {apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config {apply_board_preset "1"} [get_bd_cells ps_e]}]} {
    puts "INFO: MPSoC board automation applied (KV260 SOM preset)."
} else {
    puts "WARN: Board automation failed — configuring PS manually."
}

save_bd_design
open_bd_design [get_files system.bd]

# --- 3b. PS configuration ---
# HPM masters: auto-enabled by board preset
# Enable HP0_FPD + HP1_FPD slave ports for DMA DDR access
set_property -dict [list \
    CONFIG.PSU__FPGA_PL0_ENABLE                  {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ  ${FCLK_MHZ} \
    CONFIG.PSU__USE__IRQ0                        {1} \
    CONFIG.PSU__USE__IRQ1                        {0} \
    CONFIG.PSU__USE__S_AXI_GP2                   {1} \
    CONFIG.PSU__USE__S_AXI_GP3                   {1} \
    CONFIG.PSU__SAXIGP2__DATA_WIDTH              {64} \
    CONFIG.PSU__SAXIGP3__DATA_WIDTH              {64} \
    CONFIG.PSU__NUM_FABRIC_RESETS                {2} \
] [get_bd_cells ps_e]

# --- UART0: MIO 38-39 (KV260 carrier CP2104 USB-UART) ---
set_property -dict [list \
    CONFIG.PSU__UART0__PERIPHERAL__ENABLE         {1} \
    CONFIG.PSU__UART0__PERIPHERAL__IO             {MIO 38 .. 39} \
    CONFIG.PSU__UART0__BAUD_RATE                  {115200} \
] [get_bd_cells ps_e]

# --- SD0: MIO 13-16,21-22 (KV260 carrier microSD) ---
set_property -dict [list \
    CONFIG.PSU__SD0__PERIPHERAL__ENABLE           {1} \
    CONFIG.PSU__SD0__PERIPHERAL__IO               {MIO 13 .. 16 21 22} \
    CONFIG.PSU__SD0__SLOT_TYPE                    {SD 2.0} \
] [get_bd_cells ps_e]

# --- 3c. Resets ---
set rst_blocks [get_bd_cells -quiet -filter {VLNV =~ *:proc_sys_reset:*}]
if {[llength $rst_blocks] == 0} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_ps
    connect_bd_net [get_bd_pins ps_e/pl_clk0]    [get_bd_pins rst_ps/slowest_sync_clk]
    connect_bd_net [get_bd_pins ps_e/pl_resetn0]  [get_bd_pins rst_ps/ext_reset_in]
    puts "INFO: proc_sys_reset created manually"
}

# Separate reset for DMA (isolated from CIM soft_reset)
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_dma
connect_bd_net [get_bd_pins ps_e/pl_clk0]        [get_bd_pins rst_dma/slowest_sync_clk]
connect_bd_net [get_bd_pins ps_e/pl_resetn0]      [get_bd_pins rst_dma/ext_reset_in]

# --- 3d. CIM Accelerator ---
create_bd_cell -type module -reference cim_top_wrapper cim_0

# --- 3e. axi_dma (MM2S + S2MM) ---
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_0
set_property -dict [list \
    CONFIG.c_include_sg              {0} \
    CONFIG.c_include_s2mm            {1} \
    CONFIG.c_sg_include_stscntrl_strm {0} \
    CONFIG.c_m_axi_mm2s_data_width   {64} \
    CONFIG.c_m_axi_s2mm_data_width   {64} \
    CONFIG.c_mm2s_burst_size         {16} \
] [get_bd_cells axi_dma_0]

# --- 3f. AXI Connections ---
# Helper: determine available PS AXI master
set axi_master ""
foreach candidate {/ps_e/M_AXI_GP0 /ps_e/M_AXI_HPM0_FPD /ps_e/M_AXI_HPM0_LPD} {
    if {[llength [get_bd_intf_pins -quiet $candidate]] > 0} {
        set axi_master $candidate
        break
    }
}
puts "INFO: Using PS AXI master for CIM CSR: ${axi_master}"

# CIM CSR via HPM0_FPD (or GP0 fallback)
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config [list \
        Clk_master {/ps_e/pl_clk0} \
        Clk_slave  {Auto} \
        Clk_xbar   {Auto} \
        Master     ${axi_master} \
        Slave      {/cim_0/S_AXI} \
        ddr_seg    {Auto} \
        intc_ip    {New AXI Interconnect} \
        master_apm {0} \
    ] [get_bd_intf_pins cim_0/S_AXI]

# Determine available PS AXI master for DMA CSR
set axi_master_dma ""
foreach candidate {/ps_e/M_AXI_GP1 /ps_e/M_AXI_HPM1_FPD /ps_e/M_AXI_HPM1_LPD} {
    if {[llength [get_bd_intf_pins -quiet $candidate]] > 0} {
        set axi_master_dma $candidate
        break
    }
}
if {$axi_master_dma eq ""} {
    set axi_master_dma $axi_master
    puts "WARN: No second AXI master found; sharing ${axi_master} for DMA CSR."
}

# DMA CSR via HPM1_FPD (or GP1 fallback)
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config [list \
        Clk_master {/ps_e/pl_clk0} \
        Clk_slave  {Auto} \
        Clk_xbar   {Auto} \
        Master     ${axi_master_dma} \
        Slave      {/axi_dma_0/S_AXI_LITE} \
        ddr_seg    {Auto} \
        intc_ip    {Auto} \
        master_apm {0} \
    ] [get_bd_intf_pins axi_dma_0/S_AXI_LITE]

# DMA → PS slaves (DDR read/write): discover available PS AXI slave interfaces
set ps_slaves [list]
foreach candidate {/ps_e/S_AXI_HP0_FPD /ps_e/S_AXI_HP1_FPD \
                   /ps_e/S_AXI_HP2_FPD /ps_e/S_AXI_HP3_FPD \
                   /ps_e/S_AXI_HPC0_FPD /ps_e/S_AXI_HPC1_FPD} {
    if {[llength [get_bd_intf_pins -quiet $candidate]] > 0} {
        lappend ps_slaves $candidate
    }
}
puts "INFO: Available PS AXI slave ports: ${ps_slaves}"

# DMA MM2S → first PS slave (DDR read)
if {[llength $ps_slaves] >= 1} {
    set ps_slave_mm2s [lindex $ps_slaves 0]
    apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
        -config [list \
            Clk_master {/ps_e/pl_clk0} \
            Clk_slave  {Auto} \
            Clk_xbar   {Auto} \
            Master     {/axi_dma_0/M_AXI_MM2S} \
            Slave      ${ps_slave_mm2s} \
            ddr_seg    {Auto} \
            intc_ip    {New AXI Interconnect} \
            master_apm {0} \
        ] [get_bd_intf_pins ${ps_slave_mm2s}]
} else {
    puts "ERROR: No PS AXI slave port available for DMA MM2S"
    exit 1
}

# DMA S2MM → second PS slave (DDR write) or share first
if {[llength $ps_slaves] >= 2} {
    set ps_slave_s2mm [lindex $ps_slaves 1]
    apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
        -config [list \
            Clk_master {/ps_e/pl_clk0} \
            Clk_slave  {Auto} \
            Clk_xbar   {Auto} \
            Master     {/axi_dma_0/M_AXI_S2MM} \
            Slave      ${ps_slave_s2mm} \
            ddr_seg    {Auto} \
            intc_ip    {New AXI Interconnect} \
            master_apm {0} \
        ] [get_bd_intf_pins ${ps_slave_s2mm}]
    puts "INFO: DMA MM2S→${ps_slave_mm2s}, S2MM→${ps_slave_s2mm}"
} else {
    apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
        -config [list \
            Clk_master {/ps_e/pl_clk0} \
            Clk_slave  {Auto} \
            Clk_xbar   {Auto} \
            Master     {/axi_dma_0/M_AXI_S2MM} \
            Slave      ${ps_slave_mm2s} \
            ddr_seg    {Auto} \
            intc_ip    {Auto} \
            master_apm {0} \
        ] [get_bd_intf_pins ${ps_slave_mm2s}]
    puts "INFO: DMA MM2S and S2MM sharing ${ps_slave_mm2s}"
}

# AXIS: DMA MM2S → CIM S_AXIS
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S] \
                    [get_bd_intf_pins cim_0/S_AXIS]

# AXIS: CIM M_AXIS_RESULT → DMA S_AXIS_S2MM (result read-back)
connect_bd_intf_net [get_bd_intf_pins cim_0/M_AXIS_RESULT] \
                    [get_bd_intf_pins axi_dma_0/S_AXIS_S2MM]

# --- 3g. Interrupts ---
# Concatenate: {cim_irq, dma_mm2s_intr, dma_s2mm_intr} → pl_ps_irq0
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 xlconcat_0
set_property -dict [list \
    CONFIG.NUM_PORTS {3} \
    CONFIG.IN0_WIDTH {1} \
    CONFIG.IN1_WIDTH {1} \
    CONFIG.IN2_WIDTH {1} \
] [get_bd_cells xlconcat_0]
connect_bd_net [get_bd_pins cim_0/irq_done]         [get_bd_pins xlconcat_0/In0]
connect_bd_net [get_bd_pins axi_dma_0/mm2s_introut]  [get_bd_pins xlconcat_0/In1]
connect_bd_net [get_bd_pins axi_dma_0/s2mm_introut]  [get_bd_pins xlconcat_0/In2]
connect_bd_net [get_bd_pins xlconcat_0/dout]         [get_bd_pins ps_e/pl_ps_irq0]

# --- 3h. Reset wiring ---
proc reconnect_reset_pins {src_pin dst_pins} {
    foreach dst_pin $dst_pins {
        set old_net [get_bd_nets -quiet -of_objects $dst_pin]
        if {$old_net ne ""} {
            delete_bd_objs $old_net
        }
        connect_bd_net $src_pin $dst_pin
    }
}

# CIM control path reset — DO NOT reconnect S_AXI_ARESETN.
# apply_bd_automation creates an AXI SmartConnect whose reset shares a net
# with cim_0/S_AXI_ARESETN.  Reconnecting only the CIM pin would orphan the
# SmartConnect reset, leaving the interconnect stuck in reset and all AXI
# transactions to the CIM hanging (RCU stall on ZynqMP HPM ports).
# Let the block automation's reset connection stay intact.

# DMA data/control path reset (via rst_dma)
reconnect_reset_pins [get_bd_pins rst_dma/peripheral_aresetn] [list \
    [get_bd_pins axi_dma_0/axi_resetn] \
]

# --- 3i. Validate ---
if {[catch {validate_bd_design} errmsg]} {
    puts "WARN: validate_bd_design had non-fatal warnings: $errmsg"
}
save_bd_design
puts "INFO: Block Design saved."

# Post-validation sanity
set dma_segs [get_bd_addr_segs -of_objects [get_bd_cells axi_dma_0]]
if {[llength $dma_segs] < 1} {
    puts "ERROR: axi_dma_0 has no address segment assigned."
    exit 1
}
puts "INFO: axi_dma_0 address segments verified: $dma_segs"

# Align FREQ_HZ: DMA auto-computes 99.999 MHz from PLL (read-only).
# CIM AXIS interfaces default to 100000000 — match them to DMA to pass
# make_wrapper internal validation.
set dma_freq [get_property CONFIG.FREQ_HZ [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S]]
puts "INFO: DMA FREQ_HZ = ${dma_freq}; aligning CIM AXIS interfaces..."
set_property CONFIG.FREQ_HZ $dma_freq [get_bd_intf_pins cim_0/S_AXIS]
set_property CONFIG.FREQ_HZ $dma_freq [get_bd_intf_pins cim_0/M_AXIS_RESULT]

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
# 7. Export
# ============================================================================
set bit_file [glob ${OUT_DIR}/${PROJ_NAME}.runs/impl_1/system_wrapper.bit]
set hwh_file [glob ${OUT_DIR}/${PROJ_NAME}.gen/sources_1/bd/system/hw_handoff/system.hwh]

file mkdir kv260/deploy
file copy -force ${bit_file} kv260/deploy/cim_soc_kv260.bit
file copy -force ${hwh_file} kv260/deploy/cim_soc_kv260.hwh

# Export XSA for PetaLinux
write_hw_platform -fixed -include_bit -force -file kv260/deploy/cim_soc_kv260.xsa

puts "============================================================"
puts "KV260 BUILD COMPLETE"
puts "  Bitstream : kv260/deploy/cim_soc_kv260.bit"
puts "  HWH       : kv260/deploy/cim_soc_kv260.hwh"
puts "  XSA       : kv260/deploy/cim_soc_kv260.xsa"
puts "============================================================"

# Reports
open_run impl_1
report_utilization -file ${OUT_DIR}/utilization_report.txt
report_timing_summary -file ${OUT_DIR}/timing_report.txt
report_power -file ${OUT_DIR}/power_report.txt

set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
puts "============================================================"
puts "TIMING SUMMARY"
puts "  WNS (setup) : ${wns} ns"
puts "  WHS (hold)  : ${whs} ns"
if {${wns} < -0.5} {
    puts "  STATUS      : REGRESSION — WNS below -0.5 ns."
} elseif {${wns} < 0.0} {
    puts "  STATUS      : MARGINAL — negative slack."
} else {
    puts "  STATUS      : CLEAN — positive slack."
}
puts "============================================================"
close_design
