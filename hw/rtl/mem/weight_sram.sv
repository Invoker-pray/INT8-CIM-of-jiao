// ============================================================================
// weight_sram.sv — CIM Weight SRAM
// ============================================================================
// Storage layout: DEPTH tiles, each [TILE_ROWS][TILE_COLS] INT8 words.
//
// Write: byte-granular. wr_tile_idx + wr_chunk_idx together form a flat
//        byte address within the tile.
//        flat_byte = wr_tile_idx * TILE_ELEMS + wr_chunk_idx * ELEMS_PER_CHUNK + byte_in_chunk
//        For simplicity we expose a 32-bit chunk write interface matching
//        the testbench: each chunk holds ELEMS_PER_CHUNK=4 weight bytes,
//        addressed as mem_byte[wr_tile_idx*TILE_ELEMS + wr_chunk_idx*4 + 0..3].
//
// Read: registered (1-cycle latency), outputs rd_tile[TILE_ROWS][TILE_COLS].
//
// KEY CHANGE: uses a flat byte memory (logic [WEIGHT_W-1:0] mem[DEPTH*TILE_ELEMS])
// so that each element has its own memory word — no chunk unpacking needed
// in the read path, eliminating all VCS 2018 compatibility issues.
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

  localparam int ELEMS_PER_CHUNK = 32 / WEIGHT_W;          // 4 for INT8
  localparam int TOTAL_ELEMS     = DEPTH * TILE_ELEMS;      // total weight bytes

  // Flat byte memory: one INT8 word per weight element
  logic signed [WEIGHT_W-1:0] mem [TOTAL_ELEMS];

  // -----------------------------------------------------------------------
  // Write: unpack 32-bit chunk into ELEMS_PER_CHUNK individual bytes
  // Base byte address = (wr_tile_idx * TILE_ELEMS) + (wr_chunk_idx * ELEMS_PER_CHUNK)
  // -----------------------------------------------------------------------
  // Pre-compute base address as a wide wire to avoid expression in always_ff
  logic [31:0] wr_base;
  assign wr_base = ({20'd0, wr_tile_idx} * 32'd256)   // TILE_ELEMS = 256
                 + ({26'd0, wr_chunk_idx} * 32'd4);    // ELEMS_PER_CHUNK = 4

  always_ff @(posedge clk) begin
    if (wr_en) begin
      mem[wr_base + 0] <= signed'(wr_data[ 7: 0]);
      mem[wr_base + 1] <= signed'(wr_data[15: 8]);
      mem[wr_base + 2] <= signed'(wr_data[23:16]);
      mem[wr_base + 3] <= signed'(wr_data[31:24]);
    end
  end

  // -----------------------------------------------------------------------
  // Read: registered, read each [r][c] directly from its flat byte address.
  // flat_byte = rd_tile_idx * 256 + r * 16 + c
  // rd_base is a 32-bit wire shared across all elements in the tile.
  // Each generate instance adds its constant OFFSET at elaboration time.
  // -----------------------------------------------------------------------
  logic [31:0] rd_base;
  assign rd_base = {20'd0, rd_tile_idx} * 32'd256;

  genvar gr, gc;
  generate
    for (gr = 0; gr < TILE_ROWS; gr++) begin : GEN_R
      for (gc = 0; gc < TILE_COLS; gc++) begin : GEN_C
        localparam int OFFSET = gr * TILE_COLS + gc;

        wire [31:0] rd_elem_addr;
        assign rd_elem_addr = rd_base + OFFSET;  // OFFSET is a constant int

        always_ff @(posedge clk) begin
          rd_tile[gr][gc] <= mem[rd_elem_addr];
        end
      end
    end
  endgenerate

endmodule
