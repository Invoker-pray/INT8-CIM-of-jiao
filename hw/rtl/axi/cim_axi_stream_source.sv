// ============================================================================
// cim_axi_stream_source.sv — AXI4-Stream master for result read-back (P0: S2MM)
// ============================================================================
// 设计参考: README.md Step 8 P0 — DMA S2MM 替代 read_output 串行 MMIO
//
// 功能:
//   - 从 output_buffer 读取 INT8 结果，打包为 32-bit beats
//   - 通过 AXI4-Stream master 送往 axi_dma S2MM 通道
//   - 每 4 个 INT8 值打包为一个 32-bit beat (小端序: byte0 在 [7:0])
//   - 末拍 tlast=1，DMA 自动结束接收
//
// 时序 (BRAM read 有 2-cycle 延迟):
//   1 cycle: obuf_rd_addr 经过 slave 中 always_comb MUX 传播到 output_buffer
//   1 cycle: output_buffer 寄存器读 (rd_data <= buf_mem[rd_addr])
//   总计:   set rd_addr=N at cycle T → rd_data valid at cycle T+2
// Pipeline: obuf_rd_addr 始终比当前抓取的 byte 领先 2 个地址
//
// Fixes v2:
//   - 修正 BRAM 2-cycle 延迟 (增加 S_WAIT 状态)
//   - 修正 tlast 判定: byte_cnt == n_bytes_r-1 时置位 (原 remaining==0 有 off-by-one)
//   - 支持非 4 对齐的末字 (partial last word)
// ============================================================================

