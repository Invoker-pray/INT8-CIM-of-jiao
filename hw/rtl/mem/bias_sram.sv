// ============================================================================
// bias_sram.sv — CIM Bias SRAM (AXI-writable)
// ============================================================================
// Synchronous write, synchronous read (1-cycle latency).
// ============================================================================

module bias_sram
  import cim_pkg::*;
#(
    parameter int DEPTH = BSRAM_DEPTH  // number of output neurons
) (
    input logic clk,

    // --- Write port ---
    input logic                           wr_en,
    input logic [clog2_safe(DEPTH)-1:0]   wr_addr,
    input logic [31:0]                    wr_data,

    // --- Read port (1-cycle latency) ---
    input  logic [clog2_safe(DEPTH)-1:0]  rd_addr,
    output logic signed [BIAS_W-1:0]      rd_data
);

  logic [BIAS_W-1:0] mem [DEPTH];

  always_ff @(posedge clk) begin
    if (wr_en)
      mem[wr_addr] <= wr_data[BIAS_W-1:0];
  end

  always_ff @(posedge clk) begin
    rd_data <= signed'(mem[rd_addr]);
  end

endmodule
