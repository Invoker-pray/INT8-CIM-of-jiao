`timescale 1ns / 1ps
// ============================================================================
// tb_par_ob_sweep.sv — PAR_OB scalability sweep (cycle count + bit-exact check)
// ============================================================================
// Purpose (for thesis §"加速比/可扩展性"):
//   Demonstrate that the accelerator core is genuinely parameterized in PAR_OB:
//   as PAR_OB grows, the cycle count for a FIXED layer drops ~linearly, while
//   results stay bit-exact against an inline integer golden. This proves the
//   ARRAY architecture scales; the FPGA build is pinned to PAR_OB=1 ONLY because
//   the PYNQ-Z2 has 220 DSP48 — a resource limit, not an architectural one.
//
// How PAR_OB is selected:
//   PAR_OB is a compile-time parameter in cim_pkg.sv. This TB does NOT set it.
//   The sweep is driven externally by run_par_ob_sweep.sh, which recompiles
//   cim_pkg.sv with PAR_OB = 1,2,4,8,16 and runs this TB each time.
//
// Fixed workload (chosen so every swept PAR_OB divides N_OB):
//   IN_DIM  = 256  -> N_IB = 16
//   OUT_DIM = 256  -> N_OB = 16   (16 % {1,2,4,8,16} == 0)  ✓
//   This stays within MAX_IN_DIM=1536 / MAX_OUT_DIM=256.
//
// Architectural ceiling note:
//   The current RTL caps PAR_OB at 16: fetch_cnt/tile_idx are logic[3:0] and
//   MAX_OUT_DIM=256 (=> MAX_N_OB=16). PAR_OB=32 requires widening those counters
//   AND raising MAX_OUT_DIM — see run_par_ob_sweep.sh header. This TB refuses to
//   run for PAR_OB that does not divide N_OB, so a misconfigured 32 fails loudly
//   instead of silently producing wrong numbers.
//
// Machine-parseable result line (grepped by the runner):
//   SWEEP_RESULT PAR_OB=<p> IN=<in> OUT=<out> CYCLES=<c> MACS=<m> ERRORS=<e>
// ============================================================================

module tb_par_ob_sweep;
  import cim_pkg::*;

  // ----- fixed layer geometry -----
  localparam int IN_DIM  = 256;
  localparam int OUT_DIM = 256;
  localparam int N_IB    = IN_DIM  / TILE_COLS;   // 16
  localparam int N_OB    = OUT_DIM / TILE_ROWS;   // 16
  localparam int ZP      = -128;
  localparam int MULT    = 1073741824;            // 2^30
  localparam int SHIFT   = 30;

  // ---------- DUT signals ----------
  logic clk = 0, rst_n;
  logic start, soft_rst;
  logic busy, done;
  accel_state_t dbg_state;

  logic [15:0] cfg_in_dim, cfg_out_dim, cfg_n_ib, cfg_n_ob;
  logic signed [31:0] cfg_input_zp;
  logic [31:0] cfg_requant_mult, cfg_requant_shift;
  act_mode_t   cfg_act_mode;
  logic [clog2_safe(WSRAM_DEPTH)-1:0] cfg_weight_base = '0;
  logic [clog2_safe(BSRAM_DEPTH)-1:0] cfg_bias_base   = '0;

  // Weight SRAM
  logic        [clog2_safe(WSRAM_DEPTH)-1:0] w_rd_idx;
  logic signed [WEIGHT_W-1:0]                w_rd_tile [TILE_ROWS][TILE_COLS];
  logic                                      w_wr_en;
  logic        [$clog2(TILE_ROWS)-1:0]       w_wr_row;
  logic        [clog2_safe(WSRAM_DEPTH)-1:0] w_wr_tile_idx;
  logic        [TILE_COLS*WEIGHT_W-1:0]      w_wr_row_data;

  // Bias SRAM
  logic        [clog2_safe(BSRAM_DEPTH)-1:0] b_rd_addr;
  logic signed [BIAS_W-1:0]                  b_rd_data;
  logic                                      b_wr_en;
  logic        [clog2_safe(BSRAM_DEPTH)-1:0] b_wr_addr;
  logic        [31:0]                        b_wr_data;

  // Input buffer
  logic        [clog2_safe(MAX_IN_DIM/TILE_COLS)-1:0] ibuf_rd_idx;
  logic        [X_EFF_W-1:0]                          ibuf_x_eff [TILE_COLS];
  logic                                               ibuf_wr_en;
  logic        [clog2_safe(MAX_IN_DIM/TILE_COLS)-1:0] ibuf_wr_tile_idx;
  logic        [TILE_COLS*INPUT_W-1:0]                ibuf_wr_tile_data;

  // Output buffer
  logic                                      obuf_wr_en;
  logic        [clog2_safe(MAX_OUT_DIM)-1:0] obuf_wr_addr;
  logic signed [OUTPUT_W-1:0]                obuf_wr_data;
  logic        [clog2_safe(MAX_OUT_DIM)-1:0] obuf_rd_addr;
  logic signed [OUTPUT_W-1:0]                obuf_rd_data;
  logic        [clog2_safe(MAX_OUT_DIM)-1:0] pred_class;

  logic [63:0] perf_cycles, perf_macs;

  // ---------- Golden ----------
  logic signed [WEIGHT_W-1:0] golden_w  [OUT_DIM][IN_DIM];
  logic signed [BIAS_W-1:0]   golden_b  [OUT_DIM];
  logic        [INPUT_W-1:0]  golden_x  [IN_DIM];
  logic signed [PSUM_W-1:0]   golden_acc[OUT_DIM];
  logic signed [OUTPUT_W-1:0] golden_out[OUT_DIM];
  int err_cnt;

  // 100 MHz
  always #5 clk = ~clk;

  // x_tile is an extra output of input_buffer (raw bytes before zp); unused here
  logic [INPUT_W-1:0] ibuf_x_tile [TILE_COLS];

  // ---------- Memories (port lists copied verbatim from system TB) ----------
  weight_sram #(.DEPTH(WSRAM_DEPTH)) u_wsram (
      .clk(clk),
      .wr_en(w_wr_en), .wr_row(w_wr_row), .wr_tile_idx(w_wr_tile_idx), .wr_row_data(w_wr_row_data),
      .rd_tile_idx(w_rd_idx), .rd_tile(w_rd_tile));

  bias_sram #(.DEPTH(BSRAM_DEPTH)) u_bsram (
      .clk(clk),
      .wr_en(b_wr_en), .wr_addr(b_wr_addr), .wr_data(b_wr_data),
      .rd_addr(b_rd_addr), .rd_data(b_rd_data));

  input_buffer #(.MAX_LEN(MAX_IN_DIM)) u_ibuf (
      .clk(clk),
      .wr_en(ibuf_wr_en), .wr_tile_idx(ibuf_wr_tile_idx), .wr_tile_data(ibuf_wr_tile_data),
      .wr_bank_sel(1'b0), .rd_bank_sel(1'b0), .rd_tile_idx(ibuf_rd_idx),
      .input_zp(cfg_input_zp), .x_tile(ibuf_x_tile), .x_eff(ibuf_x_eff));

  output_buffer #(.MAX_LEN(MAX_OUT_DIM)) u_obuf (
      .clk(clk), .rst_n(rst_n),
      .wr_en(obuf_wr_en), .wr_addr(obuf_wr_addr), .wr_data(obuf_wr_data),
      .wr_bank_sel(1'b0), .rd_bank_sel(1'b0),
      .rd_addr(obuf_rd_addr), .rd_data(obuf_rd_data),
      .out_dim(cfg_out_dim[clog2_safe(MAX_OUT_DIM)-1:0]), .pred_class(pred_class));

  // ---------- DUT ----------
  cim_accel_core dut (
      .clk(clk), .rst_n(rst_n), .start(start), .soft_rst(soft_rst),
      .busy(busy), .done(done), .dbg_state(dbg_state),
      .cfg_in_dim(cfg_in_dim), .cfg_out_dim(cfg_out_dim),
      .cfg_n_ib(cfg_n_ib), .cfg_n_ob(cfg_n_ob),
      .cfg_input_zp(cfg_input_zp), .cfg_requant_mult(cfg_requant_mult),
      .cfg_requant_shift(cfg_requant_shift), .cfg_act_mode(cfg_act_mode),
      .cfg_weight_base(cfg_weight_base), .cfg_bias_base(cfg_bias_base),
      .w_rd_tile_idx(w_rd_idx), .w_rd_tile(w_rd_tile),
      .b_rd_addr(b_rd_addr), .b_rd_data(b_rd_data),
      .ibuf_rd_tile_idx(ibuf_rd_idx), .ibuf_x_eff(ibuf_x_eff),
      .obuf_wr_en(obuf_wr_en), .obuf_wr_addr(obuf_wr_addr), .obuf_wr_data(obuf_wr_data),
      .perf_cycles(perf_cycles), .perf_macs(perf_macs));

  // ---------- write tasks ----------
  task write_weight_row(input int tile_idx, input int row_idx,
                        input logic [TILE_COLS*WEIGHT_W-1:0] row_data);
    @(posedge clk);
    w_wr_en <= 1'b1; w_wr_tile_idx <= tile_idx; w_wr_row <= row_idx; w_wr_row_data <= row_data;
    @(posedge clk);
    w_wr_en <= 1'b0;
  endtask

  task write_input_tile(input int tile_idx, input logic [TILE_COLS*INPUT_W-1:0] tile_data);
    @(posedge clk);
    ibuf_wr_en <= 1'b1; ibuf_wr_tile_idx <= tile_idx; ibuf_wr_tile_data <= tile_data;
    @(posedge clk);
    ibuf_wr_en <= 1'b0;
  endtask

  task load_all_data();
    for (int ob = 0; ob < N_OB; ob++)
      for (int ib = 0; ib < N_IB; ib++) begin
        automatic int tile_addr = ob * N_IB + ib;
        for (int r = 0; r < TILE_ROWS; r++) begin
          automatic logic [TILE_COLS*WEIGHT_W-1:0] row_data = '0;
          for (int c = 0; c < TILE_COLS; c++) begin
            automatic int out_idx = ob * TILE_ROWS + r;
            automatic int in_idx  = ib * TILE_COLS + c;
            if (out_idx < OUT_DIM && in_idx < IN_DIM)
              row_data[c*WEIGHT_W+:WEIGHT_W] = golden_w[out_idx][in_idx];
          end
          write_weight_row(tile_addr, r, row_data);
        end
      end
    for (int o = 0; o < OUT_DIM; o++) begin
      @(posedge clk);
      b_wr_en <= 1'b1; b_wr_addr <= o; b_wr_data <= golden_b[o];
      @(posedge clk);
      b_wr_en <= 1'b0;
    end
    for (int tile = 0; tile < N_IB; tile++) begin
      automatic logic [TILE_COLS*INPUT_W-1:0] tdata = '0;
      for (int c = 0; c < TILE_COLS; c++) begin
        automatic int idx = tile * TILE_COLS + c;
        if (idx < IN_DIM) tdata[c*INPUT_W+:INPUT_W] = golden_x[idx];
      end
      write_input_tile(tile, tdata);
    end
    repeat (5) @(posedge clk);
  endtask

  // ---------- inline integer golden (matches RTL: unsigned x_eff) ----------
  task compute_golden();
    for (int o = 0; o < OUT_DIM; o++) begin
      golden_acc[o] = golden_b[o];
      for (int i = 0; i < IN_DIM; i++) begin
        automatic int x_eff_val = int'(golden_x[i]) - ZP;   // x + 128
        if (x_eff_val < 0)   x_eff_val = 0;
        if (x_eff_val > 511) x_eff_val = 511;
        golden_acc[o] += x_eff_val * golden_w[o][i];
      end
      if (golden_acc[o] < 0) golden_acc[o] = 0;              // ReLU
      golden_out[o] = requantize(golden_acc[o], MULT, SHIFT);
    end
  endtask

  initial begin
`ifdef VCS
    $fsdbDumpfile("tb_par_ob_sweep.fsdb");
    $fsdbDumpvars(0, tb_par_ob_sweep, "+all");
