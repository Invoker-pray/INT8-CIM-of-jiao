// ============================================================================
// input_buffer.sv — Input activation buffer with zero-point subtraction
// ============================================================================
// Port A: CPU/AXI writes input[i] one element at a time (8-bit packed in 32-bit)
// Port B: CIM reads a tile of TILE_COLS elements, with automatic zp subtraction
//
// Storage is organized as packed tiles for efficient BRAM read.
// CPU writes element-by-element; a small FSM packs them into tiles.
// Alternatively, CPU can write pre-packed tiles directly.
//
// SIMPLIFIED APPROACH: store as flat array, read with address math.
// ============================================================================

module input_buffer
  import cim_pkg::*;
#(
  parameter int MAX_LEN = MAX_IN_DIM
) (
  input  logic                              clk,

  // --- Write port (CPU/AXI) ---
  input  logic                              wr_en,
  input  logic [clog2_safe(MAX_LEN)-1:0]    wr_addr,    // element index
  input  logic [INPUT_W-1:0]                wr_data,    // 8-bit input value

  // --- Read port (CIM) ---
  input  logic [clog2_safe(MAX_LEN/TILE_COLS)-1:0] rd_tile_idx,  // input block index
  input  logic signed [31:0]                input_zp,   // zero point from CSR

  output logic signed [INPUT_W-1:0]         x_tile   [TILE_COLS],  // raw input tile
  output logic        [X_EFF_W-1:0]         x_eff    [TILE_COLS]   // after zp subtraction
);

  localparam int N_TILES = MAX_LEN / TILE_COLS;
  localparam int TILE_BITS = TILE_COLS * INPUT_W;

  // Store as packed tiles for single-cycle read
  (* ram_style = "block" *)
  logic [TILE_BITS-1:0] tile_mem [N_TILES];

  logic [TILE_BITS-1:0] tile_word_r;

  // --- Write: CPU writes individual elements ---
  // We pack them into tiles on the fly
  // Element addr / TILE_COLS = tile index
  // Element addr % TILE_COLS = position within tile
  always_ff @(posedge clk) begin
    if (wr_en) begin
      automatic int tile_idx = wr_addr / TILE_COLS;
      automatic int elem_pos = wr_addr % TILE_COLS;
      tile_mem[tile_idx][elem_pos*INPUT_W +: INPUT_W] <= wr_data;
    end
  end

  // --- Read: synchronous full-tile read ---
  always_ff @(posedge clk) begin
    tile_word_r <= tile_mem[rd_tile_idx];
  end

  // --- Unpack + zero-point subtraction ---
  logic signed [31:0] x_tmp [TILE_COLS];

  always_comb begin
    for (int c = 0; c < TILE_COLS; c++) begin
      x_tile[c] = tile_word_r[c*INPUT_W +: INPUT_W];

      // x_eff = x_raw - zp, clamped to unsigned [0, 2^X_EFF_W - 1]
      x_tmp[c] = $signed(x_tile[c]) - input_zp;

      if (x_tmp[c] < 0)
        x_eff[c] = '0;
      else if (x_tmp[c] > ((1 << X_EFF_W) - 1))
        x_eff[c] = {X_EFF_W{1'b1}};
      else
        x_eff[c] = x_tmp[c][X_EFF_W-1:0];
    end
  end

  // synthesis translate_off
  initial begin
    for (int i = 0; i < N_TILES; i++) tile_mem[i] = '0;
  end
  // synthesis translate_on

endmodule
