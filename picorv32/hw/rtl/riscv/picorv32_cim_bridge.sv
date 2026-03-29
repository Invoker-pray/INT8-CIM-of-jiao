// ============================================================================
// picorv32_cim_bridge.sv — Bridge PicoRV32 native bus → CIM + BRAM + UART + Result
// ============================================================================
//
// Address map (32-bit byte-addressed):
//   0x0000_0000 - 0x0000_7FFF : Firmware BRAM (32KB, RW)
//   0x4000_0000 - 0x4000_3FFF : CIM CSR / memory windows (16KB)
//   0x8000_0000               : UART TX data register (write-only)
//   0x8000_0004               : UART TX status (read-only, bit[0]=ready)
//   0xC000_0000 - 0xC000_00FF : Result BRAM (256 bytes, RW)
//                                PS reads this via AXI to verify results
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
    output logic        cim_start_wr,
    output logic        cim_start_rd,
    output logic [13:0] cim_addr,
    output logic [31:0] cim_wdata,
    input  logic [31:0] cim_rdata,
    input  logic        cim_wr_done,
    input  logic        cim_rd_done,

    // ---- UART TX ----
    output logic        uart_tx_valid,
    output logic [ 7:0] uart_tx_data,
    input  logic        uart_tx_ready,

    // ---- Result BRAM (port A = PicoRV32 side) ----
    output logic        res_bram_en,
    output logic [ 3:0] res_bram_we,
    output logic [ 7:0] res_bram_addr,   // 256 bytes = 64 words, 8-bit byte addr
    output logic [31:0] res_bram_wdata,
    input  logic [31:0] res_bram_rdata
);

  // Address decode
  wire sel_bram = (mem_addr[31:16] == 16'h0000);
  wire sel_cim  = (mem_addr[31:16] == 16'h4000);
  wire sel_uart = (mem_addr[31:4]  == 28'h8000_000);
  wire sel_res  = (mem_addr[31:8]  == 24'hC000_00);
  wire is_write = (mem_wstrb != 4'b0000);

  // FSM
  typedef enum logic [2:0] {
    S_IDLE,
    S_BRAM_RD,
    S_CIM_WR_WAIT,
    S_CIM_RD_WAIT,
    S_RES_RD,
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
              state <= is_write ? S_DONE : S_BRAM_RD;
            end else if (sel_cim) begin
              state <= is_write ? S_CIM_WR_WAIT : S_CIM_RD_WAIT;
            end else if (sel_uart) begin
              if (is_write) begin
                if (uart_tx_ready) state <= S_DONE;
              end else begin
                rdata_r <= {31'b0, uart_tx_ready};
                state   <= S_DONE;
              end
            end else if (sel_res) begin
              state <= is_write ? S_DONE : S_RES_RD;
            end else begin
              rdata_r <= 32'hDEAD_BEEF;
              state   <= S_DONE;
            end
          end
        end

        S_BRAM_RD: begin
          rdata_r <= fw_bram_rdata;
          state   <= S_DONE;
        end

        S_CIM_WR_WAIT: begin
          if (cim_wr_done) state <= S_DONE;
        end

        S_CIM_RD_WAIT: begin
          if (cim_rd_done) begin
            rdata_r <= cim_rdata;
            state   <= S_DONE;
          end
        end

        S_RES_RD: begin
          rdata_r <= res_bram_rdata;
          state   <= S_DONE;
        end

        S_DONE: begin
          state <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

  // Outputs
  assign mem_ready = (state == S_DONE);
  assign mem_rdata = rdata_r;

  // Firmware BRAM
  assign fw_bram_en    = mem_valid && sel_bram && (state == S_IDLE);
  assign fw_bram_we    = (mem_valid && sel_bram && is_write && state == S_IDLE) ? mem_wstrb : 4'b0;
  assign fw_bram_addr  = mem_addr[14:0];
  assign fw_bram_wdata = mem_wdata;

  // CIM
  assign cim_start_wr = mem_valid && sel_cim && is_write  && (state == S_IDLE);
  assign cim_start_rd = mem_valid && sel_cim && !is_write && (state == S_IDLE);
  assign cim_addr     = mem_addr[13:0];
  assign cim_wdata    = mem_wdata;

  // UART
  assign uart_tx_valid = mem_valid && sel_uart && is_write && uart_tx_ready && (state == S_IDLE);
  assign uart_tx_data  = mem_wdata[7:0];

  // Result BRAM (port A)
  assign res_bram_en    = mem_valid && sel_res && (state == S_IDLE);
  assign res_bram_we    = (mem_valid && sel_res && is_write && state == S_IDLE) ? mem_wstrb : 4'b0;
  assign res_bram_addr  = mem_addr[7:0];
  assign res_bram_wdata = mem_wdata;

endmodule
