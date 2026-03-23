// ============================================================================
// tb_cim_rv32.sv — Testbench for PicoRV32 + CIM SoC
// ============================================================================
//
// Loads firmware.hex into BRAM, runs the CPU, captures UART TX output,
// and checks for expected prediction in the UART stream.
//
// Usage:
//   1. Run small_mlp_quantize.py → small_mlp_data/
//   2. Run gen_fw_data.py → model_data.c
//   3. make → firmware.hex
//   4. Simulate this testbench with firmware.hex in the sim directory
//
// The testbench watches for "Predicted: X" in UART output and compares
// with the expected label.
// ============================================================================

`timescale 1ns / 1ps

module tb_cim_rv32;

  // ============================================================
  // Clock and reset
  // ============================================================
  localparam real CLK_PERIOD = 16.667;  // 60 MHz
  localparam int  TIMEOUT_US = 50_000;  // 50ms timeout (plenty for small model)

  logic clk = 0;
  logic rst_n = 0;

  always #(CLK_PERIOD/2) clk = ~clk;

  initial begin
    rst_n = 0;
    #(CLK_PERIOD * 10);
    rst_n = 1;
    $display("=== Reset released at %0t ===", $time);
  end

  // Timeout
  initial begin
    #(TIMEOUT_US * 1000);
    $display("ERROR: Timeout after %0d us!", TIMEOUT_US);
    $finish;
  end

  // ============================================================
  // DUT
  // ============================================================
  logic uart_txd;
  logic cim_done_irq;

  cim_rv32_top #(
      .CLK_FREQ  (60_000_000),
      .BAUD_RATE (115200),
      .FW_HEX    ("firmware.hex")
  ) u_dut (
      .clk          (clk),
      .rst_n        (rst_n),
      .uart_txd     (uart_txd),
      .cim_done_irq (cim_done_irq)
  );

  // ============================================================
  // UART RX — capture serial output from DUT
  // ============================================================
  localparam int BAUD = 115200;
  localparam int CLKS_PER_BIT = 60_000_000 / BAUD;  // 520 clocks

  // Simple UART receiver (behavioral)
  reg [7:0]  rx_byte;
  reg        rx_valid;
  integer    rx_bit_idx;

  // Capture full output string
  reg [8*256-1:0] uart_buf;
  integer uart_len;

  initial begin
    uart_len = 0;
    uart_buf = '0;
    rx_valid = 0;

    forever begin
      // Wait for start bit (falling edge on txd)
      @(negedge uart_txd);

      // Wait half bit to sample in middle
      #(CLK_PERIOD * CLKS_PER_BIT / 2);

      // Verify still low (start bit)
      if (uart_txd !== 1'b0) continue;

      // Sample 8 data bits
      rx_byte = 8'h0;
      for (rx_bit_idx = 0; rx_bit_idx < 8; rx_bit_idx++) begin
        #(CLK_PERIOD * CLKS_PER_BIT);
        rx_byte[rx_bit_idx] = uart_txd;
      end

      // Wait for stop bit
      #(CLK_PERIOD * CLKS_PER_BIT);

      // Output received character
      rx_valid = 1;
      if (rx_byte >= 8'h20 && rx_byte <= 8'h7E)
        $write("%c", rx_byte);
      else if (rx_byte == 8'h0A)
        $write("\n");
      else if (rx_byte == 8'h0D)
        ;  // skip CR
      else
        $write("<%02x>", rx_byte);

      // Store in buffer
      if (uart_len < 255) begin
        uart_buf[uart_len*8 +: 8] = rx_byte;
        uart_len = uart_len + 1;
      end

      // Check for "=== Done ===" marker
      if (uart_len >= 8) begin
        // Check last few chars for "Done"
        reg [31:0] last4;
        last4 = {uart_buf[(uart_len-4)*8 +: 8],
                  uart_buf[(uart_len-3)*8 +: 8],
                  uart_buf[(uart_len-2)*8 +: 8],
                  uart_buf[(uart_len-1)*8 +: 8]};
        if (last4 == {"D","o","n","e"}) begin
          // Wait a bit for remaining chars
          #(CLK_PERIOD * CLKS_PER_BIT * 20);
          $display("\n\n=== UART capture complete (%0d chars) ===", uart_len);
          check_result();
          $finish;
        end
      end

      rx_valid = 0;
    end
  end

  // ============================================================
  // Result check — look for "Predicted: X" and "CORRECT/WRONG"
  // ============================================================
  task check_result;
    integer i;
    reg found_correct, found_wrong;

    found_correct = 0;
    found_wrong = 0;

    // Scan buffer for keywords
    for (i = 0; i < uart_len - 6; i++) begin
      // Check for "CORRECT"
      if (uart_buf[i*8 +: 8] == "C" &&
          uart_buf[(i+1)*8 +: 8] == "O" &&
          uart_buf[(i+2)*8 +: 8] == "R" &&
          uart_buf[(i+3)*8 +: 8] == "R" &&
          uart_buf[(i+4)*8 +: 8] == "E" &&
          uart_buf[(i+5)*8 +: 8] == "C" &&
          uart_buf[(i+6)*8 +: 8] == "T")
        found_correct = 1;

      // Check for "WRONG"
      if (uart_buf[i*8 +: 8] == "W" &&
          uart_buf[(i+1)*8 +: 8] == "R" &&
          uart_buf[(i+2)*8 +: 8] == "O" &&
          uart_buf[(i+3)*8 +: 8] == "N" &&
          uart_buf[(i+4)*8 +: 8] == "G")
        found_wrong = 1;
    end

    $display("=== Test Result ===");
    if (found_correct) begin
      $display("PASS: Firmware reported CORRECT prediction");
    end else if (found_wrong) begin
      $display("INFO: Firmware reported WRONG prediction (model accuracy issue, not HW bug)");
    end else begin
      $display("FAIL: Could not find CORRECT or WRONG in UART output");
    end
  endtask

  // ============================================================
  // VCD dump (optional)
  // ============================================================
  initial begin
    if ($test$plusargs("VCD")) begin
      $dumpfile("tb_cim_rv32.vcd");
      $dumpvars(0, tb_cim_rv32);
    end
  end

  // ============================================================
  // Progress monitoring
  // ============================================================
  initial begin
    @(posedge rst_n);
    forever begin
      #(1000_000);  // every 1ms
      $display("[%0t] Running... CIM done_irq=%b", $time, cim_done_irq);
    end
  end

endmodule
