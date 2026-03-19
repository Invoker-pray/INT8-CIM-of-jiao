// ============================================================================
// weight_sram.sv — CIM Weight SRAM (BRAM-friendly rewrite)
// ============================================================================
// FIX vs previous version:
//   Old: flat byte array mem[TOTAL_ELEMS] with variable index → synthesizes
//        as massive MUX tree or register file, NOT BRAM.
//   New: TILE_ROWS parallel BRAM banks. Each bank stores one row of every
//        tile. Read returns a full tile in one cycle via parallel bank reads.
//
// Storage layout:
//   bank[r][tile_idx] = packed {w[r][TILE_COLS-1], ..., w[r][0]}
//   Each bank: DEPTH words × (TILE_COLS * WEIGHT_W) bits per word
//
// Write: 32-bit chunk interface (same as before for SW compatibility).
//   chunk_idx → (row, col_group) mapping, partial-word write to bank.
//
// Read: rd_tile_idx → 1-cycle latency → rd_tile[TILE_ROWS][TILE_COLS]
// ============================================================================

module weight_sram
  import cim_pkg::*;
#(
  parameter int DEPTH = WSRAM_DEPTH
) (
  input  logic clk,

  // --- Write port (32-bit chunk, 4 weights per chunk) ---
  input  logic                                    wr_en,
  input  logic [clog2_safe(DEPTH)-1:0]            wr_tile_idx,
  input  logic [clog2_safe(WSRAM_WORD_W/32)-1:0]  wr_chunk_idx,
  input  logic [31:0]                              wr_data,

  // --- Read port (registered, 1-cycle latency) ---
  input  logic [clog2_safe(DEPTH)-1:0]            rd_tile_idx,
  output logic signed [WEIGHT_W-1:0]              rd_tile [TILE_ROWS][TILE_COLS]
);

  localparam int ELEMS_PER_CHUNK = 32 / WEIGHT_W;                         // 4
  localparam int CHUNKS_PER_ROW  = TILE_COLS / ELEMS_PER_CHUNK;           // 4
  localparam int ROW_W           = TILE_COLS * WEIGHT_W;                  // 128 bits

  // -----------------------------------------------------------------------
  // BRAM banks — one per tile row, Vivado infers Block RAM
  // -----------------------------------------------------------------------
  (* ram_style = "block" *)
  logic [ROW_W-1:0] bank [TILE_ROWS][DEPTH];

  // -----------------------------------------------------------------------
  // Write address decode
  // chunk_idx layout: [row_bits : col_group_bits]
  //   row       = chunk_idx / CHUNKS_PER_ROW
  //   col_group = chunk_idx % CHUNKS_PER_ROW
  // -----------------------------------------------------------------------
  localparam int CG_BITS = $clog2(CHUNKS_PER_ROW);   // 2
  localparam int ROW_BITS = $clog2(TILE_ROWS);         // 4

  wire [ROW_BITS-1:0] wr_row       = wr_chunk_idx[CG_BITS +: ROW_BITS];
  wire [CG_BITS-1:0]  wr_col_group = wr_chunk_idx[CG_BITS-1:0];

  always_ff @(posedge clk) begin
    if (wr_en) begin
      // Partial-word write: 32 bits into the correct column group
      // bit_offset = col_group * 32
      bank[wr_row][wr_tile_idx][wr_col_group * 32 +: 32] <= wr_data;
    end
  end

  // -----------------------------------------------------------------------
  // Read: all TILE_ROWS banks in parallel, registered output
  // -----------------------------------------------------------------------
  logic [ROW_W-1:0] rd_row_data [TILE_ROWS];

  genvar gr, gc;
  generate
    for (gr = 0; gr < TILE_ROWS; gr++) begin : GEN_RD_BANK
      always_ff @(posedge clk) begin
        rd_row_data[gr] <= bank[gr][rd_tile_idx];
      end
    end
  endgenerate

  // Unpack packed row → individual signed INT8 elements
  generate
    for (gr = 0; gr < TILE_ROWS; gr++) begin : GEN_UNPACK_R
      for (gc = 0; gc < TILE_COLS; gc++) begin : GEN_UNPACK_C
        assign rd_tile[gr][gc] = signed'(rd_row_data[gr][gc*WEIGHT_W +: WEIGHT_W]);
      end
    end
  endgenerate

endmodule
