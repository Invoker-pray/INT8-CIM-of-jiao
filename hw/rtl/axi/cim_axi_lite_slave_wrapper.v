// ============================================================================
// cim_axi_lite_slave_wrapper.v — Pure Verilog wrapper for Vivado Block Design
// ============================================================================
// Vivado "Module Reference" (create_bd_cell -type module -reference ...)
// requires the top file to be plain Verilog (.v), not SystemVerilog (.sv).
// This wrapper instantiates the real cim_axi_lite_slave.sv module with its
// default parameters and exposes identical ports.
//
// Usage in vivado_build.tcl:
//   1. Add this file to the project  (add_files ... cim_axi_lite_slave_wrapper.v)
//   2. Replace line 87 with:
//        create_bd_cell -type module -reference cim_axi_lite_slave_wrapper cim_0
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

    // ---- Interrupt ----
    output wire irq_done
);

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

      // C3 stream-sink side-band — unused in the legacy BD flow; commit 4
      // switches the BD top to cim_top_wrapper.v, which wires these to the
      // new sink. Inputs tied 0 → CTRL[3] can still be written but with all
      // stream_*_wr_en=0 the MUX is a no-op, preserving legacy behavior.
      // Widths hard-coded to match cim_pkg defaults:
      //   TILE_ROWS=16, WSRAM_DEPTH=392 (9b), MAX_IN_DIM/TILE_COLS=49 (6b),
      //   BSRAM_DEPTH=128 (7b), row/tile data = 128b.
      .stream_path_en          (),
      .cfg_dest                (),
      .cfg_len                 (),
      .cfg_base_addr           (),
      .cfg_start               (),
      .status_clear            (),
      .stream_busy             (1'b0),
      .stream_done             (1'b0),
      .stream_overflow         (1'b0),
      .stream_underflow        (1'b0),
      .stream_wsram_wr_en      (1'b0),
      .stream_wsram_wr_row     (4'b0),
      .stream_wsram_wr_tile_idx(9'b0),
      .stream_wsram_wr_row_data(128'b0),
      .stream_ibuf_wr_en       (1'b0),
      .stream_ibuf_wr_tile_idx (6'b0),
      .stream_ibuf_wr_tile_data(128'b0),
      .stream_bsram_wr_en      (1'b0),
      .stream_bsram_wr_addr    (7'b0),
      .stream_bsram_wr_data    (32'b0)
  );

endmodule
