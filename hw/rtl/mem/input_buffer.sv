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
// Read: rd_tile_idx → 1-cycle latency → x_tile[TILE_COLS] + x_eff[TILE_COLS]
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

    // --- Read port ---
    input logic        [clog2_safe(MAX_LEN/TILE_COLS)-1:0] rd_tile_idx,
    input logic signed [                             31:0] input_zp,

    output logic [INPUT_W-1:0] x_tile[TILE_COLS],
    output logic [X_EFF_W-1:0] x_eff [TILE_COLS]
);

  localparam int TILE_W = TILE_COLS * INPUT_W;  // 128 bits
  localparam int DEPTH = (MAX_LEN + TILE_COLS - 1) / TILE_COLS;  // 49

  // BRAM: pure whole-word read + write
  (* ram_style = "block" *)
  logic [TILE_W-1:0] mem[DEPTH];

  // Write
  always_ff @(posedge clk) begin
    if (wr_en) mem[wr_tile_idx] <= wr_tile_data;
  end

  // Read
  logic [TILE_W-1:0] rd_word;
  always_ff @(posedge clk) begin
    rd_word <= mem[rd_tile_idx];
  end

  // Unpack
  genvar gc;
  generate
    for (gc = 0; gc < TILE_COLS; gc++) begin : GEN_UNPACK
      assign x_tile[gc] = rd_word[gc*INPUT_W+:INPUT_W];
    end
  endgenerate

  // Zero-point subtraction
  logic signed [31:0] x_full[TILE_COLS];
  genvar gx;
  generate
    for (gx = 0; gx < TILE_COLS; gx++) begin : GEN_XEFF
      assign x_full[gx] = $signed({1'b0, x_tile[gx]}) - input_zp;
      assign x_eff[gx]  = (x_full[gx] < 0)               ? {X_EFF_W{1'b0}} :
                           (x_full[gx] > (2**X_EFF_W - 1)) ? {X_EFF_W{1'b1}} :
                                                               x_full[gx][X_EFF_W-1:0];
    end
  endgenerate

endmodule
