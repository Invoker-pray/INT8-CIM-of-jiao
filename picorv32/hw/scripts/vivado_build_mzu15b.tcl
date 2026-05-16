# ============================================================================
# vivado_build_rv32.tcl — PicoRV32 + CIM SoC on MZU15B (XCZU15EG)
# ============================================================================
#
# Port of picorv32/hw/scripts/vivado_build.tcl from PYNQ-Z2 to MZU15B.
# PicoRV32 runs in PL; PS provides clock, loads FW via BRAM, reads results.
#
# Fully automated: PS DDR4, clocks, resets, AXI interconnect — all via TCL.
# No Vivado GUI interaction needed.
#
# Hardware:
#   Core board: MZU15CORE-EG-IOMAX (XCZU15EG-FFVB1156-2-I)
#   DDR4:      5x MT40A512M16LY-062E (8Gb x16 each, DDR4-3200)
#              4 chips = 64-bit data, 1 chip = ECC → total 4 GB
#
# Architecture (same as PYNQ-Z2 / KV260 PicoRV32):
#   PS (A53, Linux) ── AXI HPM0_FPD ──┬── FW BRAM ctrl  (32 KB)
#                                      ├── Res BRAM ctrl  (256 B)
#                                      └── AXI GPIO        (1b, cpu_rst_n)
#   PL: PicoRV32 + CIM via cim_rv32_top (PL↔CIM via internal AXI, PS not involved)
#
# PS AXI address map (M_AXI_HPM0_FPD):
#   0xA000_0000 (32KB)  : FW BRAM port B
#   0xA200_0000 (4KB)   : Result BRAM port B
#   0xA300_0000 (4KB)   : AXI GPIO (bit0 = cpu_rst_n)
#
# Plan C workflow (bare metal Linux, no PYNQ):
#   fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
#   fw   = mmap.mmap(fd, 0x8000, offset=0xA0000000)
#   res  = mmap.mmap(fd, 0x1000, offset=0xA2000000)
#   gpio = mmap.mmap(fd, 0x1000, offset=0xA3000000)
#
#   gpio[0:4] = struct.pack('<I', 0)     # hold CPU
#   fw[0:fw_size] = firmware_bytes        # write firmware
#   gpio[0:4] = struct.pack('<I', 1)     # release CPU
#   while struct.unpack('<I', res[0:4])[0] != 0xC1AA0001: sleep(0.001)
#   pred = struct.unpack('<I', res[4:8])[0]
# ============================================================================

# --- Configuration ---
set PROJ_NAME  "cim_rv32_mzu15b"
set PART       "xczu15eg-ffvb1156-2-i"
set FCLK_MHZ   100
set N_JOBS     4
set CIM_HW     "hw"
set RV_HW      "picorv32/hw"
set OUT_DIR    "picorv32/vivado_mzu15b_proj"

puts "============================================================"
puts "CIM SoC — MZU15B Build (PicoRV32 control)"
puts "  Part:   ${PART}"
puts "  FCLK:   ${FCLK_MHZ} MHz"
puts "  Params: MAX_IN_DIM=3072, MAX_OUT_DIM=1024, PAR_OB=13"
puts "============================================================"

# ============================================================================
# 1. Create project
# ============================================================================
create_project ${PROJ_NAME} ./${OUT_DIR} -part ${PART} -force

puts "INFO: Using part ${PART} (custom MZU15B, no board_part)."
puts "INFO: PS DDR4 will be configured manually in Step 3a."

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
    ${CIM_HW}/rtl/axi/cim_axi_stream_source.sv \
    ${CIM_HW}/rtl/axi/cim_axi_lite_slave_wrapper.v \
    ${RV_HW}/rtl/riscv/picorv32.v \
    ${RV_HW}/rtl/riscv/uart_tx.sv \
    ${RV_HW}/rtl/riscv/picorv32_cim_bridge.sv \
    ${RV_HW}/rtl/riscv/cim_rv32_top.sv \
    ${RV_HW}/rtl/riscv/cim_rv32_top_wrapper.v \
]
add_files -norecurse ${all_files}
add_files -fileset constrs_1 -norecurse picorv32/hw/constraints/cim_rv32_mzu15b.xdc

