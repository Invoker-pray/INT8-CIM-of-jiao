// ============================================================================
// cim_rv32_top_wrapper.v — Pure Verilog wrapper for Vivado Block Design
// ============================================================================
// Vivado "Module Reference" (create_bd_cell -type module -reference ...)
// requires the top file to be plain Verilog (.v), not SystemVerilog (.sv).
// This wrapper instantiates the real cim_rv32_top.sv module and exposes
// identical ports.
// ============================================================================

module cim_rv32_top_wrapper #(
    parameter CLK_FREQ  = 50000000,
    parameter BAUD_RATE = 115200,
    parameter FW_HEX   = "firmware.hex"
) (
    input  wire        clk,
    input  wire        rst_n,
    output wire        uart_txd,
    output wire        cim_done_irq,

    // ---- Result BRAM port B (exposed to PS AXI) ----
    input  wire        res_b_en,
    input  wire [ 3:0] res_b_we,
    input  wire [ 7:0] res_b_addr,
    input  wire [31:0] res_b_wdata,
    output wire [31:0] res_b_rdata
);

  cim_rv32_top #(
      .CLK_FREQ  (CLK_FREQ),
      .BAUD_RATE (BAUD_RATE),
      .FW_HEX   (FW_HEX)
  ) u_inner (
      .clk          (clk),
      .rst_n        (rst_n),
      .uart_txd     (uart_txd),
      .cim_done_irq (cim_done_irq),
      .res_b_en     (res_b_en),
      .res_b_we     (res_b_we),
      .res_b_addr   (res_b_addr),
      .res_b_wdata  (res_b_wdata),
      .res_b_rdata  (res_b_rdata)
  );

endmodule
