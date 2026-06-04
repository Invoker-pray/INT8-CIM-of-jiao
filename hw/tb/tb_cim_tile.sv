`timescale 1ns / 1ps
// ============================================================================
// tb_cim_tile.sv — CIM tile unit test
// ============================================================================
// Verifies the 16x16 MAC tile against a simple software golden model.
// Supports both TILE_MAC_REUSE=0 (full instantiation) and TILE_MAC_REUSE=1
// (time-multiplexed) by cycling through phases.
// ============================================================================

module tb_cim_tile;
  import cim_pkg::*;

  logic [X_EFF_W-1:0]          x_eff  [TILE_COLS];
  logic signed [WEIGHT_W-1:0]  w_tile [TILE_ROWS][TILE_COLS];
  logic [1:0]                  phase_sel;
  logic signed [PSUM_W-1:0]    psum   [TILE_ROWS];
  logic signed [PSUM_W-1:0]    psum_lo[TILE_ROWS];
  logic signed [PSUM_W-1:0]    psum_hi[TILE_ROWS];
  logic signed [PSUM_W-1:0]    psum_q0[TILE_ROWS];
  logic signed [PSUM_W-1:0]    psum_q1[TILE_ROWS];
  logic signed [PSUM_W-1:0]    psum_q2[TILE_ROWS];
  logic signed [PSUM_W-1:0]    psum_q3[TILE_ROWS];

  cim_tile dut (
    .x_eff    (x_eff),
    .w_tile   (w_tile),
    .phase_sel(phase_sel),
    .psum     (psum),
    .psum_lo  (psum_lo),
    .psum_hi  (psum_hi),
    .psum_q0  (psum_q0),
    .psum_q1  (psum_q1),
    .psum_q2  (psum_q2),
    .psum_q3  (psum_q3)
  );

  // Accumulated hardware result across all phases
  logic signed [PSUM_W-1:0] hw_psum [TILE_ROWS];
  logic signed [PSUM_W-1:0] golden  [TILE_ROWS];

  task compute_golden();
    for (int r = 0; r < TILE_ROWS; r++) begin
      golden[r] = 0;
      for (int c = 0; c < TILE_COLS; c++) begin
        // Use 32-bit signed int variables to avoid bit-width truncation
        // (10-bit signed × 8-bit signed → SV self-determined width = 10 bits)
        automatic int x = $signed(x_eff[c]);
        automatic int w = w_tile[r][c];
        golden[r] = golden[r] + x * w;
      end
    end
  endtask

  // Read tile psum: cycle through phases if TILE_MAC_REUSE, accumulate results
  task automatic read_tile_psum();
    for (int r = 0; r < TILE_ROWS; r++) hw_psum[r] = '0;
    if (TILE_MAC_REUSE) begin
      for (int ph = 0; ph < TILE_SPLIT_FACTOR; ph++) begin
        phase_sel = ph[1:0];
        #1;
        for (int r = 0; r < TILE_ROWS; r++)
          hw_psum[r] += psum_q0[r];
      end
    end else begin
      phase_sel = 2'd0;
      #1;
      for (int r = 0; r < TILE_ROWS; r++)
        hw_psum[r] = psum[r];
    end
  endtask

  int err_cnt;
  int test_cnt;

  initial begin
    err_cnt  = 0;
    test_cnt = 0;
    phase_sel = 2'd0;

    $display("============================================");
    $display("TB: cim_tile — 16x16 MAC unit test (TILE_MAC_REUSE=%0d)", TILE_MAC_REUSE);
    $display("============================================");

    // ---- Test 1: all zeros ----
    for (int c = 0; c < TILE_COLS; c++) x_eff[c] = '0;
    for (int r = 0; r < TILE_ROWS; r++)
      for (int c = 0; c < TILE_COLS; c++)
        w_tile[r][c] = '0;

    read_tile_psum();
    compute_golden();
    for (int r = 0; r < TILE_ROWS; r++) begin
      if (hw_psum[r] !== golden[r]) begin
        $display("FAIL zero test row=%0d: got=%0d exp=%0d", r, hw_psum[r], golden[r]);
        err_cnt++;
      end
    end
    test_cnt++;
    $display("Test %0d (all zeros): %s", test_cnt, (err_cnt == 0) ? "PASS" : "FAIL");

    // ---- Test 2: identity-like (x_eff=1, w=1) ----
    for (int c = 0; c < TILE_COLS; c++) x_eff[c] = 9'd1;
    for (int r = 0; r < TILE_ROWS; r++)
      for (int c = 0; c < TILE_COLS; c++)
        w_tile[r][c] = 8'sd1;

    read_tile_psum();
    compute_golden();
    for (int r = 0; r < TILE_ROWS; r++) begin
      if (hw_psum[r] !== golden[r]) begin
        $display("FAIL identity test row=%0d: got=%0d exp=%0d", r, hw_psum[r], golden[r]);
        err_cnt++;
      end
    end
    test_cnt++;
    $display("Test %0d (all ones): %s  hw_psum[0]=%0d (expect %0d)",
             test_cnt, (hw_psum[0] == golden[0]) ? "PASS" : "FAIL", hw_psum[0], TILE_COLS);

    // ---- Test 3: negative weights ----
    for (int c = 0; c < TILE_COLS; c++) x_eff[c] = 9'd255;
    for (int r = 0; r < TILE_ROWS; r++)
      for (int c = 0; c < TILE_COLS; c++)
        w_tile[r][c] = -8'sd1;

    read_tile_psum();
    compute_golden();
    for (int r = 0; r < TILE_ROWS; r++) begin
      if (hw_psum[r] !== golden[r]) begin
        $display("FAIL neg weight test row=%0d: got=%0d exp=%0d", r, hw_psum[r], golden[r]);
        err_cnt++;
      end
    end
    test_cnt++;
    $display("Test %0d (max input * -1 weight): %s  hw_psum[0]=%0d (expect %0d)",
             test_cnt, (hw_psum[0] == golden[0]) ? "PASS" : "FAIL", hw_psum[0], golden[0]);

    // ---- Tests 4-103: random vectors ----
    for (int t = 0; t < 100; t++) begin
      for (int c = 0; c < TILE_COLS; c++)
        x_eff[c] = $urandom_range(0, (1 << X_EFF_W) - 1);
      for (int r = 0; r < TILE_ROWS; r++)
        for (int c = 0; c < TILE_COLS; c++)
          w_tile[r][c] = $random;

      read_tile_psum();
      compute_golden();
      for (int r = 0; r < TILE_ROWS; r++) begin
        if (hw_psum[r] !== golden[r]) begin
          $display("FAIL random test %0d row=%0d: got=%0d exp=%0d", t, r, hw_psum[r], golden[r]);
          err_cnt++;
        end
      end
      test_cnt++;
    end

    $display("============================================");
    $display("Total tests: %0d, Errors: %0d", test_cnt, err_cnt);
    if (err_cnt == 0)
      $display(">>> ALL TESTS PASSED <<<");
    else
      $display(">>> SOME TESTS FAILED <<<");
    $display("============================================");
    $finish;
  end

endmodule