set_property file_type SystemVerilog [get_files *.sv]
set_property file_type Verilog       [get_files *.v]

# Define MZU15B to enable expanded parameters in cim_pkg.sv
set_property VERILOG_DEFINE {MZU15B} [get_filesets sources_1]

update_compile_order -fileset sources_1
puts "INFO: Added [llength ${all_files}] RTL source files (MZU15B params enabled)."

# ============================================================================
# 3. Block Design
# ============================================================================
create_bd_design "system"

# ---- 3a. Zynq UltraScale+ MPSoC ----
create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.5 ps_e

# Try board automation first (works if a matching board_part is installed).
set board_auto_ok 0
if {![catch {apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config {apply_board_preset "1"} [get_bd_cells ps_e]}]} {
    puts "INFO: MPSoC board automation applied successfully."
    set board_auto_ok 1
}

if {!$board_auto_ok} {
    puts "INFO: No board preset. Applying manual PS DDR4 configuration..."
    puts "INFO: DDR4: 5x MT40A512M16LY-062E (64-bit data + ECC, 4 GB, 3200 MT/s)"

    # --- PS-PL Interface ---
    set_property -dict [list \
        CONFIG.PSU__USE__M_AXI_GP0                   {1} \
        CONFIG.PSU__FPGA_PL0_ENABLE                  {1} \
        CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ  ${FCLK_MHZ} \
    ] [get_bd_cells ps_e]

    # --- DDR Controller: enable & configure ---
    # UG1085 Ch.17: DDR Memory Controller configuration
    set_property -dict [list \
        CONFIG.PSU__USE__DDRC                        {1} \
        CONFIG.PSU__DDRC__DRAM_TYPE                  {DDR 4} \
        CONFIG.PSU__DDRC__BUS_WIDTH                  {64} \
        CONFIG.PSU__DDRC__ECC                        {1} \
        CONFIG.PSU__DDRC__DEVICE_CAPACITY            {8}     ;# 8 Gb per chip (MT40A512M16)
        CONFIG.PSU__DDRC__SPEED_BIN                  {DDR4_3200T} \
        CONFIG.PSU__DDRC__ROW_ADDR_COUNT             {16}    ;# A[15:0] = 16 row bits
        CONFIG.PSU__DDRC__DEVICE_WIDTH               {16}    ;# x16 device
        CONFIG.PSU__DDRC__BG_ADDR_COUNT              {2}     ;# 4 bank groups
        CONFIG.PSU__DDRC__BANK_ADDR_COUNT            {2}     ;# 4 banks per group
    ] [get_bd_cells ps_e]

    # --- DDR PHY ---
    set_property -dict [list \
        CONFIG.PSU__DDR_PHY__INTERFACE               {DDR4} \
        CONFIG.PSU__DDR_PHY__BYTE_LANE_MAP           {0x2301} \
    ] [get_bd_cells ps_e]

    # --- DDR PLL: DDR4-3200 → MEMCLK=1600 MHz, DRAM clock=800 MHz ---
    set_property -dict [list \
        CONFIG.PSU__CRL_APB__DDR_PLL_FBDIV           {80} \
        CONFIG.PSU__CRL_APB__DDR_PLL_CLKOUTDIV       {1} \
    ] [get_bd_cells ps_e]

    # --- Essential I/O Peripherals ---
    set_property -dict [list \
        CONFIG.PSU__USE__UART0                       {1} \
        CONFIG.PSU__UART0__BAUD_RATE                 {115200} \
    ] [get_bd_cells ps_e]

    puts "INFO: Manual PS DDR4 configuration applied."
    puts "WARN: DDR timing parameters use Vivado defaults."
    puts "WARN: If DDR training fails at boot, fine-tune in Vivado GUI:"
    puts "WARN:   1. vivado picorv32/vivado_mzu15b_proj/cim_rv32_mzu15b.xpr"
    puts "WARN:   2. Open Block Design → double-click ps_e"
    puts "WARN:   3. DDR Configuration → Import from target board / manual tuning"
    puts "WARN:   4. Save BD → Generate Bitstream"
}

# Add more PS config (works regardless of board automation)
set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0                   {1} \
    CONFIG.PSU__FPGA_PL0_ENABLE                  {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ  ${FCLK_MHZ} \
] [get_bd_cells ps_e]

