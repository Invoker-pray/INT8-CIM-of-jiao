// ============================================================================
// cim_axi_stream_sink.sv — AXI4-Stream slave, routes data to weight / input / bias SRAMs
// ============================================================================
// 设计参考: docs/c3_dma_design.md §3 (C3 — AXI4-Stream + axi_dma 数据通路重构)
//
// 功能:
//   - 接收来自 axi_dma 的 32-bit AXIS 数据流 (M_AXIS_MM2S)
//   - 按 CSR 配置 (cfg_dest) 路由到三个目的地:
//       dest=0 (DEST_WEIGHT) → 每 4 beats 组装成 128-bit 行, 写 weight_sram
//       dest=1 (DEST_INPUT)  → 每 4 beats 组装成 128-bit tile, 写 input_buffer
//       dest=2 (DEST_BIAS)   → 每 1 beat  直接写 bias_sram (32-bit)
//   - 位精确 (bit-exact) 与 cim_axi_lite_slave 的 legacy staging 路径一致:
//       * word0 → staging[31:0], word1 → [63:32], word2 → [95:64], word3 → [127:96]
//       * 4th chunk 同时触发 commit 脉冲 (与 legacy 完全相同的时序)
//
// 时序 (与 legacy 完全一致):
//   cycle N:   beat_3 fires, staging[127:96] <= tdata, wr_en <= 1,
//              wr_row_data <= {tdata, staging[95:0]}
//   cycle N+1: BRAM 看到 wr_en + 完整的 row_data, 在下一个 edge 写入
//
// tready 恒为 1 (仅在 RECV 且未 ERROR 时). IDLE/ERROR 时拉低挡住 DMA, 避免误吞数据.
//
// 错误检测 (sticky, 软复位或 status_clear 清除):
//   - overflow : beat_count 达到 cfg_len 时 tlast 为 0 (DMA 送得比预期多)
//   - underflow: tlast=1 时 beat_count < cfg_len-1 (DMA 送得比预期少)
// ============================================================================

