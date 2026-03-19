// ============================================================================
// input_buffer.sv — CIM Input Buffer (AXI-writable, zero-point subtraction)
// ============================================================================
// Stores raw uint8 input vector. On read, outputs x_eff[TILE_COLS] tiles
// with zero-point subtracted (X_EFF_W-bit signed result).
//
// Write interface: scalar byte write (wr_addr, wr_data[INPUT_W-1:0]).
// Read interface:  rd_tile_idx selects which TILE_COLS-wide tile to read.
//                  x_tile  = raw uint8 values (for debug / direct use)
//                  x_eff   = uint8 - zp, clamped to ≥0, X_EFF_W-bit unsigned
//
// Interface matches tb_cim_accel_core and cim_accel_core exactly.
// ============================================================================

module input_buffer
  import cim_pkg::*;
#(
  parameter int MAX_LEN = MAX_IN_DIM   // maximum input vector length
) (
  input  logic clk,

  // --- Write port (byte-wide scalar) ---
  input  logic                              wr_en,
  input  logic [clog2_safe(MAX_LEN)-1:0]   wr_addr,
  input  logic [INPUT_W-1:0]               wr_data,

  // --- Read port ---
  input  logic [clog2_safe(MAX_LEN/TILE_COLS)-1:0]  rd_tile_idx,  // tile index (0-based)
  input  logic signed [31:0]                         input_zp,     // zero point (e.g. -128)

  // Raw tile (registered, 1-cycle latency)
  output logic [INPUT_W-1:0]       x_tile [TILE_COLS],

  // Effective tile after ZP subtraction (combinational from registered read)
  output logic [X_EFF_W-1:0]       x_eff  [TILE_COLS]
);

  logic [INPUT_W-1:0] mem [MAX_LEN];

  // -----------------------------------------------------------------------
  // Write: scalar byte write
  // -----------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (wr_en)
      mem[wr_addr] <= wr_data;
  end

  // -----------------------------------------------------------------------
  // Registered tile read — use generate to avoid 'automatic' in always_ff
  // (VCS 2018 does not support automatic variables inside always_ff).
  // Base address = rd_tile_idx * TILE_COLS
  // -----------------------------------------------------------------------
  genvar gc;
  generate
    for (gc = 0; gc < TILE_COLS; gc++) begin : GEN_IBUF_RD
      always_ff @(posedge clk) begin
        if (int'(rd_tile_idx) * TILE_COLS + gc < MAX_LEN)
          x_tile[gc] <= mem[rd_tile_idx * TILE_COLS + gc];
        else
          x_tile[gc] <= '0;
      end
    end
  endgenerate

  // -----------------------------------------------------------------------
  // Zero-point subtraction (combinational on registered x_tile)
  // x_eff = max(0, uint8(x_tile) - zp), saturated to [0, 2^X_EFF_W - 1]
  // -----------------------------------------------------------------------
  // Use intermediate signed wire to avoid automatic in always_comb
  logic signed [31:0] x_full [TILE_COLS];

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
