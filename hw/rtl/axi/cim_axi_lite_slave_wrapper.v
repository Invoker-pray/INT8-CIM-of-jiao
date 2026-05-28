// ============================================================================
// cim_axi_lite_slave_wrapper.v — Pure Verilog wrapper for Vivado Block Design
// ============================================================================
// Vivado "Module Reference" (create_bd_cell -type module -reference ...)
// requires the top file to be plain Verilog (.v), not SystemVerilog (.sv).
// This wrapper instantiates the real cim_axi_lite_slave.sv module with its
// default parameters and exposes identical ports.
//
// For BD flows without DMA (PicoRV32), stream ports are tied off.
// For DMA flows (ARM), use cim_top_wrapper.v instead.
//
// NOTE: stream port widths below are hard-coded to match the current
// cim_pkg defaults (MAX_IN_DIM=1536, MAX_OUT_DIM=256, TILE_ROWS=16).
// If these change in cim_pkg, the widths here must be updated.
// ============================================================================

module cim_axi_lite_slave_wrapper #(
    parameter AXI_ADDR_W = 14,
    parameter AXI_DATA_W = 32
) (
    // ---- Clock & Reset ----
    input wire S_AXI_ACLK,
    input wire S_AXI_ARESETN,

    // ---- AXI4-Lite Write Address Channel ----
    input  wire [AXI_ADDR_W-1:0] S_AXI_AWADDR,
    input  wire [           2:0] S_AXI_AWPROT,
    input  wire                  S_AXI_AWVALID,
    output wire                  S_AXI_AWREADY,

    // ---- AXI4-Lite Write Data Channel ----
    input  wire [  AXI_DATA_W-1:0] S_AXI_WDATA,
    input  wire [AXI_DATA_W/8-1:0] S_AXI_WSTRB,
    input  wire                    S_AXI_WVALID,
    output wire                    S_AXI_WREADY,

    // ---- AXI4-Lite Write Response Channel ----
    output wire [1:0] S_AXI_BRESP,
    output wire       S_AXI_BVALID,
    input  wire       S_AXI_BREADY,

    // ---- AXI4-Lite Read Address Channel ----
    input  wire [AXI_ADDR_W-1:0] S_AXI_ARADDR,
    input  wire [           2:0] S_AXI_ARPROT,
    input  wire                  S_AXI_ARVALID,
    output wire                  S_AXI_ARREADY,

    // ---- AXI4-Lite Read Data Channel ----
    output wire [AXI_DATA_W-1:0] S_AXI_RDATA,
    output wire [           1:0] S_AXI_RRESP,
    output wire                  S_AXI_RVALID,
    input  wire                  S_AXI_RREADY,

    // ---- AXI4-Stream Master for result read-back (P0 S2MM, unused in no-DMA BD) ----
    output wire [AXI_DATA_W-1:0] M_AXIS_RESULT_TDATA,
    output wire                  M_AXIS_RESULT_TVALID,
    input  wire                  M_AXIS_RESULT_TREADY,
    output wire                  M_AXIS_RESULT_TLAST,

    // ---- Interrupt ----
    output wire irq_done
);

  // Hard-coded port widths for current cim_pkg (MAX_IN_DIM=1536, MAX_OUT_DIM=256):
  //   TILE_ROWS=16            → wsram_wr_row        = 4 bits  ([3:0])
  //   WSRAM_DEPTH=1536        → wsram_wr_tile_idx   = 11 bits ([10:0])
  //   TILE_COLS*WEIGHT_W=128  → wsram_wr_row_data   = 128 bits
  //   IBUF_TILES=96           → ibuf_wr_tile_idx    = 7 bits  ([6:0])
  //   TILE_COLS*INPUT_W=128   → ibuf_wr_tile_data   = 128 bits
  //   BSRAM_DEPTH=256         → bsram_wr_addr       = 8 bits  ([7:0])
  //   bsram_wr_data           → 32 bits

  cim_axi_lite_slave #(
      .AXI_ADDR_W(AXI_ADDR_W),
      .AXI_DATA_W(AXI_DATA_W)
  ) u_inner (
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

      // C3 stream-sink side-band — tied 0 (no DMA in non-cim_top flows)
      .stream_path_en          (),
      .cfg_dest                (),
      .cfg_len                 (),
      .cfg_base_addr           (),
      .cfg_continue            (),
      .cfg_start               (),
      .status_clear            (),
      .stream_busy             (1'b0),
      .stream_done             (1'b0),
      .stream_overflow         (1'b0),
      .stream_underflow        (1'b0),

      // C3 stream-sink write ports — tied 0 (legacy MMIO path only)
      .stream_wsram_wr_en      (1'b0),
      .stream_wsram_wr_row     (4'b0),
      .stream_wsram_wr_tile_idx(11'b0),
      .stream_wsram_wr_row_data(128'b0),
      .stream_ibuf_wr_en       (1'b0),
      .stream_ibuf_wr_tile_idx (7'b0),
      .stream_ibuf_wr_tile_data(128'b0),
      .stream_bsram_wr_en      (1'b0),
      .stream_bsram_wr_addr    (8'b0),
      .stream_bsram_wr_data    (32'b0),

      // P0: M_AXIS_RESULT — tied off (no DMA S2MM in non-cim_top flows)
      .M_AXIS_RESULT_TDATA (M_AXIS_RESULT_TDATA),
      .M_AXIS_RESULT_TVALID(M_AXIS_RESULT_TVALID),
      .M_AXIS_RESULT_TREADY(1'b0),
      .M_AXIS_RESULT_TLAST (M_AXIS_RESULT_TLAST)
  );

endmodule
