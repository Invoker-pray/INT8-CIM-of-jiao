// ============================================================================
// cim_rv32_top_wrapper.v — Verilog wrapper for Vivado Block Design
// ============================================================================

module cim_rv32_top_wrapper #(
    parameter CLK_FREQ  = 50000000,
    parameter BAUD_RATE = 115200
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        cpu_rst_n,     // PS controls: 0=hold CPU, 1=run
    output wire        uart_txd,
    output wire        cim_done_irq,

    // FW BRAM port B (PS writes firmware)
    input  wire        fw_b_en,
    input  wire [ 3:0] fw_b_we,
    input  wire [14:0] fw_b_addr,
    input  wire [31:0] fw_b_wdata,
    output wire [31:0] fw_b_rdata,

    // Result BRAM port B (PS reads results)
    input  wire        res_b_en,
    input  wire [ 3:0] res_b_we,
    input  wire [ 7:0] res_b_addr,
    input  wire [31:0] res_b_wdata,
    output wire [31:0] res_b_rdata
);

  cim_rv32_top #(
      .CLK_FREQ  (CLK_FREQ),
      .BAUD_RATE (BAUD_RATE)
  ) u_inner (
      .clk          (clk),
      .rst_n        (rst_n),
      .cpu_rst_n    (cpu_rst_n),
      .uart_txd     (uart_txd),
      .cim_done_irq (cim_done_irq),
      .fw_b_en      (fw_b_en),
      .fw_b_we      (fw_b_we),
      .fw_b_addr    (fw_b_addr),
      .fw_b_wdata   (fw_b_wdata),
      .fw_b_rdata   (fw_b_rdata),
      .res_b_en     (res_b_en),
      .res_b_we     (res_b_we),
      .res_b_addr   (res_b_addr),
      .res_b_wdata  (res_b_wdata),
      .res_b_rdata  (res_b_rdata)
  );

endmodule
