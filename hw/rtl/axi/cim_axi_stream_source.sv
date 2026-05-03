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
// 时序:
//   output_buffer rd_data 有 1-cycle 延迟 → 用一个 pipeline stage
//   Cycle N:   设置 rd_addr, 捕获 rd_data (对应 rd_addr-1)
//   Cycle N+1: rd_data 有效 (对应 rd_addr), 移入 word_buf
//
// tvalid 只在 4-byte word 完成时有效。tready 阻塞管道推进。
// ============================================================================

`timescale 1ns / 1ps

module cim_axi_stream_source
  import cim_pkg::*;
#(
    parameter int DATA_W = 32,
    // OBUF_ADDR_W matches output_buffer's address width
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
    input  logic [15:0] cfg_len,       // number of INT8 elements to stream
    input  logic        cfg_start,     // 1-cycle pulse: latch cfg_len, start

    // ------------------------------------------------------------------
    // Status
    // ------------------------------------------------------------------
    output logic busy,
    output logic done,

    // ------------------------------------------------------------------
    // Output buffer read port (shared with legacy MMIO path)
    // ------------------------------------------------------------------
    output logic [OBUF_ADDR_W-1:0]    obuf_rd_addr,
    input  logic signed [OUTPUT_W-1:0] obuf_rd_data
);

  // ==========================================================================
  // FSM
  // ==========================================================================
  typedef enum logic [1:0] {
    S_IDLE,
    S_WARMUP,      // first read issued, waiting for rd_data
    S_READ,        // pipeline running: issue next addr + capture prev data
    S_SEND         // word complete, waiting for tready
  } src_state_t;

  src_state_t state;

  // ==========================================================================
  // Counters
  // ==========================================================================
  logic [15:0] n_bytes_r;      // latched cfg_len
  logic [15:0] byte_cnt;       // next byte index to read (rd_addr)
  logic [ 1:0] sub_idx;        // 0..3 within current 4-byte word
  logic [31:0] word_buf;       // accumulating 4 bytes into 32-bit word
  logic        is_last_word;   // this word contains the final byte

  assign busy = (state != S_IDLE);

  // ==========================================================================
  // Main FSM + datapath
  // ==========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state        <= S_IDLE;
      n_bytes_r    <= '0;
      byte_cnt     <= '0;
      sub_idx      <= '0;
      word_buf     <= '0;
      is_last_word <= 1'b0;
      m_axis_tvalid <= 1'b0;
      m_axis_tlast  <= 1'b0;
      m_axis_tdata  <= '0;
      obuf_rd_addr  <= '0;
      done          <= 1'b0;
    end else begin
      // One-cycle pulse for done
      done <= 1'b0;

      // m_axis_tvalid deasserts after accepted beat (unless reasserted this cycle)
      if (m_axis_tvalid && m_axis_tready) begin
        m_axis_tvalid <= 1'b0;
        m_axis_tlast  <= 1'b0;
      end

      case (state)
        // --------------------------------------------------------------
        S_IDLE: begin
          if (cfg_start) begin
            n_bytes_r <= cfg_len;
            byte_cnt  <= '0;
            sub_idx   <= '0;
            word_buf  <= '0;
            obuf_rd_addr <= '0;  // issue first read (addr=0)
            state     <= S_WARMUP;
          end
        end

        // --------------------------------------------------------------
        // First read was issued on IDLE→WARMUP transition; rd_data
        // available this cycle.
        S_WARMUP: begin
          // Capture rd_data (from addr=0), issue next read
          word_buf[7:0] <= obuf_rd_data;

          if (n_bytes_r == 16'd1) begin
            // Single-byte transfer: present immediately
            m_axis_tdata  <= {24'd0, obuf_rd_data};
            m_axis_tvalid <= 1'b1;
            m_axis_tlast  <= 1'b1;
            is_last_word  <= 1'b1;
            state         <= S_SEND;
          end else begin
            // Issue next read
            byte_cnt    <= 16'd1;
            obuf_rd_addr <= 'd1;
            sub_idx     <= 2'd1;
            state       <= S_READ;
          end
        end

        // --------------------------------------------------------------
        // Pipeline running: rd_data (from byte_cnt-1) valid, issue next
        S_READ: begin
          // Capture rd_data (from previous rd_addr = byte_cnt-1)
          case (sub_idx)
            2'd0: word_buf[7:0]   <= obuf_rd_data;
            2'd1: word_buf[15:8]  <= obuf_rd_data;
            2'd2: word_buf[23:16] <= obuf_rd_data;
            2'd3: word_buf[31:24] <= obuf_rd_data;
          endcase

          if (sub_idx == 2'd3) begin
            // Word complete
            logic [15:0] remaining;
            remaining = n_bytes_r - byte_cnt;

            // Build tdata: top byte = rd_data (just captured), rest from word_buf
            m_axis_tdata <= {obuf_rd_data, word_buf[23:0]};

            if (remaining == 16'd0) begin
              // No more bytes — this is the last word
              m_axis_tvalid <= 1'b1;
              m_axis_tlast  <= 1'b1;
              is_last_word  <= 1'b1;
              state <= S_SEND;
            end else begin
              m_axis_tvalid <= 1'b1;
              m_axis_tlast  <= 1'b0;
              state <= S_SEND;
            end
          end else begin
            // Continue collecting bytes
            byte_cnt    <= byte_cnt + 16'd1;
            obuf_rd_addr <= byte_cnt + 16'd1;  // next read = (byte_cnt+1), since byte_cnt was just incremented
            sub_idx     <= sub_idx + 2'd1;
          end
        end

        // --------------------------------------------------------------
        // Word presented on AXIS; wait for tready
        S_SEND: begin
          if (m_axis_tready) begin
            // tvalid/tlast deasserted by common block above
            if (is_last_word) begin
              done  <= 1'b1;
              state <= S_IDLE;
            end else begin
              // Advance to next word
              sub_idx     <= '0;
              word_buf    <= '0;
              byte_cnt    <= byte_cnt + 16'd1;
              obuf_rd_addr <= byte_cnt + 16'd1;
              state       <= S_READ;
            end
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
