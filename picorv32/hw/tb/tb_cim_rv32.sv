// ============================================================================
// tb_cim_rv32.sv — Testbench for PicoRV32 + CIM SoC (Result BRAM check)
// ============================================================================
// Monitors result BRAM port B for the magic word 0xC1AA_0001, then reads
// prediction and logits. Much faster than UART-based checking.
//
// Usage:
//   ./simv                    (default 50ms timeout)
//   ./simv +TIMEOUT=100000    (custom timeout in us)
//   ./simv +VCD               (dump waveform)
// ============================================================================

`timescale 1ns / 1ps

module tb_cim_rv32;

  localparam real CLK_PERIOD = 20.0;  // 50 MHz (matches CLK_FREQ=50_000_000)
  localparam int DEFAULT_TO = 50_000;

  // ============================================================
  // Clock and reset
  // ============================================================
  logic clk = 0;
  logic rst_n = 0;
  always #(CLK_PERIOD / 2) clk = ~clk;

  initial begin
    rst_n = 0;
    #(CLK_PERIOD * 10);
    rst_n = 1;
    $display("=== Reset released at %0t ===", $time);
  end

  integer timeout_us;
  initial begin
    if (!$value$plusargs("TIMEOUT=%d", timeout_us)) timeout_us = DEFAULT_TO;
    #(timeout_us * 1000);
    $display("ERROR: Timeout after %0d us!", timeout_us);
    $display("RESULT: TIMEOUT");
    $finish;
  end

  // ============================================================
  // DUT — result BRAM port B directly accessible
  // ============================================================
  logic uart_txd, cim_done_irq;

  // Port B of result BRAM: we use it to read results
  logic        res_b_en;
  logic [ 3:0] res_b_we;
  logic [ 7:0] res_b_addr;
  logic [31:0] res_b_wdata;
  logic [31:0] res_b_rdata;

  // Port B of FW BRAM: unused in sim (firmware loaded via $readmemh)
  logic        fw_b_en    = 0;
  logic [ 3:0] fw_b_we    = 0;
  logic [14:0] fw_b_addr  = 0;
  logic [31:0] fw_b_wdata = 0;
  logic [31:0] fw_b_rdata;

  cim_rv32_top #(
      .CLK_FREQ (50_000_000),
      .BAUD_RATE(115200),
      .FW_HEX   ("firmware.hex")
  ) u_dut (
      .clk(clk),
      .rst_n(rst_n),
      .cpu_rst_n(rst_n),         // run CPU when global reset deasserts
      .uart_txd(uart_txd),
      .cim_done_irq(cim_done_irq),
      // FW BRAM port B (not used in sim, firmware via $readmemh)
      .fw_b_en(fw_b_en),
      .fw_b_we(fw_b_we),
      .fw_b_addr(fw_b_addr),
      .fw_b_wdata(fw_b_wdata),
      .fw_b_rdata(fw_b_rdata),
      // Result BRAM port B
      .res_b_en(res_b_en),
      .res_b_we(res_b_we),
      .res_b_addr(res_b_addr),
      .res_b_wdata(res_b_wdata),
      .res_b_rdata(res_b_rdata)
  );

  // ============================================================
  // Result BRAM polling — read word[0] until magic appears
  // ============================================================
  logic [31:0] read_word;

  task automatic res_read(input int word_idx, output logic [31:0] data);
    @(posedge clk);
    res_b_en <= 1;
    res_b_we <= 4'b0;
    res_b_addr <= word_idx * 4;  // byte address
    res_b_wdata <= 0;
    @(posedge clk);  // BRAM registered output
    res_b_en <= 0;
    @(posedge clk);  // data valid now
    data = res_b_rdata;
  endtask

  initial begin
    res_b_en    = 0;
    res_b_we    = 0;
    res_b_addr  = 0;
    res_b_wdata = 0;

    @(posedge rst_n);
    $display("Waiting for PicoRV32 to complete inference...");

    // Poll magic word every 1000 cycles
    forever begin
      #(CLK_PERIOD * 1000);
      res_read(0, read_word);
      if (read_word == 32'hC1AA_0001) begin
        $display("=== Magic word detected! Inference complete. ===");
        check_results();
        $finish;
      end
    end
  end

  // ============================================================
  // Read and verify results
  // ============================================================
  task automatic check_results;
    logic [31:0] pred, expected, match_flag;
    logic [31:0] logits[0:9];

    res_read(1, pred);
    res_read(2, expected);
    res_read(3, match_flag);

    $display("  Predicted: %0d", pred);
    $display("  Expected:  %0d", expected);
    $display("  Match:     %s", match_flag ? "YES" : "NO");

    $write("  Logits:   ");
    for (int i = 0; i < 10; i++) begin
      res_read(4 + i, logits[i]);
      // Sign-extend for display
      if (logits[i][31]) $write(" %0d", $signed(logits[i]));
      else $write(" %0d", logits[i]);
    end
    $display("");

    if (match_flag) $display("RESULT: PASS");
    else $display("RESULT: WRONG");
  endtask

  // ============================================================
  // Optional UART monitor (for debug, prints chars as they come)
  // ============================================================
  localparam int BAUD = 115200;
  localparam int CLKS_PER_BIT = 50_000_000 / BAUD;

  initial begin
    forever begin : uart_rx_loop
      reg [7:0] rx_byte;
      @(negedge uart_txd);
      #(CLK_PERIOD * CLKS_PER_BIT / 2);
      if (uart_txd !== 1'b0) continue;

      rx_byte = 0;
      for (int b = 0; b < 8; b++) begin
        #(CLK_PERIOD * CLKS_PER_BIT);
        rx_byte[b] = uart_txd;
      end
      #(CLK_PERIOD * CLKS_PER_BIT);

      if (rx_byte >= 8'h20 && rx_byte <= 8'h7E) $write("%c", rx_byte);
      else if (rx_byte == 8'h0A) $write("\n");
      else if (rx_byte != 8'h0D) $write("<%02x>", rx_byte);
    end
  end

  // VCD
  initial begin
    if ($test$plusargs("VCD")) begin
      $dumpfile("tb_cim_rv32.vcd");
      $dumpvars(0, tb_cim_rv32);
    end
  end

  // Progress
  initial begin
    @(posedge rst_n);
    forever begin
      #(5_000_000);
      $display("[%0t] Running...", $time);
    end
  end

endmodule
