// ============================================================================
// cim_tile.sv — Atomic CIM compute unit
// ============================================================================
// Computes: tile_psum[r] = Σ_{c=0}^{TILE_COLS-1} x_eff[c] * w[r][c]
//
// Pure combinational — the tile is a "memory array doing computation".
// x_eff is unsigned (after zero-point subtraction), w is signed INT8.
// Result is signed PSUM_W-bit partial sum per output row.
//
// C1 (TILE_SPLIT_FACTOR=2): 16→8+8 split for 100-125 MHz timing closure.
//   ST_MAC_LO: compute lo-chain for columns [0:7] → psum_lo[r]
//   ST_MAC_HI: compute hi-chain for columns [8:15] → psum_hi[r]
//   ST_COMPUTE: psum_lo + psum_hi → tile_psum[r] (registered in accel_core)
// ============================================================================

module cim_tile
  import cim_pkg::*;
(
  input  logic [X_EFF_W-1:0]               x_eff  [TILE_COLS],
  input  logic signed [WEIGHT_W-1:0]        w_tile [TILE_ROWS][TILE_COLS],

  // C1: SPLIT_FACTOR=2 exposes lo/hi partial sums separately
  output logic signed [PSUM_W-1:0]          psum   [TILE_ROWS],
  output logic signed [PSUM_W-1:0]          psum_lo[TILE_ROWS],  // C1 only
  output logic signed [PSUM_W-1:0]          psum_hi[TILE_ROWS]   // C1 only
);

  // Intermediate accumulator arrays
  logic signed [PSUM_W-1:0] acc [TILE_ROWS];

  genvar r, c;
  generate
    if (TILE_SPLIT_FACTOR == 1) begin : GEN_MONO
      // === Legacy 16-wide MAC chain (≤60 MHz) ===
      // 16 columns → 4 CARRY4 depth → ~16 ns path
      for (r = 0; r < TILE_ROWS; r++) begin : GEN_ROW_MONO
        logic signed [PSUM_W-1:0] row_acc [TILE_COLS+1];
        assign row_acc[0] = '0;
        for (c = 0; c < TILE_COLS; c++) begin : GEN_COL_MONO
          assign row_acc[c+1] = row_acc[c]
                              + $signed({1'b0, x_eff[c]}) * $signed(w_tile[r][c]);
        end
        assign acc[r] = row_acc[TILE_COLS];
      end
      assign psum = acc;
      // psum_lo/psum_hi unused when SPLIT_FACTOR=1, assign all zeros via generate
      for (r = 0; r < TILE_ROWS; r++) begin : GEN_LO_HI_ZERO
        assign psum_lo[r] = '0;
        assign psum_hi[r] = '0;
      end

    end else begin : GEN_SPLIT
      // === C1: 8+8 split MAC chain (100-125 MHz) ===
      // Each half: 8 columns → 2 CARRY4 depth → ~8 ns per half
      // acc[r] = psum_lo[r] + psum_hi[r] (merge in accel_core ST_COMPUTE)
      for (r = 0; r < TILE_ROWS; r++) begin : GEN_ROW_SPLIT
        // Low half: columns [0..7]
        logic signed [PSUM_W-1:0] lo_acc [9];
        assign lo_acc[0] = '0;
        for (c = 0; c < 8; c++) begin : GEN_LO
          assign lo_acc[c+1] = lo_acc[c]
                             + $signed({1'b0, x_eff[c]}) * $signed(w_tile[r][c]);
        end
        assign psum_lo[r] = lo_acc[8];

        // High half: columns [8..15]
        logic signed [PSUM_W-1:0] hi_acc [9];
        assign hi_acc[0] = '0;
        for (c = 0; c < 8; c++) begin : GEN_HI
          assign hi_acc[c+1] = hi_acc[c]
                             + $signed({1'b0, x_eff[c+8]}) * $signed(w_tile[r][c+8]);
        end
        assign psum_hi[r] = hi_acc[8];

        // Merge: full 16-column result (for validation only; accel_core uses lo/hi separately)
        assign acc[r] = psum_lo[r] + psum_hi[r];
      end
      assign psum = acc;  // full result (accel_core uses lo/hi for separate pipelining)
    end
  endgenerate

endmodule
