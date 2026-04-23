// ============================================================================
// cim_accel_core.sv — CIM Accelerator Core
// ============================================================================
//
// C1/C2 pipeline (TILE_SPLIT_FACTOR):
//
//   SPLIT=1 (≤60 MHz):
//     ST_MAC_LO │ full 16-wide MAC -> tile_psum_reg
//     ST_COMPUTE │ accumulate tile_psum_reg
//
//   SPLIT=2 (100-125 MHz):
//     ST_MAC_LO │ lo-chain MAC (cols 0-7) -> tile_psum_lo_reg
//     ST_MAC_HI │ hi-chain MAC (cols 8-15) -> tile_psum_hi_reg
//     ST_COMPUTE │ accumulate lo+hi together in one clock
//
//   SPLIT=4 (100+ MHz):
//     ST_MAC_Q0 │ quarter 0 MAC (cols 0-3) -> tile_psum_q0_reg
//     ST_MAC_Q1 │ quarter 1 MAC (cols 4-7) -> tile_psum_q1_reg
//     ST_MAC_Q2 │ quarter 2 MAC (cols 8-11) -> tile_psum_q2_reg
//     ST_MAC_Q3 │ quarter 3 MAC (cols 12-15) -> tile_psum_q3_reg
//     ST_COMPUTE │ accumulate q0+q1+q2+q3 together in one clock
//
// Cost vs SPLIT=1: +1 cycle (SPLIT=2), +3 cycles (SPLIT=4) per IB iteration.
// But frequency: 1.67x (60->100 MHz), 2.08x (60->125 MHz).
// Net throughput gain: SPLIT=2 ~1.87x, SPLIT=4 ~1.67x (but WNS positive).
//
// ============================================================================

module cim_accel_core
  import cim_pkg::*;
