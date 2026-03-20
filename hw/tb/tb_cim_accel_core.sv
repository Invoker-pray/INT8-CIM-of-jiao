`timescale 1ns / 1ps
// ============================================================================
// tb_cim_accel_core.sv — System-level MVM test
// ============================================================================
// Tests the full accelerator core with a small layer (IN=32, OUT=16).
// Loads weights/bias/input via the SRAM write ports, triggers computation,
// waits for done, reads output buffer and compares with golden.
//
// Compatible with VCS + Verdi. Use $fsdbDumpvars for waveform.
// ============================================================================

module tb_cim_accel_core;
  import cim_pkg::*;

  // ---------- DUT signals ----------
  logic clk, rst_n;
  logic start, soft_rst;
  logic busy, done;
  accel_state_t dbg_state;

  logic [15:0] cfg_in_dim, cfg_out_dim, cfg_n_ib, cfg_n_ob;
  logic signed [31:0] cfg_input_zp;
  logic [31:0] cfg_requant_mult, cfg_requant_shift;
  act_mode_t                                          cfg_act_mode;

  // Weight SRAM (whole-row write interface)
  logic        [         clog2_safe(WSRAM_DEPTH)-1:0] w_rd_idx;
  logic signed [                        WEIGHT_W-1:0] w_rd_tile         [TILE_ROWS] [TILE_COLS];
  logic                                               w_wr_en;
  logic        [               $clog2(TILE_ROWS)-1:0] w_wr_row;
  logic        [         clog2_safe(WSRAM_DEPTH)-1:0] w_wr_tile_idx;
  logic        [              TILE_COLS*WEIGHT_W-1:0] w_wr_row_data;

  // Bias SRAM
  logic        [         clog2_safe(BSRAM_DEPTH)-1:0] b_rd_addr;
  logic signed [                          BIAS_W-1:0] b_rd_data;
  logic                                               b_wr_en;
  logic        [         clog2_safe(BSRAM_DEPTH)-1:0] b_wr_addr;
  logic        [                                31:0] b_wr_data;

  // Input buffer (whole-tile write interface)
  logic        [clog2_safe(MAX_IN_DIM/TILE_COLS)-1:0] ibuf_rd_idx;
  logic        [                         X_EFF_W-1:0] ibuf_x_eff        [TILE_COLS];
  logic                                               ibuf_wr_en;
  logic        [clog2_safe(MAX_IN_DIM/TILE_COLS)-1:0] ibuf_wr_tile_idx;
  logic        [               TILE_COLS*INPUT_W-1:0] ibuf_wr_tile_data;
  logic        [                         INPUT_W-1:0] ibuf_x_tile       [TILE_COLS];

  // Output buffer
  logic                                               obuf_wr_en;
  logic        [         clog2_safe(MAX_OUT_DIM)-1:0] obuf_wr_addr;
  logic signed [                        OUTPUT_W-1:0] obuf_wr_data;
  logic        [         clog2_safe(MAX_OUT_DIM)-1:0] obuf_rd_addr;
  logic signed [                        OUTPUT_W-1:0] obuf_rd_data;
  logic        [         clog2_safe(MAX_OUT_DIM)-1:0] pred_class;

  logic [63:0] perf_cycles, perf_macs;

  // ---------- Test parameters ----------
  localparam int TEST_IN = 32;  // input dim (2 input blocks @ TILE_COLS=16)
  localparam int TEST_OUT = PAR_OB * TILE_ROWS;  // output dim = exactly one ob_group (PAR_OB tiles)
  localparam int TEST_NIB = TEST_IN / TILE_COLS;  // 2
  localparam int TEST_NOB = TEST_OUT / TILE_ROWS;  // == PAR_OB
  localparam int TEST_ZP = -128;
  localparam int TEST_MULT = 1073741824;  // 2^30
  localparam int TEST_SHIFT = 30;

  // ---------- Golden storage ----------
  logic signed [WEIGHT_W-1:0] golden_w  [TEST_OUT] [TEST_IN];
  logic signed [  BIAS_W-1:0] golden_b  [TEST_OUT];
  logic        [ INPUT_W-1:0] golden_x  [ TEST_IN];
  logic signed [  PSUM_W-1:0] golden_acc[TEST_OUT];
  logic signed [OUTPUT_W-1:0] golden_out[TEST_OUT];

  int                         err_cnt;

  // ---------- Clock ----------
  initial clk = 0;
  always #5 clk = ~clk;  // 100 MHz

  // ---------- Memory instantiation ----------
  weight_sram #(
      .DEPTH(WSRAM_DEPTH)
  ) u_wsram (
      .clk        (clk),
      .wr_en      (w_wr_en),
      .wr_row     (w_wr_row),
      .wr_tile_idx(w_wr_tile_idx),
      .wr_row_data(w_wr_row_data),
      .rd_tile_idx(w_rd_idx),
      .rd_tile    (w_rd_tile)
  );

  bias_sram #(
      .DEPTH(BSRAM_DEPTH)
  ) u_bsram (
      .clk    (clk),
      .wr_en  (b_wr_en),
      .wr_addr(b_wr_addr),
      .wr_data(b_wr_data),
      .rd_addr(b_rd_addr),
      .rd_data(b_rd_data)
  );

  input_buffer #(
      .MAX_LEN(MAX_IN_DIM)
  ) u_ibuf (
      .clk         (clk),
      .wr_en       (ibuf_wr_en),
      .wr_tile_idx (ibuf_wr_tile_idx),
      .wr_tile_data(ibuf_wr_tile_data),
      .rd_tile_idx (ibuf_rd_idx),
      .input_zp    (cfg_input_zp),
      .x_tile      (ibuf_x_tile),
      .x_eff       (ibuf_x_eff)
  );

  output_buffer #(
      .MAX_LEN(MAX_OUT_DIM)
  ) u_obuf (
      .clk       (clk),
      .rst_n     (rst_n),
      .wr_en     (obuf_wr_en),
      .wr_addr   (obuf_wr_addr),
      .wr_data   (obuf_wr_data),
      .rd_addr   (obuf_rd_addr),
      .rd_data   (obuf_rd_data),
      .out_dim   (cfg_out_dim[clog2_safe(MAX_OUT_DIM)-1:0]),
      .pred_class(pred_class)
  );

  // ---------- DUT ----------
  cim_accel_core dut (
      .clk              (clk),
      .rst_n            (rst_n),
      .start            (start),
      .soft_rst         (soft_rst),
      .busy             (busy),
      .done             (done),
      .dbg_state        (dbg_state),
      .cfg_in_dim       (cfg_in_dim),
      .cfg_out_dim      (cfg_out_dim),
      .cfg_n_ib         (cfg_n_ib),
      .cfg_n_ob         (cfg_n_ob),
      .cfg_input_zp     (cfg_input_zp),
      .cfg_requant_mult (cfg_requant_mult),
      .cfg_requant_shift(cfg_requant_shift),
      .cfg_act_mode     (cfg_act_mode),
      .w_rd_tile_idx    (w_rd_idx),
      .w_rd_tile        (w_rd_tile),
      .b_rd_addr        (b_rd_addr),
      .b_rd_data        (b_rd_data),
      .ibuf_rd_tile_idx (ibuf_rd_idx),
      .ibuf_x_eff       (ibuf_x_eff),
      .obuf_wr_en       (obuf_wr_en),
      .obuf_wr_addr     (obuf_wr_addr),
      .obuf_wr_data     (obuf_wr_data),
      .perf_cycles      (perf_cycles),
      .perf_macs        (perf_macs)
  );

  // ---------- Write one whole row to weight SRAM ----------
  task write_weight_row(input int tile_idx, input int row_idx,
                        input logic [TILE_COLS*WEIGHT_W-1:0] row_data);
    @(posedge clk);
    w_wr_en       <= 1'b1;
    w_wr_tile_idx <= tile_idx;
    w_wr_row      <= row_idx;
    w_wr_row_data <= row_data;
    @(posedge clk);
    w_wr_en <= 1'b0;
  endtask

  // ---------- Write one whole tile to input buffer ----------
  task write_input_tile(input int tile_idx, input logic [TILE_COLS*INPUT_W-1:0] tile_data);
    @(posedge clk);
    ibuf_wr_en        <= 1'b1;
    ibuf_wr_tile_idx  <= tile_idx;
    ibuf_wr_tile_data <= tile_data;
    @(posedge clk);
    ibuf_wr_en <= 1'b0;
  endtask

  // ---------- Golden model ----------
  task compute_golden_model();
    for (int o = 0; o < TEST_OUT; o++) begin
      golden_acc[o] = golden_b[o];
      for (int i = 0; i < TEST_IN; i++) begin
        // x_eff = uint8(x) - zp (UNSIGNED zero-extension, matches RTL {1'b0, x_tile})
        // int'() preserves the unsigned value [0..255]; do NOT use $signed() here
        // as that would reinterpret x>=128 as negative, diverging from RTL.
        automatic int x_eff_val = int'(golden_x[i]) - TEST_ZP;  // = x + 128, range [128,383]
        if (x_eff_val < 0) x_eff_val = 0;
        if (x_eff_val > 511) x_eff_val = 511;
        golden_acc[o] = golden_acc[o] + x_eff_val * golden_w[o][i];
      end
      // ReLU
      if (golden_acc[o] < 0) golden_acc[o] = 0;
      // Requantize
      golden_out[o] = requantize(golden_acc[o], TEST_MULT, TEST_SHIFT);
    end
  endtask

  // ---------- Main test sequence ----------
  initial begin
    $display("============================================================");
    $display("TB: cim_accel_core — system MVM test (%0dx%0d)", TEST_IN, TEST_OUT);
    $display("============================================================");

    // Waveform dump (VCS+Verdi)
`ifdef VCS
    $fsdbDumpfile("tb_cim_accel_core.fsdb");
    $fsdbDumpvars(0, tb_cim_accel_core, "+all");
