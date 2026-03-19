// ============================================================================
// psum_accum.sv — Partial-sum accumulator bank
// ============================================================================
// Accumulates CIM tile outputs across input-block iterations.
// CRITICAL FIX vs FPGA_A: clear is synchronous and takes absolute priority.
// The accumulator is guaranteed to be zero before the first en pulse.
// ============================================================================

module psum_accum
  import cim_pkg::*;
(
  input  logic                        clk,
  input  logic                        rst_n,
  input  logic                        clear,     // synchronous clear (highest priority)
  input  logic                        en,        // accumulate enable
  input  logic signed [PSUM_W-1:0]    tile_psum [TILE_ROWS],  // from CIM tile
  output logic signed [PSUM_W-1:0]    psum      [TILE_ROWS]   // accumulated result
);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < TILE_ROWS; i++)
        psum[i] <= '0;
    end else if (clear) begin
      // Absolute priority: always clears regardless of en
      for (int i = 0; i < TILE_ROWS; i++)
        psum[i] <= '0;
    end else if (en) begin
      for (int i = 0; i < TILE_ROWS; i++)
        psum[i] <= psum[i] + tile_psum[i];
    end
    // else: hold value
  end

endmodule
