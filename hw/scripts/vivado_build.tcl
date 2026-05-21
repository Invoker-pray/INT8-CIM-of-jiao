# ============================================================================
# vivado_build.tcl — ARM-direct CIM SoC on MZU15B (XCZU15EG), MMIO-only
# ============================================================================
# Architecture: PS (A53, Linux) → AXI (GP0 or HPM0_FPD) → CIM S_AXI (CSR + MMIO data)
# Auto-detects available PS AXI master — on ZU+ with Vivado 2024.2, M_AXI_GP0
# may not appear as a BD interface pin; HPM0_FPD is the fallback.
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

# Board automation configures essential PS infrastructure (clocks, resets,
# AXI interface stubs). Must run even without a board preset — the PS cell
# has no AXI master interfaces until automation initializes them.
if {![catch {apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config {apply_board_preset "1"} [get_bd_cells ps_e]}]} {
    puts "INFO: MPSoC board automation applied."
} else {
    puts "INFO: Board automation failed — AXI interfaces may be unavailable."
}

# Reopen BD — automation may close the design context
save_bd_design
open_bd_design [get_files system.bd]

# --- PS core configuration ---
# GP0=1 + HPM0_FPD=1: both must be set for any AXI PL master to appear on
# ZU+ in Vivado 2024.2.  HPM0_FPD generates a Critical Warning ("parameter
# does not exist") but removing it causes all AXI PL masters to disappear.
# The actual BD interface pin used is auto-detected at step 3d.
set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0                   {1} \
    CONFIG.PSU__USE__M_AXI_HPM0_FPD             {1} \
    CONFIG.PSU__FPGA_PL0_ENABLE                  {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ  ${FCLK_MHZ} \
] [get_bd_cells ps_e]

# --- PS Peripherals ---
# UART0 -> CP2104 (J2) on MIO 34(RX) 35(TX), 115200 8N1
# SD0   -> TF card slot on MIO 13..16, 21..22 (via MAX13035E level shifter)
# SD1   -> eMMC (MTFC8GAKAJCN-4M IT) on MIO 39..51
set_property -dict [list \
    CONFIG.PSU__UART0__PERIPHERAL__ENABLE         {1} \
    CONFIG.PSU__UART0__PERIPHERAL__IO             {MIO 34 .. 35} \
    CONFIG.PSU__UART0__BAUD_RATE                  {115200} \
    CONFIG.PSU__SD0__PERIPHERAL__ENABLE           {1} \
    CONFIG.PSU__SD0__PERIPHERAL__IO               {MIO 13 .. 16 21 22} \
    CONFIG.PSU__SD0__SLOT_TYPE                    {SD 2.0} \
    CONFIG.PSU__SD1__PERIPHERAL__ENABLE           {1} \
    CONFIG.PSU__SD1__PERIPHERAL__IO               {MIO 39 .. 51} \
    CONFIG.PSU__SD1__SLOT_TYPE                    {eMMC} \
] [get_bd_cells ps_e]

# --- DDR4 Configuration (MZU15B) ---
# 4x MT40A512M16LY-062E (8Gb x16, 64-bit bus, 4 GB total).
# Vivado 2024.2 constraint for 8192 MBit x16: ROW=16, COL=10, BG=1, BA=2.
puts "INFO: Applying MZU15B PS DDR4 configuration..."
puts "INFO:   4x 8Gb x16, 64-bit, 4 GB, DDR4-2400T, ROW=16 COL=10 BG=1 BA=2"
set_property -dict [list \
    CONFIG.PSU__DDRC__ENABLE                     {1} \
    CONFIG.PSU__DDRC__MEMORY_TYPE                {DDR 4} \
    CONFIG.PSU__DDRC__BUS_WIDTH                  {64 Bit} \
    CONFIG.PSU__DDRC__ECC                        {Disabled} \
    CONFIG.PSU__DDRC__SPEED_BIN                  {DDR4_2400T} \
    CONFIG.PSU__DDRC__DEVICE_CAPACITY            {8192 MBits} \
    CONFIG.PSU__DDRC__DRAM_WIDTH                 {16 Bits} \
    CONFIG.PSU__DDRC__ROW_ADDR_COUNT             {16} \
    CONFIG.PSU__DDRC__COL_ADDR_COUNT             {10} \
    CONFIG.PSU__DDRC__BG_ADDR_COUNT              {1} \
    CONFIG.PSU__DDRC__BANK_ADDR_COUNT            {2} \
    CONFIG.PSU__DDRC__RANK_ADDR_COUNT            {0} \
    CONFIG.PSU__DDRC__COMPONENTS                 {Components} \
    CONFIG.PSU__CRF_APB__DDR_CTRL__FREQMHZ       {1200} \
] [get_bd_cells ps_e]

