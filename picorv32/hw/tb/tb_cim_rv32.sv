// ============================================================================
// tb_cim_rv32.sv — Testbench for PicoRV32 + CIM SoC
// ============================================================================
// Captures UART TX output and checks for CORRECT/WRONG in the stream.
// Outputs a machine-parseable "RESULT: PASS/FAIL/WRONG" line for scripting.
//
// Usage:
//   ./simv                    (no VCD)
//   ./simv +VCD               (dump waveform)
//   ./simv +TIMEOUT=100000    (custom timeout in us)
// ============================================================================

`timescale 1ns / 1ps

module tb_cim_rv32;

  // ============================================================
  // Parameters
  // ============================================================
  localparam real CLK_PERIOD = 16.667;  // 60 MHz
  localparam int DEFAULT_TO = 50_000;  // 50ms default timeout
  localparam int BAUD = 115200;
  localparam int CLKS_PER_BIT = 60_000_000 / BAUD;  // 520

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

  // Timeout (configurable via +TIMEOUT=<us>)
  integer timeout_us;
  initial begin
    if (!$value$plusargs("TIMEOUT=%d", timeout_us)) timeout_us = DEFAULT_TO;
    #(timeout_us * 1000);
    $display("");
    $display("ERROR: Timeout after %0d us!", timeout_us);
    $display("RESULT: TIMEOUT");
    $finish;
  end

  // ============================================================
  // DUT
  // ============================================================
  logic uart_txd;
  logic cim_done_irq;

  cim_rv32_top #(
      .CLK_FREQ (60_000_000),
      .BAUD_RATE(BAUD),
      .FW_HEX   ("firmware.hex")
  ) u_dut (
      .clk         (clk),
      .rst_n       (rst_n),
      .uart_txd    (uart_txd),
      .cim_done_irq(cim_done_irq)
  );

  // ============================================================
  // UART RX — behavioral 8N1 receiver
  // ============================================================
  reg     [      7:0] rx_byte;
  reg                 rx_valid;
  integer             rx_bit_idx;

  // Capture buffer (512 chars)
  reg     [8*512-1:0] uart_buf;
  integer             uart_len;

  initial begin
    uart_len = 0;
    uart_buf = '0;
    rx_valid = 0;

    forever begin
      @(negedge uart_txd);  // start bit edge
      #(CLK_PERIOD * CLKS_PER_BIT / 2);  // half-bit to center
      if (uart_txd !== 1'b0) continue;  // false trigger

      rx_byte = 8'h0;
      for (rx_bit_idx = 0; rx_bit_idx < 8; rx_bit_idx++) begin
        #(CLK_PERIOD * CLKS_PER_BIT);
        rx_byte[rx_bit_idx] = uart_txd;
      end
      #(CLK_PERIOD * CLKS_PER_BIT);  // stop bit

      rx_valid = 1;

      // Print character
      if (rx_byte >= 8'h20 && rx_byte <= 8'h7E) $write("%c", rx_byte);
      else if (rx_byte == 8'h0A) $write("\n");
      else
      if (rx_byte == 8'h0D);  // skip CR
      else $write("<%02x>", rx_byte);

      // Buffer
      if (uart_len < 511) begin
        uart_buf[uart_len*8+:8] = rx_byte;
        uart_len = uart_len + 1;
      end

      // Check for "Done" end marker
      if (uart_len >= 4) begin
        if (uart_buf[(uart_len-4)*8 +: 8] == "D" &&
            uart_buf[(uart_len-3)*8 +: 8] == "o" &&
            uart_buf[(uart_len-2)*8 +: 8] == "n" &&
            uart_buf[(uart_len-1)*8 +: 8] == "e") begin
          #(CLK_PERIOD * CLKS_PER_BIT * 20);
          $display("\n");
          check_result();
          $finish;
        end
      end

      rx_valid = 0;
    end
  end

  // ============================================================
  // Result check — scan buffer for CORRECT / WRONG
  // ============================================================
  task check_result;
    integer i;
    reg found_correct, found_wrong;
    found_correct = 0;
    found_wrong   = 0;

    for (i = 0; i < uart_len - 6; i++) begin
      if (uart_buf[(i+0)*8 +: 8] == "C" &&
          uart_buf[(i+1)*8 +: 8] == "O" &&
          uart_buf[(i+2)*8 +: 8] == "R" &&
          uart_buf[(i+3)*8 +: 8] == "R" &&
          uart_buf[(i+4)*8 +: 8] == "E" &&
          uart_buf[(i+5)*8 +: 8] == "C" &&
          uart_buf[(i+6)*8 +: 8] == "T")
        found_correct = 1;

      if (i < uart_len - 4)
        if (uart_buf[(i+0)*8 +: 8] == "W" &&
            uart_buf[(i+1)*8 +: 8] == "R" &&
            uart_buf[(i+2)*8 +: 8] == "O" &&
            uart_buf[(i+3)*8 +: 8] == "N" &&
            uart_buf[(i+4)*8 +: 8] == "G")
          found_wrong = 1;
    end

    if (found_correct) begin
      $display("RESULT: PASS");
    end else if (found_wrong) begin
      $display("RESULT: WRONG");
    end else begin
      $display("RESULT: FAIL");
    end
  endtask

  // ============================================================
  // VCD dump (optional, +VCD)
  // ============================================================
  initial begin
    if ($test$plusargs("VCD")) begin
      $dumpfile("tb_cim_rv32.vcd");
      $dumpvars(0, tb_cim_rv32);
    end
  end

  // ============================================================
  // Progress monitor — every 5ms (less noisy for batch runs)
  // ============================================================
  initial begin
    @(posedge rst_n);
    forever begin
      #(5_000_000);  // 5ms
      $display("[%0t] Running... done_irq=%b", $time, cim_done_irq);
    end
  end

endmodule
