// ============================================================================
// cim_tile.sv — Atomic CIM compute unit with DSP-inferable MAC reuse
// ============================================================================
// Computes: tile_psum[r] = Σ_{c=0}^{TILE_COLS-1} x_eff[c] * w[r][c]
//
// x_eff is SIGNED after zero-point subtraction, w is signed INT8.
// Result is signed PSUM_W-bit partial sum per output row.
//
// TILE_SPLIT_FACTOR:
//   1: 16-wide MAC chain in one cycle (legacy, ≤60 MHz)
//   2: 8+8 split over two cycles
//   4: 4+4+4+4 split over four cycles
//
// TILE_MAC_REUSE=1 + C4_MUL_PIPE=1:
//   Phase-latched inputs → DSP48 multiply → product register → CARRY4 accumulate
//   Breaks the DSP→CARRY4 critical path. FSM adds 1 cycle per quarter for
//   the MUL state. 80 MHz target with WNS margin.
// ============================================================================

module cim_tile
  import cim_pkg::*;
(
  input  logic                              clk,        // C4: clock for product register
  input  logic signed [X_EFF_W-1:0]        x_eff  [TILE_COLS],
  input  logic signed [WEIGHT_W-1:0]       w_tile [TILE_ROWS][TILE_COLS],
  input  logic [1:0]                       phase_sel,

  // Full result (for validation only when SPLIT>1 and TILE_MAC_REUSE=0)
  output logic signed [PSUM_W-1:0]         psum   [TILE_ROWS],

  // SPLIT=2: lo/hi halves (cols 0-7 / 8-15)
  output logic signed [PSUM_W-1:0]         psum_lo[TILE_ROWS],
  output logic signed [PSUM_W-1:0]         psum_hi[TILE_ROWS],

  // SPLIT=4: quarter outputs (cols 0-3 / 4-7 / 8-11 / 12-15)
  output logic signed [PSUM_W-1:0]         psum_q0[TILE_ROWS],
  output logic signed [PSUM_W-1:0]         psum_q1[TILE_ROWS],
  output logic signed [PSUM_W-1:0]         psum_q2[TILE_ROWS],
  output logic signed [PSUM_W-1:0]         psum_q3[TILE_ROWS]
);

  localparam int PHASE_COLS = (TILE_SPLIT_FACTOR <= 1) ? TILE_COLS :
                                (TILE_COLS / TILE_SPLIT_FACTOR);

  genvar r, c;
  generate
    if (TILE_MAC_REUSE && C4_MUL_PIPE) begin : GEN_REUSE_PIPED
      // ==================================================================
      // C4 pipelined: register DSP48 multiply outputs before accumulation.
      // Critical path becomes: reg→DSP48→reg (multiply, ~3ns) + reg→CARRY4→reg
      // (accumulate, ~0.5ns). Each stage fits easily in 10ns @ 100MHz.
      // FSM requires ST_MAC_Q*_M state between ST_MAC_Q*_L and ST_MAC_Q*.
      // ==================================================================

      // Registered multiply products (latched during ST_MAC_Q*_M)
      logic signed [PSUM_W-1:0] prod_r [TILE_ROWS][PHASE_COLS];

      // Combinational: multiply x_eff × w_tile (DSP48-inferable)
      for (r = 0; r < TILE_ROWS; r++) begin : GEN_ROW_PIPE
        for (c = 0; c < PHASE_COLS; c++) begin : GEN_COL_PIPE
          (* use_dsp = "yes" *) logic signed [PSUM_W-1:0] mac_product;
          assign mac_product = $signed(x_eff[c]) * $signed(w_tile[r][c]);

          always_ff @(posedge clk) begin
            prod_r[r][c] <= mac_product;
          end
        end

        // Accumulate from REGISTERED products (fast CARRY4 chain)
        if (PHASE_COLS == 4) begin : GEN_ACC4_P
          assign psum_q0[r] = prod_r[r][0] + prod_r[r][1] + prod_r[r][2] + prod_r[r][3];
          assign psum_q1[r] = psum_q0[r];
          assign psum_q2[r] = psum_q0[r];
          assign psum_q3[r] = psum_q0[r];
          assign psum[r]    = psum_q0[r];
        end
        if (PHASE_COLS == 8) begin : GEN_ACC8_P
          assign psum_lo[r] = prod_r[r][0] + prod_r[r][1] + prod_r[r][2] + prod_r[r][3]
                            + prod_r[r][4] + prod_r[r][5] + prod_r[r][6] + prod_r[r][7];
          assign psum_hi[r] = psum_lo[r];
          assign psum[r] = psum_lo[r];
          assign psum_q0[r] = '0; assign psum_q1[r] = '0;
          assign psum_q2[r] = '0; assign psum_q3[r] = '0;
        end
        assign psum_lo[r] = '0; assign psum_hi[r] = '0;
      end

    end else if (TILE_MAC_REUSE) begin : GEN_REUSE
      // ==================================================================
      // C4: cim_accel_core pre-muxes x_eff/w_tile into columns 0..PHASE_COLS-1
      // and REGISTERS them before this tile sees them. No internal MUX.
      // ==================================================================

      for (r = 0; r < TILE_ROWS; r++) begin : GEN_ROW_REUSE
        for (c = 0; c < PHASE_COLS; c++) begin : GEN_W_MUX
          (* use_dsp = "yes" *) logic signed [PSUM_W-1:0] mac_product;
          assign mac_product = $signed(x_eff[c]) * $signed(w_tile[r][c]);
        end

        if (PHASE_COLS == 4) begin : GEN_ACC4
          assign psum_q0[r] = GEN_W_MUX[0].mac_product + GEN_W_MUX[1].mac_product
                            + GEN_W_MUX[2].mac_product + GEN_W_MUX[3].mac_product;
          assign psum_q1[r] = psum_q0[r]; assign psum_q2[r] = psum_q0[r];
          assign psum_q3[r] = psum_q0[r]; assign psum[r] = psum_q0[r];
        end else if (PHASE_COLS == 8) begin : GEN_ACC8
          assign psum_lo[r] = GEN_W_MUX[0].mac_product + GEN_W_MUX[1].mac_product
                            + GEN_W_MUX[2].mac_product + GEN_W_MUX[3].mac_product
                            + GEN_W_MUX[4].mac_product + GEN_W_MUX[5].mac_product
                            + GEN_W_MUX[6].mac_product + GEN_W_MUX[7].mac_product;
          assign psum_hi[r] = psum_lo[r]; assign psum[r] = psum_lo[r];
          assign psum_q0[r] = '0; assign psum_q1[r] = '0;
          assign psum_q2[r] = '0; assign psum_q3[r] = '0;
        end else begin : GEN_ACC16
          logic signed [PSUM_W-1:0] row_acc [17];
          assign row_acc[0] = '0;
          for (c = 0; c < 16; c++) begin : GEN_A
            assign row_acc[c+1] = row_acc[c] + GEN_W_MUX[c].mac_product;
          end
          assign psum[r] = row_acc[16];
        end
        assign psum_lo[r] = '0; assign psum_hi[r] = '0;
      end

    end else if (TILE_SPLIT_FACTOR == 4) begin : GEN_SPLIT4
      for (r = 0; r < TILE_ROWS; r++) begin : GEN_ROW_SPLIT4
        logic signed [PSUM_W-1:0] q0_acc [5], q1_acc [5], q2_acc [5], q3_acc [5];
        assign q0_acc[0] = '0; assign q1_acc[0] = '0;
        assign q2_acc[0] = '0; assign q3_acc[0] = '0;
        for (c = 0; c < 4; c++) begin
          assign q0_acc[c+1] = q0_acc[c] + $signed(x_eff[c]) * $signed(w_tile[r][c]);
          assign q1_acc[c+1] = q1_acc[c] + $signed(x_eff[c+4]) * $signed(w_tile[r][c+4]);
          assign q2_acc[c+1] = q2_acc[c] + $signed(x_eff[c+8]) * $signed(w_tile[r][c+8]);
          assign q3_acc[c+1] = q3_acc[c] + $signed(x_eff[c+12]) * $signed(w_tile[r][c+12]);
        end
        assign psum_q0[r] = q0_acc[4]; assign psum_q1[r] = q1_acc[4];
        assign psum_q2[r] = q2_acc[4]; assign psum_q3[r] = q3_acc[4];
        assign psum[r] = psum_q0[r] + psum_q1[r] + psum_q2[r] + psum_q3[r];
        assign psum_lo[r] = '0; assign psum_hi[r] = '0;
      end
    end else if (TILE_SPLIT_FACTOR == 2) begin : GEN_SPLIT2
      for (r = 0; r < TILE_ROWS; r++) begin : GEN_ROW_SPLIT2
        logic signed [PSUM_W-1:0] lo_acc [9], hi_acc [9];
        assign lo_acc[0] = '0; assign hi_acc[0] = '0;
        for (c = 0; c < 8; c++) begin
          assign lo_acc[c+1] = lo_acc[c] + $signed(x_eff[c]) * $signed(w_tile[r][c]);
          assign hi_acc[c+1] = hi_acc[c] + $signed(x_eff[c+8]) * $signed(w_tile[r][c+8]);
        end
        assign psum_lo[r] = lo_acc[8]; assign psum_hi[r] = hi_acc[8];
        assign psum[r] = psum_lo[r] + psum_hi[r];
        assign psum_q0[r] = '0; assign psum_q1[r] = '0;
        assign psum_q2[r] = '0; assign psum_q3[r] = '0;
      end
    end else begin : GEN_MONO
      for (r = 0; r < TILE_ROWS; r++) begin : GEN_ROW_MONO
        logic signed [PSUM_W-1:0] row_acc [TILE_COLS+1];
        assign row_acc[0] = '0;
        for (c = 0; c < TILE_COLS; c++) begin
          assign row_acc[c+1] = row_acc[c] + $signed(x_eff[c]) * $signed(w_tile[r][c]);
        end
        assign psum[r] = row_acc[TILE_COLS];
      end
      for (r = 0; r < TILE_ROWS; r++) begin
        assign psum_lo[r] = '0; assign psum_hi[r] = '0;
        assign psum_q0[r] = '0; assign psum_q1[r] = '0;
        assign psum_q2[r] = '0; assign psum_q3[r] = '0;
      end
    end
  endgenerate

endmodule