`timescale 1ns / 1ps

module cim_axi_stream_source
  import cim_pkg::*;
#(
    parameter int DATA_W = 32,
    parameter int OBUF_ADDR_W = clog2_safe(MAX_OUT_DIM)
) (
    input logic clk,
    input logic rst_n,

    // ------------------------------------------------------------------
    // AXI4-Stream master (→ axi_dma S_AXIS_S2MM)
    // ------------------------------------------------------------------
    output logic [DATA_W-1:0] m_axis_tdata,
    output logic              m_axis_tvalid,
    input  logic              m_axis_tready,
    output logic              m_axis_tlast,

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------
    input  logic [15:0] cfg_len,
    input  logic        cfg_start,

    // ------------------------------------------------------------------
    // Status
    // ------------------------------------------------------------------
    output logic busy,
    output logic done,

    // ------------------------------------------------------------------
    // Output buffer read port
    // ------------------------------------------------------------------
    output logic [OBUF_ADDR_W-1:0]     obuf_rd_addr,
    input  logic signed [OUTPUT_W-1:0] obuf_rd_data
);

  // ==========================================================================
  // FSM — 5 states
  // ==========================================================================
  typedef enum logic [2:0] {
    S_IDLE,
    S_WAIT,        // MUX propagation cycle
    S_WARMUP,      // BRAM read cycle, then capture first byte
    S_READ,        // pipeline: capture byte[byte_cnt], issue rd_addr=byte_cnt+2
    S_SEND         // word presented on AXIS, waiting for tready
  } src_state_t;

  src_state_t state;

  // ==========================================================================
  // Counters
  // ==========================================================================
  logic [15:0] n_bytes_r;      // latched cfg_len (total bytes to send)
  logic [15:0] byte_cnt;       // index of byte being captured THIS cycle
  logic [ 1:0] sub_idx;        // byte position within current word (0..3)
  logic [31:0] word_buf;       // accumulating word
  logic        is_last_word;

  assign busy = (state != S_IDLE);

  // ==========================================================================
  // Main FSM + datapath
  // ==========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state         <= S_IDLE;
      n_bytes_r     <= '0;
      byte_cnt      <= '0;
      sub_idx       <= '0;
      word_buf      <= '0;
      is_last_word  <= 1'b0;
      m_axis_tvalid <= 1'b0;
      m_axis_tlast  <= 1'b0;
      m_axis_tdata  <= '0;
      obuf_rd_addr  <= '0;
      done          <= 1'b0;
    end else begin
      done <= 1'b0;

      // deassert tvalid/tlast after accepted beat
      if (m_axis_tvalid && m_axis_tready) begin
        m_axis_tvalid <= 1'b0;
        m_axis_tlast  <= 1'b0;
      end

      case (state)
        // --------------------------------------------------------------
        S_IDLE: begin
          if (cfg_start) begin
            n_bytes_r    <= cfg_len;
            byte_cnt     <= '0;
            sub_idx      <= '0;
            word_buf     <= '0;
            obuf_rd_addr <= '0;     // issue rd_addr=0
            state        <= S_WAIT;
          end
        end

        // --------------------------------------------------------------
        S_WAIT: begin
          // rd_addr=0 propagates through MUX → output_buffer this cycle.
          // Keep pipeline ahead: issue rd_addr=1.
          obuf_rd_addr <= 'd1;
          state        <= S_WARMUP;
        end

        // --------------------------------------------------------------
        S_WARMUP: begin
          // BRAM returned buf_mem[0] — valid this cycle.
          word_buf[7:0] <= obuf_rd_data;   // byte 0

          if (n_bytes_r == 16'd1) begin
            // Single-byte transfer
            m_axis_tdata  <= {24'd0, obuf_rd_data};
            m_axis_tvalid <= 1'b1;
            m_axis_tlast  <= 1'b1;
            is_last_word  <= 1'b1;
            state         <= S_SEND;
          end else begin
            byte_cnt     <= 16'd1;          // next byte to capture = 1
            obuf_rd_addr <= 'd2;            // rd_addr = byte_cnt+1
            sub_idx      <= 2'd1;
            state        <= S_READ;
          end
        end

        // --------------------------------------------------------------
        S_READ: begin
          // Capture byte[byte_cnt] from obuf_rd_data (valid now)
          case (sub_idx)
            2'd0: word_buf[7:0]   <= obuf_rd_data;
            2'd1: word_buf[15:8]  <= obuf_rd_data;
            2'd2: word_buf[23:16] <= obuf_rd_data;
            2'd3: word_buf[31:24] <= obuf_rd_data;
          endcase

          // Check if this is the last byte
          if (byte_cnt == n_bytes_r - 16'd1) begin
            // Last byte — present (possibly partial) word immediately
            case (sub_idx)
              2'd0: m_axis_tdata <= {24'd0, obuf_rd_data};
              2'd1: m_axis_tdata <= {16'd0, obuf_rd_data, word_buf[7:0]};
              2'd2: m_axis_tdata <= {8'd0, obuf_rd_data, word_buf[15:0]};
              2'd3: m_axis_tdata <= {obuf_rd_data, word_buf[23:0]};
            endcase
            m_axis_tvalid <= 1'b1;
            m_axis_tlast  <= 1'b1;
            is_last_word  <= 1'b1;
            state         <= S_SEND;
          end else if (sub_idx == 2'd3) begin
            // Full word, not last
            m_axis_tdata  <= {obuf_rd_data, word_buf[23:0]};
            m_axis_tvalid <= 1'b1;
            m_axis_tlast  <= 1'b0;
            state         <= S_SEND;
          end else begin
            // Continue accumulating bytes
            byte_cnt     <= byte_cnt + 16'd1;
            obuf_rd_addr <= byte_cnt + 16'd2;   // two ahead
            sub_idx      <= sub_idx + 2'd1;
          end
        end

        // --------------------------------------------------------------
        S_SEND: begin
          if (m_axis_tready) begin
            if (is_last_word) begin
              done  <= 1'b1;
              state <= S_IDLE;
            end else begin
              sub_idx      <= '0;
              word_buf     <= '0;
              byte_cnt     <= byte_cnt + 16'd1;
              obuf_rd_addr <= byte_cnt + 16'd2;
              state        <= S_READ;
            end
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
