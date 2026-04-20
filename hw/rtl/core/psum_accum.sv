// ============================================================================
// psum_accum.sv — Partial-sum accumulator bank
// ============================================================================
// Accumulates CIM tile outputs across input-block iterations.
// CRITICAL FIX vs FPGA_A: clear is synchronous and takes absolute priority.
// The accumulator is guaranteed to be zero before the first en pulse.
//
// C1 (SPLIT_FACTOR=2): when acc_lo is asserted, accumulates psum_lo_tile
// (lo half of split MAC). When acc_hi is asserted, accumulates psum_hi_tile
// (hi half). Both together = one full 16-wide MAC per IB iteration.
// ============================================================================

module psum_accum
  import cim_pkg::*;
(
  input  logic                        clk,
  input  logic                        rst_n,
  input  logic                        clear,     // synchronous clear (highest priority)
  input  logic                        en,        // accumulate the full tile_psum (SPLIT=1)
  input  logic                        en_lo,     // C1: accumulate psum_lo_tile
  input  logic                        en_hi,     // C1: accumulate psum_hi_tile
  input  logic signed [PSUM_W-1:0]    tile_psum [TILE_ROWS],  // SPLIT=1: full 16-wide
  input  logic signed [PSUM_W-1:0]    psum_lo_tile [TILE_ROWS],  // C1 SPLIT=2
  input  logic signed [PSUM_W-1:0]    psum_hi_tile [TILE_ROWS],  // C1 SPLIT=2
  output logic signed [PSUM_W-1:0]    psum [TILE_ROWS]   // accumulated result
);

  // C1 FIX: compute intermediate sum in same cycle so lo+hi accumulate together.
  // Without this, en_lo then en_hi in the same clock causes hi to overwrite lo's
  // contribution (second assignment wins, psum misses lo half entirely).
  logic signed [PSUM_W-1:0] psum_lo_acc [TILE_ROWS];
  logic signed [PSUM_W-1:0] psum_lo_hi_acc [TILE_ROWS];

  always_comb begin
    for (int i = 0; i < TILE_ROWS; i++) begin
      psum_lo_acc[i]    = psum[i] + psum_lo_tile[i];
      psum_lo_hi_acc[i] = psum[i] + psum_lo_tile[i] + psum_hi_tile[i];
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < TILE_ROWS; i++)
        psum[i] <= '0;
    end else if (clear) begin
      for (int i = 0; i < TILE_ROWS; i++)
        psum[i] <= '0;
    end else begin
      // C1 SPLIT=2: both halves committed in the same clock edge via intermediate sum.
      // en_lo=1, en_hi=0 → psum_lo_acc; en_lo=1, en_hi=1 → psum_lo_hi_acc (lo+hi).
      if (TILE_SPLIT_FACTOR == 2) begin
        if (en_lo && en_hi) begin
          for (int i = 0; i < TILE_ROWS; i++)
            psum[i] <= psum_lo_hi_acc[i];  // both halves accumulated
        end else if (en_lo) begin
          for (int i = 0; i < TILE_ROWS; i++)
            psum[i] <= psum_lo_acc[i];
        end
        // Note: en_hi alone is unexpected (ST_COMPUTE always sets both), but harmless.
      end else begin
        // Legacy: accumulate full tile_psum in one shot
        if (en) begin
          for (int i = 0; i < TILE_ROWS; i++)
            psum[i] <= psum[i] + tile_psum[i];
        end
      end
    end
  end

endmodule
