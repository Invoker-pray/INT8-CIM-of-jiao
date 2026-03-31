# ============================================================================
# vivado_build.tcl — PicoRV32 + CIM SoC: PS loads firmware at runtime
# ============================================================================
#
# PS AXI address map:
#   0x4000_0000 (32KB) : FW BRAM port B    — PS writes firmware here
#   0x4200_0000 (4KB)  : Result BRAM port B — PS reads inference results
#   0x4300_0000 (4KB)  : AXI GPIO          — bit[0] = cpu_rst_n (0=hold,1=run)
#
# Workflow (PYNQ Python):
#   gpio.write(0, 0)        # hold CPU
#   fw_mmio.write(i*4, w)   # write firmware words
#   gpio.write(0, 1)        # release CPU
#   while res_mmio.read(0) != 0xC1AA0001: sleep
#   pred = res_mmio.read(4) # read result
# ============================================================================

set PROJ_NAME  "cim_rv32_soc"
set PART       "xc7z020clg400-1"
set BOARD_PART "tul.com.tw:pynq-z2:part0:1.0"
set N_JOBS     4
set CIM_HW     "hw"
set RV_HW      "picorv32/hw"
set OUT_DIR    "picorv32/vivado_proj"

create_project ${PROJ_NAME} ./${OUT_DIR} -part ${PART} -force
catch {set_property board_part ${BOARD_PART} [current_project]}

# ---- RTL ----
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
add_files -fileset constrs_1 -norecurse ${RV_HW}/constraints/cim_rv32_pynq.xdc
set_property file_type SystemVerilog [get_files *.sv]
set_property file_type Verilog       [get_files *.v]

# ============================================================================
# Block Design
# ============================================================================
create_bd_design "system"

# ---- PS7 ----
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7
catch {apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR"} [get_bd_cells ps7]}
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {50} \
] [get_bd_cells ps7]

# ---- rv32_soc (module reference) ----
create_bd_cell -type module -reference cim_rv32_top_wrapper rv32

# ---- Reset ----
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_ps
connect_bd_net [get_bd_pins ps7/FCLK_CLK0]      [get_bd_pins rst_ps/slowest_sync_clk]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N]  [get_bd_pins rst_ps/ext_reset_in]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0]      [get_bd_pins rv32/clk]
connect_bd_net [get_bd_pins rst_ps/peripheral_aresetn] [get_bd_pins rv32/rst_n]

# ---- AXI GPIO for cpu_rst_n ----
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 gpio_cpu_rst
set_property -dict [list \
    CONFIG.C_GPIO_WIDTH {1} \
    CONFIG.C_ALL_OUTPUTS {1} \
    CONFIG.C_DOUT_DEFAULT {0x00000000} \
] [get_bd_cells gpio_cpu_rst]
# GPIO output bit[0] → cpu_rst_n
connect_bd_net [get_bd_pins gpio_cpu_rst/gpio_io_o] [get_bd_pins rv32/cpu_rst_n]

# ---- FW BRAM Controller (32KB, port B) ----
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 fw_bram_ctrl
set_property -dict [list \
    CONFIG.SINGLE_PORT_BRAM {1} \
    CONFIG.DATA_WIDTH {32} \
    CONFIG.PROTOCOL {AXI4LITE} \
] [get_bd_cells fw_bram_ctrl]

# Connect FW BRAM ctrl → rv32 fw_b_* ports
connect_bd_net [get_bd_pins fw_bram_ctrl/bram_en_a]     [get_bd_pins rv32/fw_b_en]
connect_bd_net [get_bd_pins fw_bram_ctrl/bram_we_a]     [get_bd_pins rv32/fw_b_we]
connect_bd_net [get_bd_pins fw_bram_ctrl/bram_wrdata_a] [get_bd_pins rv32/fw_b_wdata]
connect_bd_net [get_bd_pins fw_bram_ctrl/bram_rddata_a] [get_bd_pins rv32/fw_b_rdata]

# Address slice for fw_b_addr (15-bit from wider BRAM ctrl addr)
create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 fw_addr_slice
set_property -dict [list CONFIG.DIN_WIDTH {32} CONFIG.DIN_FROM {14} CONFIG.DIN_TO {0} CONFIG.DOUT_WIDTH {15}] [get_bd_cells fw_addr_slice]
connect_bd_net [get_bd_pins fw_bram_ctrl/bram_addr_a] [get_bd_pins fw_addr_slice/Din]
connect_bd_net [get_bd_pins fw_addr_slice/Dout]       [get_bd_pins rv32/fw_b_addr]

# ---- Result BRAM Controller (256B, port B) ----
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 res_bram_ctrl
set_property -dict [list \
    CONFIG.SINGLE_PORT_BRAM {1} \
    CONFIG.DATA_WIDTH {32} \
    CONFIG.PROTOCOL {AXI4LITE} \
] [get_bd_cells res_bram_ctrl]

