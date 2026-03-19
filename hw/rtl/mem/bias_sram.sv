// ============================================================================
// bias_sram.sv — Dual-port bias storage
// ============================================================================
// Port A: CPU/AXI writes bias[i] as 32-bit signed integers
// Port B: CIM reads bias values during computation
// ============================================================================

module bias_sram
  import cim_pkg::*;
#(
  parameter int DEPTH = BSRAM_DEPTH
) (
  input  logic                           clk,

  // Port A: write
  input  logic                           wr_en,
  input  logic [clog2_safe(DEPTH)-1:0]   wr_addr,
  input  logic [31:0]                    wr_data,

  // Port B: read
  input  logic [clog2_safe(DEPTH)-1:0]   rd_addr,
  output logic signed [BIAS_W-1:0]       rd_data
);

  (* ram_style = "block" *)
  logic [BIAS_W-1:0] mem [DEPTH];

  // Port A: write
  always_ff @(posedge clk) begin
    if (wr_en)
      mem[wr_addr] <= wr_data[BIAS_W-1:0];
  end

  // Port B: synchronous read (1-cycle latency)
  always_ff @(posedge clk) begin
    rd_data <= mem[rd_addr];
  end

  // synthesis translate_off
  initial begin
    for (int i = 0; i < DEPTH; i++) mem[i] = '0;
  end
  // synthesis translate_on

endmodule
