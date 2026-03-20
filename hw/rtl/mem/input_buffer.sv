// ============================================================================
// input_buffer.sv — CIM Input Buffer (BRAM-friendly banked rewrite)
// ============================================================================
// FIX: Original used a single flat array with TILE_COLS (16) parallel reads
// at different addresses per cycle:
//     x_tile[gc] <= mem[rd_tile_idx * TILE_COLS + gc]
// Vivado sees this as a 16-port RAM → cannot map to BRAM → dissolved into
// registers → 37,840 cells of LUT/FF, blowing the xc7z020 LUT budget.
//
// Fix: Split the flat array into TILE_COLS independent BRAM banks.
//   Bank[c] stores the c-th element of every tile:
//     bank[c][tile_idx] = original mem[tile_idx * TILE_COLS + c]
//   Reading a tile: each bank reads at the SAME address (rd_tile_idx),
//   so each bank needs only 1 read port → Vivado infers BRAM.
//
// Write mapping: AXI writes scalar byte at flat address `wr_addr`.
//   bank_sel  = wr_addr % TILE_COLS   (which bank)
//   bank_addr = wr_addr / TILE_COLS   (which tile within that bank)
//
// External interface is UNCHANGED — drop-in replacement.
// ============================================================================

module input_buffer
  import cim_pkg::*;
#(
    parameter int MAX_LEN = MAX_IN_DIM  // maximum input vector length
) (
    input logic clk,

    // --- Write port (byte-wide scalar) ---
    input logic                           wr_en,
    input logic [clog2_safe(MAX_LEN)-1:0] wr_addr,
    input logic [            INPUT_W-1:0] wr_data,

    // --- Read port ---
    input logic        [clog2_safe(MAX_LEN/TILE_COLS)-1:0] rd_tile_idx,  // tile index (0-based)
    input logic signed [                             31:0] input_zp,     // zero point (e.g. -128)

    // Raw tile (registered, 1-cycle latency)
    output logic [INPUT_W-1:0] x_tile[TILE_COLS],

    // Effective tile after ZP subtraction (combinational from registered read)
    output logic [X_EFF_W-1:0] x_eff[TILE_COLS]
);

  // -----------------------------------------------------------------------
  // Bank geometry
  // -----------------------------------------------------------------------
  localparam int N_BANKS = TILE_COLS;  // 16
  localparam int BANK_DEPTH = (MAX_LEN + N_BANKS - 1) / N_BANKS;  // ceil(MAX_LEN / 16)
  localparam int BANK_AW = clog2_safe(BANK_DEPTH);
  localparam int COL_BITS = $clog2(N_BANKS);  // 4

  // -----------------------------------------------------------------------
  // Write address decode
  //   bank_sel  = wr_addr[COL_BITS-1:0]       (lower bits = which bank)
  //   bank_addr = wr_addr[...:COL_BITS]        (upper bits = tile index)
  // -----------------------------------------------------------------------
  wire [COL_BITS-1:0] wr_bank_sel = wr_addr[COL_BITS-1:0];
  wire [ BANK_AW-1:0] wr_bank_addr = wr_addr[COL_BITS+:BANK_AW];

  // -----------------------------------------------------------------------
  // Banked storage — one BRAM per column position
  // Each bank: BANK_DEPTH × INPUT_W bits
  //   For MAX_LEN=784: BANK_DEPTH=49, each bank = 49 × 8 = 392 bits
  //   (tiny, may become LUTRAM — that's fine, much smaller than 37K cells)
  //   For MAX_LEN=1024: BANK_DEPTH=64, each bank = 64 × 8 = 512 bits
  // -----------------------------------------------------------------------
  genvar gc;
  generate
    for (gc = 0; gc < N_BANKS; gc++) begin : GEN_BANK
      (* ram_style = "auto" *)
      logic [INPUT_W-1:0] bank_mem[BANK_DEPTH];

      // Write: only the selected bank accepts the write
      always_ff @(posedge clk) begin
        if (wr_en && (wr_bank_sel == gc[COL_BITS-1:0])) bank_mem[wr_bank_addr] <= wr_data;
      end

      // Read: all banks read at the same tile index (1-cycle latency)
      always_ff @(posedge clk) begin
        if (int'(rd_tile_idx) < BANK_DEPTH) x_tile[gc] <= bank_mem[rd_tile_idx];
        else x_tile[gc] <= '0;
      end
    end
  endgenerate

  // -----------------------------------------------------------------------
  // Zero-point subtraction (combinational on registered x_tile)
  // x_eff = max(0, uint8(x_tile) - zp), saturated to [0, 2^X_EFF_W - 1]
  // -----------------------------------------------------------------------
  logic signed [31:0] x_full[TILE_COLS];

  genvar gx;
  generate
    for (gx = 0; gx < TILE_COLS; gx++) begin : GEN_XEFF
      assign x_full[gx] = $signed({1'b0, x_tile[gx]}) - input_zp;
      assign x_eff[gx]  = (x_full[gx] < 0)                ? {X_EFF_W{1'b0}} :
                           (x_full[gx] > (2**X_EFF_W - 1))  ? {X_EFF_W{1'b1}} :
                                                               x_full[gx][X_EFF_W-1:0];
    end
  endgenerate

endmodule