# MPSoC requires explicit clock connections for all active AXI master ports
connect_bd_net [get_bd_pins ps_e/pl_clk0] [get_bd_pins ps_e/maxihpm0_fpd_aclk]
connect_bd_net [get_bd_pins ps_e/pl_clk0] [get_bd_pins ps_e/maxihpm0_lpd_aclk]

# ---- 3b. rv32_soc (module reference) ----
create_bd_cell -type module -reference cim_rv32_top_wrapper rv32

# FREQ_HZ auto-propagated from pl_clk0 — no explicit set needed

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
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
    Clk_master {/ps_e/pl_clk0} Clk_slave {Auto} Clk_xbar {Auto} \
    Master {/ps_e/M_AXI_HPM0_FPD} Slave {/fw_bram_ctrl/S_AXI} \
    intc_ip {New AXI Interconnect} master_apm {0}] \
    [get_bd_intf_pins fw_bram_ctrl/S_AXI]

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

# ---- 3h. External pins (optional debug) ----
make_bd_pins_external [get_bd_pins rv32/uart_txd]
make_bd_pins_external [get_bd_pins rv32/cim_done_irq]

# ---- 3i. Address map ----
# Auto-assignment placed res_bram at 0xA000_2000 (8K) which conflicts with
# fw_bram's desired 0xA000_0000 (32K). Reassign smaller segments first.
assign_bd_address -offset 0xA2000000 -range 4K  [get_bd_addr_segs res_bram_ctrl/S_AXI/*]
assign_bd_address -offset 0xA3000000 -range 4K  [get_bd_addr_segs gpio_cpu_rst/S_AXI/*]
assign_bd_address -offset 0xA0000000 -range 32K [get_bd_addr_segs fw_bram_ctrl/S_AXI/*]

# ---- 3j. Validate ----
validate_bd_design
save_bd_design
puts "INFO: Block Design validated and saved."

# ============================================================================
# 4. Generate wrapper + synthesis + impl + bitstream
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

# --- Synthesis ---
puts "INFO: Launching synthesis..."
set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
launch_runs synth_1 -jobs $N_JOBS
wait_on_run synth_1

if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
    puts "ERROR: Synthesis failed! Check log."
    exit 1
}
puts "INFO: Synthesis complete."

open_run synth_1
set bram_count [llength [get_cells -hierarchical -filter {PRIMITIVE_TYPE =~ BMEM.*}]]
puts "INFO: BRAM primitives inferred: ${bram_count}"
close_design

# --- Implementation + Bitstream ---
puts "INFO: Launching implementation + bitstream..."

# Waive I/O DRC for unconstrained debug ports (uart_txd_0, cim_done_irq_0)
# These are optional non-critical pins — LOC+IOSTANDARD will be added when board is wired.
set_property SEVERITY {Warning} [get_drc_checks NSTD-1]
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]

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
# 5. Export + Reports
# ============================================================================
file mkdir ${OUT_DIR}/deploy
set bf [glob ${OUT_DIR}/${PROJ_NAME}.runs/impl_1/*.bit]
file copy -force $bf ${OUT_DIR}/deploy/cim_rv32_mzu15b.bit

open_run impl_1
report_utilization -file ${OUT_DIR}/utilization_report.txt
report_timing_summary -file ${OUT_DIR}/timing_report.txt

set wns [get_property STATS.WNS [get_runs impl_1]]
close_design

puts "============================================================"
puts "DONE: ${OUT_DIR}/deploy/cim_rv32_mzu15b.bit"
puts ""
puts "PS address map (M_AXI_HPM0_FPD):"
puts "  0xA000_0000 (32KB)  : FW BRAM"
puts "  0xA200_0000 (4KB)   : Result BRAM"
puts "  0xA300_0000 (4KB)   : GPIO (bit0=cpu_rst_n)"
puts ""
puts "Parameters:"
puts "  MAX_IN_DIM=3072, MAX_OUT_DIM=1024, PAR_OB=13, FCLK=${FCLK_MHZ}MHz"
puts "  BRAM primitives: ${bram_count}"
puts "  PAR_OB: 13"
puts "  WNS: ${wns} ns"
puts "============================================================"
