// ============================================================================
// cim_top_wrapper.v — Pure Verilog wrapper for Vivado Block Design (C3)
// ============================================================================
// Exposes cim_top.sv to Vivado BD via `create_bd_cell -type module -reference`.
// Adds the AXI4-Stream slave interface on top of the legacy AXI4-Lite slave.
// Port naming follows Xilinx conventions so BD auto-infers AXI-Stream bundle.
// ============================================================================

module cim_top_wrapper #(
    parameter AXI_ADDR_W  = 14,
    parameter AXI_DATA_W  = 32,
    parameter AXIS_DATA_W = 32
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

    // ---- AXI4-Stream Data Slave (from axi_dma_0/M_AXIS_MM2S) ----
    input  wire [AXIS_DATA_W-1:0] S_AXIS_TDATA,
    input  wire                   S_AXIS_TVALID,
    output wire                   S_AXIS_TREADY,
    input  wire                   S_AXIS_TLAST,

    // ---- AXI4-Stream Master for result read-back (to axi_dma_0/S_AXIS_S2MM) ----
    output wire [AXIS_DATA_W-1:0] M_AXIS_RESULT_TDATA,
    output wire                   M_AXIS_RESULT_TVALID,
    input  wire                   M_AXIS_RESULT_TREADY,
    output wire                   M_AXIS_RESULT_TLAST,

    // ---- Interrupt ----
    output wire irq_done
);

  cim_top #(
      .AXI_ADDR_W (AXI_ADDR_W),
      .AXI_DATA_W (AXI_DATA_W),
      .AXIS_DATA_W(AXIS_DATA_W)
  ) u_top (
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

      .S_AXIS_TDATA (S_AXIS_TDATA),
      .S_AXIS_TVALID(S_AXIS_TVALID),
      .S_AXIS_TREADY(S_AXIS_TREADY),
      .S_AXIS_TLAST (S_AXIS_TLAST),

      .M_AXIS_RESULT_TDATA (M_AXIS_RESULT_TDATA),
      .M_AXIS_RESULT_TVALID(M_AXIS_RESULT_TVALID),
      .M_AXIS_RESULT_TREADY(M_AXIS_RESULT_TREADY),
      .M_AXIS_RESULT_TLAST (M_AXIS_RESULT_TLAST),

      .irq_done(irq_done)
  );

endmodule
