// ============================================================================
// cim_axi_lite_slave.sv — AXI4-Lite Slave Interface for CIM Accelerator IP
// ============================================================================
// Standard AXI4-Lite slave that maps CSR registers and SRAM windows.
//
// Address Map (see cim_pkg.sv for details):
//   0x000 - 0x0FF : Control/Status/Config registers
//   0x400 - 0x7FF : Input buffer write window
//   0x800 - 0xBFF : Bias buffer write window
//   Weight SRAM:    written via DMA-style registers (CSR_WDMA_*)
//
// AXI4-Lite protocol:
//   - 32-bit data bus
//   - Single-beat transactions only
//   - Supports concurrent read/write channels
//
// For Vivado IP Integrator:
//   - Instantiate this in Block Design
//   - Connect S_AXI to Zynq PS M_AXI_GP0
//   - Connect irq_done to PS IRQ_F2P
// ============================================================================

module cim_axi_lite_slave
  import cim_pkg::*;
#(
  parameter int AXI_ADDR_W = 12,   // 4KB address space
  parameter int AXI_DATA_W = 32
) (
  // ============================================================
  // AXI4-Lite Slave Interface
  // ============================================================
  input  logic                       S_AXI_ACLK,
  input  logic                       S_AXI_ARESETN,

  // Write Address Channel
  input  logic [AXI_ADDR_W-1:0]     S_AXI_AWADDR,
  input  logic [2:0]                 S_AXI_AWPROT,
  input  logic                       S_AXI_AWVALID,
  output logic                       S_AXI_AWREADY,

  // Write Data Channel
  input  logic [AXI_DATA_W-1:0]     S_AXI_WDATA,
  input  logic [AXI_DATA_W/8-1:0]   S_AXI_WSTRB,
  input  logic                       S_AXI_WVALID,
  output logic                       S_AXI_WREADY,

  // Write Response Channel
  output logic [1:0]                 S_AXI_BRESP,
  output logic                       S_AXI_BVALID,
  input  logic                       S_AXI_BREADY,

  // Read Address Channel
  input  logic [AXI_ADDR_W-1:0]     S_AXI_ARADDR,
  input  logic [2:0]                 S_AXI_ARPROT,
  input  logic                       S_AXI_ARVALID,
  output logic                       S_AXI_ARREADY,

  // Read Data Channel
  output logic [AXI_DATA_W-1:0]     S_AXI_RDATA,
  output logic [1:0]                 S_AXI_RRESP,
  output logic                       S_AXI_RVALID,
  input  logic                       S_AXI_RREADY,

  // ============================================================
  // Interrupt Output
  // ============================================================
  output logic                       irq_done
);

  // ============================================================
  // Internal clk/rst aliases
  // ============================================================
  logic clk;
  logic rst_n;
  assign clk   = S_AXI_ACLK;
  assign rst_n = S_AXI_ARESETN;

  // ============================================================
  // AXI Write FSM
  // ============================================================
  logic                      aw_ready_r, w_ready_r, b_valid_r;
  logic [AXI_ADDR_W-1:0]    aw_addr_r;

  assign S_AXI_AWREADY = aw_ready_r;
  assign S_AXI_WREADY  = w_ready_r;
  assign S_AXI_BRESP   = 2'b00;  // OKAY
  assign S_AXI_BVALID  = b_valid_r;

  // Accept write address and data simultaneously
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_ready_r <= 1'b1;
      w_ready_r  <= 1'b1;
      b_valid_r  <= 1'b0;
      aw_addr_r  <= '0;
    end else begin
      if (aw_ready_r && S_AXI_AWVALID && w_ready_r && S_AXI_WVALID) begin
        aw_addr_r  <= S_AXI_AWADDR;
        aw_ready_r <= 1'b0;
        w_ready_r  <= 1'b0;
        b_valid_r  <= 1'b1;
      end else if (b_valid_r && S_AXI_BREADY) begin
        aw_ready_r <= 1'b1;
        w_ready_r  <= 1'b1;
        b_valid_r  <= 1'b0;
      end
    end
  end

  // ============================================================
  // AXI Read FSM
  // ============================================================
  logic                      ar_ready_r, r_valid_r;
  logic [AXI_ADDR_W-1:0]    ar_addr_r;
  logic [AXI_DATA_W-1:0]    r_data_r;

  assign S_AXI_ARREADY = ar_ready_r;
  assign S_AXI_RDATA   = r_data_r;
  assign S_AXI_RRESP   = 2'b00;
  assign S_AXI_RVALID  = r_valid_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ar_ready_r <= 1'b1;
      r_valid_r  <= 1'b0;
      ar_addr_r  <= '0;
      r_data_r   <= '0;
    end else begin
      if (ar_ready_r && S_AXI_ARVALID) begin
        ar_addr_r  <= S_AXI_ARADDR;
        ar_ready_r <= 1'b0;
        r_valid_r  <= 1'b1;
        r_data_r   <= read_csr(S_AXI_ARADDR);
      end else if (r_valid_r && S_AXI_RREADY) begin
        ar_ready_r <= 1'b1;
        r_valid_r  <= 1'b0;
      end
    end
  end

  // ============================================================
  // CSR Registers
  // ============================================================
  logic [15:0]    reg_in_dim;
  logic [15:0]    reg_out_dim;
  logic [15:0]    reg_n_ib;
  logic [15:0]    reg_n_ob;
  logic [31:0]    reg_requant_mult;
  logic [31:0]    reg_requant_shift;
  logic signed [31:0] reg_input_zp;
  act_mode_t      reg_act_mode;
  logic           reg_irq_en;

  // DMA-style weight write registers
  logic [15:0]    reg_wdma_addr;
  logic [31:0]    reg_wdma_data;
  logic [3:0]     reg_wdma_chunk;
  logic           reg_wdma_wr;

  // Start/clear signals
  logic start_pulse;
  logic soft_rst_pulse;
  logic done_irq_clear;

  // ============================================================
  // Accelerator Core instantiation
  // ============================================================
  logic accel_busy, accel_done;
  logic done_sticky;
  accel_state_t accel_state;
  logic [63:0] perf_cycles, perf_macs;

  // Memory interfaces
  logic [clog2_safe(WSRAM_DEPTH)-1:0]      w_rd_tile_idx;
  logic signed [WEIGHT_W-1:0]              w_rd_tile [TILE_ROWS][TILE_COLS];
  logic [clog2_safe(BSRAM_DEPTH)-1:0]      b_rd_addr;
  logic signed [BIAS_W-1:0]                b_rd_data;
  logic [clog2_safe(MAX_IN_DIM/TILE_COLS)-1:0] ibuf_rd_tile_idx;
  logic [X_EFF_W-1:0]                      ibuf_x_eff [TILE_COLS];
  logic                                    obuf_wr_en;
  logic [clog2_safe(MAX_OUT_DIM)-1:0]      obuf_wr_addr;
  logic signed [OUTPUT_W-1:0]              obuf_wr_data;

  // Output buffer read interface (for CPU readback)
  logic [clog2_safe(MAX_OUT_DIM)-1:0]      obuf_rd_addr;
  logic signed [OUTPUT_W-1:0]              obuf_rd_data;
  logic [clog2_safe(MAX_OUT_DIM)-1:0]      pred_class;

  // Input tile for x_tile (unused directly, just x_eff)
  logic signed [INPUT_W-1:0]               ibuf_x_tile [TILE_COLS];

  cim_accel_core u_core (
    .clk              (clk),
    .rst_n            (rst_n),
    .start            (start_pulse),
    .soft_rst         (soft_rst_pulse),
    .busy             (accel_busy),
    .done             (accel_done),
    .dbg_state        (accel_state),
    .cfg_in_dim       (reg_in_dim),
    .cfg_out_dim      (reg_out_dim),
    .cfg_n_ib         (reg_n_ib),
    .cfg_n_ob         (reg_n_ob),
    .cfg_input_zp     (reg_input_zp),
    .cfg_requant_mult (reg_requant_mult),
    .cfg_requant_shift(reg_requant_shift),
    .cfg_act_mode     (reg_act_mode),
    .w_rd_tile_idx    (w_rd_tile_idx),
    .w_rd_tile        (w_rd_tile),
    .b_rd_addr        (b_rd_addr),
    .b_rd_data        (b_rd_data),
    .ibuf_rd_tile_idx (ibuf_rd_tile_idx),
    .ibuf_x_eff       (ibuf_x_eff),
    .obuf_wr_en       (obuf_wr_en),
    .obuf_wr_addr     (obuf_wr_addr),
    .obuf_wr_data     (obuf_wr_data),
    .perf_cycles      (perf_cycles),
    .perf_macs        (perf_macs)
  );

  // ============================================================
  // Memory Blocks
  // ============================================================
  weight_sram #(.DEPTH(WSRAM_DEPTH)) u_wsram (
    .clk          (clk),
    .wr_en        (reg_wdma_wr),
    .wr_tile_idx  (reg_wdma_addr[clog2_safe(WSRAM_DEPTH)-1:0]),
    .wr_chunk_idx (reg_wdma_chunk[clog2_safe(WSRAM_WORD_W/32)-1:0]),
    .wr_data      (reg_wdma_data),
    .rd_tile_idx  (w_rd_tile_idx),
    .rd_tile      (w_rd_tile)
  );

  bias_sram #(.DEPTH(BSRAM_DEPTH)) u_bsram (
    .clk     (clk),
    .wr_en   (aw_ready_r == 1'b0 && aw_addr_r >= MEM_BIAS_BASE && aw_addr_r < 12'hC00),
    .wr_addr ((aw_addr_r - MEM_BIAS_BASE) >> 2),
    .wr_data (S_AXI_WDATA),
    .rd_addr (b_rd_addr),
    .rd_data (b_rd_data)
  );

  input_buffer #(.MAX_LEN(MAX_IN_DIM)) u_ibuf (
    .clk          (clk),
    .wr_en        (aw_ready_r == 1'b0 && aw_addr_r >= MEM_INPUT_BASE && aw_addr_r < 12'h800),
    .wr_addr      ((aw_addr_r - MEM_INPUT_BASE) >> 2),
    .wr_data      (S_AXI_WDATA[INPUT_W-1:0]),
    .rd_tile_idx  (ibuf_rd_tile_idx),
    .input_zp     (reg_input_zp),
    .x_tile       (ibuf_x_tile),
    .x_eff        (ibuf_x_eff)
  );

  output_buffer #(.MAX_LEN(MAX_OUT_DIM)) u_obuf (
    .clk        (clk),
    .rst_n      (rst_n),
    .wr_en      (obuf_wr_en),
    .wr_addr    (obuf_wr_addr),
    .wr_data    (obuf_wr_data),
    .rd_addr    (obuf_rd_addr),
    .rd_data    (obuf_rd_data),
    .out_dim    (reg_out_dim[clog2_safe(MAX_OUT_DIM)-1:0]),
    .pred_class (pred_class)
  );

  // ============================================================
  // CSR Write Logic
  // ============================================================
  // Write happens when AXI write transaction completes
  wire csr_wr = (aw_ready_r == 1'b0) && (w_ready_r == 1'b0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      reg_in_dim        <= 16'd784;
      reg_out_dim       <= 16'd128;
      reg_n_ib          <= 16'd49;
      reg_n_ob          <= 16'd8;
      reg_requant_mult  <= 32'd1;
      reg_requant_shift <= 32'd0;
      reg_input_zp      <= -32'sd128;
      reg_act_mode      <= ACT_RELU;
      reg_irq_en        <= 1'b0;
      start_pulse       <= 1'b0;
      soft_rst_pulse    <= 1'b0;
      done_irq_clear    <= 1'b0;
      reg_wdma_wr       <= 1'b0;
      reg_wdma_addr     <= '0;
      reg_wdma_data     <= '0;
      reg_wdma_chunk    <= '0;
    end else begin
      // Self-clearing pulses
      start_pulse    <= 1'b0;
      soft_rst_pulse <= 1'b0;
      done_irq_clear <= 1'b0;
      reg_wdma_wr    <= 1'b0;

      if (csr_wr) begin
        case (aw_addr_r)
          CSR_CTRL: begin
            if (S_AXI_WDATA[0]) start_pulse    <= 1'b1;
            if (S_AXI_WDATA[1]) done_irq_clear <= 1'b1;
            if (S_AXI_WDATA[2]) soft_rst_pulse <= 1'b1;
          end
          CSR_IRQ_EN:        reg_irq_en        <= S_AXI_WDATA[0];
          CSR_IN_DIM:        reg_in_dim        <= S_AXI_WDATA[15:0];
          CSR_OUT_DIM:       reg_out_dim       <= S_AXI_WDATA[15:0];
          CSR_N_IB:          reg_n_ib          <= S_AXI_WDATA[15:0];
          CSR_N_OB:          reg_n_ob          <= S_AXI_WDATA[15:0];
          CSR_REQUANT_MULT:  reg_requant_mult  <= S_AXI_WDATA;
          CSR_REQUANT_SHIFT: reg_requant_shift <= S_AXI_WDATA;
          CSR_INPUT_ZP:      reg_input_zp      <= $signed(S_AXI_WDATA);
          CSR_ACT_MODE:      reg_act_mode      <= act_mode_t'(S_AXI_WDATA[1:0]);
          CSR_WDMA_ADDR:     reg_wdma_addr     <= S_AXI_WDATA[15:0];
          CSR_WDMA_DATA:     reg_wdma_data     <= S_AXI_WDATA;
          CSR_WDMA_CTRL: begin
            reg_wdma_wr    <= S_AXI_WDATA[0];
            reg_wdma_chunk <= S_AXI_WDATA[7:4];
          end
          default: ;  // input/bias windows handled by memory blocks directly
        endcase
      end
    end
  end

  // ============================================================
  // Done Sticky + IRQ
  // ============================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      done_sticky <= 1'b0;
    end else begin
      if (done_irq_clear || soft_rst_pulse)
        done_sticky <= 1'b0;
      else if (accel_done)
        done_sticky <= 1'b1;
    end
  end

  assign irq_done = done_sticky & reg_irq_en;

  // ============================================================
  // CSR Read Logic
  // ============================================================
  // Output buffer read address derived from AXI read address
  assign obuf_rd_addr = (ar_addr_r >= CSR_LOGIT_BASE)
                        ? ((ar_addr_r - CSR_LOGIT_BASE) >> 2)
                        : '0;

  function automatic logic [31:0] read_csr(input logic [AXI_ADDR_W-1:0] addr);
    case (addr)
      CSR_CTRL:          return 32'd0;  // write-only
      CSR_STATUS:        return {24'd0, accel_state, done_sticky, accel_busy};
      CSR_IRQ_EN:        return {31'd0, reg_irq_en};
      CSR_IRQ_STATUS:    return {31'd0, done_sticky};
      CSR_IN_DIM:        return {16'd0, reg_in_dim};
      CSR_OUT_DIM:       return {16'd0, reg_out_dim};
      CSR_N_IB:          return {16'd0, reg_n_ib};
      CSR_N_OB:          return {16'd0, reg_n_ob};
      CSR_REQUANT_MULT:  return reg_requant_mult;
      CSR_REQUANT_SHIFT: return reg_requant_shift;
      CSR_INPUT_ZP:      return reg_input_zp;
      CSR_ACT_MODE:      return {30'd0, reg_act_mode};
      CSR_CYCLE_CNT_LO:  return perf_cycles[31:0];
      CSR_CYCLE_CNT_HI:  return perf_cycles[63:32];
      CSR_MAC_CNT_LO:    return perf_macs[31:0];
      CSR_MAC_CNT_HI:    return perf_macs[63:32];
      CSR_PRED_CLASS:     return {22'd0, pred_class};
      default: begin
        // Logit readback window
        if (addr >= CSR_LOGIT_BASE && addr < MEM_INPUT_BASE)
          return {{(32-OUTPUT_W){obuf_rd_data[OUTPUT_W-1]}}, obuf_rd_data};
        else
          return 32'hDEAD_BEEF;
      end
    endcase
  endfunction

endmodule
