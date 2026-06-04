// ============================================================================
// input_buffer.sv — CIM Input Buffer (pure whole-word BRAM)
// ============================================================================
// Same BRAM-friendly principle as weight_sram: only whole-word writes.
// The AXI slave assembles individual bytes into a full 128-bit tile word
// using a staging register, then writes the complete word here.
//
// Storage: single BRAM, width = TILE_COLS * INPUT_W = 128 bits,
//          depth = ceil(MAX_LEN / TILE_COLS).
//
// Write: wr_en + wr_tile_idx + wr_tile_data[127:0]
//        Writes one complete tile (16 bytes packed) in one cycle.
//
// Read: rd_tile_idx → 1-cycle latency → rd_word, then registered x_tile/x_eff
// C1: Added output pipeline register to break BRAM→x_eff combinational path
//      for 100 MHz timing closure (was ~10.35ns critical path).
//
// C4 fix: x_eff is now SIGNED. The previous implementation clamped
//         (x_uint8 - input_zp) to [0, 511], which silently broke standard
//         affine UINT8 zero-points when x < zp. This version computes a
//         signed 10-bit effective activation and only saturates if software
//         programs an out-of-range zero-point.
// ============================================================================

module input_buffer
  import cim_pkg::*;
#(
    parameter int MAX_LEN = MAX_IN_DIM
) (
    input logic clk,

    // --- Write port: whole-tile write ---
    input logic                                     wr_en,
    input logic [clog2_safe(MAX_LEN/TILE_COLS)-1:0] wr_tile_idx,
    input logic [            TILE_COLS*INPUT_W-1:0] wr_tile_data, // full 128-bit tile

    // --- Phase B: Bank select ---
    input logic                                     wr_bank_sel,
    input logic                                     rd_bank_sel,

    // --- Read port ---
    input logic        [clog2_safe(MAX_LEN/TILE_COLS)-1:0] rd_tile_idx,
    input logic signed [                             31:0] input_zp,

    output logic        [INPUT_W-1:0] x_tile[TILE_COLS],
    output logic signed [X_EFF_W-1:0] x_eff [TILE_COLS]
);

  localparam int TILE_W = TILE_COLS * INPUT_W;  // 128 bits
  localparam int DEPTH = (MAX_LEN + TILE_COLS - 1) / TILE_COLS;  // 49
  localparam int signed XEFF_MIN = -(1 <<< (X_EFF_W-1));
  localparam int signed XEFF_MAX =  (1 <<< (X_EFF_W-1)) - 1;
  localparam logic signed [X_EFF_W-1:0] XEFF_MIN_VAL = XEFF_MIN;
  localparam logic signed [X_EFF_W-1:0] XEFF_MAX_VAL = XEFF_MAX;

  // BRAM: dual-bank
  (* ram_style = "block" *)
  logic [TILE_W-1:0] bank0[DEPTH];
  (* ram_style = "block" *)
  logic [TILE_W-1:0] bank1[DEPTH];

  // Write
  always_ff @(posedge clk) begin
    if (wr_en) begin
      if (wr_bank_sel) bank1[wr_tile_idx] <= wr_tile_data;
      else             bank0[wr_tile_idx] <= wr_tile_data;
    end
  end

  // Read (1-cycle BRAM latency)
  logic [TILE_W-1:0] rd_word;
  always_ff @(posedge clk) begin
    if (rd_bank_sel) rd_word <= bank1[rd_tile_idx];
    else             rd_word <= bank0[rd_tile_idx];
  end

  // Unpack (combinational)
  logic [INPUT_W-1:0] x_tile_comb[TILE_COLS];
  genvar gc;
  generate
    for (gc = 0; gc < TILE_COLS; gc++) begin : GEN_UNPACK
      assign x_tile_comb[gc] = rd_word[gc*INPUT_W+:INPUT_W];
    end
  endgenerate

  // Signed zero-point subtraction (combinational)
  logic signed [31:0] x_full[TILE_COLS];
  logic signed [X_EFF_W-1:0] x_eff_comb[TILE_COLS];
  genvar gx;
  generate
    for (gx = 0; gx < TILE_COLS; gx++) begin : GEN_XEFF
      assign x_full[gx] = $signed({1'b0, x_tile_comb[gx]}) - input_zp;
      assign x_eff_comb[gx] = (x_full[gx] < XEFF_MIN) ? XEFF_MIN_VAL :
                              (x_full[gx] > XEFF_MAX) ? XEFF_MAX_VAL :
                                                         x_full[gx][X_EFF_W-1:0];
    end
  endgenerate

  // Output pipeline register
  always_ff @(posedge clk) begin
    for (int c = 0; c < TILE_COLS; c++) begin
      x_tile[c] <= x_tile_comb[c];
      x_eff[c]  <= x_eff_comb[c];
    end
  end

endmodule