# --- 3b. Create reset block (if board automation didn't) ---
set rst_blocks [get_bd_cells -quiet -filter {VLNV =~ *:proc_sys_reset:*}]
if {[llength $rst_blocks] == 0} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_ps
    connect_bd_net [get_bd_pins ps_e/pl_clk0]    [get_bd_pins rst_ps/slowest_sync_clk]
    connect_bd_net [get_bd_pins ps_e/pl_resetn0]  [get_bd_pins rst_ps/ext_reset_in]
    puts "INFO: proc_sys_reset created manually"
} else {
    puts "INFO: proc_sys_reset already exists from board automation"
}

# --- 3c. CIM Accelerator IP ---
create_bd_cell -type module -reference cim_top_wrapper cim_0

# --- 3d. Debug: list PS AXI master interfaces ---
puts "INFO: === Available PS AXI master interfaces ==="
foreach intf [get_bd_intf_pins -quiet -of_objects [get_bd_cells ps_e] -filter {MODE == Master && VLNV =~ *:aximm:*}] {
    puts "INFO:   $intf"
}
puts "INFO: === End of AXI master list ==="

# Determine which AXI master to use. On ZU+, GP0 may not exist as a BD
# interface pin; HPM0_FPD is often the only master exposed after automation.
set axi_master ""
foreach candidate {/ps_e/M_AXI_GP0 /ps_e/M_AXI_HPM0_FPD /ps_e/M_AXI_HPM0_LPD} {
    if {[llength [get_bd_intf_pins -quiet $candidate]] > 0} {
        set axi_master $candidate
        break
    }
}
if {$axi_master eq ""} {
    puts "ERROR: No AXI master interface found on ps_e!"
    exit 1
}
puts "INFO: Using AXI master: ${axi_master}"

# --- 3e. AXI Connection: PS -> CIM ---
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config [list \
        Clk_master {/ps_e/pl_clk0} Clk_slave {Auto} Clk_xbar {Auto} \
        Master ${axi_master} Slave {/cim_0/S_AXI} \
        ddr_seg {Auto} intc_ip {New AXI SmartConnect} master_apm {0} \
    ] [get_bd_intf_pins cim_0/S_AXI]

# --- 3f. Interrupt: cim_0/irq_done -> ps_e/pl_ps_irq0 (if available) ---
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

# --- 3g. Explicit clock / reset wiring ---
# Only connect pins that AXI automation didn't already wire.

# CIM clock
set cim_clk_net [get_bd_nets -quiet -of_objects [get_bd_pins cim_0/S_AXI_ACLK]]
if {$cim_clk_net eq ""} {
    connect_bd_net [get_bd_pins ps_e/pl_clk0] [get_bd_pins cim_0/S_AXI_ACLK]
    puts "INFO: CIM S_AXI_ACLK connected manually"
} else {
    puts "INFO: CIM S_AXI_ACLK already connected by automation"
}

# CIM reset (find reset block dynamically)
set rst_blocks [get_bd_cells -quiet -filter {VLNV =~ *:proc_sys_reset:*}]
set rst_main [lindex [lsort $rst_blocks] 0]
if {$rst_main eq ""} {
    puts "ERROR: No proc_sys_reset found in block design!"
    exit 1
}
set cim_rst_net [get_bd_nets -quiet -of_objects [get_bd_pins cim_0/S_AXI_ARESETN]]
if {$cim_rst_net eq ""} {
    connect_bd_net [get_bd_pins ${rst_main}/peripheral_aresetn] \
                   [get_bd_pins cim_0/S_AXI_ARESETN]
    puts "INFO: CIM reset connected to ${rst_main}"
} else {
    puts "INFO: CIM S_AXI_ARESETN already connected by automation"
}

# Interconnect (SmartConnect or AXI Interconnect) clock + reset
set intc_cells [get_bd_cells -quiet -filter {VLNV =~ *:smartconnect:* || VLNV =~ *:axi_interconnect:*}]
if {[llength $intc_cells] > 0} {
    set intc [lindex [lsort $intc_cells] 0]
    set intc_clk_net [get_bd_nets -quiet -of_objects [get_bd_pins ${intc}/aclk]]
    if {$intc_clk_net eq ""} {
        connect_bd_net [get_bd_pins ps_e/pl_clk0] [get_bd_pins ${intc}/aclk]
        puts "INFO: Interconnect ${intc} aclk connected"
    }
    set intc_rst_net [get_bd_nets -quiet -of_objects [get_bd_pins ${intc}/aresetn]]
    if {$intc_rst_net eq ""} {
        connect_bd_net [get_bd_pins ${rst_main}/peripheral_aresetn] \
                       [get_bd_pins ${intc}/aresetn]
        puts "INFO: Interconnect ${intc} aresetn connected"
    }
    puts "INFO: Interconnect ${intc} clock + reset verified"
}

