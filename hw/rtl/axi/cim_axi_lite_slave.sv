// ============================================================================
// cim_axi_lite_slave.sv — AXI4-Lite Slave Interface for CIM Accelerator IP
// ============================================================================
// FIXES vs previous version:
//   FIX2: AW/W channels now accept independently (AW-first, W-first, or
//         simultaneous). Fully AXI4-Lite compliant.
//   FIX3: Weight DMA adds auto-increment burst mode. Write CSR_WDMA_CTRL
//         with bit[1]=1 to enable auto-increment of chunk_idx (and tile_idx
//         wrap). This allows SW to just stream CSR_WDMA_DATA writes.
//   FIX5: CSR read path uses a 2-cycle pipeline for output buffer reads.
//         First cycle latches the address and issues obuf_rd_addr.
//         Second cycle captures obuf_rd_data into r_data_r.
// ============================================================================

module cim_axi_lite_slave
  import cim_pkg::*;
#(
  parameter int AXI_ADDR_W = 12,
  parameter int AXI_DATA_W = 32
) (
  // AXI4-Lite Slave Interface
  input  logic                       S_AXI_ACLK,
  input  logic                       S_AXI_ARESETN,

  input  logic [AXI_ADDR_W-1:0]     S_AXI_AWADDR,
  input  logic [2:0]                 S_AXI_AWPROT,
  input  logic                       S_AXI_AWVALID,
  output logic                       S_AXI_AWREADY,

  input  logic [AXI_DATA_W-1:0]     S_AXI_WDATA,
  input  logic [AXI_DATA_W/8-1:0]   S_AXI_WSTRB,
  input  logic                       S_AXI_WVALID,
  output logic                       S_AXI_WREADY,

  output logic [1:0]                 S_AXI_BRESP,
  output logic                       S_AXI_BVALID,
  input  logic                       S_AXI_BREADY,

  input  logic [AXI_ADDR_W-1:0]     S_AXI_ARADDR,
  input  logic [2:0]                 S_AXI_ARPROT,
  input  logic                       S_AXI_ARVALID,
  output logic                       S_AXI_ARREADY,

  output logic [AXI_DATA_W-1:0]     S_AXI_RDATA,
  output logic [1:0]                 S_AXI_RRESP,
  output logic                       S_AXI_RVALID,
  input  logic                       S_AXI_RREADY,

  output logic                       irq_done
);

  logic clk, rst_n;
  assign clk   = S_AXI_ACLK;
  assign rst_n = S_AXI_ARESETN;

  // ============================================================
  // FIX2: AXI Write FSM — independent AW/W acceptance
  // ============================================================
  // State: track whether AW and W have been received independently
  logic aw_received, w_received;
  logic [AXI_ADDR_W-1:0] aw_addr_r;
  logic [AXI_DATA_W-1:0] w_data_r;
  logic b_valid_r;

  assign S_AXI_AWREADY = !aw_received && !b_valid_r;
  assign S_AXI_WREADY  = !w_received  && !b_valid_r;
  assign S_AXI_BRESP   = 2'b00;
  assign S_AXI_BVALID  = b_valid_r;

  // Write transaction fires when both AW and W have been captured
  wire wr_fire = aw_received && w_received && !b_valid_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_received <= 1'b0;
      w_received  <= 1'b0;
      b_valid_r   <= 1'b0;
      aw_addr_r   <= '0;
      w_data_r    <= '0;
    end else begin
      // Accept AW independently
      if (S_AXI_AWVALID && S_AXI_AWREADY) begin
        aw_addr_r   <= S_AXI_AWADDR;
        aw_received <= 1'b1;
      end
      // Accept W independently
      if (S_AXI_WVALID && S_AXI_WREADY) begin
        w_data_r    <= S_AXI_WDATA;
        w_received  <= 1'b1;
      end
      // Both received → issue write response
      if (aw_received && w_received && !b_valid_r) begin
        b_valid_r <= 1'b1;
      end
      // Response accepted → back to idle
      if (b_valid_r && S_AXI_BREADY) begin
        aw_received <= 1'b0;
        w_received  <= 1'b0;
        b_valid_r   <= 1'b0;
      end
    end
  end

  // ============================================================
  // FIX5: AXI Read FSM — 2-cycle pipeline for BRAM reads
  // ============================================================
  typedef enum logic [1:0] {
    RD_IDLE    = 2'd0,
    RD_WAIT    = 2'd1,   // BRAM read latency cycle
    RD_RESPOND = 2'd2
  } rd_state_t;

  rd_state_t rd_state;
  logic [AXI_ADDR_W-1:0] ar_addr_r;
  logic [AXI_DATA_W-1:0] r_data_r;

  assign S_AXI_ARREADY = (rd_state == RD_IDLE);
  assign S_AXI_RDATA   = r_data_r;
  assign S_AXI_RRESP   = 2'b00;
  assign S_AXI_RVALID  = (rd_state == RD_RESPOND);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_state  <= RD_IDLE;
      ar_addr_r <= '0;
      r_data_r  <= '0;
    end else begin
      case (rd_state)
        RD_IDLE: begin
          if (S_AXI_ARVALID) begin
            ar_addr_r <= S_AXI_ARADDR;
            rd_state  <= RD_WAIT;
          end
        end
        RD_WAIT: begin
          // BRAM data is now valid on obuf_rd_data; latch everything
          r_data_r <= read_csr_fn(ar_addr_r);
          rd_state <= RD_RESPOND;
        end
        RD_RESPOND: begin
          if (S_AXI_RREADY) begin
            rd_state <= RD_IDLE;
          end
        end
        default: rd_state <= RD_IDLE;
      endcase
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
  // FIX3: burst mode — auto-increment chunk/tile
  logic           reg_wdma_burst;

  // Start/clear signals
  logic start_pulse;
  logic soft_rst_pulse;
  logic done_irq_clear;

  // ============================================================
  // Accelerator Core
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

  logic [clog2_safe(MAX_OUT_DIM)-1:0]      obuf_rd_addr;
  logic signed [OUTPUT_W-1:0]              obuf_rd_data;
  logic [clog2_safe(MAX_OUT_DIM)-1:0]      pred_class;

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

  // Bias/Input/Output write enable signals from AXI write path
  wire bias_wr_hit  = wr_fire && (aw_addr_r >= MEM_BIAS_BASE)  && (aw_addr_r < 12'hC00);
  wire input_wr_hit = wr_fire && (aw_addr_r >= MEM_INPUT_BASE) && (aw_addr_r < 12'h800);

  bias_sram #(.DEPTH(BSRAM_DEPTH)) u_bsram (
    .clk     (clk),
    .wr_en   (bias_wr_hit),
    .wr_addr ((aw_addr_r - MEM_BIAS_BASE) >> 2),
    .wr_data (w_data_r),
    .rd_addr (b_rd_addr),
    .rd_data (b_rd_data)
  );

  input_buffer #(.MAX_LEN(MAX_IN_DIM)) u_ibuf (
    .clk          (clk),
    .wr_en        (input_wr_hit),
    .wr_addr      ((aw_addr_r - MEM_INPUT_BASE) >> 2),
    .wr_data      (w_data_r[INPUT_W-1:0]),
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

  // FIX5: Output buffer read address — set one cycle early (RD_IDLE or RD_WAIT)
  // In RD_IDLE, use the incoming ARADDR directly for minimum latency.
  // In RD_WAIT, use the latched ar_addr_r.
  always_comb begin
    if (rd_state == RD_IDLE && S_AXI_ARVALID && S_AXI_ARADDR >= CSR_LOGIT_BASE)
      obuf_rd_addr = (S_AXI_ARADDR - CSR_LOGIT_BASE) >> 2;
    else if (ar_addr_r >= CSR_LOGIT_BASE)
      obuf_rd_addr = (ar_addr_r - CSR_LOGIT_BASE) >> 2;
    else
      obuf_rd_addr = '0;
  end

  // ============================================================
  // CSR Write Logic — fires on wr_fire
  // ============================================================
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
      reg_wdma_burst    <= 1'b0;
    end else begin
      // Self-clearing pulses
      start_pulse    <= 1'b0;
      soft_rst_pulse <= 1'b0;
      done_irq_clear <= 1'b0;
      reg_wdma_wr    <= 1'b0;

      if (wr_fire) begin
        case (aw_addr_r)
          CSR_CTRL: begin
            if (w_data_r[0]) start_pulse    <= 1'b1;
            if (w_data_r[1]) done_irq_clear <= 1'b1;
            if (w_data_r[2]) soft_rst_pulse <= 1'b1;
          end
          CSR_IRQ_EN:        reg_irq_en        <= w_data_r[0];
          CSR_IN_DIM:        reg_in_dim        <= w_data_r[15:0];
          CSR_OUT_DIM:       reg_out_dim       <= w_data_r[15:0];
          CSR_N_IB:          reg_n_ib          <= w_data_r[15:0];
          CSR_N_OB:          reg_n_ob          <= w_data_r[15:0];
          CSR_REQUANT_MULT:  reg_requant_mult  <= w_data_r;
          CSR_REQUANT_SHIFT: reg_requant_shift <= w_data_r;
          CSR_INPUT_ZP:      reg_input_zp      <= $signed(w_data_r);
          CSR_ACT_MODE:      reg_act_mode      <= act_mode_t'(w_data_r[1:0]);
          CSR_WDMA_ADDR:     reg_wdma_addr     <= w_data_r[15:0];
          CSR_WDMA_DATA: begin
            reg_wdma_data <= w_data_r;
            // FIX3: In burst mode, auto-fire write + auto-increment
            if (reg_wdma_burst) begin
              reg_wdma_wr <= 1'b1;
              // Auto-increment chunk, wrap to next tile
              if (reg_wdma_chunk == (TILE_ROWS * TILE_COLS / (32/WEIGHT_W)) - 1) begin
                reg_wdma_chunk <= '0;
                reg_wdma_addr  <= reg_wdma_addr + 16'd1;
              end else begin
                reg_wdma_chunk <= reg_wdma_chunk + 4'd1;
              end
            end
          end
          CSR_WDMA_CTRL: begin
            reg_wdma_wr    <= w_data_r[0];
            reg_wdma_burst <= w_data_r[1];  // FIX3: bit[1] = burst enable
            reg_wdma_chunk <= w_data_r[7:4];
          end
          default: ;  // input/bias windows handled by memory blocks
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
  // FIX5: CSR Read Function — now called in RD_WAIT when BRAM
  // data is valid. obuf_rd_data is the registered output from
  // the address set in the previous cycle.
  // ============================================================
  function automatic logic [31:0] read_csr_fn(input logic [AXI_ADDR_W-1:0] addr);
    case (addr)
      CSR_CTRL:          return 32'd0;
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
      CSR_PRED_CLASS:    return {22'd0, pred_class};
      default: begin
        if (addr >= CSR_LOGIT_BASE && addr < MEM_INPUT_BASE)
          return {{(32-OUTPUT_W){obuf_rd_data[OUTPUT_W-1]}}, obuf_rd_data};
        else
          return 32'hDEAD_BEEF;
      end
    endcase
  endfunction

endmodule
