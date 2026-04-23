`timescale 1ns / 1ps
// ============================================================================
// tb_cim_stream_sink.sv — Standalone testbench for cim_axi_stream_sink
// ============================================================================
// 目的 (参见 docs/c3_dma_design.md §7.1):
//   验证 cim_axi_stream_sink 把 32-bit AXIS 流正确路由到
//     - weight_sram (4 beats/row, 16 rows/tile, 多 tile autoincrement)
//     - input_buffer (4 beats/tile, autoincrement)
//     - bias_sram (1 beat/addr, autoincrement)
//   并在 len / tlast 不一致时正确标出 overflow / underflow.
//
// 验证方式:
//   把 sink 的三组写端口接到真 SRAM 模块 (weight_sram / input_buffer / bias_sram),
//   然后通过 SRAM 的读端口 bit-exact 回读内容, 与软件模型比对.
//
// Test cases:
//   1. Weight: 1 tile (64 beats)
//   2. Weight: 2 tiles (128 beats), base_tile = 3
//   3. Input: 1 tile (4 beats)
//   4. Bias: 10 beats 起始 addr=5
//   5. Overflow: cfg_len=8 但第 8 beat tlast=0
//   6. Underflow: cfg_len=8 但第 3 beat tlast=1
//   7. 软件清 status 后可连续发新事务
// ============================================================================

module tb_cim_stream_sink;
  import cim_pkg::*;

  // ==========================================================================
  // Clock / reset
  // ==========================================================================
  logic clk = 0;
  logic rst_n;
  always #5 clk = ~clk;  // 100 MHz TB clock (与功能无关)

  // ==========================================================================
  // DUT connections
  // ==========================================================================
  // AXIS slave (TB drives these as AXIS master)
  logic [31:0] s_axis_tdata;
  logic        s_axis_tvalid;
  logic        s_axis_tready;
  logic        s_axis_tlast;

  // Configuration
  logic [ 1:0] cfg_dest;
  logic [15:0] cfg_len;
  logic        cfg_start;
  logic [15:0] cfg_base_addr;
  logic        status_clear;

  // Status
  logic        cfg_continue;
  logic busy, done, overflow, underflow;

  // Write ports → memories
  logic                                          wsram_wr_en;
  logic [      $clog2(TILE_ROWS)-1:0]            wsram_wr_row;
  logic [  clog2_safe(WSRAM_DEPTH)-1:0]          wsram_wr_tile_idx;
  logic [        TILE_COLS*WEIGHT_W-1:0]         wsram_wr_row_data;

  logic                                               ibuf_wr_en;
  logic [clog2_safe(MAX_IN_DIM/TILE_COLS)-1:0]        ibuf_wr_tile_idx;
  logic [                TILE_COLS*INPUT_W-1:0]       ibuf_wr_tile_data;

  logic                                          bsram_wr_en;
  logic [  clog2_safe(BSRAM_DEPTH)-1:0]          bsram_wr_addr;
  logic [                                31:0]   bsram_wr_data;

  // ==========================================================================
  // DUT
  // ==========================================================================
  cim_axi_stream_sink dut (
      .clk            (clk),
      .rst_n          (rst_n),
      .s_axis_tdata   (s_axis_tdata),
      .s_axis_tvalid  (s_axis_tvalid),
      .s_axis_tready  (s_axis_tready),
      .s_axis_tlast   (s_axis_tlast),
      .cfg_dest       (cfg_dest),
      .cfg_len        (cfg_len),
      .cfg_start      (cfg_start),
      .cfg_base_addr  (cfg_base_addr),
      .cfg_continue   (cfg_continue),
      .status_clear   (status_clear),
      .busy           (busy),
      .done           (done),
      .overflow       (overflow),
      .underflow      (underflow),
      .wsram_wr_en    (wsram_wr_en),
      .wsram_wr_row   (wsram_wr_row),
      .wsram_wr_tile_idx(wsram_wr_tile_idx),
      .wsram_wr_row_data(wsram_wr_row_data),
      .ibuf_wr_en     (ibuf_wr_en),
      .ibuf_wr_tile_idx(ibuf_wr_tile_idx),
      .ibuf_wr_tile_data(ibuf_wr_tile_data),
      .bsram_wr_en    (bsram_wr_en),
      .bsram_wr_addr  (bsram_wr_addr),
      .bsram_wr_data  (bsram_wr_data)
  );

  // ==========================================================================
  // Memories (对比目标)
  // ==========================================================================
  logic [  clog2_safe(WSRAM_DEPTH)-1:0] w_rd_idx;
  logic signed [WEIGHT_W-1:0] w_rd_tile [TILE_ROWS][TILE_COLS];

  weight_sram u_wsram (
      .clk        (clk),
      .wr_en      (wsram_wr_en),
      .wr_row     (wsram_wr_row),
      .wr_tile_idx(wsram_wr_tile_idx),
      .wr_row_data(wsram_wr_row_data),
      .rd_tile_idx(w_rd_idx),
      .rd_tile    (w_rd_tile)
  );

  logic [clog2_safe(MAX_IN_DIM/TILE_COLS)-1:0] i_rd_idx;
  logic signed [31:0] i_zp;
  logic [INPUT_W-1:0] x_tile [TILE_COLS];
  logic [X_EFF_W-1:0] x_eff  [TILE_COLS];

  input_buffer u_ibuf (
      .clk         (clk),
      .wr_en       (ibuf_wr_en),
      .wr_tile_idx (ibuf_wr_tile_idx),
      .wr_tile_data(ibuf_wr_tile_data),
      .rd_tile_idx (i_rd_idx),
      .input_zp    (i_zp),
      .x_tile      (x_tile),
      .x_eff       (x_eff)
  );

  logic [clog2_safe(BSRAM_DEPTH)-1:0] b_rd_addr;
  logic signed [BIAS_W-1:0] b_rd_data;

  bias_sram u_bsram (
      .clk    (clk),
      .wr_en  (bsram_wr_en),
      .wr_addr(bsram_wr_addr),
      .wr_data(bsram_wr_data),
      .rd_addr(b_rd_addr),
      .rd_data(b_rd_data)
  );

  // ==========================================================================
  // Error counter (全局)
  // ==========================================================================
  int err_cnt = 0;
  int test_cnt = 0;

  // ==========================================================================
  // BFM tasks
  // ==========================================================================
  task do_reset();
    rst_n         = 1'b0;
    s_axis_tdata  = '0;
    s_axis_tvalid = 1'b0;
    s_axis_tlast  = 1'b0;
    cfg_dest      = '0;
    cfg_len       = '0;
    cfg_start     = 1'b0;
    cfg_base_addr = '0;
    cfg_continue  = 1'b0;
    status_clear  = 1'b0;
    i_zp          = 32'sd0;  // 零点为 0, x_tile 直接等于 BRAM 存的字节
    w_rd_idx      = '0;
    i_rd_idx      = '0;
    b_rd_addr     = '0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (3) @(posedge clk);
  endtask

  // 下发一次配置, 并保证 sink 在 cfg_start 采样后进入 RECV.
  task cfg_load(input logic [1:0] dest, input logic [15:0] len, input logic [15:0] base,
               input logic cont = 1'b0);
    @(posedge clk);
    cfg_dest      <= dest;
    cfg_len       <= len;
    cfg_base_addr <= base;
    cfg_continue  <= cont;
    cfg_start     <= 1'b1;
    @(posedge clk);
    cfg_start <= 1'b0;
    @(posedge clk);
  endtask

  // 发一拍 AXIS.
  task axis_send(input logic [31:0] data, input logic last);
    s_axis_tdata  <= data;
    s_axis_tvalid <= 1'b1;
    s_axis_tlast  <= last;
    @(posedge clk);
    while (!s_axis_tready) @(posedge clk);
    // 刚才这条边沿上 tvalid & tready 同时为 1 → handshake.
    s_axis_tvalid <= 1'b0;
    s_axis_tlast  <= 1'b0;
  endtask

  task wait_done_or_err(input int timeout_cycles);
    int cnt = 0;
    while (!done && !overflow && !underflow && cnt < timeout_cycles) begin
      @(posedge clk);
      cnt++;
    end
    if (cnt >= timeout_cycles) begin
      $display("TIMEOUT waiting for done / overflow / underflow");
      err_cnt++;
    end
  endtask

  task clear_status();
    @(posedge clk);
    status_clear <= 1'b1;
    @(posedge clk);
    status_clear <= 1'b0;
    @(posedge clk);
  endtask

  // ==========================================================================
  // Reference models (SW golden)
  // ==========================================================================
  // 软件视角: 给出一段 32-bit 字序列, 预测每个 SRAM 位置的内容.
  //
  // Weight: 4 chunks → 1 row, 16 rows → 1 tile. 字序:
  //   words[0..3]   → tile=base,   row=0  (chunk0 在 row[31:0], chunk3 在 row[127:96])
  //   words[4..7]   → tile=base,   row=1
  //   ...
  //   words[60..63] → tile=base,   row=15
  //   words[64..67] → tile=base+1, row=0
  //   ...
  // Input: 同上但仅 1 tile = 4 chunks (因为 ibuf tile width = 128b).
  // Bias: 每 beat 直接成为 bsram[base + i].

  function automatic logic [127:0] ref_row(
      input logic [31:0] words[$],
      input int offset  // 第一个 chunk 在 words 中的下标
  );
    ref_row = {words[offset+3], words[offset+2], words[offset+1], words[offset+0]};
  endfunction

  // ==========================================================================
  // Memory read helpers
  // ==========================================================================
  // weight_sram.rd_tile 有 1 cycle 延迟.
  task read_weight_tile(input int tile_idx);
    @(posedge clk);
    w_rd_idx <= tile_idx[clog2_safe(WSRAM_DEPTH)-1:0];
    @(posedge clk);  // 发地址
    @(posedge clk);  // 拿数据
  endtask

  task read_input_tile(input int tile_idx);
    @(posedge clk);
    i_rd_idx <= tile_idx[clog2_safe(MAX_IN_DIM/TILE_COLS)-1:0];
    @(posedge clk);
    @(posedge clk);
  endtask

  // Returns the byte at (row, col) for current read_weight_tile result.
  function automatic logic [7:0] w_byte(input int row, input int col);
    // rd_tile is signed INT8; bit-pattern is the same as the stored byte.
    w_byte = w_rd_tile[row][col][7:0];
  endfunction

  function automatic logic [7:0] i_byte(input int col);
    i_byte = x_tile[col];
  endfunction

  // ==========================================================================
  // Assertions
  // ==========================================================================
  task check_weight_tile_content(
      input  int tile_idx,
      input  logic [31:0] words[$],
      input  int base_word,
      output int local_err
  );
    logic [127:0] ref_row_val;
    logic [127:0] got_row_val;

    local_err = 0;
    read_weight_tile(tile_idx);

    for (int r = 0; r < TILE_ROWS; r++) begin
      ref_row_val = {words[base_word + r*4 + 3],
                     words[base_word + r*4 + 2],
                     words[base_word + r*4 + 1],
                     words[base_word + r*4 + 0]};
      got_row_val = '0;
      for (int c = 0; c < TILE_COLS; c++) begin
        got_row_val[c*8 +: 8] = w_byte(r, c);
      end
      if (got_row_val !== ref_row_val) begin
        $display("  FAIL weight tile=%0d row=%0d: got=0x%032x exp=0x%032x",
                 tile_idx, r, got_row_val, ref_row_val);
        local_err++;
      end
    end
  endtask

  task check_input_tile_content(
      input  int tile_idx,
      input  logic [31:0] words[$],
      input  int base_word,
      output int local_err
  );
    logic [127:0] ref_val;
    logic [127:0] got_val;

    local_err = 0;
    read_input_tile(tile_idx);

    ref_val = {words[base_word + 3], words[base_word + 2],
               words[base_word + 1], words[base_word + 0]};
    got_val = '0;
    for (int c = 0; c < TILE_COLS; c++) got_val[c*8 +: 8] = i_byte(c);
    if (got_val !== ref_val) begin
      $display("  FAIL input tile=%0d: got=0x%032x exp=0x%032x",
               tile_idx, got_val, ref_val);
      local_err++;
    end
  endtask

  task check_bias_word(input int addr, input logic [31:0] exp, output int local_err);
    @(posedge clk);
    b_rd_addr <= addr[clog2_safe(BSRAM_DEPTH)-1:0];
    @(posedge clk);
    @(posedge clk);
    if (b_rd_data !== $signed(exp)) begin
      $display("  FAIL bias addr=%0d: got=0x%08x exp=0x%08x", addr, b_rd_data, exp);
      local_err = 1;
    end else begin
      local_err = 0;
    end
  endtask

  // ==========================================================================
  // Test sequences
  // ==========================================================================
  task test_weight_single_tile();
    automatic logic [31:0] words[$];
    int err_before;
    int le;

    $display("------------------------------------------------------------");
    $display("TEST %0d: Weight single tile (64 beats, tile=0)", test_cnt+1);
    $display("------------------------------------------------------------");
    err_before = err_cnt;

    for (int i = 0; i < 64; i++) words.push_back(32'hCAFE_0000 | i);

    cfg_load(2'd0, 16'd64, 16'd0);
    for (int i = 0; i < 64; i++) axis_send(words[i], (i == 63));
    wait_done_or_err(200);

    if (!done || overflow || underflow) begin
      $display("  FAIL: status done=%0b overflow=%0b underflow=%0b",
               done, overflow, underflow);
      err_cnt++;
    end
    check_weight_tile_content(0, words, 0, le); err_cnt += le;

    if (err_cnt == err_before) $display("  PASS"); else $display("  FAIL");
    test_cnt++;
    clear_status();
  endtask

  task test_weight_two_tiles();
    automatic logic [31:0] words[$];
    int err_before;
    int base_tile = 3;
    int le;

    $display("------------------------------------------------------------");
    $display("TEST %0d: Weight 2 tiles (128 beats, base_tile=%0d)", test_cnt+1, base_tile);
    $display("------------------------------------------------------------");
    err_before = err_cnt;

    for (int i = 0; i < 128; i++) words.push_back($urandom);

    cfg_load(2'd0, 16'd128, 16'(base_tile));
    for (int i = 0; i < 128; i++) axis_send(words[i], (i == 127));
    wait_done_or_err(400);

    if (!done || overflow || underflow) begin
      $display("  FAIL: status done=%0b overflow=%0b underflow=%0b",
               done, overflow, underflow);
      err_cnt++;
    end
    check_weight_tile_content(base_tile,     words,  0, le); err_cnt += le;
    check_weight_tile_content(base_tile + 1, words, 64, le); err_cnt += le;

    if (err_cnt == err_before) $display("  PASS"); else $display("  FAIL");
    test_cnt++;
    clear_status();
  endtask

  task test_input_single_tile();
    automatic logic [31:0] words[$];
    int err_before;
    int le;

    $display("------------------------------------------------------------");
    $display("TEST %0d: Input single tile (4 beats, tile=0)", test_cnt+1);
    $display("------------------------------------------------------------");
    err_before = err_cnt;

    for (int i = 0; i < 4; i++) words.push_back(32'hDEAD_0000 | (i << 4));

    cfg_load(2'd1, 16'd4, 16'd0);
    for (int i = 0; i < 4; i++) axis_send(words[i], (i == 3));
    wait_done_or_err(50);

    if (!done || overflow || underflow) begin
      $display("  FAIL: status done=%0b overflow=%0b underflow=%0b",
               done, overflow, underflow);
      err_cnt++;
    end
    check_input_tile_content(0, words, 0, le); err_cnt += le;

    if (err_cnt == err_before) $display("  PASS"); else $display("  FAIL");
    test_cnt++;
    clear_status();
  endtask

  task test_bias_range();
    automatic logic [31:0] words[$];
    int err_before;
    int base = 5;
    int n    = 10;
    int le;

    $display("------------------------------------------------------------");
    $display("TEST %0d: Bias %0d beats at base=%0d", test_cnt+1, n, base);
    $display("------------------------------------------------------------");
    err_before = err_cnt;

    for (int i = 0; i < n; i++) words.push_back($urandom);

    cfg_load(2'd2, 16'(n), 16'(base));
    for (int i = 0; i < n; i++) axis_send(words[i], (i == n - 1));
    wait_done_or_err(50);

    if (!done || overflow || underflow) begin
      $display("  FAIL: status done=%0b overflow=%0b underflow=%0b",
               done, overflow, underflow);
      err_cnt++;
    end
    for (int i = 0; i < n; i++) begin
      check_bias_word(base + i, words[i], le);
      err_cnt += le;
    end

    if (err_cnt == err_before) $display("  PASS"); else $display("  FAIL");
    test_cnt++;
    clear_status();
  endtask

  task test_overflow();
    int err_before;

    $display("------------------------------------------------------------");
    $display("TEST %0d: Overflow — cfg_len=8 but tlast=0 on beat 8", test_cnt+1);
    $display("------------------------------------------------------------");
    err_before = err_cnt;

    cfg_load(2'd2, 16'd8, 16'd0);
    // 发 8 个 beat, 但最后一拍 tlast=0 → overflow
    for (int i = 0; i < 8; i++) axis_send(32'hA5A5_A5A5 + i, 1'b0);
    wait_done_or_err(50);

    if (!overflow) begin
      $display("  FAIL: expected overflow=1, got %0b", overflow);
      err_cnt++;
    end
    if (done) begin
      $display("  FAIL: expected done=0 in overflow, got 1");
      err_cnt++;
    end

    if (err_cnt == err_before) $display("  PASS"); else $display("  FAIL");
    test_cnt++;
    clear_status();
  endtask

  task test_underflow();
    int err_before;

    $display("------------------------------------------------------------");
    $display("TEST %0d: Underflow — cfg_len=8 but tlast=1 on beat 3", test_cnt+1);
    $display("------------------------------------------------------------");
    err_before = err_cnt;

    cfg_load(2'd2, 16'd8, 16'd0);
    for (int i = 0; i < 3; i++) axis_send(32'h1234_0000 + i, (i == 2));
    wait_done_or_err(50);

    if (!underflow) begin
      $display("  FAIL: expected underflow=1, got %0b", underflow);
      err_cnt++;
    end

    if (err_cnt == err_before) $display("  PASS"); else $display("  FAIL");
    test_cnt++;
    clear_status();
  endtask

  task test_back_to_back();
    automatic logic [31:0] words[$];
    int err_before;
    int le;

    $display("------------------------------------------------------------");
    $display("TEST %0d: Back-to-back weight after status_clear", test_cnt+1);
    $display("------------------------------------------------------------");
    err_before = err_cnt;

    for (int i = 0; i < 64; i++) words.push_back(32'h5A5A_0000 | i);

    cfg_load(2'd0, 16'd64, 16'd7);
    for (int i = 0; i < 64; i++) axis_send(words[i], (i == 63));
    wait_done_or_err(200);

    if (!done || overflow || underflow) begin
      $display("  FAIL status: done=%0b overflow=%0b underflow=%0b",
               done, overflow, underflow);
      err_cnt++;
    end
    check_weight_tile_content(7, words, 0, le); err_cnt += le;

    if (err_cnt == err_before) $display("  PASS"); else $display("  FAIL");
    test_cnt++;
    clear_status();
  endtask

  // Test chunked transfer: 2 tiles (128 beats) split into two cfg_start transactions
  // with cfg_continue=1 on the second chunk — exercises the staging-preserve path.
  task test_chunked_weight();
    automatic logic [31:0] words[$];
    int err_before;
    int le;
    int CHUNK = 68;  // not aligned to 64 — splits mid-tile to stress staging

    $display("------------------------------------------------------------");
    $display("TEST %0d: Chunked weight (2×cfg_start, cfg_continue=1)", test_cnt+1);
    $display("------------------------------------------------------------");
    err_before = err_cnt;

    for (int i = 0; i < 128; i++) words.push_back(32'hBEEF_0000 | i);

    // First chunk: beats 0..CHUNK-1
    cfg_load(2'd0, 16'(CHUNK), 16'd0, 1'b0);
    for (int i = 0; i < CHUNK; i++) axis_send(words[i], (i == CHUNK-1));
    wait_done_or_err(300);
    if (!done || overflow || underflow) begin
      $display("  FAIL chunk0 status: done=%0b overflow=%0b underflow=%0b",
               done, overflow, underflow);
      err_cnt++;
    end
    clear_status();

    // Second chunk: beats CHUNK..127, continue from current position
    cfg_load(2'd0, 16'(128-CHUNK), 16'd0, 1'b1);
    for (int i = CHUNK; i < 128; i++) axis_send(words[i], (i == 127));
    wait_done_or_err(300);
    if (!done || overflow || underflow) begin
      $display("  FAIL chunk1 status: done=%0b overflow=%0b underflow=%0b",
               done, overflow, underflow);
      err_cnt++;
    end

    check_weight_tile_content(0, words,  0, le); err_cnt += le;
    check_weight_tile_content(1, words, 64, le); err_cnt += le;

    if (err_cnt == err_before) $display("  PASS"); else $display("  FAIL");
    test_cnt++;
    clear_status();
  endtask

  // ==========================================================================
  // Main
  // ==========================================================================
  initial begin
    $display("============================================================");
    $display("TB: cim_axi_stream_sink");
    $display("============================================================");

    do_reset();

    test_weight_single_tile();
    test_weight_two_tiles();
    test_input_single_tile();
    test_bias_range();
    test_overflow();
    test_underflow();
    test_back_to_back();
    test_chunked_weight();

    $display("============================================================");
    $display("Total tests: %0d, Errors: %0d", test_cnt, err_cnt);
    if (err_cnt == 0)
      $display(">>> ALL TESTS PASSED <<<");
    else
      $display(">>> SOME TESTS FAILED <<<");
    $display("============================================================");

    #50;
    $finish;
  end

  // Safety timeout
  initial begin
    #200000;
    $display(">>> SIM TIMEOUT — SOME TESTS FAILED <<<");
    $finish;
  end

endmodule
