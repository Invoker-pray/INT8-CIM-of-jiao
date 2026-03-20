// ============================================================================
// weight_sram.sv — CIM Weight SRAM (pure whole-word BRAM)
// ============================================================================
// KEY RULE: Vivado BRAM inference requires PURE whole-word writes.
// Any bit-select, part-select, or read-modify-write in the always_ff
// block causes Vivado to fall back to LUTRAM/registers.
//
// Solution: This module only accepts whole-ROW writes (128 bits).
// The 32-bit chunk assembly is done OUTSIDE (in cim_axi_lite_slave)
// using a staging register. Once all chunks of a row are assembled,
// the AXI slave writes the full 128-bit row here in one cycle.
//
// Storage: TILE_ROWS independent BRAMs, each DEPTH × ROW_W bits.
//   GEN_BANK[r].bank_mem[tile_idx] = packed row r of that tile.
//
// Write: wr_en + wr_row + wr_tile_idx + wr_row_data[ROW_W-1:0]
//   Writes one complete row (128 bits) to bank[wr_row][wr_tile_idx].
//
// Read: rd_tile_idx → 1-cycle latency → rd_tile[TILE_ROWS][TILE_COLS]
// ============================================================================

module weight_sram
  import cim_pkg::*;
#(
    parameter int DEPTH = WSRAM_DEPTH
) (
    input logic clk,

    // --- Write port: whole-row write ---
    input logic                          wr_en,
    input logic [ $clog2(TILE_ROWS)-1:0] wr_row,       // which row (0..15)
    input logic [ clog2_safe(DEPTH)-1:0] wr_tile_idx,  // which tile
    input logic [TILE_COLS*WEIGHT_W-1:0] wr_row_data,  // full 128-bit row

    // --- Read port (registered, 1-cycle latency) ---
    input  logic [clog2_safe(DEPTH)-1:0]  rd_tile_idx,
    output logic signed [WEIGHT_W-1:0]    rd_tile [TILE_ROWS][TILE_COLS]
);

  localparam int ROW_W = TILE_COLS * WEIGHT_W;  // 128 bits

  // Read data intermediate
  logic [ROW_W-1:0] rd_row_data[TILE_ROWS];

  // Generate-split BRAM banks — pure whole-word read + write
  genvar gr, gc;
  generate
    for (gr = 0; gr < TILE_ROWS; gr++) begin : GEN_BANK
      (* ram_style = "block" *)
      logic [ROW_W-1:0] bank_mem[DEPTH];

      // Write: whole word, no bit-select
      always_ff @(posedge clk) begin
        if (wr_en && (wr_row == gr[$clog2(TILE_ROWS)-1:0])) bank_mem[wr_tile_idx] <= wr_row_data;
      end

      // Read: whole word
      always_ff @(posedge clk) begin
        rd_row_data[gr] <= bank_mem[rd_tile_idx];
      end
    end
  endgenerate

  // Unpack rows → individual signed INT8 elements
  generate
    for (gr = 0; gr < TILE_ROWS; gr++) begin : GEN_UNPACK_R
      for (gc = 0; gc < TILE_COLS; gc++) begin : GEN_UNPACK_C
        assign rd_tile[gr][gc] = signed'(rd_row_data[gr][gc*WEIGHT_W+:WEIGHT_W]);
      end
    end
  endgenerate

endmodule
