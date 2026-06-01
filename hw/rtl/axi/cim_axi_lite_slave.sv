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
    parameter int AXI_ADDR_W = 14,
    parameter int AXI_DATA_W = 32
) (
    // AXI4-Lite Slave Interface
    input logic S_AXI_ACLK,
    input logic S_AXI_ARESETN,

    input  logic [AXI_ADDR_W-1:0] S_AXI_AWADDR,
    input  logic [           2:0] S_AXI_AWPROT,
    input  logic                  S_AXI_AWVALID,
    output logic                  S_AXI_AWREADY,

    input  logic [  AXI_DATA_W-1:0] S_AXI_WDATA,
    input  logic [AXI_DATA_W/8-1:0] S_AXI_WSTRB,
    input  logic                    S_AXI_WVALID,
    output logic                    S_AXI_WREADY,

    output logic [1:0] S_AXI_BRESP,
    output logic       S_AXI_BVALID,
    input  logic       S_AXI_BREADY,

    input  logic [AXI_ADDR_W-1:0] S_AXI_ARADDR,
    input  logic [           2:0] S_AXI_ARPROT,
    input  logic                  S_AXI_ARVALID,
    output logic                  S_AXI_ARREADY,

    output logic [AXI_DATA_W-1:0] S_AXI_RDATA,
    output logic [           1:0] S_AXI_RRESP,
    output logic                  S_AXI_RVALID,
    input  logic                  S_AXI_RREADY,

    output logic irq_done,

    // C3 stream-sink side-band interface (wired by cim_top, unused in legacy BD)
    // CTRL[3]=0 → legacy MMIO data path only, all outputs below are inert.
    output logic        stream_path_en,
    output logic [ 1:0] cfg_dest,
    output logic [15:0] cfg_len,
    output logic [15:0] cfg_base_addr,
    output logic        cfg_continue,    // 0=reset addr ptrs, 1=continue from current position
    output logic        cfg_start,       // 1-cycle pulse on CSR_STREAM_LEN write
    output logic        status_clear,    // 1-cycle pulse on CSR_STREAM_STATUS write
    input  logic        stream_busy,
    input  logic        stream_done,
    input  logic        stream_overflow,
    input  logic        stream_underflow,

    // C3 stream-sink write ports — MUXed into weight_sram / input_buffer / bias_sram
    // when reg_stream_path_en==1 (CTRL[3]=1). Tied 0 in legacy BD.
    input logic                                              stream_wsram_wr_en,
    input logic [      $clog2(cim_pkg::TILE_ROWS)-1:0]       stream_wsram_wr_row,
    input logic [clog2_safe(cim_pkg::WSRAM_DEPTH)-1:0]       stream_wsram_wr_tile_idx,
    input logic [cim_pkg::TILE_COLS*cim_pkg::WEIGHT_W-1:0]   stream_wsram_wr_row_data,
    input logic                                              stream_ibuf_wr_en,
    input logic [clog2_safe(cim_pkg::MAX_IN_DIM/cim_pkg::TILE_COLS)-1:0]
                                                             stream_ibuf_wr_tile_idx,
    input logic [cim_pkg::TILE_COLS*cim_pkg::INPUT_W-1:0]    stream_ibuf_wr_tile_data,
    input logic                                              stream_bsram_wr_en,
    input logic [clog2_safe(cim_pkg::BSRAM_DEPTH)-1:0]       stream_bsram_wr_addr,
    input logic [                                   31:0]    stream_bsram_wr_data,

    // P0: AXI4-Stream master for result read-back (→ axi_dma S_AXIS_S2MM)
    output logic [AXI_DATA_W-1:0]                             M_AXIS_RESULT_TDATA,
    output logic                                              M_AXIS_RESULT_TVALID,
    input  logic                                              M_AXIS_RESULT_TREADY,
    output logic                                              M_AXIS_RESULT_TLAST
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
  assign S_AXI_WREADY  = !w_received && !b_valid_r;
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
        w_data_r   <= S_AXI_WDATA;
        w_received <= 1'b1;
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
  logic        [15:0] reg_in_dim;
  logic        [15:0] reg_out_dim;
  logic        [15:0] reg_n_ib;
  logic        [15:0] reg_n_ob;
  logic        [31:0] reg_requant_mult;
  logic        [31:0] reg_requant_shift;
  logic signed [31:0] reg_input_zp;
  act_mode_t          reg_act_mode;
  logic               reg_irq_en;

  // DMA-style weight write registers
  logic        [15:0] reg_wdma_addr;
  logic        [31:0] reg_wdma_data;
  // FIX: chunk index needs clog2(TILE_ROWS * TILE_COLS / (32/WEIGHT_W)) = clog2(64) = 6 bits
  localparam int CHUNK_IDX_W = clog2_safe(TILE_ROWS * TILE_COLS / (32 / WEIGHT_W));  // 6
  localparam int IBUF_TILE_W = TILE_COLS * INPUT_W;  // 128
  logic [CHUNK_IDX_W-1:0] reg_wdma_chunk;
  logic                   reg_wdma_wr;
  // FIX3: burst mode — auto-increment chunk/tile
  logic                   reg_wdma_burst;
  logic                   burst_inc_pending;  // delayed auto-increment

  // Start/clear signals
  logic                   start_pulse;
  logic                   soft_rst_pulse;
  logic                   done_irq_clear;

  // C3 stream-sink CSR shadow state
  logic                   reg_stream_path_en;
  logic [         1:0]    reg_stream_dest;
  logic [        15:0]    reg_stream_len;
  logic [        15:0]    reg_stream_base_addr;
  logic                   reg_stream_continue;
  logic                   cfg_start_r;
  logic                   cfg_start_pending;  // Delay cfg_start by 1 cycle
  logic                   status_clear_r;

  // P0: result stream CSRs
  logic [15:0]           reg_result_len;
  logic                  result_start_pulse_r;

  // Phase B: ping-pong bank select
  logic                  reg_ping_ctrl;

  // Phase C: multi-layer base offsets
  logic [clog2_safe(WSRAM_DEPTH)-1:0] reg_weight_base;
  logic [clog2_safe(BSRAM_DEPTH)-1:0] reg_bias_base;

  // Phase C: Layer Fusion — OBUF→IBUF direct copy
  // v7: F_WAIT_MUX captures byte 0 (rd_data valid at posedge after MUX NBA),
  //     then transitions directly to F_PACK. Eliminates F_RD_FIRST.
  typedef enum logic [2:0] {
    F_IDLE, F_WAIT_MUX, F_PACK, F_WRITE
  } fusion_state_t;
  fusion_state_t fusion_state;
  logic                  fusion_start_pulse;
  logic                  fusion_busy;
  logic                  fusion_done_sticky;
  logic [         15:0]  reg_fusion_len;
  logic [         15:0]  fusion_cnt;           // bytes packed so far (0..len)
  logic [          3:0]  fusion_byte_in_tile;  // position within current tile (0..15)
  logic [        127:0]  fusion_tile_buf;
  logic                  fusion_tile_wr;       // pulse: write tile to IBUF
  logic [clog2_safe(MAX_IN_DIM/TILE_COLS)-1:0] fusion_tile_idx;
  logic [clog2_safe(MAX_OUT_DIM)-1:0]          fusion_obuf_addr;
  logic                  fusion_last_byte;     // flag: current byte is last
  logic                  fusion_tile_full;     // flag: tile complete after current byte
  logic [         15:0]  fusion_cycle_cnt;     // debug: cycles spent in fusion FSM
  logic [          7:0]  fusion_wr_cnt;        // debug: number of tile writes

  // Pipeline registers for IBUF write timing closure
  logic                  fusion_wr_en_pipe;
  logic [clog2_safe(MAX_IN_DIM/TILE_COLS)-1:0] fusion_wr_tile_pipe;
  logic [            IBUF_TILE_W-1:0]           fusion_wr_data_pipe;

  assign stream_path_en = reg_stream_path_en;
  assign cfg_dest       = reg_stream_dest;
  assign cfg_len        = reg_stream_len;
  assign cfg_base_addr  = reg_stream_base_addr;
  assign cfg_continue   = reg_stream_continue;
  assign cfg_start      = cfg_start_r;
  assign status_clear   = status_clear_r;

  // ============================================================
  // Accelerator Core
  // ============================================================
  logic accel_busy, accel_done;
  logic done_sticky;
  accel_state_t accel_state;
  logic [63:0] perf_cycles, perf_macs;

  // Memory interfaces
  logic        [         clog2_safe(WSRAM_DEPTH)-1:0] w_rd_tile_idx;
  logic signed [                        WEIGHT_W-1:0] w_rd_tile        [TILE_ROWS] [TILE_COLS];
  logic        [         clog2_safe(BSRAM_DEPTH)-1:0] b_rd_addr;
  logic signed [                          BIAS_W-1:0] b_rd_data;
  logic        [clog2_safe(MAX_IN_DIM/TILE_COLS)-1:0] ibuf_rd_tile_idx;
  logic        [                         X_EFF_W-1:0] ibuf_x_eff       [TILE_COLS];
  logic                                               obuf_wr_en;
  logic        [         clog2_safe(MAX_OUT_DIM)-1:0] obuf_wr_addr;
  logic signed [                        OUTPUT_W-1:0] obuf_wr_data;

  logic        [         clog2_safe(MAX_OUT_DIM)-1:0] obuf_rd_addr;
  logic signed [                        OUTPUT_W-1:0] obuf_rd_data;
  logic        [         clog2_safe(MAX_OUT_DIM)-1:0] pred_class;

  logic        [                         INPUT_W-1:0] ibuf_x_tile      [TILE_COLS];

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
      .cfg_weight_base  (reg_weight_base),
      .cfg_bias_base    (reg_bias_base),
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
  // Memory Blocks — with staging registers for BRAM-friendly writes
  // ============================================================
  // Vivado BRAM inference requires PURE whole-word writes.
  // We assemble partial writes in staging registers here,
  // then write the full word to BRAM in one shot.

  // ---- Weight SRAM: staging register for row assembly ----
  // Each row = TILE_COLS * WEIGHT_W = 128 bits = 4 chunks of 32 bits.
  // chunk_idx encodes (row, col_group): row = chunk_idx / 4, col_group = chunk_idx % 4.
  // When col_group == 3 (last chunk of a row), commit the full 128-bit row to BRAM.
  localparam int CHUNKS_PER_ROW = TILE_COLS / (32 / WEIGHT_W);  // 4
  localparam int ROW_W = TILE_COLS * WEIGHT_W;  // 128
  localparam int CG_BITS = $clog2(CHUNKS_PER_ROW);  // 2
  localparam int ROW_BITS_W = $clog2(TILE_ROWS);  // 4

  logic [                  ROW_W-1:0] wsram_staging;  // 128-bit staging register
  logic                               wsram_commit;  // pulse: write full row to BRAM
  logic [      $clog2(TILE_ROWS)-1:0] wsram_commit_row;  // which row to write
  logic [clog2_safe(WSRAM_DEPTH)-1:0] wsram_commit_tile;  // which tile

  // Fill staging register on each chunk write
  wire  [                CG_BITS-1:0] wdma_col_group = reg_wdma_chunk[CG_BITS-1:0];
  wire  [             ROW_BITS_W-1:0] wdma_row = reg_wdma_chunk[CG_BITS+:ROW_BITS_W];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wsram_staging   <= '0;
      wsram_commit    <= 1'b0;
      wsram_commit_row  <= '0;
      wsram_commit_tile <= '0;
    end else begin
      wsram_commit <= 1'b0;  // self-clearing

      if (reg_wdma_wr) begin
        // Place 32-bit chunk into correct position of staging register
        case (wdma_col_group)
          2'd0: wsram_staging[31:0] <= reg_wdma_data;
          2'd1: wsram_staging[63:32] <= reg_wdma_data;
          2'd2: wsram_staging[95:64] <= reg_wdma_data;
          2'd3: wsram_staging[127:96] <= reg_wdma_data;
        endcase

        // When last col_group is written, commit full row
        if (wdma_col_group == CG_BITS'(CHUNKS_PER_ROW - 1)) begin
          wsram_commit      <= 1'b1;
          wsram_commit_row  <= wdma_row;
          wsram_commit_tile <= reg_wdma_addr[clog2_safe(WSRAM_DEPTH)-1:0];
        end
      end
    end
  end

  // C3 MUX: when reg_stream_path_en (CTRL[3]=1) → stream sink drives writes;
  // otherwise legacy MMIO staging path. Selection is reg_stream_path_en, a
  // mode bit that changes rarely (only between full layer uploads), so no
  // glitch hazard at the SRAM write port.
  logic                                 wsram_wr_en_mux;
  logic [      $clog2(TILE_ROWS)-1:0]   wsram_wr_row_mux;
  logic [clog2_safe(WSRAM_DEPTH)-1:0]   wsram_wr_tile_mux;
  logic [                 ROW_W-1:0]    wsram_wr_data_mux;

  assign wsram_wr_en_mux   = reg_stream_path_en ? stream_wsram_wr_en       : wsram_commit;
  assign wsram_wr_row_mux  = reg_stream_path_en ? stream_wsram_wr_row      : wsram_commit_row;
  assign wsram_wr_tile_mux = reg_stream_path_en ? stream_wsram_wr_tile_idx : wsram_commit_tile;
  assign wsram_wr_data_mux = reg_stream_path_en ? stream_wsram_wr_row_data : wsram_staging;

  weight_sram #(
      .DEPTH(WSRAM_DEPTH)
  ) u_wsram (
      .clk        (clk),
      .wr_en      (wsram_wr_en_mux),
      .wr_row     (wsram_wr_row_mux),
      .wr_tile_idx(wsram_wr_tile_mux),
      .wr_row_data(wsram_wr_data_mux),
      .rd_tile_idx(w_rd_tile_idx),
      .rd_tile    (w_rd_tile)
  );

  // ---- Input Buffer: staging register for tile assembly ----
  // Each tile = TILE_COLS * INPUT_W = 128 bits = 16 bytes.
  // AXI writes one byte at a time to flat address (MEM_INPUT_BASE + 4*i).
  // Staging register accumulates 16 bytes, commits when byte 15 is written.
  localparam int IBUF_DEPTH = (MAX_IN_DIM + TILE_COLS - 1) / TILE_COLS;
  localparam int IBUF_COL_BITS = $clog2(TILE_COLS);  // 4

  logic [IBUF_TILE_W-1:0] ibuf_staging;
  logic ibuf_commit;
  logic [clog2_safe(MAX_IN_DIM/TILE_COLS)-1:0] ibuf_commit_tile;

  wire input_wr_hit = wr_fire && (aw_addr_r >= MEM_INPUT_BASE) && (aw_addr_r < MEM_BIAS_BASE);
  wire [13:0] input_flat_addr = (aw_addr_r - MEM_INPUT_BASE) >> 2;  // byte index
  wire [IBUF_COL_BITS-1:0] ibuf_byte_pos = input_flat_addr[IBUF_COL_BITS-1:0];
  wire [clog2_safe(
MAX_IN_DIM/TILE_COLS
)-1:0] ibuf_tile_addr = input_flat_addr[IBUF_COL_BITS+:clog2_safe(
      MAX_IN_DIM/TILE_COLS
  )];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ibuf_staging     <= '0;
      ibuf_commit      <= 1'b0;
      ibuf_commit_tile <= '0;
    end else begin
      ibuf_commit <= 1'b0;

      if (input_wr_hit) begin
        // Place byte into correct position
        case (ibuf_byte_pos)
          4'd0:  ibuf_staging[7:0] <= w_data_r[INPUT_W-1:0];
          4'd1:  ibuf_staging[15:8] <= w_data_r[INPUT_W-1:0];
          4'd2:  ibuf_staging[23:16] <= w_data_r[INPUT_W-1:0];
          4'd3:  ibuf_staging[31:24] <= w_data_r[INPUT_W-1:0];
          4'd4:  ibuf_staging[39:32] <= w_data_r[INPUT_W-1:0];
          4'd5:  ibuf_staging[47:40] <= w_data_r[INPUT_W-1:0];
          4'd6:  ibuf_staging[55:48] <= w_data_r[INPUT_W-1:0];
          4'd7:  ibuf_staging[63:56] <= w_data_r[INPUT_W-1:0];
          4'd8:  ibuf_staging[71:64] <= w_data_r[INPUT_W-1:0];
          4'd9:  ibuf_staging[79:72] <= w_data_r[INPUT_W-1:0];
          4'd10: ibuf_staging[87:80] <= w_data_r[INPUT_W-1:0];
          4'd11: ibuf_staging[95:88] <= w_data_r[INPUT_W-1:0];
          4'd12: ibuf_staging[103:96] <= w_data_r[INPUT_W-1:0];
          4'd13: ibuf_staging[111:104] <= w_data_r[INPUT_W-1:0];
          4'd14: ibuf_staging[119:112] <= w_data_r[INPUT_W-1:0];
          4'd15: ibuf_staging[127:120] <= w_data_r[INPUT_W-1:0];
        endcase

        // Commit when last byte of tile is written
        if (ibuf_byte_pos == IBUF_COL_BITS'(TILE_COLS - 1)) begin
          ibuf_commit      <= 1'b1;
          ibuf_commit_tile <= ibuf_tile_addr;
        end
      end
    end
  end

  // C3 / Phase C MUX: input buffer write path
  // Priority: Fusion > stream sink > legacy MMIO
  logic                                                  ibuf_wr_en_mux;
  logic [clog2_safe(MAX_IN_DIM/TILE_COLS)-1:0]           ibuf_wr_tile_mux;
  logic [                            IBUF_TILE_W-1:0]    ibuf_wr_data_mux;

  assign ibuf_wr_en_mux   = fusion_wr_en_pipe || (reg_stream_path_en ? stream_ibuf_wr_en       : ibuf_commit);
  assign ibuf_wr_tile_mux = fusion_wr_en_pipe ? fusion_wr_tile_pipe :
                            (reg_stream_path_en ? stream_ibuf_wr_tile_idx : ibuf_commit_tile);
  assign ibuf_wr_data_mux = fusion_wr_en_pipe ? fusion_wr_data_pipe :
                            (reg_stream_path_en ? stream_ibuf_wr_tile_data: ibuf_staging);

  input_buffer #(
      .MAX_LEN(MAX_IN_DIM)
  ) u_ibuf (
      .clk         (clk),
      .wr_en       (ibuf_wr_en_mux),
      .wr_tile_idx (ibuf_wr_tile_mux),
      .wr_tile_data(ibuf_wr_data_mux),
      .wr_bank_sel (~reg_ping_ctrl),
      .rd_bank_sel (reg_ping_ctrl),
      .rd_tile_idx (ibuf_rd_tile_idx),
      .input_zp    (reg_input_zp),
      .x_tile      (ibuf_x_tile),
      .x_eff       (ibuf_x_eff)
  );

  // ---- Bias SRAM: already whole-word (32-bit), no staging needed ----
  wire bias_wr_hit = wr_fire && (aw_addr_r >= MEM_BIAS_BASE) && (aw_addr_r < MEM_BIAS_BASE + 14'h400);
  wire [clog2_safe(BSRAM_DEPTH)-1:0] legacy_bsram_wr_addr =
      (aw_addr_r - MEM_BIAS_BASE) >> 2;

  // C3 MUX: bias sram write path
  logic                                bsram_wr_en_mux;
  logic [clog2_safe(BSRAM_DEPTH)-1:0]  bsram_wr_addr_mux;
  logic [                        31:0] bsram_wr_data_mux;

  assign bsram_wr_en_mux   = reg_stream_path_en ? stream_bsram_wr_en   : bias_wr_hit;
  assign bsram_wr_addr_mux = reg_stream_path_en ? stream_bsram_wr_addr : legacy_bsram_wr_addr;
  assign bsram_wr_data_mux = reg_stream_path_en ? stream_bsram_wr_data : w_data_r;

  bias_sram #(
      .DEPTH(BSRAM_DEPTH)
  ) u_bsram (
      .clk    (clk),
      .wr_en  (bsram_wr_en_mux),
      .wr_addr(bsram_wr_addr_mux),
      .wr_data(bsram_wr_data_mux),
      .rd_addr(b_rd_addr),
      .rd_data(b_rd_data)
  );

  output_buffer #(
      .MAX_LEN(MAX_OUT_DIM)
  ) u_obuf (
      .clk       (clk),
      .rst_n     (rst_n),
      .wr_en     (obuf_wr_en),
      .wr_addr   (obuf_wr_addr),
      .wr_data   (obuf_wr_data),
      .wr_bank_sel (reg_ping_ctrl),
      .rd_bank_sel (~reg_ping_ctrl),
      .rd_addr   (obuf_rd_addr),
      .rd_data   (obuf_rd_data),
      .out_dim   (reg_out_dim[clog2_safe(MAX_OUT_DIM)-1:0]),
      .pred_class(pred_class)
  );

  // P0: result stream source signals
  logic                                    result_busy, result_done;
  logic [clog2_safe(MAX_OUT_DIM)-1:0]      src_obuf_rd_addr;

  // P0: cim_axi_stream_source — read output_buffer, stream via M_AXIS_RESULT
  cim_axi_stream_source #(
      .DATA_W(32),
      .OBUF_ADDR_W(clog2_safe(MAX_OUT_DIM))
  ) u_result_source (
      .clk            (clk),
      .rst_n          (rst_n),
      .m_axis_tdata   (M_AXIS_RESULT_TDATA),
      .m_axis_tvalid  (M_AXIS_RESULT_TVALID),
      .m_axis_tready  (M_AXIS_RESULT_TREADY),
      .m_axis_tlast   (M_AXIS_RESULT_TLAST),
      .cfg_len        (reg_result_len),
      .cfg_start      (result_start_pulse_r),
      .busy           (result_busy),
      .done           (result_done),
      .obuf_rd_addr   (src_obuf_rd_addr),
      .obuf_rd_data   (obuf_rd_data)
  );

  // FIX5 / Phase C: Output buffer read address mux
  // Priority: Fusion > P0 result source > AXI CSR reads
  always_comb begin
    if (fusion_busy)
      obuf_rd_addr = fusion_obuf_addr;
    else if (result_busy)
      obuf_rd_addr = src_obuf_rd_addr;
    else if (rd_state == RD_IDLE && S_AXI_ARVALID && S_AXI_ARADDR >= CSR_LOGIT_BASE)
      obuf_rd_addr = (S_AXI_ARADDR - CSR_LOGIT_BASE) >> 2;
    else if (ar_addr_r >= CSR_LOGIT_BASE) obuf_rd_addr = (ar_addr_r - CSR_LOGIT_BASE) >> 2;
    else obuf_rd_addr = '0;
  end

  // ============================================================
  // Phase C: Layer Fusion FSM — OBUF → IBUF direct copy
  // ============================================================
  // Reads OBUF byte-by-byte from the DMA-accessible bank (~reg_ping_ctrl),
  // packs 16 bytes into each 128-bit IBUF tile word, writes to the
  // DMA-writable IBUF bank (~reg_ping_ctrl). After copy, software must
  // toggle reg_ping_ctrl so compute reads from the newly-written bank.
  //
  // OBUF read pipeline (registered BRAM + NBA addr advance):
  //   OBUF BRAM read is registered (always_ff): rd_data <= bank[rd_addr].
  //   rd_data lags rd_addr by 1 cycle. To avoid duplicate reads, addr must
  //   be incremented in the SAME cycle that captures the current byte.
  //
  //   Invariant: at the start of each capture cycle (F_PACK), addr = byte_idx + 1.
  //
  //   F_IDLE:     addr=0. fusion_busy=1 (NBA).
  //   F_WAIT_MUX: OBUF reads bank[0] at addr=0 (→ rd_data ready next cycle).
  //               Advance addr: 0→1. → F_PACK.
  //   F_PACK:     rd_data = bank[byte_idx]. Capture into tile_buf.
  //               Advance addr: N→N+1 (unless tile full).
  //               If tile full or last byte → F_WRITE, else loop F_PACK.
  //   F_WRITE:    Commit 128-bit tile to IBUF. Advance addr by 1.
  //               If not done → F_PACK (addr is now byte_idx+1 for next tile).
  // ============================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fusion_state        <= F_IDLE;
      fusion_busy         <= 1'b0;
      fusion_done_sticky  <= 1'b0;
      fusion_cnt          <= 16'd0;
      fusion_byte_in_tile <= 4'd0;
      fusion_tile_buf     <= 128'd0;
      fusion_tile_wr      <= 1'b0;
      fusion_tile_idx     <= '0;
      fusion_obuf_addr    <= '0;
      fusion_last_byte    <= 1'b0;
      fusion_tile_full    <= 1'b0;
      fusion_cycle_cnt   <= 16'd0;
      fusion_wr_cnt      <= 8'd0;
      fusion_wr_en_pipe  <= 1'b0;
      fusion_wr_data_pipe <= 128'd0;
      fusion_wr_tile_pipe <= '0;
    end else begin
      fusion_tile_wr <= 1'b0;  // self-clearing

      // Debug: count cycles and tile writes
      if (fusion_busy) fusion_cycle_cnt <= fusion_cycle_cnt + 16'd1;
      if (fusion_start_pulse) begin
        fusion_cycle_cnt <= 16'd0;
        fusion_wr_cnt    <= 8'd0;
      end

      // Sticky done: cleared on fusion start, set on completion
      if (fusion_start_pulse) fusion_done_sticky <= 1'b0;

      // Combinational flags
      fusion_last_byte = (fusion_cnt + 16'd1 >= reg_fusion_len);
      fusion_tile_full = (fusion_byte_in_tile == 4'd15);

      case (fusion_state)
        F_IDLE: begin
          fusion_busy <= 1'b0;
          if (fusion_start_pulse) begin
            fusion_busy         <= 1'b1;
            fusion_cnt          <= 16'd0;
            fusion_byte_in_tile <= 4'd0;
            fusion_tile_buf     <= 128'd0;
            fusion_tile_idx     <= '0;
            fusion_obuf_addr    <= '0;
            fusion_state        <= F_WAIT_MUX;
          end
        end

        // Wait 1 cycle for OBUF registered read to complete AND advance
        // addr to avoid duplicate bank[0] read. F_IDLE set addr=0; OBUF
        // reads bank[0] here (data ready in F_PACK). Advancing addr to 1
        // now means OBUF will read bank[1] in the next F_PACK, keeping
        // the pipeline aligned: addr = byte_idx + 1 at each capture cycle.
        F_WAIT_MUX: begin
          fusion_obuf_addr <= fusion_obuf_addr + 1;  // 0→1
          fusion_state <= F_PACK;
        end

        // Pack byte from OBUF into tile buffer.
        // obuf_rd_data holds the byte addressed 1 cycle ago (addr was set
        // in previous cycle's NBA, OBUF registered read captured at this posedge).
        F_PACK: begin
          fusion_tile_buf[fusion_byte_in_tile*8 +: 8] <= obuf_rd_data;
          fusion_byte_in_tile <= fusion_byte_in_tile + 4'd1;
          fusion_cnt <= fusion_cnt + 16'd1;

          if (fusion_tile_full || fusion_last_byte) begin
            // Tile needs to be written. NB: the byte just packed won't be
            // visible in fusion_tile_buf until next cycle, so we commit
            // in F_WRITE state.
            fusion_state <= F_WRITE;
          end else begin
            // Continue reading next byte
            fusion_obuf_addr <= fusion_obuf_addr + 1;
          end
        end

        // Write complete tile to IBUF. By now fusion_tile_buf has all
        // 16 bytes (the last one was NB-assigned in F_PACK last cycle).
        F_WRITE: begin
          fusion_tile_wr <= 1'b1;
          fusion_wr_cnt  <= fusion_wr_cnt + 8'd1;
          fusion_byte_in_tile <= 4'd0;
          // Pipeline: capture complete tile for write next cycle
          fusion_wr_data_pipe <= fusion_tile_buf;
          fusion_wr_tile_pipe <= fusion_tile_idx;
          fusion_tile_idx <= fusion_tile_idx + 1;

          if (fusion_last_byte) begin
            fusion_busy         <= 1'b0;
            fusion_done_sticky  <= 1'b1;
            fusion_state        <= F_IDLE;
          end else begin
            fusion_obuf_addr <= fusion_obuf_addr + 1;
            fusion_state     <= F_PACK;
          end
        end

        default: fusion_state <= F_IDLE;
      endcase
      // Pipeline: delay write-enable by 1 cycle for IBUF timing closure
      fusion_wr_en_pipe <= fusion_tile_wr;
    end
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
      burst_inc_pending <= 1'b0;
      reg_stream_path_en   <= 1'b0;
      reg_stream_dest      <= 2'd0;
      reg_stream_len       <= 16'd0;
      reg_stream_base_addr <= 16'd0;
      reg_stream_continue  <= 1'b0;
      cfg_start_r          <= 1'b0;
      cfg_start_pending    <= 1'b0;
      status_clear_r       <= 1'b0;
      reg_result_len        <= 16'd0;
      result_start_pulse_r  <= 1'b0;
      reg_ping_ctrl         <= 1'b0;
      reg_weight_base       <= '0;
      reg_bias_base         <= '0;
      fusion_start_pulse    <= 1'b0;
      reg_fusion_len        <= 16'd0;
    end else begin
      // Self-clearing pulses
      start_pulse    <= 1'b0;
      soft_rst_pulse <= 1'b0;
      done_irq_clear <= 1'b0;
      reg_wdma_wr       <= 1'b0;
      result_start_pulse_r <= 1'b0;
      cfg_start_r    <= cfg_start_pending;  // Fire cfg_start 1 cycle after LEN write
      cfg_start_pending <= 1'b0;
      status_clear_r <= 1'b0;
      fusion_start_pulse <= 1'b0;

      // Burst auto-increment: fires one cycle AFTER the write pulse,
      // so weight_sram sees current chunk_idx during wr_en, then we advance.
      if (burst_inc_pending) begin
        burst_inc_pending <= 1'b0;
        if (reg_wdma_chunk == CHUNK_IDX_W'((TILE_ROWS * TILE_COLS / (32 / WEIGHT_W)) - 1)) begin
          reg_wdma_chunk <= '0;
          reg_wdma_addr  <= reg_wdma_addr + 16'd1;
        end else begin
          reg_wdma_chunk <= reg_wdma_chunk + CHUNK_IDX_W'(1);
        end
      end

      if (wr_fire) begin
        case (aw_addr_r)
          CSR_CTRL: begin
            if (w_data_r[0]) start_pulse <= 1'b1;
            if (w_data_r[1]) done_irq_clear <= 1'b1;
            if (w_data_r[2]) soft_rst_pulse <= 1'b1;
            reg_stream_path_en <= w_data_r[3];  // CTRL[3]=stream path enable (mode bit)
          end
          CSR_IRQ_EN:        reg_irq_en <= w_data_r[0];
          CSR_IN_DIM:        reg_in_dim <= w_data_r[15:0];
          CSR_OUT_DIM:       reg_out_dim <= w_data_r[15:0];
          CSR_N_IB:          reg_n_ib <= w_data_r[15:0];
          CSR_N_OB:          reg_n_ob <= w_data_r[15:0];
          CSR_REQUANT_MULT:  reg_requant_mult <= w_data_r;
          CSR_REQUANT_SHIFT: reg_requant_shift <= w_data_r;
          CSR_INPUT_ZP:      reg_input_zp <= $signed(w_data_r);
          CSR_ACT_MODE:      reg_act_mode <= act_mode_t'(w_data_r[1:0]);
          CSR_WDMA_ADDR:     reg_wdma_addr <= w_data_r[15:0];
          CSR_WDMA_DATA: begin
            reg_wdma_data <= w_data_r;
            // FIX3: In burst mode, fire write with CURRENT chunk/tile,
            // then increment AFTER the write pulse is consumed.
            if (reg_wdma_burst) begin
              reg_wdma_wr       <= 1'b1;
              burst_inc_pending <= 1'b1;  // increment next cycle
            end
          end
          CSR_WDMA_CTRL: begin
            reg_wdma_wr <= w_data_r[0];
            reg_wdma_burst <= w_data_r[1];  // FIX3: bit[1] = burst enable
            reg_wdma_chunk <= w_data_r[CHUNK_IDX_W+1:2];  // FIX: was [7:4] for 4-bit, now [7:2] for 6-bit
          end
          // C3: AXI4-Stream sink control registers (only used when CTRL[3]=1)
          CSR_STREAM_DEST: begin
            reg_stream_dest      <= w_data_r[1:0];
            reg_stream_base_addr <= w_data_r[31:16];
          end
          CSR_STREAM_LEN: begin
            reg_stream_len <= w_data_r[15:0];
            cfg_start_pending <= 1'b1;  // Trigger cfg_start next cycle after reg_stream_len updates
          end
          CSR_STREAM_STATUS: begin
            status_clear_r <= 1'b1;  // any write clears sink sticky status
          end
          CSR_STREAM_CONTINUE: begin
            reg_stream_continue <= w_data_r[0];
          end
          // P0: result stream registers
          CSR_RESULT_LEN: begin
            reg_result_len <= w_data_r[15:0];
          end
          CSR_RESULT_CTRL: begin
            if (w_data_r[0]) result_start_pulse_r <= 1'b1;
          end
          CSR_PING_CTRL: begin
            if (w_data_r[0]) reg_ping_ctrl <= ~reg_ping_ctrl;
          end
          CSR_FUSION_LEN: begin
            reg_fusion_len <= w_data_r[15:0];
          end
          CSR_FUSION_CTRL: begin
            if (w_data_r[0]) fusion_start_pulse <= 1'b1;
          end
          CSR_WEIGHT_BASE: begin
            reg_weight_base <= w_data_r[10:0];
          end
          CSR_BIAS_BASE: begin
            reg_bias_base <= w_data_r[7:0];
          end
          default:           ;  // input/bias windows handled by memory blocks
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
      if (done_irq_clear || soft_rst_pulse) done_sticky <= 1'b0;
      else if (accel_done) done_sticky <= 1'b1;
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
      CSR_CTRL:          return {28'd0, reg_stream_path_en, 3'd0};
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
      CSR_STREAM_DEST:     return {reg_stream_base_addr, 14'd0, reg_stream_dest};
      CSR_STREAM_LEN:      return {16'd0, reg_stream_len};
      CSR_STREAM_STATUS:   return {28'd0, stream_underflow, stream_overflow, stream_done, stream_busy};
      CSR_STREAM_CONTINUE: return {31'd0, reg_stream_continue};
      CSR_RESULT_LEN:    return {16'd0, reg_result_len};
      CSR_RESULT_STATUS: return {30'd0, result_done, result_busy};
      CSR_PING_CTRL:    return {31'd0, reg_ping_ctrl};
      CSR_FUSION_CTRL:  return 32'd0;
      CSR_FUSION_LEN:   return {16'd0, reg_fusion_len};
      CSR_FUSION_STATUS: return {30'd0, fusion_done_sticky, fusion_busy};
      CSR_FUSION_DBG0:  return {16'd0, fusion_cycle_cnt};
      CSR_FUSION_DBG1:  return {24'd0, fusion_wr_cnt};
      CSR_WEIGHT_BASE:  return {21'd0, reg_weight_base};
      CSR_BIAS_BASE:    return {24'd0, reg_bias_base};
      default: begin
        if (addr >= CSR_LOGIT_BASE && addr < MEM_INPUT_BASE)
          return {{(32 - OUTPUT_W) {obuf_rd_data[OUTPUT_W-1]}}, obuf_rd_data};
        else return 32'hDEAD_BEEF;
      end
    endcase
  endfunction

endmodule
