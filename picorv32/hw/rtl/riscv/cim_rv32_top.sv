// ============================================================================
// cim_rv32_top.sv — PicoRV32 + CIM + Dual-Port FW/Result BRAM
// ============================================================================
//
// PS workflow for each test image:
//   1. Assert cpu_rst_n=0 (hold CPU)
//   2. Write firmware into FW BRAM port B (0x4000_0000, 32KB)
//   3. Clear Result BRAM magic via port B (optional)
//   4. Deassert cpu_rst_n=1 (CPU starts from 0x0)
//   5. Poll Result BRAM magic (0x4200_0000) for 0xC1AA0001
//   6. Read prediction + logits from Result BRAM
//   7. Goto 1 for next image
//
// PicoRV32 address map:
//   0x0000_0000 : FW BRAM (32KB)       port B at AXI 0x4000_0000
//   0x4000_0000 : CIM CSR (16KB)
//   0x8000_0000 : UART TX
//   0xC000_0000 : Result BRAM (256B)   port B at AXI 0x4200_0000
// ============================================================================

module cim_rv32_top
  import cim_pkg::*;
#(
    parameter int CLK_FREQ  = 50_000_000,
    parameter int BAUD_RATE = 115200
) (
    input  logic clk,
    input  logic rst_n,       // global reset
    input  logic cpu_rst_n,   // CPU-only reset (PS: 0=hold, 1=run)
    output logic uart_txd,
    output logic cim_done_irq,

    // FW BRAM port B (PS writes firmware)
    input  logic        fw_b_en,
    input  logic [ 3:0] fw_b_we,
    input  logic [14:0] fw_b_addr,
    input  logic [31:0] fw_b_wdata,
    output logic [31:0] fw_b_rdata,

    // Result BRAM port B (PS reads results)
    input  logic        res_b_en,
    input  logic [ 3:0] res_b_we,
    input  logic [ 7:0] res_b_addr,
    input  logic [31:0] res_b_wdata,
    output logic [31:0] res_b_rdata
);

  wire cpu_resetn = rst_n & cpu_rst_n;

  // ---- PicoRV32 ----
  logic mem_valid, mem_ready, mem_instr;
  logic [31:0] mem_addr, mem_wdata, mem_rdata;
  logic [3:0] mem_wstrb;

  picorv32 #(
      .STACKADDR(32'h0000_7FFC), .PROGADDR_RESET(32'h0000_0000),
      .PROGADDR_IRQ(32'h0000_0010), .ENABLE_MUL(1), .ENABLE_DIV(1),
      .ENABLE_IRQ(0), .BARREL_SHIFTER(1), .COMPRESSED_ISA(0),
      .ENABLE_COUNTERS(0), .ENABLE_REGS_16_31(1)
  ) u_cpu (
      .clk(clk), .resetn(cpu_resetn),
      .mem_valid(mem_valid), .mem_ready(mem_ready),
      .mem_addr(mem_addr), .mem_wdata(mem_wdata),
      .mem_wstrb(mem_wstrb), .mem_rdata(mem_rdata), .mem_instr(mem_instr),
      .mem_la_read(), .mem_la_write(), .mem_la_addr(),
      .mem_la_wdata(), .mem_la_wstrb(),
      .irq(32'b0), .eoi(), .trace_valid(), .trace_data(),
      .pcpi_valid(), .pcpi_insn(), .pcpi_rs1(), .pcpi_rs2(),
      .pcpi_wr(1'b0), .pcpi_rd(32'b0), .pcpi_wait(1'b0), .pcpi_ready(1'b0),
      .trap()
  );

  // ---- FW BRAM: True Dual-Port 32KB ----
  localparam int FW_DEPTH = 8192;
  localparam int FW_AW = $clog2(FW_DEPTH);

  logic fw_a_en; logic [3:0] fw_a_we;
  logic [14:0] fw_a_byte_addr;
  logic [31:0] fw_a_wdata, fw_a_rdata;
  wire [FW_AW-1:0] fw_a_word = fw_a_byte_addr[FW_AW+1:2];
  wire [FW_AW-1:0] fw_b_word = fw_b_addr[FW_AW+1:2];

  (* ram_style = "block" *) reg [31:0] fw_mem [0:FW_DEPTH-1];

  always @(posedge clk) begin  // Port A
    if (fw_a_en) begin
      if (fw_a_we[0]) fw_mem[fw_a_word][ 7: 0] <= fw_a_wdata[ 7: 0];
      if (fw_a_we[1]) fw_mem[fw_a_word][15: 8] <= fw_a_wdata[15: 8];
      if (fw_a_we[2]) fw_mem[fw_a_word][23:16] <= fw_a_wdata[23:16];
      if (fw_a_we[3]) fw_mem[fw_a_word][31:24] <= fw_a_wdata[31:24];
      fw_a_rdata <= fw_mem[fw_a_word];
    end
  end
  always @(posedge clk) begin  // Port B
    if (fw_b_en) begin
      if (fw_b_we[0]) fw_mem[fw_b_word][ 7: 0] <= fw_b_wdata[ 7: 0];
      if (fw_b_we[1]) fw_mem[fw_b_word][15: 8] <= fw_b_wdata[15: 8];
      if (fw_b_we[2]) fw_mem[fw_b_word][23:16] <= fw_b_wdata[23:16];
      if (fw_b_we[3]) fw_mem[fw_b_word][31:24] <= fw_b_wdata[31:24];
      fw_b_rdata <= fw_mem[fw_b_word];
    end
  end

  // ---- Result BRAM: True Dual-Port 256B ----
  localparam int RES_DEPTH = 64;
  localparam int RES_AW = 6;
  logic res_a_en; logic [3:0] res_a_we;
  logic [7:0] res_a_byte_addr;
  logic [31:0] res_a_wdata, res_a_rdata;
  wire [RES_AW-1:0] res_a_word = res_a_byte_addr[RES_AW+1:2];
  wire [RES_AW-1:0] res_b_word = res_b_addr[RES_AW+1:2];

  (* ram_style = "block" *) reg [31:0] res_mem [0:RES_DEPTH-1];
  integer ri; initial for (ri=0; ri<RES_DEPTH; ri++) res_mem[ri]=0;

  always @(posedge clk) begin
    if (res_a_en) begin
      if (res_a_we[0]) res_mem[res_a_word][ 7: 0] <= res_a_wdata[ 7: 0];
      if (res_a_we[1]) res_mem[res_a_word][15: 8] <= res_a_wdata[15: 8];
      if (res_a_we[2]) res_mem[res_a_word][23:16] <= res_a_wdata[23:16];
      if (res_a_we[3]) res_mem[res_a_word][31:24] <= res_a_wdata[31:24];
      res_a_rdata <= res_mem[res_a_word];
    end
  end
  always @(posedge clk) begin
    if (res_b_en) begin
      if (res_b_we[0]) res_mem[res_b_word][ 7: 0] <= res_b_wdata[ 7: 0];
      if (res_b_we[1]) res_mem[res_b_word][15: 8] <= res_b_wdata[15: 8];
      if (res_b_we[2]) res_mem[res_b_word][23:16] <= res_b_wdata[23:16];
      if (res_b_we[3]) res_mem[res_b_word][31:24] <= res_b_wdata[31:24];
      res_b_rdata <= res_mem[res_b_word];
    end
  end

  // ---- UART ----
  logic uart_tx_valid; logic [7:0] uart_tx_data; logic uart_tx_ready;
  uart_tx #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD_RATE)) u_uart (
      .clk(clk), .rst_n(rst_n), .tx_valid(uart_tx_valid),
      .tx_data(uart_tx_data), .tx_ready(uart_tx_ready), .uart_txd(uart_txd));

  // ---- CIM AXI Slave (unchanged) ----
  logic [13:0] axi_awaddr, axi_araddr;
  logic axi_awvalid, axi_awready, axi_wvalid, axi_wready;
  logic [31:0] axi_wdata, axi_rdata; logic [3:0] axi_wstrb;
  logic [1:0] axi_bresp, axi_rresp;
  logic axi_bvalid, axi_bready, axi_arvalid, axi_arready, axi_rvalid, axi_rready;

  cim_axi_lite_slave_wrapper #(.AXI_ADDR_W(14),.AXI_DATA_W(32)) u_cim (
      .S_AXI_ACLK(clk),.S_AXI_ARESETN(rst_n),
      .S_AXI_AWADDR(axi_awaddr),.S_AXI_AWPROT(3'b0),.S_AXI_AWVALID(axi_awvalid),.S_AXI_AWREADY(axi_awready),
      .S_AXI_WDATA(axi_wdata),.S_AXI_WSTRB(axi_wstrb),.S_AXI_WVALID(axi_wvalid),.S_AXI_WREADY(axi_wready),
      .S_AXI_BRESP(axi_bresp),.S_AXI_BVALID(axi_bvalid),.S_AXI_BREADY(axi_bready),
      .S_AXI_ARADDR(axi_araddr),.S_AXI_ARPROT(3'b0),.S_AXI_ARVALID(axi_arvalid),.S_AXI_ARREADY(axi_arready),
      .S_AXI_RDATA(axi_rdata),.S_AXI_RRESP(axi_rresp),.S_AXI_RVALID(axi_rvalid),.S_AXI_RREADY(axi_rready),
      .irq_done(cim_done_irq));

  // ---- Mini AXI Master (unchanged) ----
  logic cim_start_wr, cim_start_rd;
  logic [13:0] cim_addr;
  logic [31:0] cim_wdata_bridge, cim_rdata_bridge;
  logic cim_wr_done, cim_rd_done;
  typedef enum logic [2:0] {AXI_IDLE,AXI_WR_HS,AXI_WR_R,AXI_RD_A,AXI_RD_D} axi_state_t;
  axi_state_t axi_st;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      axi_st<=AXI_IDLE; axi_awvalid<=0; axi_wvalid<=0; axi_bready<=0;
      axi_arvalid<=0; axi_rready<=0; cim_wr_done<=0; cim_rd_done<=0; cim_rdata_bridge<=0;
    end else begin
      cim_wr_done<=0; cim_rd_done<=0;
      case(axi_st)
        AXI_IDLE: if(cim_start_wr) begin
            axi_awaddr<=cim_addr;axi_awvalid<=1;axi_wdata<=cim_wdata_bridge;axi_wstrb<=4'b1111;axi_wvalid<=1;axi_st<=AXI_WR_HS;
          end else if(cim_start_rd) begin axi_araddr<=cim_addr;axi_arvalid<=1;axi_st<=AXI_RD_A; end
        AXI_WR_HS: begin
          if(axi_awready&&axi_awvalid) axi_awvalid<=0;
          if(axi_wready&&axi_wvalid) axi_wvalid<=0;
          if((!axi_awvalid||axi_awready)&&(!axi_wvalid||axi_wready)) begin axi_awvalid<=0;axi_wvalid<=0;axi_bready<=1;axi_st<=AXI_WR_R; end
        end
        AXI_WR_R: if(axi_bvalid) begin axi_bready<=0;cim_wr_done<=1;axi_st<=AXI_IDLE; end
        AXI_RD_A: if(axi_arready) begin axi_arvalid<=0;axi_rready<=1;axi_st<=AXI_RD_D; end
        AXI_RD_D: if(axi_rvalid) begin cim_rdata_bridge<=axi_rdata;axi_rready<=0;cim_rd_done<=1;axi_st<=AXI_IDLE; end
        default: axi_st<=AXI_IDLE;
      endcase
    end
  end

  // ---- Bridge (unchanged) ----
  picorv32_cim_bridge u_bridge (
      .clk(clk),.rst_n(rst_n),
      .mem_valid(mem_valid),.mem_ready(mem_ready),
      .mem_addr(mem_addr),.mem_wdata(mem_wdata),.mem_wstrb(mem_wstrb),.mem_rdata(mem_rdata),
      .fw_bram_en(fw_a_en),.fw_bram_we(fw_a_we),
      .fw_bram_addr(fw_a_byte_addr),.fw_bram_wdata(fw_a_wdata),.fw_bram_rdata(fw_a_rdata),
      .cim_start_wr(cim_start_wr),.cim_start_rd(cim_start_rd),
      .cim_addr(cim_addr),.cim_wdata(cim_wdata_bridge),
      .cim_rdata(cim_rdata_bridge),.cim_wr_done(cim_wr_done),.cim_rd_done(cim_rd_done),
      .uart_tx_valid(uart_tx_valid),.uart_tx_data(uart_tx_data),.uart_tx_ready(uart_tx_ready),
      .res_bram_en(res_a_en),.res_bram_we(res_a_we),
      .res_bram_addr(res_a_byte_addr),.res_bram_wdata(res_a_wdata),.res_bram_rdata(res_a_rdata));

endmodule
