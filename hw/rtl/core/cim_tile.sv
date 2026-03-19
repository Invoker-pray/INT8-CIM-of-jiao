// ============================================================================
// cim_tile.sv — Atomic CIM compute unit
// ============================================================================
// Computes: tile_psum[r] = Σ_{c=0}^{TILE_COLS-1} x_eff[c] * w[r][c]
//
// Pure combinational — the tile is a "memory array doing computation"
// x_eff is unsigned (after zero-point subtraction), w is signed INT8
// Result is signed PSUM_W-bit partial sum per output row
// ============================================================================

module cim_tile
  import cim_pkg::*;
(
  input  logic [X_EFF_W-1:0]               x_eff  [TILE_COLS],
  input  logic signed [WEIGHT_W-1:0]        w_tile [TILE_ROWS][TILE_COLS],
  output logic signed [PSUM_W-1:0]          psum   [TILE_ROWS]
);

  // Each row: dot product of x_eff (unsigned) and w_tile[row] (signed)
  always_comb begin
    for (int r = 0; r < TILE_ROWS; r++) begin
      automatic logic signed [PSUM_W-1:0] acc = '0;
      for (int c = 0; c < TILE_COLS; c++) begin
        // Sign-extend unsigned x_eff to signed, then multiply with signed weight
        acc = acc + $signed({1'b0, x_eff[c]}) * w_tile[r][c];
      end
      psum[r] = acc;
    end
  end

endmodule
