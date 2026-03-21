// ============================================================================
// cim_accel_core.sv — CIM Accelerator Core (FULLY PIPELINED for 125MHz)
// ============================================================================
//
// Two pipeline regions:
//
// A) Compute pipeline (per input-block iteration):
//    Splits the 26ns combinational path BRAM→ZP→MAC→accumulate into 3 stages:
//
//    ST_FETCH/WAIT  │ Issue BRAM read addr; weight BRAM → w_tile_reg
//    ST_XEFF_REG    │ input BRAM output + ZP subtract settles → register x_eff_reg
//                   │ Critical path: BRAM Tco + 32-bit subtract + clamp (~10ns) ✓
//    ST_MAC         │ cim_tile: x_eff_reg × w_tile_reg → register tile_psum_reg
//                   │ Critical path: 16-element MAC chain (~10ns) ✓
//    ST_COMPUTE     │ psum_accum += tile_psum_reg (registered add)
//                   │ Critical path: 32-bit add (~4ns) ✓
//
// B) Output pipeline (per neuron, after all IB iterations):
//    ST_BIAS_ADD  → ST_ACTIVATE → ST_REQUANT → ST_STORE
//    (unchanged from previous version)
//
// Cost: +2 cycles per IB iteration (XEFF_REG + MAC) vs original.
// For FC1: ~49*(9+2) = ~539 compute cycles + output pipeline.
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
  // Pre-computed addresses (unchanged)
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
  // Weight tile register bank (unchanged)
  // ============================================================
  logic signed [WEIGHT_W-1:0] w_tile_reg[PAR_OB][TILE_ROWS][TILE_COLS];

  // ============================================================
  // Compute pipeline registers (NEW for 125MHz timing closure)
  // ============================================================
  // Stage A output: registered x_eff (latched in ST_XEFF_REG)
  // Cuts path: BRAM_read → ZP_subtract | register | cim_tile_MAC
  logic [X_EFF_W-1:0] x_eff_reg[TILE_COLS];

  // Stage B output: registered tile_psum (latched in ST_MAC)
  // Cuts path: cim_tile_MAC | register | psum_accumulate
  logic signed [PSUM_W-1:0] tile_psum_reg[PAR_OB][TILE_ROWS];

  // ============================================================
  // CIM Tile Array + psum accum
  // ============================================================
  // cim_tile is purely combinational: x_eff_reg × w_tile_reg → tile_psum
  // tile_psum is registered into tile_psum_reg before feeding psum_accum
  logic signed [PSUM_W-1:0] tile_psum[PAR_OB][TILE_ROWS];
  logic signed [PSUM_W-1:0] psum_out[PAR_OB][TILE_ROWS];
  logic psum_clear, psum_en;

  genvar g;
  generate
    for (g = 0; g < PAR_OB; g++) begin : GEN_TILE
      cim_tile u_tile (
          .x_eff (x_eff_reg),      // use REGISTERED x_eff
          .w_tile(w_tile_reg[g]),
          .psum  (tile_psum[g])
      );
      psum_accum u_psum (
          .clk      (clk),
          .rst_n    (rst_n),
          .clear    (psum_clear),
          .en       (psum_en),
          .tile_psum(tile_psum_reg[g]),  // use REGISTERED tile_psum
          .psum     (psum_out[g])
      );
    end
  endgenerate

  // ============================================================
  // Pipeline registers
  // ============================================================
  // Stage 1 output (registered at end of ST_BIAS_ADD):
  logic signed [  PSUM_W-1:0] psum_sel_r;  // MUXed psum value
  logic        [        31:0] neuron_addr_p1;  // neuron index for bounds check

  // Stage 2 output (registered at end of ST_ACTIVATE):
  logic signed [  BIAS_W-1:0] bias_val_r;  // bias from BRAM

  // Stage 3 output (registered at end of ST_REQUANT):
  logic signed [  PSUM_W-1:0] activated_r;  // after bias+ReLU
  logic        [        31:0] neuron_addr_p3;

  // Stage 4 output (registered at end of ST_STORE):
  logic signed [OUTPUT_W-1:0] requant_r;  // requantized INT8 value
  logic        [        31:0] neuron_addr_p4;

  // ============================================================
  // Combinational logic for pipeline stages
  // ============================================================

  // In ST_REQUANT: bias_val_r and psum_sel_r are both registered
  logic signed [  PSUM_W-1:0] acc_with_bias;
  logic signed [  PSUM_W-1:0] after_act;
  assign acc_with_bias = psum_sel_r + bias_val_r;
  always_comb begin
    case (cfg_act_mode)
      ACT_RELU: after_act = (acc_with_bias > 0) ? acc_with_bias : '0;
      default:  after_act = acc_with_bias;
    endcase
  end

  // In ST_STORE: activated_r is registered
  logic signed [OUTPUT_W-1:0] requant_result;
  assign requant_result = requantize(activated_r, cfg_requant_mult, cfg_requant_shift);

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
      requant_r      <= '0;
      neuron_addr_p4 <= '0;
      for (int c = 0; c < TILE_COLS; c++) x_eff_reg[c] <= '0;
      for (int t = 0; t < PAR_OB; t++)
      for (int r = 0; r < TILE_ROWS; r++) begin
        tile_psum_reg[t][r] <= '0;
        for (int c = 0; c < TILE_COLS; c++) w_tile_reg[t][r][c] <= '0;
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

      // NEW Stage A: Register x_eff (ZP subtract output settles during WAIT_SRAM)
      // ibuf_x_eff is combinational from BRAM rd_word → ZP subtract.
      // By the time we reach ST_XEFF_REG, BRAM read is done and x_eff is stable.
      if (state == ST_XEFF_REG) begin
        for (int c = 0; c < TILE_COLS; c++) x_eff_reg[c] <= ibuf_x_eff[c];
      end

      // NEW Stage B: Register tile_psum (cim_tile MAC output)
      // cim_tile is combinational on x_eff_reg × w_tile_reg → tile_psum.
      // In ST_MAC, tile_psum has settled; latch it for psum_accum.
      if (state == ST_MAC) begin
        for (int t = 0; t < PAR_OB; t++)
        for (int r = 0; r < TILE_ROWS; r++) tile_psum_reg[t][r] <= tile_psum[t][r];
      end

      // Pipeline Stage 1 → register at end of BIAS_ADD
      // psum_out[tile_idx][row_idx] is a big MUX; register the result
      if (state == ST_BIAS_ADD) begin
        psum_sel_r     <= psum_out[tile_idx][row_idx];
        neuron_addr_p1 <= bias_addr_cur;
      end

      // Pipeline Stage 2 → register at end of ACTIVATE
      // Bias BRAM has 1-cycle latency: addr set in BIAS_ADD, data valid in ACTIVATE
      if (state == ST_ACTIVATE) begin
        bias_val_r <= b_rd_data;
      end

      // Pipeline Stage 3 → register at end of REQUANT
      // acc_with_bias and after_act use psum_sel_r + bias_val_r (both registered)
      if (state == ST_REQUANT) begin
        activated_r    <= after_act;
        neuron_addr_p3 <= neuron_addr_p1;
      end

      // Pipeline Stage 4 → register at end of ST_STORE
      // requantize is combinational on activated_r (registered input)
      // Register the result so obuf write + argmax happen on clean registered data
      if (state == ST_STORE) begin
        requant_r      <= requant_result;
        neuron_addr_p4 <= neuron_addr_p3;
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

      // ====== Weight fetch loop (+ tile settle) ======
      ST_FETCH: begin
        busy          = 1'b1;
        perf_counting = 1'b1;
        // w_rd_tile_idx set by default assign (uses current fetch_cnt, ib)
        state_nxt     = ST_WAIT_SRAM;
      end

      ST_WAIT_SRAM: begin
        busy          = 1'b1;
        perf_counting = 1'b1;
        // w_tile_reg[fetch_cnt] latched in sequential block
        if (fetch_cnt == PAR_OB[3:0] - 4'd1) begin
          fetch_cnt_nxt = '0;
          state_nxt     = ST_XEFF_REG;  // → register x_eff before MAC
        end else begin
          fetch_cnt_nxt = fetch_cnt + 4'd1;
          state_nxt     = ST_FETCH;
        end
      end

      // NEW Stage A: x_eff settles (BRAM read + ZP subtract done), register it
      ST_XEFF_REG: begin
        busy          = 1'b1;
        perf_counting = 1'b1;
        // x_eff_reg latched in sequential block from ibuf_x_eff
        state_nxt     = ST_MAC;
      end

      // NEW Stage B: cim_tile MAC runs on x_eff_reg × w_tile_reg, register tile_psum
      ST_MAC: begin
        busy          = 1'b1;
        perf_counting = 1'b1;
        // tile_psum_reg latched in sequential block from tile_psum
        state_nxt     = ST_COMPUTE;
      end

      // Stage C: psum_accum += tile_psum_reg (registered input, short path)
      ST_COMPUTE: begin
        busy          = 1'b1;
        psum_en       = 1'b1;
        perf_counting = 1'b1;
        state_nxt     = ST_NEXT_IB;
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

      // ====== 4-stage output pipeline (per neuron) ======

      // Stage 1: register psum MUX, set bias BRAM address
      ST_BIAS_ADD: begin
        busy          = 1'b1;
        perf_counting = 1'b1;
        // b_rd_addr = bias_addr_cur (set by default combinational assign)
        // psum_sel_r and neuron_addr_p1 registered in seq block
        state_nxt     = ST_ACTIVATE;
      end

      // Stage 2: bias BRAM data available, latch it
      ST_ACTIVATE: begin
        busy          = 1'b1;
        perf_counting = 1'b1;
        // bias_val_r latched in seq block from b_rd_data
        state_nxt     = ST_REQUANT;
      end

      // Stage 3: compute bias_add + ReLU, register result
      ST_REQUANT: begin
        busy          = 1'b1;
        perf_counting = 1'b1;
        // after_act = ReLU(psum_sel_r + bias_val_r) — combinational
        // activated_r and neuron_addr_p3 registered in seq block
        state_nxt     = ST_STORE;
      end

      // Stage 4: requantize only — result registered into requant_r
      ST_STORE: begin
        busy          = 1'b1;
        perf_counting = 1'b1;
        // requant_result = requantize(activated_r) — combinational
        // requant_r and neuron_addr_p4 latched in seq block
        state_nxt     = ST_WRITE_OBUF;
      end

      // Stage 5: write output buffer from registered requant_r
      ST_WRITE_OBUF: begin
        busy          = 1'b1;
        perf_counting = 1'b1;

        if (neuron_addr_p4 < {16'd0, cfg_out_dim}) begin
          obuf_wr_en   = 1'b1;
          obuf_wr_addr = neuron_addr_p4[OBUF_AW-1:0];
          obuf_wr_data = requant_r;
        end

        // Advance to next neuron (pre-fetch next bias address)
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
  // Performance Counters (unchanged)
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
      if (psum_en) perf_macs <= perf_macs + 64'(PAR_OB) * 64'(TILE_ROWS) * 64'(TILE_COLS);
    end
  end

endmodule
