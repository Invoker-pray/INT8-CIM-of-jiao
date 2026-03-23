// ============================================================================
// picorv32_cim_bridge.sv — Bridge PicoRV32 native bus → CIM + BRAM + UART
// ============================================================================
//
// Address map (32-bit byte-addressed):
//   0x0000_0000 - 0x0000_7FFF : Firmware BRAM (32KB, RW)
//   0x4000_0000 - 0x4000_3FFF : CIM CSR / memory windows (16KB, same as AXI)
//   0x8000_0000               : UART TX data register (write-only)
//   0x8000_0004               : UART TX status (read-only, bit[0]=ready)
//
// Wait cycles:
//   BRAM write:  1 cycle (immediate, goes to S_DONE same cycle)
//   BRAM read:   2 cycles (S_BRAM_RD waits for sync BRAM output)
//   CIM write:   ~4-5 cycles (waits for AXI master cim_wr_done)
//   CIM read:    ~5-6 cycles (waits for AXI master cim_rd_done)
//   UART write:  1 cycle if ready, stalls if busy
// ============================================================================

module picorv32_cim_bridge (
    input  logic        clk,
    input  logic        rst_n,

    // ---- PicoRV32 native memory interface ----
    input  logic        mem_valid,
    output logic        mem_ready,
    input  logic [31:0] mem_addr,
    input  logic [31:0] mem_wdata,
    input  logic [ 3:0] mem_wstrb,
    output logic [31:0] mem_rdata,

    // ---- Firmware BRAM ----
    output logic        fw_bram_en,
    output logic [ 3:0] fw_bram_we,
    output logic [14:0] fw_bram_addr,
    output logic [31:0] fw_bram_wdata,
    input  logic [31:0] fw_bram_rdata,

    // ---- CIM AXI master control ----
    output logic        cim_start_wr,   // pulse: start AXI write
    output logic        cim_start_rd,   // pulse: start AXI read
    output logic [13:0] cim_addr,
    output logic [31:0] cim_wdata,
    input  logic [31:0] cim_rdata,
    input  logic        cim_wr_done,    // pulse: AXI write complete
    input  logic        cim_rd_done,    // pulse: AXI read complete, rdata valid

    // ---- UART TX ----
    output logic        uart_tx_valid,
    output logic [ 7:0] uart_tx_data,
    input  logic        uart_tx_ready
);

  // Address decode
  wire sel_bram = (mem_addr[31:16] == 16'h0000);
  wire sel_cim  = (mem_addr[31:16] == 16'h4000);
  wire sel_uart = (mem_addr[31:4]  == 28'h8000_000);
  wire is_write = (mem_wstrb != 4'b0000);

  // FSM
  typedef enum logic [2:0] {
    S_IDLE,
    S_BRAM_RD,
    S_CIM_WR_WAIT,
    S_CIM_RD_WAIT,
    S_DONE
  } state_t;

  state_t state;
  logic [31:0] rdata_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state   <= S_IDLE;
      rdata_r <= 32'h0;
    end else begin
      case (state)
        S_IDLE: begin
          if (mem_valid) begin
            if (sel_bram) begin
              if (is_write)
                state <= S_DONE;        // write immediate
              else
                state <= S_BRAM_RD;     // wait 1 cycle for read data
            end else if (sel_cim) begin
              if (is_write)
                state <= S_CIM_WR_WAIT;
              else
                state <= S_CIM_RD_WAIT;
            end else if (sel_uart) begin
              if (is_write) begin
                if (uart_tx_ready)
                  state <= S_DONE;
                // else stall: stay IDLE, mem_ready=0
              end else begin
                rdata_r <= {31'b0, uart_tx_ready};
                state   <= S_DONE;
              end
            end else begin
              rdata_r <= 32'hDEAD_BEEF;
              state   <= S_DONE;
            end
          end
        end

        S_BRAM_RD: begin
          rdata_r <= fw_bram_rdata;     // sync BRAM data now valid
          state   <= S_DONE;
        end

        S_CIM_WR_WAIT: begin
          if (cim_wr_done)
            state <= S_DONE;
        end

        S_CIM_RD_WAIT: begin
          if (cim_rd_done) begin
            rdata_r <= cim_rdata;
            state   <= S_DONE;
          end
        end

        S_DONE: begin
          state <= S_IDLE;              // mem_ready=1 for exactly this cycle
        end

        default: state <= S_IDLE;
      endcase
    end
  end

  // Outputs
  assign mem_ready = (state == S_DONE);
  assign mem_rdata = rdata_r;

  // BRAM
  assign fw_bram_en    = mem_valid && sel_bram && (state == S_IDLE);
  assign fw_bram_we    = (mem_valid && sel_bram && is_write && state == S_IDLE) ? mem_wstrb : 4'b0;
  assign fw_bram_addr  = mem_addr[14:0];
  assign fw_bram_wdata = mem_wdata;

  // CIM: one-cycle start pulses
  assign cim_start_wr = mem_valid && sel_cim && is_write  && (state == S_IDLE);
  assign cim_start_rd = mem_valid && sel_cim && !is_write && (state == S_IDLE);
  assign cim_addr     = mem_addr[13:0];
  assign cim_wdata    = mem_wdata;

  // UART
  assign uart_tx_valid = mem_valid && sel_uart && is_write && uart_tx_ready && (state == S_IDLE);
  assign uart_tx_data  = mem_wdata[7:0];

endmodule