`endif

    err_cnt           = 0;
    rst_n             = 0;
    start             = 0;
    soft_rst          = 0;
    w_wr_en           = 0;
    b_wr_en           = 0;
    ibuf_wr_en        = 0;
    obuf_rd_addr      = '0;

    cfg_in_dim        = TEST_IN;
    cfg_out_dim       = TEST_OUT;
    cfg_n_ib          = TEST_NIB;
    cfg_n_ob          = TEST_NOB;
    cfg_input_zp      = TEST_ZP;
    cfg_requant_mult  = TEST_MULT;
    cfg_requant_shift = TEST_SHIFT;
    cfg_act_mode      = ACT_RELU;

    // Reset
    repeat (10) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);

    // ---- Generate random test data ----
    $display("Generating random test vectors...");
    for (int o = 0; o < TEST_OUT; o++) for (int i = 0; i < TEST_IN; i++) golden_w[o][i] = $random;

    for (int o = 0; o < TEST_OUT; o++) golden_b[o] = $random & 32'h0000FFFF;  // small bias

    for (int i = 0; i < TEST_IN; i++) golden_x[i] = $urandom_range(0, 255);

    // ---- Load all data using shared task ----
    $display("Loading weights/bias/input...");
    load_all_data();

    // ---- Compute golden ----
    compute_golden_model();

    // ---- Trigger computation ----
    $display("Starting CIM computation...");
    @(posedge clk);
    start <= 1'b1;
    @(posedge clk);
    start <= 1'b0;

    // ---- Wait for done ----
    wait (done);
    $display("Computation done! Cycles=%0d, MACs=%0d", perf_cycles, perf_macs);
    repeat (3) @(posedge clk);
    dump_psum();

    // ---- Read and compare results ----
    $display("Comparing results...");
    for (int o = 0; o < TEST_OUT; o++) begin
      obuf_rd_addr = o;
      repeat (2) @(posedge clk);  // 1-cycle read latency
      if (obuf_rd_data !== golden_out[o]) begin
        $display("MISMATCH out[%0d]: RTL=%0d  Golden=%0d  (acc=%0d)", o, obuf_rd_data,
                 golden_out[o], golden_acc[o]);
        err_cnt++;
      end else begin
        $display("  out[%2d] = %4d  (acc=%0d)  OK", o, obuf_rd_data, golden_acc[o]);
      end
    end

    $display("============================================================");
    $display("Pred class (argmax) = %0d", pred_class);
    $display("Performance: %0d cycles, %0d MACs", perf_cycles, perf_macs);
    $display("Test 1 (random) errors: %0d / %0d outputs", err_cnt, TEST_OUT);
    if (err_cnt == 0) $display(">>> Test 1 PASSED <<<");
    else $display(">>> Test 1 FAILED <<<");
    $display("============================================================");

    // ================================================================
    // Test 2: All-zero input → all outputs should be ReLU(bias) requantized
    // ================================================================
    $display("\n============ Test 2: All-zero input ============");
    for (int o = 0; o < TEST_OUT; o++) for (int i = 0; i < TEST_IN; i++) golden_w[o][i] = $random;
    for (int o = 0; o < TEST_OUT; o++) golden_b[o] = $random & 32'h0000FFFF;
    for (int i = 0; i < TEST_IN; i++) golden_x[i] = 8'd0;  // ALL ZERO

    load_all_data();
    compute_golden_model();
    run_and_compare("Test 2 (all-zero input)");

    // ================================================================
    // Test 3: Weight all -128 (most negative INT8)
    // ================================================================
    $display("\n============ Test 3: Weight all -128 ============");
    for (int o = 0; o < TEST_OUT; o++) for (int i = 0; i < TEST_IN; i++) golden_w[o][i] = -8'sd128;
    for (int o = 0; o < TEST_OUT; o++) golden_b[o] = 32'sd0;
    for (int i = 0; i < TEST_IN; i++) golden_x[i] = $urandom_range(0, 255);

    load_all_data();
    compute_golden_model();
    run_and_compare("Test 3 (weight all -128)");

    // ================================================================
    // Test 4: Input all 0xFF + weight all +127 + large positive bias
    //         Exercises positive accumulator overflow → clamp to +127
    // ================================================================
    $display("\n============ Test 4: Max positive overflow ============");
    for (int o = 0; o < TEST_OUT; o++) for (int i = 0; i < TEST_IN; i++) golden_w[o][i] = 8'sd127;
    for (int o = 0; o < TEST_OUT; o++) golden_b[o] = 32'h7FFF_FFFF;  // INT32 max
    for (int i = 0; i < TEST_IN; i++) golden_x[i] = 8'hFF;

    load_all_data();
    compute_golden_model();
    run_and_compare("Test 4 (max positive overflow)");

    // ================================================================
    // Test 5: Input all 0xFF + weight all -128 + large negative bias
    //         Exercises negative accumulator → ReLU clamps to 0
    // ================================================================
    $display("\n============ Test 5: Max negative → ReLU zero ============");
    for (int o = 0; o < TEST_OUT; o++) for (int i = 0; i < TEST_IN; i++) golden_w[o][i] = -8'sd128;
    for (int o = 0; o < TEST_OUT; o++) golden_b[o] = 32'sh8000_0001;  // very negative
    for (int i = 0; i < TEST_IN; i++) golden_x[i] = 8'hFF;

    load_all_data();
    compute_golden_model();
    run_and_compare("Test 5 (max negative, ReLU=0)");

    // ================================================================
    // Test 6: Re-run Test 1 pattern to verify no state contamination
    //         (This was the FPGA_A bug: second inference produced wrong results)
    // ================================================================
    $display("\n============ Test 6: Re-run random (contamination check) ============");
    for (int o = 0; o < TEST_OUT; o++) for (int i = 0; i < TEST_IN; i++) golden_w[o][i] = $random;
    for (int o = 0; o < TEST_OUT; o++) golden_b[o] = $random & 32'h0000FFFF;
    for (int i = 0; i < TEST_IN; i++) golden_x[i] = $urandom_range(0, 255);

    load_all_data();
    compute_golden_model();
    run_and_compare("Test 6 (re-run random, no contamination)");

    // ================================================================
    // Final summary
    // ================================================================
    $display("\n============================================================");
    $display("OVERALL: %0d total errors across all tests", err_cnt);
    if (err_cnt == 0) $display(">>> ALL TESTS PASSED <<<");
    else $display(">>> SOME TESTS FAILED <<<");
    $display("============================================================");

    #100;
    $finish;
  end

  // ==========================================================================
  // Shared tasks for multi-test flow
  // ==========================================================================

  task load_all_data();
    // Load weights — assemble each row (16 bytes) then write whole-word
    for (int ob = 0; ob < TEST_NOB; ob++) begin
      for (int ib = 0; ib < TEST_NIB; ib++) begin
        automatic int tile_addr = ob * TEST_NIB + ib;
        for (int r = 0; r < TILE_ROWS; r++) begin
          automatic logic [TILE_COLS*WEIGHT_W-1:0] row_data = '0;
          for (int c = 0; c < TILE_COLS; c++) begin
            automatic int out_idx = ob * TILE_ROWS + r;
            automatic int in_idx = ib * TILE_COLS + c;
            if (out_idx < TEST_OUT && in_idx < TEST_IN)
              row_data[c*WEIGHT_W+:WEIGHT_W] = golden_w[out_idx][in_idx];
          end
          write_weight_row(tile_addr, r, row_data);
        end
      end
    end
    // Load biases
    for (int o = 0; o < TEST_OUT; o++) begin
      @(posedge clk);
      b_wr_en   <= 1'b1;
      b_wr_addr <= o;
      b_wr_data <= golden_b[o];
      @(posedge clk);
      b_wr_en <= 1'b0;
    end
    // Load inputs — assemble each tile (16 bytes) then write whole-word
    for (int tile = 0; tile < TEST_NIB; tile++) begin
      automatic logic [TILE_COLS*INPUT_W-1:0] tdata = '0;
      for (int c = 0; c < TILE_COLS; c++) begin
        automatic int idx = tile * TILE_COLS + c;
        if (idx < TEST_IN) tdata[c*INPUT_W+:INPUT_W] = golden_x[idx];
      end
      write_input_tile(tile, tdata);
    end
    repeat (5) @(posedge clk);
  endtask

  task run_and_compare(input string test_name);
    int local_err;
    local_err = 0;

    @(posedge clk);
    start <= 1'b1;
    @(posedge clk);
    start <= 1'b0;

    wait (done);
    repeat (3) @(posedge clk);

    for (int o = 0; o < TEST_OUT; o++) begin
      obuf_rd_addr = o;
      repeat (2) @(posedge clk);
      if (obuf_rd_data !== golden_out[o]) begin
        $display("  MISMATCH [%0d]: RTL=%0d Golden=%0d (acc=%0d)", o, obuf_rd_data, golden_out[o],
                 golden_acc[o]);
        local_err++;
      end
    end

    if (local_err == 0) $display("  %s: ALL %0d outputs MATCH — PASS", test_name, TEST_OUT);
    else begin
      $display("  %s: %0d / %0d MISMATCHES — FAIL", test_name, local_err, TEST_OUT);
    end
    err_cnt += local_err;
  endtask

  // ---- Debug monitor: trace every obuf write ----
  always @(posedge clk) begin
    if (obuf_wr_en)
      $display(
          "DBG_WR: obuf[%0d] <= %0d  (bias_val=%0d)", obuf_wr_addr, obuf_wr_data, dut.bias_val_r
      );
  end

  // ---- Print golden accumulator values for failed outputs ----
  task dump_psum;
    $display("DBG: golden_acc (bias+MAC, before ReLU/requant):");
    for (int o = 0; o < TEST_OUT; o++) begin
      if (golden_out[o] === 8'sd0)
        $display("  golden[%2d]: acc=%0d  out=%0d  (zero/neg)", o, golden_acc[o], golden_out[o]);
    end
  endtask

  // Timeout
  initial begin
    #10_000_000;
    $display("ERROR: Timeout! State=%0d", dbg_state);
    $finish;
  end

endmodule
