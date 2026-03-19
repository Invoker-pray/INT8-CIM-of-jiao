// ============================================================================
// cim_tile.sv — Atomic CIM compute unit
// ============================================================================
// Computes: tile_psum[r] = Σ_{c=0}^{TILE_COLS-1} x_eff[c] * w[r][c]
//
// Pure combinational — the tile is a "memory array doing computation".
// x_eff is unsigned (after zero-point subtraction), w is signed INT8.
// Result is signed PSUM_W-bit partial sum per output row.
// ============================================================================

module cim_tile
  import cim_pkg::*;
(
  input  logic [X_EFF_W-1:0]               x_eff  [TILE_COLS],
  input  logic signed [WEIGHT_W-1:0]        w_tile [TILE_ROWS][TILE_COLS],
  output logic signed [PSUM_W-1:0]          psum   [TILE_ROWS]
);

  // Intermediate accumulator array (avoids 'automatic' inside always_comb)
  logic signed [PSUM_W-1:0] acc [TILE_ROWS];

  // Row-wise dot product: accumulate across columns combinationally
  genvar r, c;
  generate
    for (r = 0; r < TILE_ROWS; r++) begin : GEN_ROW
      // Start from 0 and add each column's contribution
      // Use a chain of assign statements via an intermediate wire array
      logic signed [PSUM_W-1:0] row_acc [TILE_COLS+1];
      assign row_acc[0] = '0;
      for (c = 0; c < TILE_COLS; c++) begin : GEN_COL
        assign row_acc[c+1] = row_acc[c]
                            + $signed({1'b0, x_eff[c]}) * $signed(w_tile[r][c]);
      end
      assign acc[r] = row_acc[TILE_COLS];
    end
  endgenerate

  // Drive output
  always_comb begin
    for (int i = 0; i < TILE_ROWS; i++)
      psum[i] = acc[i];
  end

endmodule
