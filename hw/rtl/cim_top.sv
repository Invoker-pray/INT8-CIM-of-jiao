// ============================================================================
// cim_top.sv — CIM IP top wrapper (C3 stream-capable)
// ============================================================================
// 设计参考: docs/c3_dma_design.md §2.1, §4.1
//
// 本模块是上板 IP 的新顶层，组合:
//   1. cim_axi_lite_slave  — CSR 控制 + legacy MMIO staging + MUX 写入内存
//   2. cim_axi_stream_sink — DMA AXIS 数据路径，writes directly to memory via
//                            slave's stream_*_wr_* input ports
//
// CTRL[3] 切换:
//   CTRL[3]=0 (默认) — slave 内部 staging 路径驱动 weight_sram/input_buffer/
//                       bias_sram；stream sink 仍在跑但 wr_en=0 (被 slave 忽略)
//   CTRL[3]=1        — slave 内部 staging 被忽略；sink 的写信号驱动存储
//
// 对外端口 = legacy wrapper 的全部端口 + AXI4-Stream slave 一条。
// Vivado BD 通过 cim_top_wrapper.v (commit 4 新增) 实例化此模块。
// ============================================================================

`timescale 1ns / 1ps

module cim_top
  import cim_pkg::*;
#(
    parameter int AXI_ADDR_W = 14,
    parameter int AXI_DATA_W = 32,
    parameter int AXIS_DATA_W = 32
) (
    // ---- Clock & Reset (AXI 子系统共享 FCLK_CLK0) ----
    input logic S_AXI_ACLK,
    input logic S_AXI_ARESETN,

    // ---- AXI4-Lite Write / Read (来自 ps7/M_AXI_GP0) ----
    input  logic [AXI_ADDR_W-1:0]     S_AXI_AWADDR,
    input  logic [           2:0]     S_AXI_AWPROT,
    input  logic                      S_AXI_AWVALID,
    output logic                      S_AXI_AWREADY,

    input  logic [  AXI_DATA_W-1:0]   S_AXI_WDATA,
    input  logic [AXI_DATA_W/8-1:0]   S_AXI_WSTRB,
    input  logic                      S_AXI_WVALID,
    output logic                      S_AXI_WREADY,

    output logic [1:0]                S_AXI_BRESP,
    output logic                      S_AXI_BVALID,
    input  logic                      S_AXI_BREADY,

    input  logic [AXI_ADDR_W-1:0]     S_AXI_ARADDR,
    input  logic [           2:0]     S_AXI_ARPROT,
    input  logic                      S_AXI_ARVALID,
    output logic                      S_AXI_ARREADY,

    output logic [AXI_DATA_W-1:0]     S_AXI_RDATA,
    output logic [           1:0]     S_AXI_RRESP,
    output logic                      S_AXI_RVALID,
    input  logic                      S_AXI_RREADY,

    // ---- AXI4-Stream slave (来自 axi_dma_0/M_AXIS_MM2S) ----
    input  logic [AXIS_DATA_W-1:0]    S_AXIS_TDATA,
    input  logic                      S_AXIS_TVALID,
    output logic                      S_AXIS_TREADY,
    input  logic                      S_AXIS_TLAST,

    // ---- Interrupt (→ xlconcat/In0) ----
    output logic                      irq_done
);

  // ==========================================================================
  // Internal side-band wires between slave and sink
  // ==========================================================================
  logic        stream_path_en;  // == CTRL[3]

  // Slave → Sink (configuration + status-clear)
  logic [ 1:0] cfg_dest;
  logic [15:0] cfg_len;
  logic [15:0] cfg_base_addr;
  logic        cfg_start;
  logic        status_clear;

  // Sink → Slave (status flags readable via CSR_STREAM_STATUS)
  logic        stream_busy;
  logic        stream_done;
  logic        stream_overflow;
  logic        stream_underflow;

  // Sink → Slave (memory write ports, MUXed inside slave on stream_path_en)
  logic                                                wsram_wr_en;
  logic [      $clog2(TILE_ROWS)-1:0]                  wsram_wr_row;
  logic [clog2_safe(WSRAM_DEPTH)-1:0]                  wsram_wr_tile_idx;
  logic [        TILE_COLS*WEIGHT_W-1:0]               wsram_wr_row_data;

  logic                                                ibuf_wr_en;
  logic [clog2_safe(MAX_IN_DIM/TILE_COLS)-1:0]         ibuf_wr_tile_idx;
  logic [         TILE_COLS*INPUT_W-1:0]               ibuf_wr_tile_data;

  logic                                                bsram_wr_en;
  logic [clog2_safe(BSRAM_DEPTH)-1:0]                  bsram_wr_addr;
  logic [                          31:0]               bsram_wr_data;

  // ==========================================================================
  // AXI4-Lite slave + legacy MMIO staging + internal memory instances
  // ==========================================================================
  cim_axi_lite_slave #(
      .AXI_ADDR_W(AXI_ADDR_W),
      .AXI_DATA_W(AXI_DATA_W)
  ) u_slave (
      .S_AXI_ACLK   (S_AXI_ACLK),
      .S_AXI_ARESETN(S_AXI_ARESETN),

      .S_AXI_AWADDR (S_AXI_AWADDR),
      .S_AXI_AWPROT (S_AXI_AWPROT),
      .S_AXI_AWVALID(S_AXI_AWVALID),
      .S_AXI_AWREADY(S_AXI_AWREADY),

      .S_AXI_WDATA (S_AXI_WDATA),
      .S_AXI_WSTRB (S_AXI_WSTRB),
      .S_AXI_WVALID(S_AXI_WVALID),
      .S_AXI_WREADY(S_AXI_WREADY),

      .S_AXI_BRESP (S_AXI_BRESP),
      .S_AXI_BVALID(S_AXI_BVALID),
      .S_AXI_BREADY(S_AXI_BREADY),

      .S_AXI_ARADDR (S_AXI_ARADDR),
      .S_AXI_ARPROT (S_AXI_ARPROT),
      .S_AXI_ARVALID(S_AXI_ARVALID),
      .S_AXI_ARREADY(S_AXI_ARREADY),

      .S_AXI_RDATA (S_AXI_RDATA),
      .S_AXI_RRESP (S_AXI_RRESP),
      .S_AXI_RVALID(S_AXI_RVALID),
      .S_AXI_RREADY(S_AXI_RREADY),

      .irq_done(irq_done),

      // Slave → Sink (configuration)
      .stream_path_en  (stream_path_en),
      .cfg_dest        (cfg_dest),
      .cfg_len         (cfg_len),
      .cfg_base_addr   (cfg_base_addr),
      .cfg_start       (cfg_start),
      .status_clear    (status_clear),

      // Sink → Slave (status)
      .stream_busy     (stream_busy),
      .stream_done     (stream_done),
      .stream_overflow (stream_overflow),
      .stream_underflow(stream_underflow),

      // Sink → Slave (memory writes; MUX internally on stream_path_en)
      .stream_wsram_wr_en      (wsram_wr_en),
      .stream_wsram_wr_row     (wsram_wr_row),
      .stream_wsram_wr_tile_idx(wsram_wr_tile_idx),
      .stream_wsram_wr_row_data(wsram_wr_row_data),
      .stream_ibuf_wr_en       (ibuf_wr_en),
      .stream_ibuf_wr_tile_idx (ibuf_wr_tile_idx),
      .stream_ibuf_wr_tile_data(ibuf_wr_tile_data),
      .stream_bsram_wr_en      (bsram_wr_en),
      .stream_bsram_wr_addr    (bsram_wr_addr),
      .stream_bsram_wr_data    (bsram_wr_data)
  );

  // ==========================================================================
  // AXI4-Stream sink (runs unconditionally; slave ignores writes when CTRL[3]=0)
  // ==========================================================================
  cim_axi_stream_sink #(
      .DATA_W(AXIS_DATA_W)
  ) u_sink (
      .clk              (S_AXI_ACLK),
      .rst_n            (S_AXI_ARESETN),

      .s_axis_tdata     (S_AXIS_TDATA),
      .s_axis_tvalid    (S_AXIS_TVALID),
      .s_axis_tready    (S_AXIS_TREADY),
      .s_axis_tlast     (S_AXIS_TLAST),

      .cfg_dest         (cfg_dest),
      .cfg_len          (cfg_len),
      .cfg_start        (cfg_start),
      .cfg_base_addr    (cfg_base_addr),
      .status_clear     (status_clear),

      .busy             (stream_busy),
      .done             (stream_done),
      .overflow         (stream_overflow),
      .underflow        (stream_underflow),

      .wsram_wr_en      (wsram_wr_en),
      .wsram_wr_row     (wsram_wr_row),
      .wsram_wr_tile_idx(wsram_wr_tile_idx),
      .wsram_wr_row_data(wsram_wr_row_data),

      .ibuf_wr_en       (ibuf_wr_en),
      .ibuf_wr_tile_idx (ibuf_wr_tile_idx),
      .ibuf_wr_tile_data(ibuf_wr_tile_data),

      .bsram_wr_en      (bsram_wr_en),
      .bsram_wr_addr    (bsram_wr_addr),
      .bsram_wr_data    (bsram_wr_data)
  );

  // stream_path_en currently only informs the slave's MUX (already tapped
  // via the .stream_path_en() port). No other use here, so leave as observe-only.
  // synthesis translate_off
  initial begin
    $display("cim_top: reset defaults stream_path_en=%0b (expect 0 → legacy path)",
             stream_path_en);
  end
  // synthesis translate_on

endmodule
