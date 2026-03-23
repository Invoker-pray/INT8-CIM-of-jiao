// ============================================================================
// cim_rv32_fpga_top.v — FPGA wrapper for PicoRV32 + CIM SoC on PYNQ-Z2
// ============================================================================
// Pure-PL design (no Zynq PS). Provides:
//   - MMCM: 125MHz board clock → 60MHz system clock
//   - Reset synchronizer from push button (active-high BTN0 → active-low rst_n)
//   - UART TX output on PMOD-A pin
//   - LED indicators
//
// Board: PYNQ-Z2 (xc7z020clg400-1)
//   SYSCLK 125MHz : H16
//   BTN0 (reset)  : D19 (active-high)
//   PMODA[0] UART : Y18
//   LED0           : R14  (CIM done)
//   LED1           : P14  (heartbeat)
// ============================================================================

module cim_rv32_fpga_top (
    input  wire sys_clk_125,   // 125MHz from board oscillator
    input  wire btn_rst,       // BTN0, active-high
    output wire uart_txd,      // PMOD-A pin 0
    output wire led_done,      // LED0: CIM done_irq
    output wire led_heartbeat  // LED1: ~1Hz heartbeat (proof of life)
);

  // ============================================================
  // Clock generation: 125MHz → 60MHz via MMCME2_BASE
  // ============================================================
  // MMCM formula:
  //   VCO = 125 × (MULT / DIV_IN) = 125 × (36/5) = 900 MHz
  //   CLK_OUT0 = VCO / DIV_OUT0 = 900 / 15 = 60 MHz
  // VCO range for xc7z020-1: 600–1200 MHz, so 900 is safe.
  // ============================================================
  wire clk_60m;
  wire mmcm_locked;
  wire mmcm_fb;

  MMCME2_BASE #(
      .CLKIN1_PERIOD   (8.000),   // 125 MHz = 8ns
      .CLKFBOUT_MULT_F (36.0),    // VCO = 125 * 36 / 5 = 900 MHz
      .CLKOUT0_DIVIDE_F(18.0),    // 900 / 18 = 50 MHz
      .DIVCLK_DIVIDE   (5)
  ) u_mmcm (
      .CLKIN1  (sys_clk_125),
      .CLKFBOUT(mmcm_fb),
      .CLKFBIN (mmcm_fb),
      .CLKOUT0 (clk_60m),
      .LOCKED  (mmcm_locked),
      .PWRDWN  (1'b0),
      .RST     (btn_rst)       // active-high reset for MMCM
  );

  // Buffer the output clock
  wire clk;
  BUFG u_bufg (
      .I(clk_60m),
      .O(clk)
  );

  // ============================================================
  // Reset synchronizer
  // ============================================================
  // rst_n = active-low, asserted when button pressed OR MMCM not locked
  reg [3:0] rst_pipe = 4'b0000;
  wire rst_n = rst_pipe[3];

  always @(posedge clk) begin
    if (!mmcm_locked || btn_rst) rst_pipe <= 4'b0000;
    else rst_pipe <= {rst_pipe[2:0], 1'b1};
  end

  // ============================================================
  // SoC core
  // ============================================================
  wire cim_done_irq;

  cim_rv32_top #(
      .CLK_FREQ (60_000_000),
      .BAUD_RATE(115200),
      .FW_HEX   ("firmware.hex")
  ) u_soc (
      .clk         (clk),
      .rst_n       (rst_n),
      .uart_txd    (uart_txd),
      .cim_done_irq(cim_done_irq)
  );

  assign led_done = cim_done_irq;

  // ============================================================
  // Heartbeat: ~1Hz blink (60M / 2^26 ≈ 0.89Hz)
  // ============================================================
  reg [25:0] hb_cnt = 0;
  always @(posedge clk)
    if (!rst_n) hb_cnt <= 0;
    else hb_cnt <= hb_cnt + 1;

  assign led_heartbeat = hb_cnt[25];

endmodule
