// ============================================================================
// uart_tx.sv — Simple 8N1 UART transmitter for PicoRV32 debug
// ============================================================================
// Parameters:
//   CLK_FREQ: system clock frequency in Hz (default 60MHz)
//   BAUD:     baud rate (default 115200)
//
// Interface:
//   tx_valid + tx_data: write one byte (handshake: valid & ready)
//   tx_ready:           high when idle, can accept new byte
//   uart_txd:           serial output pin
// ============================================================================

module uart_tx #(
    parameter int CLK_FREQ = 60_000_000,
    parameter int BAUD     = 115200
) (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       tx_valid,
    input  logic [7:0] tx_data,
    output logic       tx_ready,

    output logic       uart_txd
);

  localparam int CLKS_PER_BIT = CLK_FREQ / BAUD;

  typedef enum logic [1:0] {
    S_IDLE,
    S_START,
    S_DATA,
    S_STOP
  } uart_state_t;

  uart_state_t state;
  logic [$clog2(CLKS_PER_BIT)-1:0] clk_cnt;
  logic [2:0] bit_idx;
  logic [7:0] shift_reg;

  assign tx_ready = (state == S_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state     <= S_IDLE;
      uart_txd  <= 1'b1;  // idle high
      clk_cnt   <= '0;
      bit_idx   <= '0;
      shift_reg <= '0;
    end else begin
      case (state)
        S_IDLE: begin
          uart_txd <= 1'b1;
          if (tx_valid) begin
            shift_reg <= tx_data;
            state     <= S_START;
            clk_cnt   <= '0;
          end
        end

        S_START: begin
          uart_txd <= 1'b0;  // start bit
          if (clk_cnt == CLKS_PER_BIT - 1) begin
            clk_cnt <= '0;
            bit_idx <= '0;
            state   <= S_DATA;
          end else begin
            clk_cnt <= clk_cnt + 1;
          end
        end

        S_DATA: begin
          uart_txd <= shift_reg[bit_idx];
          if (clk_cnt == CLKS_PER_BIT - 1) begin
            clk_cnt <= '0;
            if (bit_idx == 3'd7) begin
              state <= S_STOP;
            end else begin
              bit_idx <= bit_idx + 1;
            end
          end else begin
            clk_cnt <= clk_cnt + 1;
          end
        end

        S_STOP: begin
          uart_txd <= 1'b1;  // stop bit
          if (clk_cnt == CLKS_PER_BIT - 1) begin
            state <= S_IDLE;
          end else begin
            clk_cnt <= clk_cnt + 1;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