# HPM0 FPD clock (if available and not already connected)
set hpm0_fpd_clk [get_bd_pins -quiet ps_e/maxihpm0_fpd_aclk]
if {[llength $hpm0_fpd_clk] > 0} {
    set hpm0_clk_net [get_bd_nets -quiet -of_objects $hpm0_fpd_clk]
    if {$hpm0_clk_net eq ""} {
        connect_bd_net [get_bd_pins ps_e/pl_clk0] $hpm0_fpd_clk
        puts "INFO: pl_clk0 -> maxihpm0_fpd_aclk connected"
    } else {
        puts "INFO: maxihpm0_fpd_aclk already connected by automation"
    }
}

# HPM0 LPD clock — validation requires it if the pin exists
set hpm0_lpd_clk [get_bd_pins -quiet ps_e/maxihpm0_lpd_aclk]
if {[llength $hpm0_lpd_clk] > 0} {
    set hpm0_lpd_net [get_bd_nets -quiet -of_objects $hpm0_lpd_clk]
    if {$hpm0_lpd_net eq ""} {
        connect_bd_net [get_bd_pins ps_e/pl_clk0] $hpm0_lpd_clk
        puts "INFO: pl_clk0 -> maxihpm0_lpd_aclk connected"
    } else {
        puts "INFO: maxihpm0_lpd_aclk already connected by automation"
    }
}

# --- 3h. Address mapping ---
assign_bd_address -offset 0xA0000000 -range 16K \
    [get_bd_addr_segs {cim_0/S_AXI/reg0}]

# --- 3i. Validate ---
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
# Query run stats BEFORE open_run — some STATS properties are invalid with design open
set wns      [get_property STATS.WNS          [get_runs impl_1]]
set whs      [get_property STATS.WHS          [get_runs impl_1]]
set lut_pct  [get_property STATS.LUT_PERCENT  [get_runs impl_1]]
set dsp_pct  [get_property STATS.DSP_PERCENT  [get_runs impl_1]]
set bram_pct [get_property STATS.BRAM_PERCENT [get_runs impl_1]]

file mkdir ${OUT_DIR}/deploy
set bit_file [glob ${OUT_DIR}/${PROJ_NAME}.runs/impl_1/system_wrapper.bit]
set hwh_file [glob ${OUT_DIR}/${PROJ_NAME}.gen/sources_1/bd/system/hw_handoff/system.hwh]

file copy -force ${bit_file} ${OUT_DIR}/deploy/cim_soc_mzu15b.bit
file copy -force ${hwh_file} ${OUT_DIR}/deploy/cim_soc_mzu15b.hwh

# Open routed design for XSA export + detailed reports
open_run impl_1
write_hw_platform -fixed -include_bit -force ${OUT_DIR}/deploy/cim_soc_mzu15b.xsa
puts "INFO: XSA exported to ${OUT_DIR}/deploy/cim_soc_mzu15b.xsa"

report_utilization   -file ${OUT_DIR}/utilization_report.txt
report_timing_summary -file ${OUT_DIR}/timing_report.txt
close_design

puts "============================================================"
puts "BUILD COMPLETE"
puts "  Bitstream : ${OUT_DIR}/deploy/cim_soc_mzu15b.bit"
puts "  HWH       : ${OUT_DIR}/deploy/cim_soc_mzu15b.hwh"
puts "  Clock     : ${FCLK_MHZ} MHz"
puts "  PAR_OB    : 13 (MZU15B, 3528 DSP)"
puts "  Data path : MMIO via ${axi_master} (no DMA)"
puts "  BRAM      : ${bram_count} primitives (${bram_pct}%)"
puts "  LUT/FF    : ${lut_pct}%"
puts "  DSP       : ${dsp_pct}%"
puts "  WNS/WHS   : ${wns} / ${whs} ns"
puts ""
puts "PS address map (${axi_master}):"
puts "  0xA0000000 (16K)  : CIM CSR + MMIO data"
puts "============================================================"
