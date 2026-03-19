// ============================================================================
// weight_sram.sv — CIM Weight SRAM (BRAM-friendly, generate-split banks)
// ============================================================================
// FIXES:
//   1. Split bank[TILE_ROWS][DEPTH] → TILE_ROWS independent generate-block
//      arrays to avoid Vivado's single-variable size limit (1M bits).
//   2. Replace partial bit-select write (bank[...][...][offset +: 32])
//      with a READ-MODIFY-WRITE pattern so Vivado can infer true BRAM.
//      Vivado requires whole-word writes for BRAM inference; bit-select
//      writes cause it to fall back to LUT/FF registers.
//
// Storage layout (unchanged from original):
//   GEN_BANK[r].bank_mem[tile_idx] = packed {w[r][TILE_COLS-1], ..., w[r][0]}
//   Each bank: DEPTH words × (TILE_COLS * WEIGHT_W) bits per word = 128b × D
//
// Write: 32-bit chunk interface. chunk_idx encodes (row, col_group).
//        Uses 2-cycle read-modify-write: read old word, merge 32-bit chunk,
//        write full word back. wr_en must be held for 2 cycles (which matches
//        the existing single-cycle pulse from CSR — the write completes in
//        the cycle after wr_en, using the registered address/data).
//
// Read: rd_tile_idx → 1-cycle latency → rd_tile[TILE_ROWS][TILE_COLS]
// ============================================================================

module weight_sram
  import cim_pkg::*;
#(
    parameter int DEPTH = WSRAM_DEPTH
) (
    input logic clk,

    // --- Write port (32-bit chunk, 4 weights per chunk) ---
    input logic                                   wr_en,
    input logic [          clog2_safe(DEPTH)-1:0] wr_tile_idx,
    input logic [clog2_safe(WSRAM_WORD_W/32)-1:0] wr_chunk_idx,
    input logic [                           31:0] wr_data,

    // --- Read port (registered, 1-cycle latency) ---
    input  logic        [clog2_safe(DEPTH)-1:0] rd_tile_idx,
    output logic signed [         WEIGHT_W-1:0] rd_tile    [TILE_ROWS][TILE_COLS]
);

  localparam int ELEMS_PER_CHUNK = 32 / WEIGHT_W;  // 4
  localparam int CHUNKS_PER_ROW = TILE_COLS / ELEMS_PER_CHUNK;  // 4
  localparam int ROW_W = TILE_COLS * WEIGHT_W;  // 128 bits

  // -----------------------------------------------------------------------
  // Write address decode
  // chunk_idx layout: [row_bits : col_group_bits]
  //   row       = chunk_idx / CHUNKS_PER_ROW
  //   col_group = chunk_idx % CHUNKS_PER_ROW
  // -----------------------------------------------------------------------
  localparam int CG_BITS = $clog2(CHUNKS_PER_ROW);  // 2
  localparam int ROW_BITS = $clog2(TILE_ROWS);  // 4

  wire  [ROW_BITS-1:0] wr_row = wr_chunk_idx[CG_BITS+:ROW_BITS];
  wire  [ CG_BITS-1:0] wr_col_group = wr_chunk_idx[CG_BITS-1:0];

  // -----------------------------------------------------------------------
  // Read data intermediate (one per bank)
  // -----------------------------------------------------------------------
  logic [   ROW_W-1:0] rd_row_data                              [TILE_ROWS];

  // -----------------------------------------------------------------------
  // Generate-split BRAM banks with read-modify-write for partial updates
  // -----------------------------------------------------------------------
  genvar gr, gc;
  generate
    for (gr = 0; gr < TILE_ROWS; gr++) begin : GEN_BANK
      (* ram_style = "block" *)
      logic [            ROW_W-1:0] bank_mem   [DEPTH];

      // --- Write path: read-modify-write for BRAM compatibility ---
      // Stage 1: register write request, read old value
      logic                         wr_pending;
      logic [clog2_safe(DEPTH)-1:0] wr_addr_r;
      logic [          CG_BITS-1:0] wr_cg_r;
      logic [                 31:0] wr_data_r;
      logic [            ROW_W-1:0] rmw_old;

      always_ff @(posedge clk) begin
        // Default: clear pending
        wr_pending <= 1'b0;

        // Stage 1: Capture write request and read old word
        if (wr_en && (wr_row == gr[ROW_BITS-1:0])) begin
          wr_pending <= 1'b1;
          wr_addr_r  <= wr_tile_idx;
          wr_cg_r    <= wr_col_group;
          wr_data_r  <= wr_data;
          rmw_old    <= bank_mem[wr_tile_idx];  // BRAM read
        end

        // Stage 2: Merge and write back full word
        if (wr_pending) begin : RMW_WRITE
          logic [ROW_W-1:0] merged;
          merged = rmw_old;
          merged[wr_cg_r*32+:32] = wr_data_r;
          bank_mem[wr_addr_r] <= merged;  // BRAM write (full word)
        end
      end

      // --- Read path: registered output (1-cycle latency) ---
      always_ff @(posedge clk) begin
        rd_row_data[gr] <= bank_mem[rd_tile_idx];
      end
    end
  endgenerate

  // -----------------------------------------------------------------------
  // Unpack packed row → individual signed INT8 elements
  // -----------------------------------------------------------------------
  generate
    for (gr = 0; gr < TILE_ROWS; gr++) begin : GEN_UNPACK_R
      for (gc = 0; gc < TILE_COLS; gc++) begin : GEN_UNPACK_C
        assign rd_tile[gr][gc] = signed'(rd_row_data[gr][gc*WEIGHT_W+:WEIGHT_W]);
      end
    end
  endgenerate

endmodule