connect_bd_net [get_bd_pins res_bram_ctrl/bram_en_a]     [get_bd_pins rv32/res_b_en]
connect_bd_net [get_bd_pins res_bram_ctrl/bram_we_a]     [get_bd_pins rv32/res_b_we]
connect_bd_net [get_bd_pins res_bram_ctrl/bram_wrdata_a] [get_bd_pins rv32/res_b_wdata]
connect_bd_net [get_bd_pins res_bram_ctrl/bram_rddata_a] [get_bd_pins rv32/res_b_rdata]

create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 res_addr_slice
set_property -dict [list CONFIG.DIN_WIDTH {32} CONFIG.DIN_FROM {7} CONFIG.DIN_TO {0} CONFIG.DOUT_WIDTH {8}] [get_bd_cells res_addr_slice]
connect_bd_net [get_bd_pins res_bram_ctrl/bram_addr_a] [get_bd_pins res_addr_slice/Din]
connect_bd_net [get_bd_pins res_addr_slice/Dout]       [get_bd_pins rv32/res_b_addr]

# ---- AXI connections (PS GP0 → all 3 slaves) ----
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
    Clk_master {/ps7/FCLK_CLK0} Clk_slave {Auto} Clk_xbar {Auto} \
    Master {/ps7/M_AXI_GP0} Slave {/fw_bram_ctrl/S_AXI} \
    intc_ip {New AXI Interconnect} master_apm {0}] \
    [get_bd_intf_pins fw_bram_ctrl/S_AXI]

apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
    Clk_master {/ps7/FCLK_CLK0} Clk_slave {Auto} Clk_xbar {Auto} \
    Master {/ps7/M_AXI_GP0} Slave {/res_bram_ctrl/S_AXI} \
    intc_ip {/ps7_axi_periph} master_apm {0}] \
    [get_bd_intf_pins res_bram_ctrl/S_AXI]

apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
    Clk_master {/ps7/FCLK_CLK0} Clk_slave {Auto} Clk_xbar {Auto} \
    Master {/ps7/M_AXI_GP0} Slave {/gpio_cpu_rst/S_AXI} \
    intc_ip {/ps7_axi_periph} master_apm {0}] \
    [get_bd_intf_pins gpio_cpu_rst/S_AXI]

# ---- External pins ----
make_bd_pins_external [get_bd_pins rv32/uart_txd]
make_bd_pins_external [get_bd_pins rv32/cim_done_irq]

# ---- Address map ----
assign_bd_address -offset 0x40000000 -range 32K [get_bd_addr_segs {fw_bram_ctrl/S_AXI/Mem0}]
assign_bd_address -offset 0x42000000 -range 4K  [get_bd_addr_segs {res_bram_ctrl/S_AXI/Mem0}]
assign_bd_address -offset 0x43000000 -range 4K  [get_bd_addr_segs {gpio_cpu_rst/S_AXI/Reg}]

validate_bd_design
save_bd_design

# ---- Build ----
make_wrapper -files [get_files system.bd] -top
set wf [glob -nocomplain ${OUT_DIR}/${PROJ_NAME}.gen/sources_1/bd/system/hdl/system_wrapper.v]
if {$wf eq ""} { set wf [glob ${OUT_DIR}/${PROJ_NAME}.srcs/sources_1/bd/system/hdl/system_wrapper.v] }
add_files -norecurse $wf
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1

launch_runs synth_1 -jobs $N_JOBS
wait_on_run synth_1

launch_runs impl_1 -to_step write_bitstream -jobs $N_JOBS
wait_on_run impl_1

# ---- Export ----
file mkdir ${OUT_DIR}/deploy
set bf [glob ${OUT_DIR}/${PROJ_NAME}.runs/impl_1/*.bit]
file copy -force $bf ${OUT_DIR}/deploy/cim_rv32_soc.bit
write_hw_platform -fixed -include_bit -force ${OUT_DIR}/deploy/cim_rv32_soc.xsa
catch {exec unzip -o -j ${OUT_DIR}/deploy/cim_rv32_soc.xsa *.hwh -d ${OUT_DIR}/deploy/}
foreach h [glob -nocomplain ${OUT_DIR}/deploy/*.hwh] { file rename -force $h ${OUT_DIR}/deploy/cim_rv32_soc.hwh; break }

open_run impl_1
report_utilization -file ${OUT_DIR}/utilization_report.txt
report_timing_summary -file ${OUT_DIR}/timing_report.txt
close_design

puts "============================================================"
puts "DONE: ${OUT_DIR}/deploy/cim_rv32_soc.{bit,hwh}"
puts "PS address map:"
puts "  0x4000_0000 (32KB) : FW BRAM"
puts "  0x4200_0000 (4KB)  : Result BRAM"
puts "  0x4300_0000 (4KB)  : GPIO (bit0=cpu_rst_n)"
puts "============================================================"
