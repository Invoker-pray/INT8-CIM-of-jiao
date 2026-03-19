// ============================================================================
// weight_sram.sv — Dual-port weight storage
// ============================================================================
// Port A (write): 32-bit granularity for AXI/CPU access
//   - CPU writes weight data 32 bits at a time
//   - tile_idx selects which tile, chunk_idx selects which 32-bit chunk within tile
//
// Port B (read): full tile-width read for CIM compute
//   - Reads an entire TILE_ROWS × TILE_COLS × WEIGHT_W bit tile in one cycle
//
// Implementation: true dual-port BRAM with asymmetric widths
// For synthesis, we use a single wide array and handle the asymmetry in logic.
// ============================================================================

module weight_sram
  import cim_pkg::*;
#(
  parameter int DEPTH = WSRAM_DEPTH   // number of tiles
) (
  input  logic                               clk,

  // --- Port A: CPU/AXI write (32-bit chunks) ---
  input  logic                               wr_en,
  input  logic [clog2_safe(DEPTH)-1:0]       wr_tile_idx,    // which tile
  input  logic [clog2_safe(WSRAM_WORD_W/32)-1:0] wr_chunk_idx,  // which 32-bit chunk
  input  logic [31:0]                        wr_data,

  // --- Port B: CIM read (full tile) ---
  input  logic [clog2_safe(DEPTH)-1:0]       rd_tile_idx,
  output logic signed [WEIGHT_W-1:0]         rd_tile [TILE_ROWS][TILE_COLS]
);

  localparam int CHUNKS_PER_TILE = WSRAM_WORD_W / 32;  // e.g. 2048/32 = 64

  // Storage: flat array of 32-bit words
  // Total words = DEPTH * CHUNKS_PER_TILE
  localparam int TOTAL_WORDS = DEPTH * CHUNKS_PER_TILE;

  (* ram_style = "block" *)
  logic [31:0] mem [TOTAL_WORDS];

  // Read side: assemble full tile from consecutive 32-bit words
  logic [WSRAM_WORD_W-1:0] tile_word;

  // Port A: write
  always_ff @(posedge clk) begin
    if (wr_en) begin
      mem[wr_tile_idx * CHUNKS_PER_TILE + wr_chunk_idx] <= wr_data;
    end
  end

  // Port B: read — gather all chunks of the requested tile
  // For BRAM inference, we read one word per cycle and use a shift register
  // Alternative: use a wider BRAM if tool supports it
  //
  // Simple approach: registered tile word with multi-cycle assembly
  // But for CIM compute, we need the full tile in one read.
  // Solution: use a separate wide BRAM for the read port.
  //
  // PRACTICAL APPROACH: We store data in BOTH a narrow array (for writes)
  // and a wide array (for reads). Writes update both.

  (* ram_style = "block" *)
  logic [WSRAM_WORD_W-1:0] tile_mem [DEPTH];

  // Write: update the wide array at the appropriate chunk position
  always_ff @(posedge clk) begin
    if (wr_en) begin
      tile_mem[wr_tile_idx][wr_chunk_idx*32 +: 32] <= wr_data;
    end
  end

  // Read: synchronous, full-tile width
  always_ff @(posedge clk) begin
    tile_word <= tile_mem[rd_tile_idx];
  end

  // Unpack tile_word into 2D weight array
  always_comb begin
    for (int r = 0; r < TILE_ROWS; r++) begin
      for (int c = 0; c < TILE_COLS; c++) begin
        automatic int flat = r * TILE_COLS + c;
        rd_tile[r][c] = tile_word[flat*WEIGHT_W +: WEIGHT_W];
      end
    end
  end

  // Optional: $readmemh for simulation/initial load
  // synthesis translate_off
  initial begin
    for (int i = 0; i < DEPTH; i++)
      tile_mem[i] = '0;
  end
  // synthesis translate_on

endmodule
