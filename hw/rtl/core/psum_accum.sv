// ============================================================================
// psum_accum.sv — Partial-sum accumulator bank
// ============================================================================
// Accumulates CIM tile outputs across input-block iterations.
// CRITICAL FIX vs FPGA_A: clear is synchronous and takes absolute priority.
//
// TILE_SPLIT_FACTOR:
//   1: accumulate full tile_psum in one shot
//   2: accumulate lo+hi halves together in same clock (en_lo + en_hi)
//   4: accumulate q0+q1+q2+q3 quarters together in same clock (en_q0..3)
// ============================================================================

module psum_accum
  import cim_pkg::*;
(
  input  logic                        clk,
  input  logic                        rst_n,
  input  logic                        clear,     // synchronous clear (highest priority)

  // SPLIT=1: accumulate full tile_psum
  input  logic                        en,
  input  logic signed [PSUM_W-1:0]    tile_psum [TILE_ROWS],

  // SPLIT=2: lo/hi halves
  input  logic                        en_lo,
  input  logic                        en_hi,
  input  logic signed [PSUM_W-1:0]    psum_lo_tile [TILE_ROWS],
  input  logic signed [PSUM_W-1:0]    psum_hi_tile [TILE_ROWS],

  // SPLIT=4: 4 quarters
  input  logic                        en_q0,
  input  logic                        en_q1,
  input  logic                        en_q2,
  input  logic                        en_q3,
  input  logic signed [PSUM_W-1:0]    psum_q0_tile [TILE_ROWS],
  input  logic signed [PSUM_W-1:0]    psum_q1_tile [TILE_ROWS],
  input  logic signed [PSUM_W-1:0]    psum_q2_tile [TILE_ROWS],
  input  logic signed [PSUM_W-1:0]    psum_q3_tile [TILE_ROWS],

  output logic signed [PSUM_W-1:0]    psum [TILE_ROWS]
);

  // Pre-compute all intermediate sums so lo+hi (or all 4 quarters) accumulate
  // together in the same clock edge. Without this, later enables overwrite earlier
  // contributions.
  logic signed [PSUM_W-1:0] psum_q0_acc [TILE_ROWS];
  logic signed [PSUM_W-1:0] psum_q01_acc [TILE_ROWS];
  logic signed [PSUM_W-1:0] psum_q012_acc [TILE_ROWS];
  logic signed [PSUM_W-1:0] psum_q0123_acc [TILE_ROWS];

  always_comb begin
    for (int i = 0; i < TILE_ROWS; i++) begin
      psum_q0_acc[i]    = psum[i] + psum_q0_tile[i];
      psum_q01_acc[i]   = psum[i] + psum_q0_tile[i] + psum_q1_tile[i];
      psum_q012_acc[i]  = psum[i] + psum_q0_tile[i] + psum_q1_tile[i] + psum_q2_tile[i];
      psum_q0123_acc[i] = psum[i] + psum_q0_tile[i] + psum_q1_tile[i]
                         + psum_q2_tile[i] + psum_q3_tile[i];
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < TILE_ROWS; i++)
        psum[i] <= '0;
    end else if (clear) begin
      for (int i = 0; i < TILE_ROWS; i++)
        psum[i] <= '0;
    end else if (TILE_SPLIT_FACTOR == 4) begin
      // SPLIT=4: all 4 quarters committed together in one clock edge
      if (en_q0 && en_q1 && en_q2 && en_q3) begin
        for (int i = 0; i < TILE_ROWS; i++)
          psum[i] <= psum_q0123_acc[i];
      end else if (en_q0 && en_q1 && en_q2) begin
        for (int i = 0; i < TILE_ROWS; i++)
          psum[i] <= psum_q012_acc[i];
      end else if (en_q0 && en_q1) begin
        for (int i = 0; i < TILE_ROWS; i++)
          psum[i] <= psum_q01_acc[i];
      end else if (en_q0) begin
        for (int i = 0; i < TILE_ROWS; i++)
          psum[i] <= psum_q0_acc[i];
      end
    end else if (TILE_SPLIT_FACTOR == 2) begin
      // SPLIT=2: lo+hi halves committed together in one clock edge
      if (en_lo && en_hi) begin
        for (int i = 0; i < TILE_ROWS; i++)
          psum[i] <= psum[i] + psum_lo_tile[i] + psum_hi_tile[i];
      end else if (en_lo) begin
        for (int i = 0; i < TILE_ROWS; i++)
          psum[i] <= psum[i] + psum_lo_tile[i];
      end else if (en_hi) begin
        for (int i = 0; i < TILE_ROWS; i++)
          psum[i] <= psum[i] + psum_hi_tile[i];
      end
    end else begin
      // SPLIT=1: accumulate full tile_psum
      if (en) begin
        for (int i = 0; i < TILE_ROWS; i++)
          psum[i] <= psum[i] + tile_psum[i];
      end
    end
  end

endmodule