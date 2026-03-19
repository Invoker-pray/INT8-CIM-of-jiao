`timescale 1ns / 1ps
// ============================================================================
// tb_cim_tile.sv — CIM tile unit test
// ============================================================================
// Verifies the 16x16 MAC tile against a simple software golden model.
// Test vectors: random signed weights, random unsigned effective inputs.
// ============================================================================

module tb_cim_tile;
  import cim_pkg::*;

  logic [X_EFF_W-1:0]          x_eff  [TILE_COLS];
  logic signed [WEIGHT_W-1:0]  w_tile [TILE_ROWS][TILE_COLS];
  logic signed [PSUM_W-1:0]    psum   [TILE_ROWS];

  cim_tile dut (
    .x_eff  (x_eff),
    .w_tile (w_tile),
    .psum   (psum)
  );

  // Golden model computation
  logic signed [PSUM_W-1:0] golden [TILE_ROWS];

  task compute_golden();
    for (int r = 0; r < TILE_ROWS; r++) begin
      golden[r] = 0;
      for (int c = 0; c < TILE_COLS; c++) begin
        golden[r] = golden[r] + $signed({1'b0, x_eff[c]}) * w_tile[r][c];
      end
    end
  endtask

  int err_cnt;
  int test_cnt;

  initial begin
    err_cnt  = 0;
    test_cnt = 0;

    $display("============================================");
    $display("TB: cim_tile — 16x16 MAC unit test");
    $display("============================================");

    // ---- Test 1: all zeros ----
    for (int c = 0; c < TILE_COLS; c++) x_eff[c] = '0;
    for (int r = 0; r < TILE_ROWS; r++)
      for (int c = 0; c < TILE_COLS; c++)
        w_tile[r][c] = '0;

    #10;
    compute_golden();
    for (int r = 0; r < TILE_ROWS; r++) begin
      if (psum[r] !== golden[r]) begin
        $display("FAIL zero test row=%0d: got=%0d exp=%0d", r, psum[r], golden[r]);
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

    #10;
    compute_golden();
    for (int r = 0; r < TILE_ROWS; r++) begin
      if (psum[r] !== golden[r]) begin
        $display("FAIL identity test row=%0d: got=%0d exp=%0d", r, psum[r], golden[r]);
        err_cnt++;
      end
    end
    test_cnt++;
    $display("Test %0d (all ones): %s  psum[0]=%0d (expect %0d)",
             test_cnt, (psum[0] == golden[0]) ? "PASS" : "FAIL", psum[0], TILE_COLS);

    // ---- Test 3: negative weights ----
    for (int c = 0; c < TILE_COLS; c++) x_eff[c] = 9'd255;  // max unsigned
    for (int r = 0; r < TILE_ROWS; r++)
      for (int c = 0; c < TILE_COLS; c++)
        w_tile[r][c] = -8'sd1;  // -1

    #10;
    compute_golden();
    for (int r = 0; r < TILE_ROWS; r++) begin
      if (psum[r] !== golden[r]) begin
        $display("FAIL neg weight test row=%0d: got=%0d exp=%0d", r, psum[r], golden[r]);
        err_cnt++;
      end
    end
    test_cnt++;
    $display("Test %0d (max input * -1 weight): %s  psum[0]=%0d (expect %0d)",
             test_cnt, (psum[0] == golden[0]) ? "PASS" : "FAIL", psum[0], golden[0]);

    // ---- Tests 4-103: random vectors ----
    for (int t = 0; t < 100; t++) begin
      for (int c = 0; c < TILE_COLS; c++)
        x_eff[c] = $urandom_range(0, (1 << X_EFF_W) - 1);
      for (int r = 0; r < TILE_ROWS; r++)
        for (int c = 0; c < TILE_COLS; c++)
          w_tile[r][c] = $random;

      #10;
      compute_golden();
      for (int r = 0; r < TILE_ROWS; r++) begin
        if (psum[r] !== golden[r]) begin
          $display("FAIL random test %0d row=%0d: got=%0d exp=%0d", t, r, psum[r], golden[r]);
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
