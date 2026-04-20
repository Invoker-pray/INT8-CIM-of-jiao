// ============================================================================
// cim_tile.sv — Atomic CIM compute unit
// ============================================================================
// Computes: tile_psum[r] = Σ_{c=0}^{TILE_COLS-1} x_eff[c] * w[r][c]
//
// Pure combinational — the tile is a "memory array doing computation".
// x_eff is unsigned (after zero-point subtraction), w is signed INT8.
// Result is signed PSUM_W-bit partial sum per output row.
//
// TILE_SPLIT_FACTOR:
//   1: 16-wide MAC chain in one cycle (≤60 MHz)
//   2: 8+8 split over two cycles (100-125 MHz) - psum_lo, psum_hi exposed
//   4: 4+4+4+4 split over four cycles (100+ MHz) - psum_q0..3 exposed
//
// Each quarter has ~4 DSP48 multipliers + 1 CARRY4 → ~5 ns path, fits 10 ns period.
// ============================================================================

module cim_tile
  import cim_pkg::*;
(
  input  logic [X_EFF_W-1:0]               x_eff  [TILE_COLS],
  input  logic signed [WEIGHT_W-1:0]        w_tile [TILE_ROWS][TILE_COLS],

  // Full result (for validation only when SPLIT>1)
  output logic signed [PSUM_W-1:0]          psum   [TILE_ROWS],

  // SPLIT=2: lo/hi halves (cols 0-7 / 8-15)
  output logic signed [PSUM_W-1:0]          psum_lo[TILE_ROWS],
  output logic signed [PSUM_W-1:0]          psum_hi[TILE_ROWS],

  // SPLIT=4: quarter outputs (cols 0-3 / 4-7 / 8-11 / 12-15)
  output logic signed [PSUM_W-1:0]          psum_q0[TILE_ROWS],
  output logic signed [PSUM_W-1:0]          psum_q1[TILE_ROWS],
  output logic signed [PSUM_W-1:0]          psum_q2[TILE_ROWS],
  output logic signed [PSUM_W-1:0]          psum_q3[TILE_ROWS]
);

  // Intermediate accumulator array
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
      for (r = 0; r < TILE_ROWS; r++) begin : GEN_LO_HI_ZERO
        assign psum_lo[r] = '0;
        assign psum_hi[r] = '0;
        assign psum_q0[r] = '0;
        assign psum_q1[r] = '0;
        assign psum_q2[r] = '0;
        assign psum_q3[r] = '0;
      end

    end else if (TILE_SPLIT_FACTOR == 2) begin : GEN_SPLIT2
      // === SPLIT=2: 8+8 split (100-125 MHz) ===
      // Each half: 8 columns → 2 CARRY4 depth → ~8 ns per half
      for (r = 0; r < TILE_ROWS; r++) begin : GEN_ROW_SPLIT2
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

        // Merge: full result (validation only)
        assign acc[r] = psum_lo[r] + psum_hi[r];
        assign psum_q0[r] = '0;
        assign psum_q1[r] = '0;
        assign psum_q2[r] = '0;
        assign psum_q3[r] = '0;
      end
      assign psum = acc;

    end else begin : GEN_SPLIT4
      // === SPLIT=4: 4+4+4+4 split (100+ MHz) ===
      // Each quarter: 4 columns → 1 CARRY4 → ~5 ns per quarter
      // Goal: 4 quarters × ~5 ns = ~5 ns total via pipeline → fits 10 ns period
      for (r = 0; r < TILE_ROWS; r++) begin : GEN_ROW_SPLIT4
        // Quarter 0: columns [0..3]
        logic signed [PSUM_W-1:0] q0_acc [5];
        assign q0_acc[0] = '0;
        for (c = 0; c < 4; c++) begin : GEN_Q0
          assign q0_acc[c+1] = q0_acc[c]
                             + $signed({1'b0, x_eff[c]}) * $signed(w_tile[r][c]);
        end
        assign psum_q0[r] = q0_acc[4];

        // Quarter 1: columns [4..7]
        logic signed [PSUM_W-1:0] q1_acc [5];
        assign q1_acc[0] = '0;
        for (c = 0; c < 4; c++) begin : GEN_Q1
          assign q1_acc[c+1] = q1_acc[c]
                             + $signed({1'b0, x_eff[c+4]}) * $signed(w_tile[r][c+4]);
        end
        assign psum_q1[r] = q1_acc[4];

        // Quarter 2: columns [8..11]
        logic signed [PSUM_W-1:0] q2_acc [5];
        assign q2_acc[0] = '0;
        for (c = 0; c < 4; c++) begin : GEN_Q2
          assign q2_acc[c+1] = q2_acc[c]
                             + $signed({1'b0, x_eff[c+8]}) * $signed(w_tile[r][c+8]);
        end
        assign psum_q2[r] = q2_acc[4];

        // Quarter 3: columns [12..15]
        logic signed [PSUM_W-1:0] q3_acc [5];
        assign q3_acc[0] = '0;
        for (c = 0; c < 4; c++) begin : GEN_Q3
          assign q3_acc[c+1] = q3_acc[c]
                             + $signed({1'b0, x_eff[c+12]}) * $signed(w_tile[r][c+12]);
        end
        assign psum_q3[r] = q3_acc[4];

        // Merge: full result (validation only)
        assign acc[r] = psum_q0[r] + psum_q1[r] + psum_q2[r] + psum_q3[r];
        assign psum_lo[r] = '0;  // unused for SPLIT=4
        assign psum_hi[r] = '0;
      end
      assign psum = acc;
    end
  endgenerate

endmodule