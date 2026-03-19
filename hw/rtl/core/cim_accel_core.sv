// ============================================================================
// cim_accel_core.sv — CIM Accelerator Core Engine (lint-clean)
// ============================================================================
// Unified MVM engine: software configures dims via CSR, then triggers.
// PAR_OB parallel CIM tiles share the same input tile.
//
// FIXES vs FPGA_A:
//   1. Explicit psum clear before every ob_group
//   2. All SRAMs AXI-writable (no $readmemh)
//   3. Unified engine for all layers
//   4. PAR_OB centralized in cim_pkg
//   5. Performance counters built-in
// ============================================================================

module cim_accel_core
  import cim_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,

  input  logic        start,
  input  logic        soft_rst,
  output logic        busy,
  output logic        done,
  output accel_state_t dbg_state,

  input  logic [15:0] cfg_in_dim,
  input  logic [15:0] cfg_out_dim,
  input  logic [15:0] cfg_n_ib,
  input  logic [15:0] cfg_n_ob,
  input  logic signed [31:0] cfg_input_zp,
  input  logic [31:0] cfg_requant_mult,
  input  logic [31:0] cfg_requant_shift,
  input  act_mode_t   cfg_act_mode,

  output logic [clog2_safe(WSRAM_DEPTH)-1:0]          w_rd_tile_idx,
  input  logic signed [WEIGHT_W-1:0]                   w_rd_tile [TILE_ROWS][TILE_COLS],

  output logic [clog2_safe(BSRAM_DEPTH)-1:0]          b_rd_addr,
  input  logic signed [BIAS_W-1:0]                     b_rd_data,

  output logic [clog2_safe(MAX_IN_DIM/TILE_COLS)-1:0]  ibuf_rd_tile_idx,
  input  logic [X_EFF_W-1:0]                           ibuf_x_eff [TILE_COLS],

  output logic                                         obuf_wr_en,
  output logic [clog2_safe(MAX_OUT_DIM)-1:0]           obuf_wr_addr,
  output logic signed [OUTPUT_W-1:0]                   obuf_wr_data,

  output logic [63:0] perf_cycles,
  output logic [63:0] perf_macs
);

  localparam int WSRAM_AW = clog2_safe(WSRAM_DEPTH);
  localparam int BSRAM_AW = clog2_safe(BSRAM_DEPTH);
  localparam int IBUF_AW  = clog2_safe(MAX_IN_DIM / TILE_COLS);
  localparam int OBUF_AW  = clog2_safe(MAX_OUT_DIM);

  // ============================================================
  // State & loop counters
  // ============================================================
  accel_state_t state, state_nxt;

  logic [15:0] ob_group,    ob_group_nxt;
  logic [15:0] ib,          ib_nxt;
  logic [3:0]  fetch_cnt,   fetch_cnt_nxt;
  logic [3:0]  tile_idx,    tile_idx_nxt;
  logic [3:0]  row_idx,     row_idx_nxt;

  // ============================================================
  // Pre-computed addresses (clean wires, no complex bit-selects)
  // ============================================================
  logic [31:0] w_addr_full;
  logic [31:0] bias_addr_cur;
  logic [31:0] bias_addr_next_tile;
  logic [31:0] bias_addr_next_row;

  assign w_addr_full          = ({16'd0, ob_group} + {28'd0, fetch_cnt})
                                * {16'd0, cfg_n_ib} + {16'd0, ib};
  assign bias_addr_cur        = ({16'd0, ob_group} + {28'd0, tile_idx})
                                * TILE_ROWS + {28'd0, row_idx};
  assign bias_addr_next_tile  = ({16'd0, ob_group} + {28'd0, tile_idx} + 32'd1)
                                * TILE_ROWS;
  assign bias_addr_next_row   = bias_addr_cur + 32'd1;

  // ============================================================
  // Weight tile register bank
  // ============================================================
  logic signed [WEIGHT_W-1:0] w_tile_reg [PAR_OB][TILE_ROWS][TILE_COLS];

  // ============================================================
  // CIM Tile Array — PAR_OB tiles sharing input
  // ============================================================
  logic signed [PSUM_W-1:0] tile_psum [PAR_OB][TILE_ROWS];
  logic signed [PSUM_W-1:0] psum_out  [PAR_OB][TILE_ROWS];
  logic psum_clear, psum_en;

  genvar g;
  generate
    for (g = 0; g < PAR_OB; g++) begin : GEN_TILE
      cim_tile u_tile (
        .x_eff  (ibuf_x_eff),
        .w_tile (w_tile_reg[g]),
        .psum   (tile_psum[g])
      );
      psum_accum u_psum (
        .clk       (clk),
        .rst_n     (rst_n),
        .clear     (psum_clear),
        .en        (psum_en),
        .tile_psum (tile_psum[g]),
        .psum      (psum_out[g])
      );
    end
  endgenerate

  // ============================================================
  // Bias latch + Activation unit
  // ============================================================
  logic signed [BIAS_W-1:0]   bias_val_r;
  logic signed [PSUM_W-1:0]   acc_with_bias;
  logic signed [PSUM_W-1:0]   after_act;
  logic signed [OUTPUT_W-1:0] act_out;

  assign acc_with_bias = psum_out[tile_idx][row_idx] + bias_val_r;

  activation_unit u_act (
    .acc_in        (acc_with_bias),
    .act_mode      (cfg_act_mode),
    .requant_mult  (cfg_requant_mult),
    .requant_shift (cfg_requant_shift),
    .after_act     (after_act),
    .out_val       (act_out)
  );

  // ============================================================
  // Performance counter flag
  // ============================================================
  logic perf_counting;

  // ============================================================
  // Sequential block
  // ============================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n || soft_rst) begin
      state      <= ST_IDLE;
      ob_group   <= '0;
      ib         <= '0;
      fetch_cnt  <= '0;
      tile_idx   <= '0;
      row_idx    <= '0;
      bias_val_r <= '0;
      for (int t = 0; t < PAR_OB; t++)
        for (int r = 0; r < TILE_ROWS; r++)
          for (int c = 0; c < TILE_COLS; c++)
            w_tile_reg[t][r][c] <= '0;
    end else begin
      state     <= state_nxt;
      ob_group  <= ob_group_nxt;
      ib        <= ib_nxt;
      fetch_cnt <= fetch_cnt_nxt;
      tile_idx  <= tile_idx_nxt;
      row_idx   <= row_idx_nxt;

      // Latch one weight tile per WAIT_SRAM cycle
      if (state == ST_WAIT_SRAM) begin
        for (int r = 0; r < TILE_ROWS; r++)
          for (int c = 0; c < TILE_COLS; c++)
            w_tile_reg[fetch_cnt][r][c] <= w_rd_tile[r][c];
      end

      // Latch bias (1-cycle read latency: addr set in BIAS_ADD, data in ACTIVATE)
      if (state == ST_ACTIVATE)
        bias_val_r <= b_rd_data;
    end
  end

  // ============================================================
  // Combinational next-state + outputs
  // ============================================================
  always_comb begin
    state_nxt     = state;
    ob_group_nxt  = ob_group;
    ib_nxt        = ib;
    fetch_cnt_nxt = fetch_cnt;
    tile_idx_nxt  = tile_idx;
    row_idx_nxt   = row_idx;

    busy          = 1'b0;
    done          = 1'b0;
    psum_clear    = 1'b0;
    psum_en       = 1'b0;
    obuf_wr_en    = 1'b0;
    obuf_wr_addr  = '0;
    obuf_wr_data  = '0;
    perf_counting = 1'b0;

    w_rd_tile_idx    = w_addr_full[WSRAM_AW-1:0];
    ibuf_rd_tile_idx = ib[IBUF_AW-1:0];
    b_rd_addr        = bias_addr_cur[BSRAM_AW-1:0];

    case (state)
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
          state_nxt     = ST_COMPUTE;
        end else begin
          fetch_cnt_nxt = fetch_cnt + 4'd1;
          state_nxt     = ST_FETCH;
        end
      end

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

      ST_BIAS_ADD: begin
        busy          = 1'b1;
        perf_counting = 1'b1;
        // bias read addr is bias_addr_cur (set by default)
        state_nxt     = ST_ACTIVATE;
      end

      ST_ACTIVATE: begin
        busy          = 1'b1;
        perf_counting = 1'b1;
        // bias_val_r latched by seq block; activation computed combinationally
        state_nxt     = ST_STORE;
      end

      ST_STORE: begin
        busy          = 1'b1;
        perf_counting = 1'b1;

        if (bias_addr_cur < {16'd0, cfg_out_dim}) begin
          obuf_wr_en   = 1'b1;
          obuf_wr_addr = bias_addr_cur[OBUF_AW-1:0];
          obuf_wr_data = act_out;
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

  assign dbg_state = state;

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
      if (perf_counting)
        perf_cycles <= perf_cycles + 64'd1;
      if (psum_en)
        perf_macs <= perf_macs + 64'(PAR_OB) * 64'(TILE_ROWS) * 64'(TILE_COLS);
    end
  end

endmodule
