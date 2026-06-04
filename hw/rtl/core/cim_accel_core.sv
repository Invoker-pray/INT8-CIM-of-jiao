// ============================================================================
// cim_accel_core.sv — CIM Accelerator Core (C4 pipeline: L+M+MAC states)
// ============================================================================
// C4 pipeline with C4_MUL_PIPE=1:
//   XEFF_LATCH → Q0_L → Q0_M → Q0 → Q1_L → Q1_M → Q1 → ... → Q3 → COMPUTE
//   - L state: latch phase-selected x_eff/w_tile into registered copies
//   - M state: DSP48 multiply, product registered inside cim_tile (1 cycle)
//   - MAC state: CARRY4 accumulate from registered products (combinational)
//   Critical path: reg→DSP48→reg (~3ns) + reg→CARRY4→reg (~0.5ns)
//   Each stage fits easily in 10ns period (100 MHz target).
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
    input logic [clog2_safe(WSRAM_DEPTH)-1:0] cfg_weight_base,
    input logic [clog2_safe(BSRAM_DEPTH)-1:0] cfg_bias_base,

    output logic        [clog2_safe(WSRAM_DEPTH)-1:0] w_rd_tile_idx,
    input  logic signed [               WEIGHT_W-1:0] w_rd_tile    [TILE_ROWS][TILE_COLS],

    output logic        [clog2_safe(BSRAM_DEPTH)-1:0] b_rd_addr,
    input  logic signed [                 BIAS_W-1:0] b_rd_data,

    output logic [clog2_safe(MAX_IN_DIM/TILE_COLS)-1:0] ibuf_rd_tile_idx,
    input  logic signed [                  X_EFF_W-1:0] ibuf_x_eff      [TILE_COLS],

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
  localparam int PHASE_COLS = TILE_COLS / TILE_SPLIT_FACTOR;

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
  assign w_addr_full = ({16'd0, ob_group} + {28'd0, fetch_cnt}) * {16'd0, cfg_n_ib} + {16'd0, ib} + {21'd0, cfg_weight_base};
  assign bias_addr_cur = ({16'd0, ob_group} + {28'd0, tile_idx}) * TILE_ROWS + {28'd0, row_idx};

  logic [WSRAM_AW-1:0] w_rd_tile_idx_r;
  logic [BSRAM_AW-1:0] b_rd_addr_r;

  // ============================================================
  // Weight tile register bank + C4 latched registers
  // ============================================================
  logic signed [WEIGHT_W-1:0] w_tile_reg[PAR_OB][TILE_ROWS][TILE_COLS];
  logic signed [WEIGHT_W-1:0] w_tile_latched[PAR_OB][TILE_ROWS][TILE_COLS];

  // Stage A: registered x_eff (from ibuf) + C4 latched (phase-selected)
  logic signed [X_EFF_W-1:0] x_eff_reg[TILE_COLS];
  logic signed [X_EFF_W-1:0] x_eff_latched[TILE_COLS];

  // Quarter partial sum registers
  logic signed [PSUM_W-1:0] tile_psum_reg[PAR_OB][TILE_ROWS];
  logic signed [PSUM_W-1:0] tile_psum_lo_reg[PAR_OB][TILE_ROWS];
  logic signed [PSUM_W-1:0] tile_psum_hi_reg[PAR_OB][TILE_ROWS];
  logic signed [PSUM_W-1:0] tile_psum_q0_reg[PAR_OB][TILE_ROWS];
  logic signed [PSUM_W-1:0] tile_psum_q1_reg[PAR_OB][TILE_ROWS];
  logic signed [PSUM_W-1:0] tile_psum_q2_reg[PAR_OB][TILE_ROWS];
  logic signed [PSUM_W-1:0] tile_psum_q3_reg[PAR_OB][TILE_ROWS];

  // ============================================================
  // CIM Tile Array + psum accum
  // ============================================================
  logic signed [PSUM_W-1:0] tile_psum[PAR_OB][TILE_ROWS];
  logic signed [PSUM_W-1:0] psum_out[PAR_OB][TILE_ROWS];
  logic psum_clear, psum_en, psum_en_lo, psum_en_hi;
  logic psum_en_q0, psum_en_q1, psum_en_q2, psum_en_q3;

  logic signed [PSUM_W-1:0] psum_lo_tile[PAR_OB][TILE_ROWS];
  logic signed [PSUM_W-1:0] psum_hi_tile[PAR_OB][TILE_ROWS];
  logic signed [PSUM_W-1:0] psum_q0_tile[PAR_OB][TILE_ROWS];
  logic signed [PSUM_W-1:0] psum_q1_tile[PAR_OB][TILE_ROWS];
  logic signed [PSUM_W-1:0] psum_q2_tile[PAR_OB][TILE_ROWS];
  logic signed [PSUM_W-1:0] psum_q3_tile[PAR_OB][TILE_ROWS];

  logic [1:0] mac_phase_sel;
  // M states drive the same phase as the preceding L state
  always_comb begin
    unique case (state)
      ST_MAC_HI:                     mac_phase_sel = 2'd1;
      ST_MAC_Q1, ST_MAC_Q1_L, ST_MAC_Q1_M: mac_phase_sel = 2'd1;
      ST_MAC_Q2, ST_MAC_Q2_L, ST_MAC_Q2_M: mac_phase_sel = 2'd2;
      ST_MAC_Q3, ST_MAC_Q3_L, ST_MAC_Q3_M: mac_phase_sel = 2'd3;
      default:                        mac_phase_sel = 2'd0;
    endcase
  end

  genvar g;
  generate
    for (g = 0; g < PAR_OB; g++) begin : GEN_TILE
      cim_tile u_tile (
          .clk      (clk),
          .x_eff    (x_eff_latched),
          .w_tile   (w_tile_latched[g]),
          .phase_sel(mac_phase_sel),
          .psum     (tile_psum[g]),
          .psum_lo  (psum_lo_tile[g]),
          .psum_hi  (psum_hi_tile[g]),
          .psum_q0  (psum_q0_tile[g]),
          .psum_q1  (psum_q1_tile[g]),
          .psum_q2  (psum_q2_tile[g]),
          .psum_q3  (psum_q3_tile[g])
      );
      psum_accum u_psum (
          .clk      (clk), .rst_n(rst_n), .clear(psum_clear),
          .en       (psum_en), .en_lo(psum_en_lo), .en_hi(psum_en_hi),
          .en_q0    (psum_en_q0), .en_q1(psum_en_q1),
          .en_q2    (psum_en_q2), .en_q3(psum_en_q3),
          .tile_psum(tile_psum[g]),
          .psum_lo_tile(tile_psum_lo_reg[g]), .psum_hi_tile(tile_psum_hi_reg[g]),
          .psum_q0_tile(tile_psum_q0_reg[g]), .psum_q1_tile(tile_psum_q1_reg[g]),
          .psum_q2_tile(tile_psum_q2_reg[g]), .psum_q3_tile(tile_psum_q3_reg[g]),
          .psum     (psum_out[g])
      );
    end
  endgenerate

  // ============================================================
  // Output pipeline registers
  // ============================================================
  logic signed [PSUM_W-1:0] psum_sel_r;
  logic        [31:0] neuron_addr_p1;
  logic signed [BIAS_W-1:0] bias_val_r;
  logic signed [PSUM_W-1:0] activated_r;
  logic        [31:0] neuron_addr_p3;
  longint signed             prod_r;
  logic        [31:0] neuron_addr_p4;
  longint signed             pre_shift_r;
  logic        [31:0] neuron_addr_p4b;
  logic signed [OUTPUT_W-1:0] requant_r;
  logic        [31:0] neuron_addr_p5;

  // Combinational pipeline logic
  logic signed [PSUM_W-1:0] acc_with_bias, after_act;
  assign acc_with_bias = psum_sel_r + bias_val_r;
  always_comb begin
    case (cfg_act_mode)
      ACT_RELU: after_act = (acc_with_bias > 0) ? acc_with_bias : '0;
      default:  after_act = acc_with_bias;
    endcase
  end

  longint signed prod_comb;
  assign prod_comb = longint'(activated_r) * longint'($signed(cfg_requant_mult));

  longint signed round_comb;
  always_comb begin
    if (cfg_requant_shift == 0) round_comb = prod_r;
    else round_comb = prod_r + (longint'(1) <<< (cfg_requant_shift - 1));
  end

  longint signed shifted_comb;
  always_comb begin
    if (cfg_requant_shift == 0) shifted_comb = pre_shift_r;
    else shifted_comb = pre_shift_r >>> cfg_requant_shift;
  end

  // ============================================================
  // Tiles-this-pass for partial OB support
  // FIXED: use 8-bit to avoid truncation when N_OB=16 (4'd0)
  // ============================================================
  logic [7:0] tiles_this_pass;
  always_comb begin
    if ({8'd0, ob_group[7:0]} + {8'd0, PAR_OB[7:0]} > {8'd0, cfg_n_ob[7:0]})
      tiles_this_pass = cfg_n_ob[7:0] - ob_group[7:0];
    else
      tiles_this_pass = PAR_OB[7:0];
  end

  logic perf_counting;

  // ============================================================
  // Sequential block
  // ============================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n || soft_rst) begin
      state <= ST_IDLE; ob_group <= '0; ib <= '0; fetch_cnt <= '0;
      tile_idx <= '0; row_idx <= '0;
      psum_sel_r <= '0; bias_val_r <= '0; activated_r <= '0;
      neuron_addr_p1 <= '0; neuron_addr_p3 <= '0;
      prod_r <= '0; neuron_addr_p4 <= '0;
      pre_shift_r <= '0; neuron_addr_p4b <= '0;
      requant_r <= '0; neuron_addr_p5 <= '0;
      w_rd_tile_idx_r <= '0; b_rd_addr_r <= '0;
      for (int c = 0; c < TILE_COLS; c++) begin
        x_eff_reg[c] <= '0; x_eff_latched[c] <= '0;
      end
      for (int t = 0; t < PAR_OB; t++) begin
        for (int r = 0; r < TILE_ROWS; r++) begin
          tile_psum_reg[t][r]   <= '0; tile_psum_lo_reg[t][r] <= '0;
          tile_psum_hi_reg[t][r] <= '0;
          tile_psum_q0_reg[t][r] <= '0; tile_psum_q1_reg[t][r] <= '0;
          tile_psum_q2_reg[t][r] <= '0; tile_psum_q3_reg[t][r] <= '0;
          for (int c = 0; c < TILE_COLS; c++) begin
            w_tile_reg[t][r][c] <= '0; w_tile_latched[t][r][c] <= '0;
          end
        end
      end
    end else begin
      state <= state_nxt; ob_group <= ob_group_nxt;
      ib <= ib_nxt; fetch_cnt <= fetch_cnt_nxt;
      tile_idx <= tile_idx_nxt; row_idx <= row_idx_nxt;

      // Latch weight tile
      if (state == ST_WAIT_SRAM) begin
        for (int r = 0; r < TILE_ROWS; r++)
        for (int c = 0; c < TILE_COLS; c++)
          w_tile_reg[fetch_cnt][r][c] <= w_rd_tile[r][c];
      end

      // Stage A: register x_eff from ibuf + init latched
      if (state == ST_XEFF_LATCH) begin
        for (int c = 0; c < TILE_COLS; c++) begin
          x_eff_reg[c] <= ibuf_x_eff[c];
          x_eff_latched[c] <= ibuf_x_eff[c];
        end
      end

      // C4 L states: pre-select and latch current quarter's x_eff/w_tile
      if (TILE_MAC_REUSE && TILE_SPLIT_FACTOR >= 2) begin
        if (state == ST_MAC_Q0_L) begin
          for (int c = 0; c < PHASE_COLS; c++) x_eff_latched[c] <= x_eff_reg[c];
          for (int c = PHASE_COLS; c < TILE_COLS; c++) x_eff_latched[c] <= '0;
          for (int t = 0; t < PAR_OB; t++)
          for (int r = 0; r < TILE_ROWS; r++) begin
            for (int c = 0; c < PHASE_COLS; c++)
              w_tile_latched[t][r][c] <= w_tile_reg[t][r][c];
            for (int c = PHASE_COLS; c < TILE_COLS; c++)
              w_tile_latched[t][r][c] <= '0;
          end
        end
        if (state == ST_MAC_Q1_L) begin
          for (int c = 0; c < PHASE_COLS; c++) x_eff_latched[c] <= x_eff_reg[c + PHASE_COLS];
          for (int c = PHASE_COLS; c < TILE_COLS; c++) x_eff_latched[c] <= '0;
          for (int t = 0; t < PAR_OB; t++)
          for (int r = 0; r < TILE_ROWS; r++) begin
            for (int c = 0; c < PHASE_COLS; c++)
              w_tile_latched[t][r][c] <= w_tile_reg[t][r][c + PHASE_COLS];
            for (int c = PHASE_COLS; c < TILE_COLS; c++)
              w_tile_latched[t][r][c] <= '0;
          end
        end
        if (state == ST_MAC_Q2_L) begin
          for (int c = 0; c < PHASE_COLS; c++) x_eff_latched[c] <= x_eff_reg[c + 2*PHASE_COLS];
          for (int c = PHASE_COLS; c < TILE_COLS; c++) x_eff_latched[c] <= '0;
          for (int t = 0; t < PAR_OB; t++)
          for (int r = 0; r < TILE_ROWS; r++) begin
            for (int c = 0; c < PHASE_COLS; c++)
              w_tile_latched[t][r][c] <= w_tile_reg[t][r][c + 2*PHASE_COLS];
            for (int c = PHASE_COLS; c < TILE_COLS; c++)
              w_tile_latched[t][r][c] <= '0;
          end
        end
        if (state == ST_MAC_Q3_L) begin
          for (int c = 0; c < PHASE_COLS; c++) x_eff_latched[c] <= x_eff_reg[c + 3*PHASE_COLS];
          for (int c = PHASE_COLS; c < TILE_COLS; c++) x_eff_latched[c] <= '0;
          for (int t = 0; t < PAR_OB; t++)
          for (int r = 0; r < TILE_ROWS; r++) begin
            for (int c = 0; c < PHASE_COLS; c++)
              w_tile_latched[t][r][c] <= w_tile_reg[t][r][c + 3*PHASE_COLS];
            for (int c = PHASE_COLS; c < TILE_COLS; c++)
              w_tile_latched[t][r][c] <= '0;
          end
        end
      end

      // MAC partial sum latching
      if (TILE_SPLIT_FACTOR == 1) begin
        if (state == ST_MAC_LO) begin
          for (int t = 0; t < PAR_OB; t++)
          for (int r = 0; r < TILE_ROWS; r++)
            tile_psum_reg[t][r] <= tile_psum[t][r];
        end
      end else if (TILE_SPLIT_FACTOR == 2) begin
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

      // Output pipeline
      if (state == ST_BIAS_ADD) begin
        psum_sel_r <= psum_out[tile_idx][row_idx];
        neuron_addr_p1 <= bias_addr_cur;
      end
      if (state == ST_ACTIVATE)   bias_val_r <= b_rd_data;
      if (state == ST_REQUANT) begin
        activated_r <= after_act; neuron_addr_p3 <= neuron_addr_p1;
      end
      if (state == ST_STORE) begin
        prod_r <= prod_comb; neuron_addr_p4 <= neuron_addr_p3;
      end
      if (state == ST_SHIFT) begin
        pre_shift_r <= round_comb; neuron_addr_p4b <= neuron_addr_p4;
      end
      if (state == ST_CLAMP) begin
        if (shifted_comb > 127)       requant_r <= 8'sd127;
        else if (shifted_comb < -128) requant_r <= -8'sd128;
        else                          requant_r <= shifted_comb[OUTPUT_W-1:0];
        neuron_addr_p5 <= neuron_addr_p4b;
      end

      // Pre-compute SRAM addresses
      if (state == ST_CLEAR_PSUM) begin
        w_rd_tile_idx_r <= ({16'd0, ob_group} * {16'd0, cfg_n_ib} + {21'd0, cfg_weight_base});
      end else if (state == ST_WAIT_SRAM && fetch_cnt < tiles_this_pass - 8'd1) begin
        w_rd_tile_idx_r <= (({16'd0, ob_group} + {28'd0, fetch_cnt} + 32'd1) * {16'd0, cfg_n_ib} + {16'd0, ib} + {21'd0, cfg_weight_base});
      end else if (state == ST_NEXT_IB && ib < cfg_n_ib - 16'd1) begin
        w_rd_tile_idx_r <= ({16'd0, ob_group} * {16'd0, cfg_n_ib} + {16'd0, ib} + 32'd1 + {21'd0, cfg_weight_base});
      end

      if (state == ST_NEXT_IB && ib == cfg_n_ib - 16'd1) begin
        b_rd_addr_r <= {24'd0, cfg_bias_base} + ({16'd0, ob_group} * 32'd16);
      end else if (state == ST_WRITE_OBUF) begin
        if (row_idx == TILE_ROWS[3:0] - 4'd1) begin
          if (tile_idx != tiles_this_pass - 8'd1)
            b_rd_addr_r <= {24'd0, cfg_bias_base} + (({16'd0, ob_group} + {28'd0, tile_idx} + 32'd1) * 32'd16);
        end else
          b_rd_addr_r <= {24'd0, cfg_bias_base} + (({16'd0, ob_group} + {28'd0, tile_idx}) * 32'd16 + {28'd0, row_idx} + 32'd1);
      end
    end
  end

  // ============================================================
  // Combinational FSM
  // ============================================================
  always_comb begin
    state_nxt = state; ob_group_nxt = ob_group; ib_nxt = ib;
    fetch_cnt_nxt = fetch_cnt; tile_idx_nxt = tile_idx; row_idx_nxt = row_idx;
    busy = 1'b0; done = 1'b0;
    psum_clear = 1'b0; psum_en = 1'b0; psum_en_lo = 1'b0; psum_en_hi = 1'b0;
    psum_en_q0 = 1'b0; psum_en_q1 = 1'b0; psum_en_q2 = 1'b0; psum_en_q3 = 1'b0;
    obuf_wr_en = 1'b0; obuf_wr_addr = '0; obuf_wr_data = '0;
    perf_counting = 1'b0;
    w_rd_tile_idx = w_rd_tile_idx_r;
    ibuf_rd_tile_idx = ib[IBUF_AW-1:0];
    b_rd_addr = b_rd_addr_r;

    case (state)
      ST_IDLE: if (start) begin
        ob_group_nxt = '0; ib_nxt = '0; fetch_cnt_nxt = '0;
        tile_idx_nxt = '0; row_idx_nxt = '0; state_nxt = ST_CLEAR_PSUM;
      end

      ST_CLEAR_PSUM: begin
        busy = 1'b1; psum_clear = 1'b1; ib_nxt = '0; fetch_cnt_nxt = '0;
        state_nxt = ST_FETCH; perf_counting = 1'b1;
      end

      ST_FETCH: begin busy = 1'b1; perf_counting = 1'b1; state_nxt = ST_WAIT_SRAM; end

      ST_WAIT_SRAM: begin
        busy = 1'b1; perf_counting = 1'b1;
        if (fetch_cnt == tiles_this_pass - 8'd1) begin
          fetch_cnt_nxt = '0; state_nxt = ST_XEFF_REG;
        end else begin fetch_cnt_nxt = fetch_cnt + 4'd1; state_nxt = ST_FETCH; end
      end

      ST_XEFF_REG:   begin busy = 1'b1; perf_counting = 1'b1; state_nxt = ST_XEFF_LATCH; end

      ST_XEFF_LATCH: begin
        busy = 1'b1; perf_counting = 1'b1;
        if (TILE_SPLIT_FACTOR == 1)      state_nxt = ST_MAC_LO;
        else if (TILE_SPLIT_FACTOR == 2) state_nxt = ST_MAC_LO;
        else if (TILE_MAC_REUSE)         state_nxt = ST_MAC_Q0_L;
        else                             state_nxt = ST_MAC_Q0;
      end

      // Legacy MAC states
      ST_MAC_LO: begin busy=1'b1; perf_counting=1'b1;
        state_nxt = (TILE_SPLIT_FACTOR==1) ? ST_COMPUTE : ST_MAC_HI; end
      ST_MAC_HI: begin busy=1'b1; perf_counting=1'b1; state_nxt = ST_COMPUTE; end

      // === C4 pipeline: L → M → MAC chain ===
      // L states: latch phase-selected x_eff/w_tile
      ST_MAC_Q0_L: begin busy=1'b1; perf_counting=1'b1;
        state_nxt = C4_MUL_PIPE ? ST_MAC_Q0_M : ST_MAC_Q0; end
      ST_MAC_Q1_L: begin busy=1'b1; perf_counting=1'b1;
        state_nxt = C4_MUL_PIPE ? ST_MAC_Q1_M : ST_MAC_Q1; end
      ST_MAC_Q2_L: begin busy=1'b1; perf_counting=1'b1;
        state_nxt = C4_MUL_PIPE ? ST_MAC_Q2_M : ST_MAC_Q2; end
      ST_MAC_Q3_L: begin busy=1'b1; perf_counting=1'b1;
        state_nxt = C4_MUL_PIPE ? ST_MAC_Q3_M : ST_MAC_Q3; end

      // M states: wait for tile's product register (DSP48 multiply latency)
      ST_MAC_Q0_M: begin busy=1'b1; perf_counting=1'b1; state_nxt = ST_MAC_Q0; end
      ST_MAC_Q1_M: begin busy=1'b1; perf_counting=1'b1; state_nxt = ST_MAC_Q1; end
      ST_MAC_Q2_M: begin busy=1'b1; perf_counting=1'b1; state_nxt = ST_MAC_Q2; end
      ST_MAC_Q3_M: begin busy=1'b1; perf_counting=1'b1; state_nxt = ST_MAC_Q3; end

      // MAC states: accumulate from registered products
      ST_MAC_Q0: begin busy=1'b1; perf_counting=1'b1;
        state_nxt = TILE_MAC_REUSE ? ST_MAC_Q1_L : ST_MAC_Q1; end
      ST_MAC_Q1: begin busy=1'b1; perf_counting=1'b1;
        state_nxt = TILE_MAC_REUSE ? ST_MAC_Q2_L : ST_MAC_Q2; end
      ST_MAC_Q2: begin busy=1'b1; perf_counting=1'b1;
        state_nxt = TILE_MAC_REUSE ? ST_MAC_Q3_L : ST_MAC_Q3; end
      ST_MAC_Q3: begin busy=1'b1; perf_counting=1'b1; state_nxt = ST_COMPUTE; end

      ST_COMPUTE: begin
        busy = 1'b1; perf_counting = 1'b1;
        psum_en_q0 = 1'b1; psum_en_q1 = 1'b1; psum_en_q2 = 1'b1; psum_en_q3 = 1'b1;
        state_nxt = ST_NEXT_IB;
      end

      ST_NEXT_IB: begin
        busy = 1'b1; perf_counting = 1'b1;
        if (ib == cfg_n_ib - 16'd1) begin
          tile_idx_nxt = '0; row_idx_nxt = '0; state_nxt = ST_BIAS_ADD;
        end else begin ib_nxt = ib + 16'd1; fetch_cnt_nxt = '0; state_nxt = ST_FETCH; end
      end

      // Output pipeline
      ST_BIAS_ADD:  begin busy=1'b1; perf_counting=1'b1; state_nxt = ST_ACTIVATE; end
      ST_ACTIVATE:  begin busy=1'b1; perf_counting=1'b1; state_nxt = ST_REQUANT; end
      ST_REQUANT:   begin busy=1'b1; perf_counting=1'b1; state_nxt = ST_STORE; end
      ST_STORE:     begin busy=1'b1; perf_counting=1'b1; state_nxt = ST_SHIFT; end
      ST_SHIFT:     begin busy=1'b1; perf_counting=1'b1; state_nxt = ST_CLAMP; end
      ST_CLAMP:     begin busy=1'b1; perf_counting=1'b1; state_nxt = ST_WRITE_OBUF; end

      ST_WRITE_OBUF: begin
        busy = 1'b1; perf_counting = 1'b1;
        if (neuron_addr_p5 < {16'd0, cfg_out_dim}) begin
          obuf_wr_en = 1'b1; obuf_wr_addr = neuron_addr_p5[OBUF_AW-1:0]; obuf_wr_data = requant_r;
        end
        if (row_idx == TILE_ROWS[3:0] - 4'd1) begin
          row_idx_nxt = '0;
          if (tile_idx == tiles_this_pass - 8'd1) state_nxt = ST_NEXT_OB;
          else begin tile_idx_nxt = tile_idx + 4'd1; state_nxt = ST_BIAS_ADD; end
        end else begin row_idx_nxt = row_idx + 4'd1; state_nxt = ST_BIAS_ADD; end
      end

      ST_NEXT_OB: begin
        busy = 1'b1; perf_counting = 1'b1;
        if (ob_group + PAR_OB[15:0] >= cfg_n_ob) state_nxt = ST_DONE;
        else begin ob_group_nxt = ob_group + PAR_OB[15:0]; state_nxt = ST_CLEAR_PSUM; end
      end

      ST_DONE: begin done = 1'b1; state_nxt = ST_IDLE; end
      default: state_nxt = ST_IDLE;
    endcase
  end

  assign dbg_state = state;

  // ============================================================
  // Performance Counters
  // ============================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n || soft_rst) begin perf_cycles <= '0; perf_macs <= '0; end
    else if (start && state == ST_IDLE) begin perf_cycles <= '0; perf_macs <= '0; end
    else begin
      if (perf_counting) perf_cycles <= perf_cycles + 64'd1;
      if (psum_en_q0 && psum_en_q1 && psum_en_q2 && psum_en_q3)
        perf_macs <= perf_macs + 64'(PAR_OB) * 64'(TILE_ROWS) * 64'(TILE_COLS);
    end
  end

endmodule