`endif

    // ---- compile-time guard: PAR_OB must divide N_OB ----
    if ((N_OB % PAR_OB) != 0) begin
      $display("SWEEP_RESULT PAR_OB=%0d IN=%0d OUT=%0d CYCLES=0 MACS=0 ERRORS=999",
               PAR_OB, IN_DIM, OUT_DIM);
      $display(">>> FATAL: PAR_OB=%0d does NOT divide N_OB=%0d. "
               "Pick OUT_DIM so N_OB %% PAR_OB == 0 (and widen counters/MAX_OUT_DIM "
               "if PAR_OB>16). Aborting. <<<", PAR_OB, N_OB);
      $finish;
    end

    err_cnt = 0; rst_n = 0; start = 0; soft_rst = 0;
    w_wr_en = 0; b_wr_en = 0; ibuf_wr_en = 0; obuf_rd_addr = '0;

    cfg_in_dim = IN_DIM; cfg_out_dim = OUT_DIM;
    cfg_n_ib = N_IB; cfg_n_ob = N_OB;
    cfg_input_zp = ZP; cfg_requant_mult = MULT; cfg_requant_shift = SHIFT;
    cfg_act_mode = ACT_RELU;

    repeat (10) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);

    // deterministic vectors (fixed seed so every PAR_OB sees identical data)
    begin
      automatic int unsigned seed = 32'hC1A0_0001;
      void'($urandom(seed));
      for (int o = 0; o < OUT_DIM; o++)
        for (int i = 0; i < IN_DIM; i++)
          golden_w[o][i] = $signed($urandom() & 8'hFF);
      for (int o = 0; o < OUT_DIM; o++) golden_b[o] = $urandom() & 32'h0000FFFF;
      for (int i = 0; i < IN_DIM; i++)  golden_x[i] = $urandom() & 8'hFF;
    end

    load_all_data();
    compute_golden();

    @(posedge clk); start <= 1'b1;
    @(posedge clk); start <= 1'b0;

    wait (done);
    repeat (3) @(posedge clk);

    for (int o = 0; o < OUT_DIM; o++) begin
      obuf_rd_addr = o;
      repeat (2) @(posedge clk);
      if (obuf_rd_data !== golden_out[o]) err_cnt++;
    end

    $display("============================================================");
    $display("PAR_OB sweep point: PAR_OB=%0d  layer %0dx%0d (N_IB=%0d N_OB=%0d)",
             PAR_OB, IN_DIM, OUT_DIM, N_IB, N_OB);
    $display("  cycles=%0d  macs=%0d  errors=%0d/%0d",
             perf_cycles, perf_macs, err_cnt, OUT_DIM);
    // machine-parseable line for the runner:
    $display("SWEEP_RESULT PAR_OB=%0d IN=%0d OUT=%0d CYCLES=%0d MACS=%0d ERRORS=%0d",
             PAR_OB, IN_DIM, OUT_DIM, perf_cycles, perf_macs, err_cnt);
    if (err_cnt == 0) $display(">>> PASS (bit-exact) <<<");
    else              $display(">>> FAIL <<<");
    $display("============================================================");
    $finish;
  end

  // safety timeout
  initial begin
    #20_000_000;
    $display("SWEEP_RESULT PAR_OB=%0d IN=%0d OUT=%0d CYCLES=0 MACS=0 ERRORS=998", PAR_OB, IN_DIM, OUT_DIM);
    $display(">>> TIMEOUT <<<");
    $finish;
  end

endmodule