(
    input logic clk,
    input logic rst_n,

    input  logic         start,
    input  logic         soft_rst,
    output logic         busy,
    output logic         done,
    output accel_state_t dbg_state,

    input logic [15:0] cfg_in_dim,
    input logic [15:0] cfg_out_dim,
    input logic [15:0] cfg_n_ib,
    input logic [15:0] cfg_n_ob,
    input logic signed [31:0] cfg_input_zp,
    input logic [31:0] cfg_requant_mult,
    input logic [31:0] cfg_requant_shift,
    input act_mode_t cfg_act_mode,

    output logic        [clog2_safe(WSRAM_DEPTH)-1:0] w_rd_tile_idx,
    input  logic signed [               WEIGHT_W-1:0] w_rd_tile    [TILE_ROWS][TILE_COLS],

    output logic        [clog2_safe(BSRAM_DEPTH)-1:0] b_rd_addr,
    input  logic signed [                 BIAS_W-1:0] b_rd_data,

    output logic [clog2_safe(MAX_IN_DIM/TILE_COLS)-1:0] ibuf_rd_tile_idx,
    input  logic [                         X_EFF_W-1:0] ibuf_x_eff      [TILE_COLS],

    output logic                                      obuf_wr_en,
    output logic        [clog2_safe(MAX_OUT_DIM)-1:0] obuf_wr_addr,
    output logic signed [               OUTPUT_W-1:0] obuf_wr_data,

    output logic [63:0] perf_cycles,
    output logic [63:0] perf_macs
);

  localparam int WSRAM_AW = clog2_safe(WSRAM_DEPTH);
  localparam int BSRAM_AW = clog2_safe(BSRAM_DEPTH);
  localparam int IBUF_AW = clog2_safe(MAX_IN_DIM / TILE_COLS);
  localparam int OBUF_AW = clog2_safe(MAX_OUT_DIM);

  // ============================================================
  // State
  // ============================================================
  accel_state_t state, state_nxt;

  logic [15:0] ob_group, ob_group_nxt;
  logic [15:0] ib, ib_nxt;
  logic [3:0] fetch_cnt, fetch_cnt_nxt;
  logic [3:0] tile_idx, tile_idx_nxt;
  logic [3:0] row_idx, row_idx_nxt;

  // ============================================================
  // Pre-computed addresses
  // ============================================================
  logic [31:0] w_addr_full;
  logic [31:0] bias_addr_cur;
  logic [31:0] bias_addr_next_tile;
  logic [31:0] bias_addr_next_row;

  assign w_addr_full = ({16'd0, ob_group} + {28'd0, fetch_cnt}) * {16'd0, cfg_n_ib} + {16'd0, ib};
  assign bias_addr_cur = ({16'd0, ob_group} + {28'd0, tile_idx}) * TILE_ROWS + {28'd0, row_idx};
  assign bias_addr_next_tile = ({16'd0, ob_group} + {28'd0, tile_idx} + 32'd1) * TILE_ROWS;
  assign bias_addr_next_row = bias_addr_cur + 32'd1;

  // ============================================================
  // Weight tile register bank
  // ============================================================
  logic signed [WEIGHT_W-1:0] w_tile_reg[PAR_OB][TILE_ROWS][TILE_COLS];

  // ============================================================
  // Compute pipeline registers
  // ============================================================
  // Stage A: registered x_eff
  logic [X_EFF_W-1:0] x_eff_reg[TILE_COLS];

  // Stage B-C (C1): registered lo/hi partial sums (split MAC)
  // SPLIT_FACTOR=1: only tile_psum_reg is used, lo/hi = unused
  // SPLIT_FACTOR=2: tile_psum_lo_reg + tile_psum_hi_reg are used, tile_psum_reg = unused
  // SPLIT_FACTOR=4: tile_psum_q0-q3_reg are used (4 quarter registers)
  logic signed [PSUM_W-1:0] tile_psum_reg[PAR_OB][TILE_ROWS];  // SPLIT=1 only
  logic signed [PSUM_W-1:0] tile_psum_lo_reg[PAR_OB][TILE_ROWS];  // C1 SPLIT=2
  logic signed [PSUM_W-1:0] tile_psum_hi_reg[PAR_OB][TILE_ROWS];  // C1 SPLIT=2
  // SPLIT=4: 4 quarter registers (cols 0-3, 4-7, 8-11, 12-15)
  logic signed [PSUM_W-1:0] tile_psum_q0_reg[PAR_OB][TILE_ROWS];
  logic signed [PSUM_W-1:0] tile_psum_q1_reg[PAR_OB][TILE_ROWS];
  logic signed [PSUM_W-1:0] tile_psum_q2_reg[PAR_OB][TILE_ROWS];
  logic signed [PSUM_W-1:0] tile_psum_q3_reg[PAR_OB][TILE_ROWS];

  // ============================================================
  // CIM Tile Array + psum accum
  // ============================================================
  // cim_tile is purely combinational.
  // With SPLIT_FACTOR=2: psum_lo/hi exposed separately.
  // With SPLIT_FACTOR=4: psum_q0-q3 exposed separately.
  logic signed [PSUM_W-1:0] tile_psum[PAR_OB][TILE_ROWS];
  logic signed [PSUM_W-1:0] psum_out[PAR_OB][TILE_ROWS];
  logic psum_clear, psum_en, psum_en_lo, psum_en_hi;
  logic psum_en_q0, psum_en_q1, psum_en_q2, psum_en_q3;

  // C1: lo/hi partial sums from each tile instance (module-level for generate scoping)
  logic signed [PSUM_W-1:0] psum_lo_tile[PAR_OB][TILE_ROWS];
  logic signed [PSUM_W-1:0] psum_hi_tile[PAR_OB][TILE_ROWS];
  // SPLIT=4: 4 quarter partial sums
  logic signed [PSUM_W-1:0] psum_q0_tile[PAR_OB][TILE_ROWS];
  logic signed [PSUM_W-1:0] psum_q1_tile[PAR_OB][TILE_ROWS];
  logic signed [PSUM_W-1:0] psum_q2_tile[PAR_OB][TILE_ROWS];
  logic signed [PSUM_W-1:0] psum_q3_tile[PAR_OB][TILE_ROWS];

  genvar g;
  generate
    for (g = 0; g < PAR_OB; g++) begin : GEN_TILE
      cim_tile u_tile (
          .x_eff   (x_eff_reg),
          .w_tile  (w_tile_reg[g]),
          .psum    (tile_psum[g]),
          .psum_lo (psum_lo_tile[g]),  // SPLIT=2
          .psum_hi (psum_hi_tile[g]),   // SPLIT=2
          .psum_q0 (psum_q0_tile[g]),   // SPLIT=4
          .psum_q1 (psum_q1_tile[g]),   // SPLIT=4
          .psum_q2 (psum_q2_tile[g]),   // SPLIT=4
          .psum_q3 (psum_q3_tile[g])    // SPLIT=4
      );
      psum_accum u_psum (
          .clk      (clk),
          .rst_n    (rst_n),
          .clear    (psum_clear),
          .en       (psum_en),
          .en_lo    (psum_en_lo),
          .en_hi    (psum_en_hi),
          .en_q0    (psum_en_q0),     // SPLIT=4
          .en_q1    (psum_en_q1),     // SPLIT=4
          .en_q2    (psum_en_q2),     // SPLIT=4
          .en_q3    (psum_en_q3),     // SPLIT=4
          .tile_psum(tile_psum[g]),
          .psum_lo_tile(tile_psum_lo_reg[g]),
          .psum_hi_tile(tile_psum_hi_reg[g]),
          .psum_q0_tile(tile_psum_q0_reg[g]),  // SPLIT=4
          .psum_q1_tile(tile_psum_q1_reg[g]),  // SPLIT=4
          .psum_q2_tile(tile_psum_q2_reg[g]),  // SPLIT=4
          .psum_q3_tile(tile_psum_q3_reg[g]),  // SPLIT=4
          .psum     (psum_out[g])
      );
    end
  endgenerate

  // ============================================================
  // Output pipeline registers (same as before)
  // ============================================================
  logic signed   [  PSUM_W-1:0] psum_sel_r;
  logic          [        31:0] neuron_addr_p1;

  logic signed   [  BIAS_W-1:0] bias_val_r;
  logic signed   [  PSUM_W-1:0] activated_r;
  logic          [        31:0] neuron_addr_p3;

  longint signed                prod_r;
  logic          [        31:0] neuron_addr_p4;

  longint signed                pre_shift_r;     // round result (no shift yet)
  logic          [        31:0] neuron_addr_p4b; // pipeline address for shift stage

  logic signed   [OUTPUT_W-1:0] requant_r;
  logic          [        31:0] neuron_addr_p5;

  // ============================================================
  // Combinational logic for pipeline stages
  // ============================================================
  logic signed   [  PSUM_W-1:0] acc_with_bias;
  logic signed   [  PSUM_W-1:0] after_act;
  assign acc_with_bias = psum_sel_r + bias_val_r;
  always_comb begin
    case (cfg_act_mode)
      ACT_RELU: after_act = (acc_with_bias > 0) ? acc_with_bias : '0;
      default:  after_act = acc_with_bias;
    endcase
  end

  longint signed prod_comb;
  assign prod_comb = longint'(activated_r) * longint'($signed(cfg_requant_mult));

  // C1: split requantize into two pipeline stages — round then shift+clamp
  // Stage 1 (ST_SHIFT): round only — prod_r + half-up rounding offset -> pre_shift_r
  //   This cuts the 22-CARRY4 rounding adder from the barrel shifter path
  longint signed round_comb;
  always_comb begin
    if (cfg_requant_shift == 0) round_comb = prod_r;
    else round_comb = prod_r + (longint'(1) <<< (cfg_requant_shift - 1));
  end

  // Stage 2 (ST_CLAMP): barrel shift on registered pre_shift_r, then clamp
  //   pre_shift_r is registered, so the barrel shifter starts from a clean register
  longint signed shifted_comb;
  always_comb begin
    if (cfg_requant_shift == 0) shifted_comb = pre_shift_r;
    else shifted_comb = pre_shift_r >>> cfg_requant_shift;
  end

  // ============================================================
  // Performance counter flag
  // ============================================================
  logic perf_counting;

  // ============================================================
  // Sequential block
  // ============================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n || soft_rst) begin
      state          <= ST_IDLE;
      ob_group       <= '0;
      ib             <= '0;
      fetch_cnt      <= '0;
      tile_idx       <= '0;
      row_idx        <= '0;
      psum_sel_r     <= '0;
      bias_val_r     <= '0;
      activated_r    <= '0;
      neuron_addr_p1 <= '0;
      neuron_addr_p3 <= '0;
      prod_r         <= '0;
      neuron_addr_p4 <= '0;
      pre_shift_r    <= '0;
      neuron_addr_p4b <= '0;
      requant_r      <= '0;
      neuron_addr_p5 <= '0;
      for (int c = 0; c < TILE_COLS; c++) x_eff_reg[c] <= '0;
      for (int t = 0; t < PAR_OB; t++) begin
        for (int r = 0; r < TILE_ROWS; r++) begin
          tile_psum_reg[t][r]   <= '0;
          tile_psum_lo_reg[t][r] <= '0;
          tile_psum_hi_reg[t][r] <= '0;
          tile_psum_q0_reg[t][r] <= '0;
          tile_psum_q1_reg[t][r] <= '0;
          tile_psum_q2_reg[t][r] <= '0;
          tile_psum_q3_reg[t][r] <= '0;
          for (int c = 0; c < TILE_COLS; c++) w_tile_reg[t][r][c] <= '0;
        end
      end
    end else begin
      state     <= state_nxt;
      ob_group  <= ob_group_nxt;
      ib        <= ib_nxt;
      fetch_cnt <= fetch_cnt_nxt;
      tile_idx  <= tile_idx_nxt;
      row_idx   <= row_idx_nxt;

      // Latch weight tile in WAIT_SRAM
      if (state == ST_WAIT_SRAM) begin
        for (int r = 0; r < TILE_ROWS; r++)
        for (int c = 0; c < TILE_COLS; c++) w_tile_reg[fetch_cnt][r][c] <= w_rd_tile[r][c];
      end

      // Stage A: register x_eff
      if (state == ST_XEFF_REG) begin
        for (int c = 0; c < TILE_COLS; c++) x_eff_reg[c] <= ibuf_x_eff[c];
      end

      // C1: ST_MAC_LO -> latch lo-chain psum (cols 0-7)
      // C1: ST_MAC_HI -> latch hi-chain psum (cols 8-15)
      // SPLIT=4: ST_MAC_Q0-Q3 -> latch 4 quarter psums
      // Legacy: ST_MAC -> latch full psum
      if (TILE_SPLIT_FACTOR == 1) begin
        // === SPLIT_FACTOR=1: full 16-wide MAC in one cycle ===
        if (state == ST_MAC_LO) begin  // renamed from ST_MAC
          for (int t = 0; t < PAR_OB; t++)
          for (int r = 0; r < TILE_ROWS; r++)
            tile_psum_reg[t][r] <= tile_psum[t][r];
        end
      end else if (TILE_SPLIT_FACTOR == 2) begin
        // === SPLIT_FACTOR=2: 8+8 split MAC over two cycles ===
        if (state == ST_MAC_LO) begin
          for (int t = 0; t < PAR_OB; t++)
          for (int r = 0; r < TILE_ROWS; r++)
            tile_psum_lo_reg[t][r] <= psum_lo_tile[t][r];
        end
        if (state == ST_MAC_HI) begin
          for (int t = 0; t < PAR_OB; t++)
          for (int r = 0; r < TILE_ROWS; r++)
            tile_psum_hi_reg[t][r] <= psum_hi_tile[t][r];
        end
      end else begin
        // === SPLIT_FACTOR=4: 4+4+4+4 split MAC over four cycles ===
        if (state == ST_MAC_Q0) begin
          for (int t = 0; t < PAR_OB; t++)
          for (int r = 0; r < TILE_ROWS; r++)
            tile_psum_q0_reg[t][r] <= psum_q0_tile[t][r];
        end
        if (state == ST_MAC_Q1) begin
          for (int t = 0; t < PAR_OB; t++)
          for (int r = 0; r < TILE_ROWS; r++)
            tile_psum_q1_reg[t][r] <= psum_q1_tile[t][r];
        end
        if (state == ST_MAC_Q2) begin
          for (int t = 0; t < PAR_OB; t++)
          for (int r = 0; r < TILE_ROWS; r++)
            tile_psum_q2_reg[t][r] <= psum_q2_tile[t][r];
        end
        if (state == ST_MAC_Q3) begin
          for (int t = 0; t < PAR_OB; t++)
          for (int r = 0; r < TILE_ROWS; r++)
            tile_psum_q3_reg[t][r] <= psum_q3_tile[t][r];
        end
      end

      // Pipeline Stage 1: BIAS_ADD
      if (state == ST_BIAS_ADD) begin
        psum_sel_r     <= psum_out[tile_idx][row_idx];
        neuron_addr_p1 <= bias_addr_cur;
      end

      // Pipeline Stage 2: ACTIVATE
      if (state == ST_ACTIVATE) begin
        bias_val_r <= b_rd_data;
      end

      // Pipeline Stage 3: REQUANT
      if (state == ST_REQUANT) begin
        activated_r    <= after_act;
        neuron_addr_p3 <= neuron_addr_p1;
      end

      // Pipeline Stage 4: ST_STORE (64-bit multiply -> prod_r)
      if (state == ST_STORE) begin
        prod_r         <= prod_comb;
        neuron_addr_p4 <= neuron_addr_p3;
      end

      // Pipeline Stage 5: ST_SHIFT (round only -> pre_shift_r)
      if (state == ST_SHIFT) begin
        pre_shift_r    <= round_comb;
        neuron_addr_p4b <= neuron_addr_p4;
      end

      // Pipeline Stage 6: ST_CLAMP (barrel shift + clamp to INT8 -> requant_r)
      if (state == ST_CLAMP) begin
        // Inline clamp to avoid extra pipeline stage
        if (shifted_comb > 127)        requant_r <= 8'sd127;
        else if (shifted_comb < -128)  requant_r <= -8'sd128;
        else                           requant_r <= shifted_comb[OUTPUT_W-1:0];
        neuron_addr_p5 <= neuron_addr_p4b;
      end
    end
  end

  // ============================================================
  // Combinational next-state + outputs
  // ============================================================
  always_comb begin
    state_nxt        = state;
    ob_group_nxt     = ob_group;
    ib_nxt           = ib;
    fetch_cnt_nxt    = fetch_cnt;
    tile_idx_nxt     = tile_idx;
    row_idx_nxt      = row_idx;

    busy             = 1'b0;
    done             = 1'b0;
    psum_clear       = 1'b0;
    psum_en          = 1'b0;
    psum_en_lo       = 1'b0;
    psum_en_hi       = 1'b0;
    psum_en_q0       = 1'b0;
    psum_en_q1       = 1'b0;
    psum_en_q2       = 1'b0;
    psum_en_q3       = 1'b0;
    obuf_wr_en       = 1'b0;
    obuf_wr_addr     = '0;
    obuf_wr_data     = '0;
    perf_counting    = 1'b0;

    w_rd_tile_idx    = w_addr_full[WSRAM_AW-1:0];
    ibuf_rd_tile_idx = ib[IBUF_AW-1:0];
    b_rd_addr        = bias_addr_cur[BSRAM_AW-1:0];

    case (state)
      // ====== Idle / Setup ======
      ST_IDLE: begin
        if (start) begin
          ob_group_nxt  = '0;
          ib_nxt        = '0;
          fetch_cnt_nxt = '0;
          tile_idx_nxt  = '0;
          row_idx_nxt   = '0;
          state_nxt     = ST_CLEAR_PSUM;
        end
      end

      ST_CLEAR_PSUM: begin
        busy          = 1'b1;
        psum_clear    = 1'b1;
        ib_nxt        = '0;
        fetch_cnt_nxt = '0;
        state_nxt     = ST_FETCH;
        perf_counting = 1'b1;
      end

      // ====== Weight fetch loop ======
      ST_FETCH: begin
        busy          = 1'b1;
        perf_counting = 1'b1;
        state_nxt     = ST_WAIT_SRAM;
      end

      ST_WAIT_SRAM: begin
        busy          = 1'b1;
        perf_counting = 1'b1;
        if (fetch_cnt == PAR_OB[3:0] - 4'd1) begin
          fetch_cnt_nxt = '0;
          state_nxt     = ST_XEFF_REG;
        end else begin
          fetch_cnt_nxt = fetch_cnt + 4'd1;
          state_nxt     = ST_FETCH;
        end
      end

      // ====== Stage A: x_eff register ======
      ST_XEFF_REG: begin
        busy          = 1'b1;
        perf_counting = 1'b1;
        if (TILE_SPLIT_FACTOR == 1) state_nxt = ST_MAC_LO;
        else if (TILE_SPLIT_FACTOR == 2) state_nxt = ST_MAC_LO;
        else state_nxt = ST_MAC_Q0;  // SPLIT=4
      end

      // ====== SPLIT=1: ST_MAC_LO = full 16-wide MAC ======
      ST_MAC_LO: begin
        busy          = 1'b1;
        perf_counting = 1'b1;
        if (TILE_SPLIT_FACTOR == 1) begin
          state_nxt = ST_COMPUTE;  // SPLIT=1: lo = full, skip hi
        end else begin
          state_nxt = ST_MAC_HI;   // SPLIT=2: lo done, proceed to hi
        end
      end

      // ====== SPLIT=2: ST_MAC_HI -> hi half (cols 8-15) ======
      ST_MAC_HI: begin
        busy          = 1'b1;
        perf_counting = 1'b1;
        state_nxt     = ST_COMPUTE;
      end

      // ====== SPLIT=4: quarter states (cols 0-3, 4-7, 8-11, 12-15) ======
      ST_MAC_Q0: begin
        busy          = 1'b1;
        perf_counting = 1'b1;
        state_nxt     = ST_MAC_Q1;
      end

      ST_MAC_Q1: begin
        busy          = 1'b1;
        perf_counting = 1'b1;
        state_nxt     = ST_MAC_Q2;
      end

      ST_MAC_Q2: begin
        busy          = 1'b1;
        perf_counting = 1'b1;
        state_nxt     = ST_MAC_Q3;
      end

      ST_MAC_Q3: begin
        busy          = 1'b1;
        perf_counting = 1'b1;
        state_nxt     = ST_COMPUTE;
      end

      // ====== Stage C: psum accumulation ======
      // SPLIT=1: psum_en accumulates tile_psum_reg (full 16-wide, latched in ST_MAC_LO)
      // SPLIT=2: psum_en_lo + psum_en_hi accumulate registered lo/hi from MAC_LO/MAC_HI
      // SPLIT=4: psum_en_q0-q3 accumulate registered q0-q3 from MAC_Q0-Q3
      ST_COMPUTE: begin
        busy          = 1'b1;
        perf_counting = 1'b1;
        if (TILE_SPLIT_FACTOR == 1) begin
          psum_en = 1'b1;  // accumulate full tile_psum_reg
        end else if (TILE_SPLIT_FACTOR == 2) begin
          psum_en_lo = 1'b1;  // accumulate tile_psum_lo_reg
          psum_en_hi = 1'b1;  // accumulate tile_psum_hi_reg
        end else begin  // SPLIT=4
          psum_en_q0 = 1'b1;  // accumulate tile_psum_q0_reg
          psum_en_q1 = 1'b1;  // accumulate tile_psum_q1_reg
          psum_en_q2 = 1'b1;  // accumulate tile_psum_q2_reg
          psum_en_q3 = 1'b1;  // accumulate tile_psum_q3_reg
        end
        state_nxt = ST_NEXT_IB;
      end

      ST_NEXT_IB: begin
        busy          = 1'b1;
        perf_counting = 1'b1;
        if (ib == cfg_n_ib - 16'd1) begin
          tile_idx_nxt = '0;
          row_idx_nxt  = '0;
          state_nxt    = ST_BIAS_ADD;
        end else begin
          ib_nxt        = ib + 16'd1;
          fetch_cnt_nxt = '0;
          state_nxt     = ST_FETCH;
        end
      end

      // ====== 5-stage output pipeline (per neuron) ======
      ST_BIAS_ADD: begin
        busy          = 1'b1;
        perf_counting = 1'b1;
        state_nxt     = ST_ACTIVATE;
      end

      ST_ACTIVATE: begin
        busy          = 1'b1;
        perf_counting = 1'b1;
        state_nxt     = ST_REQUANT;
      end

      ST_REQUANT: begin
        busy          = 1'b1;
        perf_counting = 1'b1;
        state_nxt     = ST_STORE;
      end

      ST_STORE: begin
        busy          = 1'b1;
        perf_counting = 1'b1;
        state_nxt     = ST_SHIFT;
      end

      ST_SHIFT: begin
        busy          = 1'b1;
        perf_counting = 1'b1;
        state_nxt     = ST_CLAMP;
      end

      ST_CLAMP: begin
        busy          = 1'b1;
        perf_counting = 1'b1;
        state_nxt     = ST_WRITE_OBUF;
      end

      ST_WRITE_OBUF: begin
        busy          = 1'b1;
        perf_counting = 1'b1;

        if (neuron_addr_p5 < {16'd0, cfg_out_dim}) begin
          obuf_wr_en   = 1'b1;
          obuf_wr_addr = neuron_addr_p5[OBUF_AW-1:0];
          obuf_wr_data = requant_r;
        end

        if (row_idx == TILE_ROWS[3:0] - 4'd1) begin
          row_idx_nxt = '0;
          if (tile_idx == PAR_OB[3:0] - 4'd1) begin
            state_nxt = ST_NEXT_OB;
          end else begin
            tile_idx_nxt = tile_idx + 4'd1;
            b_rd_addr    = bias_addr_next_tile[BSRAM_AW-1:0];
            state_nxt    = ST_BIAS_ADD;
          end
        end else begin
          row_idx_nxt = row_idx + 4'd1;
          b_rd_addr   = bias_addr_next_row[BSRAM_AW-1:0];
          state_nxt   = ST_BIAS_ADD;
        end
      end

      // ====== OB group advance / Done ======
      ST_NEXT_OB: begin
        busy          = 1'b1;
        perf_counting = 1'b1;
        if (ob_group + PAR_OB[15:0] >= cfg_n_ob) begin
          state_nxt = ST_DONE;
        end else begin
          ob_group_nxt = ob_group + PAR_OB[15:0];
          state_nxt    = ST_CLEAR_PSUM;
        end
      end

      ST_DONE: begin
        done      = 1'b1;
        state_nxt = ST_IDLE;
      end

      default: state_nxt = ST_IDLE;
    endcase
  end

  assign dbg_state = accel_state_t'(state);

  // ============================================================
  // Performance Counters
  // ============================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n || soft_rst) begin
      perf_cycles <= '0;
      perf_macs   <= '0;
    end else if (start && state == ST_IDLE) begin
      perf_cycles <= '0;
      perf_macs   <= '0;
    end else begin
      if (perf_counting) perf_cycles <= perf_cycles + 64'd1;
      if (psum_en || (psum_en_lo && psum_en_hi) || (psum_en_q0 && psum_en_q1 && psum_en_q2 && psum_en_q3))
        perf_macs <= perf_macs + 64'(PAR_OB) * 64'(TILE_ROWS) * 64'(TILE_COLS);
    end
  end

endmodule