`timescale 1ns / 1ps

module cim_axi_stream_sink
  import cim_pkg::*;
#(
    parameter int DATA_W = 32
) (
    input logic clk,
    input logic rst_n,

    // ------------------------------------------------------------------
    // AXI4-Stream slave (来自 axi_dma M_AXIS_MM2S)
    // ------------------------------------------------------------------
    input  logic [DATA_W-1:0] s_axis_tdata,
    input  logic              s_axis_tvalid,
    output logic              s_axis_tready,
    input  logic              s_axis_tlast,

    // ------------------------------------------------------------------
    // Configuration (来自 cim_axi_lite_slave 的 CSR 寄存器)
    // ------------------------------------------------------------------
    input logic [ 1:0] cfg_dest,       // 0=weight, 1=input, 2=bias
    input logic [15:0] cfg_len,        // 期望 beat 数 (必须 > 0)
    input logic        cfg_start,      // 1-cycle pulse: 锁存配置, 开始接收
    input logic [15:0] cfg_base_addr,  // 起始地址 (weight/input: tile idx; bias: word addr)
    input logic        cfg_continue,   // 0=reset addr ptrs, 1=continue from current position
    input logic        status_clear,   // 1-cycle pulse: 清除 done/overflow/underflow

    // ------------------------------------------------------------------
    // Status
    // ------------------------------------------------------------------
    output logic busy,
    output logic done,       // 1-cycle pulse after last beat, or latched until status_clear
    output logic overflow,   // sticky
    output logic underflow,  // sticky

    // ------------------------------------------------------------------
    // Write port → weight_sram (整行 128-bit)
    // ------------------------------------------------------------------
    output logic                                  wsram_wr_en,
    output logic [      $clog2(TILE_ROWS)-1:0]    wsram_wr_row,
    output logic [  clog2_safe(WSRAM_DEPTH)-1:0]  wsram_wr_tile_idx,
    output logic [        TILE_COLS*WEIGHT_W-1:0] wsram_wr_row_data,

    // ------------------------------------------------------------------
    // Write port → input_buffer (整 tile 128-bit)
    // ------------------------------------------------------------------
    output logic                                               ibuf_wr_en,
    output logic [clog2_safe(MAX_IN_DIM/TILE_COLS)-1:0]        ibuf_wr_tile_idx,
    output logic [                TILE_COLS*INPUT_W-1:0]       ibuf_wr_tile_data,

    // ------------------------------------------------------------------
    // Write port → bias_sram (32-bit word)
    // ------------------------------------------------------------------
    output logic                                  bsram_wr_en,
    output logic [  clog2_safe(BSRAM_DEPTH)-1:0]  bsram_wr_addr,
    output logic [                          31:0] bsram_wr_data
);

  // ==========================================================================
  // Local constants
  // ==========================================================================
  localparam int CHUNKS_PER_ROW = 4;   // 4 × 32-bit = 128-bit row
  localparam int ROW_W          = TILE_COLS * WEIGHT_W;  // 128
  localparam int IBUF_TILE_W    = TILE_COLS * INPUT_W;   // 128

  localparam logic [1:0] DEST_WEIGHT = 2'd0;
  localparam logic [1:0] DEST_INPUT  = 2'd1;
  localparam logic [1:0] DEST_BIAS   = 2'd2;

  localparam int WSRAM_IDX_W = clog2_safe(WSRAM_DEPTH);
  localparam int IBUF_IDX_W  = clog2_safe(MAX_IN_DIM / TILE_COLS);
  localparam int BSRAM_IDX_W = clog2_safe(BSRAM_DEPTH);

  // ==========================================================================
  // FSM
  // ==========================================================================
  typedef enum logic [1:0] {
    ST_IDLE,
    ST_RECV,
    ST_ERROR
  } sink_state_t;

  sink_state_t state;

  // ==========================================================================
  // Latched configuration
  // ==========================================================================
  logic [ 1:0] dest_r;
  logic [15:0] len_r;
  logic [15:0] base_r;

  // ==========================================================================
  // Counters
  // ==========================================================================
  logic [          15:0] beat_count;   // 0..cfg_len-1
  logic [           1:0] chunk_in_row; // 0..3 (weight/input only)
  logic [           3:0] w_row_cnt;    // 0..15 (weight only)
  logic [WSRAM_IDX_W-1:0] w_tile_cnt;  // weight tile cursor
  logic [ IBUF_IDX_W-1:0] i_tile_cnt;  // input tile cursor
  logic [BSRAM_IDX_W-1:0] b_addr_cnt;  // bias addr cursor

  // ==========================================================================
  // Staging registers
  // ==========================================================================
  logic [     ROW_W-1:0] wsram_staging;
  logic [IBUF_TILE_W-1:0] ibuf_staging;

  // ==========================================================================
  // Status registers (sticky)
  // ==========================================================================
  logic done_r, overflow_r, underflow_r;

  assign busy      = (state == ST_RECV);
  assign done      = done_r;
  assign overflow  = overflow_r;
  assign underflow = underflow_r;

  // Accept beats only in RECV.  IDLE/ERROR → tready=0 (reject stray beats).
  assign s_axis_tready = (state == ST_RECV);

  wire beat_fire = s_axis_tvalid && s_axis_tready;
  wire is_last_expected_beat = (beat_count == len_r - 16'd1);
  wire chunk_full = (chunk_in_row == 2'd3);

  // ==========================================================================
  // Main FSM + datapath
  // ==========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state             <= ST_IDLE;
      dest_r            <= '0;
      len_r             <= '0;
      base_r            <= '0;
      beat_count        <= '0;
      chunk_in_row      <= '0;
      w_row_cnt         <= '0;
      w_tile_cnt        <= '0;
      i_tile_cnt        <= '0;
      b_addr_cnt        <= '0;
      wsram_staging     <= '0;
      ibuf_staging      <= '0;
      done_r            <= 1'b0;
      overflow_r        <= 1'b0;
      underflow_r       <= 1'b0;
      wsram_wr_en       <= 1'b0;
      wsram_wr_row      <= '0;
      wsram_wr_tile_idx <= '0;
      wsram_wr_row_data <= '0;
      ibuf_wr_en        <= 1'b0;
      ibuf_wr_tile_idx  <= '0;
      ibuf_wr_tile_data <= '0;
      bsram_wr_en       <= 1'b0;
      bsram_wr_addr     <= '0;
      bsram_wr_data     <= '0;
    end else begin
      // --- Default: self-clearing write enables + done pulse ---
      wsram_wr_en <= 1'b0;
      ibuf_wr_en  <= 1'b0;
      bsram_wr_en <= 1'b0;

      // status_clear takes effect regardless of state (软件可在任意时刻清)
      if (status_clear) begin
        done_r      <= 1'b0;
        overflow_r  <= 1'b0;
        underflow_r <= 1'b0;
      end

      case (state)
        // ------------------------------------------------------------------
        ST_IDLE: begin
          if (cfg_start) begin
            dest_r       <= cfg_dest;
            len_r        <= cfg_len;
            base_r       <= cfg_base_addr;
            beat_count   <= '0;
            state        <= ST_RECV;
            done_r       <= 1'b0;  // 新事务开始时自动清 done

            // Only reset address pointers and staging state when NOT continuing
            if (!cfg_continue) begin
              chunk_in_row  <= '0;
              w_row_cnt     <= '0;
              w_tile_cnt    <= cfg_base_addr[WSRAM_IDX_W-1:0];
              i_tile_cnt    <= cfg_base_addr[IBUF_IDX_W-1:0];
              b_addr_cnt    <= cfg_base_addr[BSRAM_IDX_W-1:0];
              wsram_staging <= '0;
              ibuf_staging  <= '0;
            end
            // When continuing, preserve chunk_in_row, w_row_cnt, w_tile_cnt, and staging registers
          end
        end

        // ------------------------------------------------------------------
        ST_RECV: begin
          if (beat_fire) begin
            beat_count <= beat_count + 16'd1;

            // ---------------- Dest-specific datapath ----------------
            case (dest_r)
              // -------- Weight: 4-chunk row assembly --------
              DEST_WEIGHT: begin
                if (chunk_full) begin
                  // Commit completed 128-bit row to weight_sram
                  // Use s_axis_tdata directly as [127:96] since staging[127:96] hasn't updated yet
                  wsram_wr_en       <= 1'b1;
                  wsram_wr_row      <= w_row_cnt;
                  wsram_wr_tile_idx <= w_tile_cnt;
                  wsram_wr_row_data <= {s_axis_tdata, wsram_staging[95:0]};

                  // Advance row / tile
                  if (w_row_cnt == 4'd15) begin
                    w_row_cnt  <= '0;
                    w_tile_cnt <= w_tile_cnt + {{(WSRAM_IDX_W-1){1'b0}}, 1'b1};
                  end else begin
                    w_row_cnt <= w_row_cnt + 4'd1;
                  end
                  chunk_in_row <= '0;
                end else begin
                  // Accumulate chunks 0-2 into staging register
                  case (chunk_in_row)
                    2'd0: wsram_staging[ 31:  0] <= s_axis_tdata;
                    2'd1: wsram_staging[ 63: 32] <= s_axis_tdata;
                    2'd2: wsram_staging[ 95: 64] <= s_axis_tdata;
                  endcase
                  chunk_in_row <= chunk_in_row + 2'd1;
                end
              end

              // -------- Input: 4-chunk tile assembly (同 byte-ordering 为 legacy) --------
              // Legacy per-byte staging 把第 k 个字节放在 [8k+7:8k], 等价于
              // 每 4 个连续字节打包为一个 uint32 little-endian 放在对应 32-bit 槽.
              DEST_INPUT: begin
                if (chunk_full) begin
                  ibuf_wr_en        <= 1'b1;
                  ibuf_wr_tile_idx  <= i_tile_cnt;
                  ibuf_wr_tile_data <= {s_axis_tdata, ibuf_staging[95:0]};
                  i_tile_cnt        <= i_tile_cnt + {{(IBUF_IDX_W-1){1'b0}}, 1'b1};
                  chunk_in_row      <= '0;
                end else begin
                  case (chunk_in_row)
                    2'd0: ibuf_staging[ 31:  0] <= s_axis_tdata;
                    2'd1: ibuf_staging[ 63: 32] <= s_axis_tdata;
                    2'd2: ibuf_staging[ 95: 64] <= s_axis_tdata;
                  endcase
                  chunk_in_row <= chunk_in_row + 2'd1;
                end
              end

              // -------- Bias: direct 32-bit write, addr autoincrement --------
              DEST_BIAS: begin
                bsram_wr_en   <= 1'b1;
                bsram_wr_addr <= b_addr_cnt;
                bsram_wr_data <= s_axis_tdata;
                b_addr_cnt    <= b_addr_cnt + {{(BSRAM_IDX_W-1){1'b0}}, 1'b1};
              end

              default: ;  // reserved dest: no write
            endcase

            // ---------------- End-of-stream handling ----------------
            if (is_last_expected_beat) begin
              if (s_axis_tlast) begin
                // Normal termination
                done_r <= 1'b1;
                state  <= ST_IDLE;
              end else begin
                // cfg_len reached but DMA still has more → overflow
                overflow_r <= 1'b1;
                state      <= ST_ERROR;
              end
            end else begin
              if (s_axis_tlast) begin
                // DMA ended early → underflow
                underflow_r <= 1'b1;
                state       <= ST_ERROR;
              end
            end
          end
        end

        // ------------------------------------------------------------------
        ST_ERROR: begin
          // Halt until status_clear (or rst_n) clears overflow/underflow
          if (!overflow_r && !underflow_r) begin
            state <= ST_IDLE;
          end
        end

        default: state <= ST_IDLE;
      endcase
    end
  end

endmodule
