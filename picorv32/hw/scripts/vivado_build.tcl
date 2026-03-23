# ============================================================================
# vivado_build.tcl — Build PicoRV32 + CIM SoC bitstream for PYNQ-Z2
# ============================================================================
# Pure-PL design (no Zynq PS / no Block Design).
# Top module: cim_rv32_fpga_top
#
# Usage:
#   vivado -mode batch -source picorv32/hw/scripts/vivado_build.tcl
#   or: bash picorv32/hw/scripts/vivado_build.sh
#
# What it does:
#   1. Create project targeting xc7z020clg400-1
#   2. Add CIM IP RTL + PicoRV32 RTL + FPGA wrapper
#   3. Copy firmware.hex into project for BRAM init
#   4. Run synth → impl → write_bitstream
#   5. Export .bit for deployment
# ============================================================================

# --- Configuration ---
set PROJ_NAME  "cim_rv32_soc"
set PART       "xc7z020clg400-1"
set BOARD_PART "tul.com.tw:pynq-z2:part0:1.0"
set N_JOBS     4

# --- Paths (relative to where vivado is invoked = project root) ---
set PROJ_ROOT  [pwd]
set CIM_HW     "hw"                      ;# shared CIM IP
set RV_HW      "picorv32/hw"             ;# PicoRV32 SoC RTL
set FW_DIR     "picorv32/fw"             ;# firmware
set OUT_DIR    "picorv32/vivado_proj"

puts "============================================================"
puts "PicoRV32 + CIM SoC — Vivado Build (Pure PL)"
puts "  Project root : ${PROJ_ROOT}"
puts "  Output       : ${OUT_DIR}"
puts "============================================================"

# ============================================================================
# 1. Create project
# ============================================================================
create_project ${PROJ_NAME} ./${OUT_DIR} -part ${PART} -force

if {![catch {set_property board_part ${BOARD_PART} [current_project]}]} {
    puts "INFO: Board part ${BOARD_PART} applied."
} else {
    puts "WARN: Board part not found. Using part ${PART} only."
}

# ============================================================================
# 2. Add RTL sources
# ============================================================================

# --- CIM IP (shared with PS version) ---
set cim_files [list \
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
]

# --- PicoRV32 SoC ---
set rv_files [list \
    ${RV_HW}/rtl/riscv/picorv32.v \
    ${RV_HW}/rtl/riscv/uart_tx.sv \
    ${RV_HW}/rtl/riscv/picorv32_cim_bridge.sv \
    ${RV_HW}/rtl/riscv/cim_rv32_top.sv \
    ${RV_HW}/rtl/riscv/cim_rv32_fpga_top.v \
]

set all_files [concat ${cim_files} ${rv_files}]
add_files -norecurse ${all_files}

# Constraints
add_files -fileset constrs_1 -norecurse ${RV_HW}/constraints/cim_rv32_pynq.xdc

# File types
set_property file_type SystemVerilog [get_files *.sv]
set_property file_type Verilog       [get_files *.v]

# Top module
set_property top cim_rv32_fpga_top [current_fileset]
update_compile_order -fileset sources_1

puts "INFO: Added [llength ${all_files}] RTL files."

# ============================================================================
# 3. Copy firmware.hex into project directory
# ============================================================================
# $readmemh resolves relative to the Vivado run directory.
# Copy firmware.hex so synthesis can find it.
set fw_hex "${FW_DIR}/firmware.hex"
if {[file exists ${fw_hex}]} {
    # Copy to multiple locations where Vivado might look
    file copy -force ${fw_hex} ${OUT_DIR}/firmware.hex
    file mkdir ${OUT_DIR}/${PROJ_NAME}.runs
    puts "INFO: firmware.hex copied to ${OUT_DIR}/"
} else {
    puts "WARN: ${fw_hex} not found!"
    puts "  Run: cd picorv32/fw && make DATA_DIR=small_mlp_data"
    puts "  BRAM will be empty — CPU will not execute."
}

# ============================================================================
# 4. Synthesis
# ============================================================================
puts "INFO: Launching synthesis..."
launch_runs synth_1 -jobs ${N_JOBS}
wait_on_run synth_1

if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
    puts "ERROR: Synthesis failed!"
    exit 1
}
puts "INFO: Synthesis complete."

# Post-synth checks
open_run synth_1
set bram_count [llength [get_cells -hierarchical -filter {PRIMITIVE_TYPE =~ BMEM.*}]]
set dsp_count  [llength [get_cells -hierarchical -filter {PRIMITIVE_TYPE =~ MULT.*}]]
puts "INFO: BRAM primitives: ${bram_count}, DSP primitives: ${dsp_count}"
report_utilization -file ${OUT_DIR}/synth_utilization.txt
close_design

# ============================================================================
# 5. Implementation + Bitstream
# ============================================================================
# Copy firmware.hex to impl run directory (where Vivado actually executes)
set impl_dir "${OUT_DIR}/${PROJ_NAME}.runs/impl_1"
file mkdir ${impl_dir}
if {[file exists ${fw_hex}]} {
    file copy -force ${fw_hex} ${impl_dir}/firmware.hex
}

# Also copy to synth run directory
set synth_dir "${OUT_DIR}/${PROJ_NAME}.runs/synth_1"
if {[file exists ${fw_hex}]} {
    file copy -force ${fw_hex} ${synth_dir}/firmware.hex
}

puts "INFO: Launching implementation + bitstream..."
launch_runs impl_1 -to_step write_bitstream -jobs ${N_JOBS}
wait_on_run impl_1

if {[get_property STATUS [get_runs impl_1]] ne "write_bitstream Complete!"} {
    puts "ERROR: Implementation/bitstream failed!"
    exit 1
}
puts "INFO: Bitstream generated."

# ============================================================================
# 6. Export bitstream
# ============================================================================
set bit_file [glob ${OUT_DIR}/${PROJ_NAME}.runs/impl_1/cim_rv32_fpga_top.bit]

file mkdir ${OUT_DIR}/deploy
file copy -force ${bit_file} ${OUT_DIR}/deploy/cim_rv32_soc.bit

puts "============================================================"
puts "BUILD COMPLETE"
puts "  Bitstream : ${OUT_DIR}/deploy/cim_rv32_soc.bit"
puts ""
puts "  Program FPGA:"
puts "    open_hw_manager"
puts "    connect_hw_server"
puts "    open_hw_target"
puts "    set_property PROGRAM.FILE {${OUT_DIR}/deploy/cim_rv32_soc.bit} [get_hw_devices]"
puts "    program_hw_device [get_hw_devices]"
puts ""
puts "  Or use openFPGALoader:"
puts "    openFPGALoader -b pynq_z2 ${OUT_DIR}/deploy/cim_rv32_soc.bit"
puts ""
puts "  Connect USB-TTL to PMODA pin 1 (Y18), open minicom:"
puts "    minicom -D /dev/ttyUSBx -b 115200"
puts "============================================================"

# Reports
open_run impl_1
report_utilization -file ${OUT_DIR}/utilization_report.txt
report_timing_summary -file ${OUT_DIR}/timing_report.txt
puts "INFO: Reports saved to ${OUT_DIR}/"
close_design
