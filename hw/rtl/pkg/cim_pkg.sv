// ============================================================================
// cim_pkg.sv — Central parameter package for CIM SoC
// ============================================================================
// ALL configurable parameters live here. No magic numbers in RTL modules.
//
// Design philosophy:
//   - Tile dimensions define the atomic CIM compute unit
//   - PAR controls how many tiles run in parallel (area vs throughput)
//   - Layer dimensions are set by software via CSR, not hardcoded
//   - Data widths are parameterized for INT4/INT8/INT16 experiments
// ============================================================================

package cim_pkg;

  // ==========================================================================
  // 1. CIM Tile Geometry
  // ==========================================================================
  // A single CIM tile computes: out[TILE_ROWS] = Weight[TILE_ROWS][TILE_COLS] × in[TILE_COLS]
  // Typical: 16×16 = 256 MACs per tile per cycle

  parameter int TILE_ROWS = 16;  // output neurons per tile
  parameter int TILE_COLS = 16;  // input elements per tile
  parameter int TILE_ELEMS = TILE_ROWS * TILE_COLS;  // 256

  // ==========================================================================
  // 1b. CIM Tile Pipeline Split (C1/C2)
  // ==========================================================================
  // SPLIT_FACTOR=1: 16-wide MAC chain in one cycle (legacy, ≤60 MHz)
  // SPLIT_FACTOR=2: split 16→8+8 over two cycles (100-125 MHz target)
  // SPLIT_FACTOR=4: split 16→4+4+4+4 over four cycles (100+ MHz target)
  //
  // Critical path with SPLIT_FACTOR=1: w_tile_reg → DSP48×16 → CARRY4×4 chain → tile_psum_reg
  //   At 60 MHz (16.7 ns period): 16.2 ns actual → WNS = -0.086 ns
  //   At 55 MHz (18.2 ns period): 16.2 ns actual → WNS = +2.0 ns
  // With SPLIT_FACTOR=2: each half has 8 elements → CARRY4×2 depth → ≤8 ns per stage
  //   But 8-wide DSP48→CARRY4 chain still ~14 ns at 10 ns period → timing fails
  // With SPLIT_FACTOR=4: each quarter has 4 elements → CARRY4×1 depth → ≤5 ns per stage
  //   Target for 100 MHz (10 ns period): each stage ≤8 ns, WNS ≈ +0.5 ns
  //
  // The SPLIT_FACTOR is compiled-in (Vivado synthesis parameter), not runtime.

  parameter int TILE_SPLIT_FACTOR = 4;  // 1=monolithic, 2=8+8, 4=4+4+4+4 (100+ MHz)

  // ==========================================================================
  // 1c. Multiplier Time-Multiplexing (C4 resource optimization)
  // ==========================================================================
  // TILE_MAC_REUSE=0: instantiate all TILE_COLS multipliers per row (legacy).
  //   With 16x16 tile: 256 multipliers → ~220 DSP48 + 36 LUT.
  // TILE_MAC_REUSE=1: instantiate only one split slice (TILE_COLS/SPLIT_FACTOR
  //   columns per row) and time-multiplex via phase_sel. Same FSM schedule,
  //   same cycle count, but multiplier count drops from 256 to 64 (16 rows x 4
  //   cols with default SPLIT=4). This directly addresses reviewer feedback:
  //   "DSP资源使用方式低效" — DSP usage reduced ~4x without throughput loss.

  parameter bit TILE_MAC_REUSE = 1'b1;

  // ============================================================
  // C4 multiply pipeline: register DSP48 products before CARRY4 accumulate.
  //  0: legacy — combinational multiply + accumulate in one cycle
  //  1: pipelined — DSP multiply → product reg → CARRY4 accumulate
  //     Requires ST_MAC_Q*_M FSM states. Adds +4 cycles/IB but breaks
  //     the DSP→CARRY4 critical path (~3ns→~0.5ns per stage).
  parameter bit C4_MUL_PIPE = 1'b0;

  // ==========================================================================
  // 2. Parallelism — how many tiles compute simultaneously
  // ==========================================================================
  // PAR_OB = number of output-block tiles active in parallel
  // Total output neurons computed per input-block iteration = PAR_OB * TILE_ROWS
  //
  // Trade-off: higher PAR_OB → more area (DSP * PAR_OB) but fewer cycles.
  //
  // With TILE_MAC_REUSE=1 (default): each tile instance uses ~64 DSP48.
  // PYNQ-Z2 has 220 DSP48E1 → PAR_OB ≤ 3 for MAC alone (~192 DSP).
  // Plus requant/other logic overhead → PAR_OB=3 is the practical maximum.
  //
  // Example for FC1 (784→128): N_OB = 128/16 = 8
  //   PAR_OB=1  → 8 passes, each 49 IB iterations =  392 tile-cycles
  //   PAR_OB=2  → 4 passes, each 49 IB iterations =  196 tile-cycles
  //   PAR_OB=3  → 3 passes (last partial),         = ~131 tile-cycles
  //   PAR_OB=4  → 2 passes, each 49 IB iterations =   98 tile-cycles
  //
  // C4: PAR_OB no longer required to divide N_OB. The core FSM handles
  // partial last passes (fewer tiles than PAR_OB) via tiles_this_pass runtime
  // computation. PAR_OB=3 now works for N_OB=8 (processes 3+3+2 tiles).

  parameter int PAR_OB = 1;  // with TILE_MAC_REUSE=1: ~64 DSP (29% of 220) (87% of 220, max safe)

  // ==========================================================================
  // 3. Data Widths
  // ==========================================================================
  parameter int INPUT_W = 8;  // input activation width (INT8)
  parameter int WEIGHT_W = 8;  // weight width (INT8)
  parameter int BIAS_W = 32;  // bias width (INT32)
  parameter int PSUM_W = 32;  // partial sum accumulator width
  parameter int OUTPUT_W = 8;  // output activation width (INT8 after requantize)

  // Effective input width after zero-point subtraction.
  // Signed 10-bit: supports both legacy zp=-128 (range [128,383]) and
  // standard affine UINT8 zero-points zp∈[0,255] (range [-255,255]).
  // Fixes reviewer comment #5: previous unsigned 9-bit silently clamped
  // negative (x-zp) values to zero, breaking non-zero-input-zp semantics.
  parameter int X_EFF_W = 10;

  // ==========================================================================
  // 4. Quantization Zero-Points (defaults, overridable via CSR)
  // ==========================================================================
  parameter int signed INPUT_ZP = -128;
  parameter int signed WEIGHT_ZP = 0;
  parameter int signed OUTPUT_ZP = 0;

  // ==========================================================================
  // 5. Maximum Supported Layer Dimensions
  // ==========================================================================
  // These set the SRAM sizing. Actual layer dims are configured via CSR at runtime.
  // The accelerator can handle any layer up to these limits.

  parameter int MAX_IN_DIM = 1536;  // max input vector length
  parameter int MAX_OUT_DIM = 256;  // max output vector length
  parameter int MAX_WEIGHT_ELEMS = MAX_IN_DIM * MAX_OUT_DIM;  // worst case

  // Derived: max tile blocks
  parameter int MAX_N_IB = (MAX_IN_DIM + TILE_COLS - 1) / TILE_COLS;  // ceil
  parameter int MAX_N_OB = (MAX_OUT_DIM + TILE_ROWS - 1) / TILE_ROWS;

  // ==========================================================================
  // 6. Weight SRAM Configuration
  // ==========================================================================
  // Weight SRAM stores packed tiles: each word = one TILE_ROWS × TILE_COLS tile
  // Word width = TILE_ELEMS * WEIGHT_W bits
  // Depth = MAX_N_OB * MAX_N_IB tiles
  //
  // For MNIST FC1 (784→128): 8 * 49 = 392 tiles, each 256 bytes = ~100KB

  parameter int WSRAM_WORD_W = TILE_ELEMS * WEIGHT_W;  // 256 * 8 = 2048 bits
  parameter int WSRAM_DEPTH = MAX_N_OB * MAX_N_IB;

  // Bias SRAM: one word per output neuron
  parameter int BSRAM_DEPTH = MAX_OUT_DIM;

  // Input buffer: one packed tile per input block
  parameter int IBUF_WORD_W = TILE_COLS * INPUT_W;  // 16 * 8 = 128 bits
  parameter int IBUF_DEPTH = MAX_N_IB;

  // Output buffer: one word per output neuron
  parameter int OBUF_DEPTH = MAX_OUT_DIM;

  // ==========================================================================
  // 7. CSR Address Map (AXI4-Lite, byte-addressed, 32-bit registers)
  // ==========================================================================
  // All offsets relative to base address of CIM IP

  // --- Control / Status ---
  parameter logic [13:0] CSR_CTRL = 14'h000;  // [0]=start, [1]=clear_done, [2]=soft_rst, [3]=stream_path_en
  parameter logic [13:0] CSR_STATUS = 14'h004;  // [0]=busy, [1]=done, [7:4]=state
  parameter logic [13:0] CSR_IRQ_EN = 14'h008;  // [0]=done_irq_en
  parameter logic [13:0] CSR_IRQ_STATUS = 14'h00C;  // [0]=done_irq (write-1-clear)

  // --- Layer Configuration ---
  parameter logic [13:0] CSR_IN_DIM = 14'h010;  // input dimension (e.g. 784)
  parameter logic [13:0] CSR_OUT_DIM = 14'h014;  // output dimension (e.g. 128)
  parameter logic [13:0] CSR_N_IB = 14'h018;  // number of input blocks = ceil(IN_DIM/TILE_COLS)
  parameter logic [13:0] CSR_N_OB = 14'h01C;  // number of output blocks = ceil(OUT_DIM/TILE_ROWS)

  // --- Quantization Parameters ---
  parameter logic [13:0] CSR_REQUANT_MULT = 14'h020;  // requantize multiplier
  parameter logic [13:0] CSR_REQUANT_SHIFT = 14'h024;  // requantize right-shift
  parameter logic [13:0] CSR_INPUT_ZP = 14'h028;  // input zero point
  parameter logic [13:0] CSR_ACT_MODE = 14'h02C;  // [1:0] 00=none, 01=ReLU, 10=clamp

  // --- Performance Counters ---
  parameter logic [13:0] CSR_CYCLE_CNT_LO = 14'h030;  // cycle counter low 32
  parameter logic [13:0] CSR_CYCLE_CNT_HI = 14'h034;  // cycle counter high 32
  parameter logic [13:0] CSR_MAC_CNT_LO = 14'h038;  // MAC operation counter low 32
  parameter logic [13:0] CSR_MAC_CNT_HI = 14'h03C;  // MAC operation counter high 32

  // --- Result Readback ---
  parameter logic [13:0] CSR_PRED_CLASS = 14'h040;  // argmax result
  parameter logic [13:0] CSR_LOGIT_BASE = 14'h100;  // logits[0..127] at 0x100 + 4*i

  // --- Memory Windows (for AXI writes) ---
  // 16KB address space (14-bit). Input needs 784 words = 3136 bytes.
  parameter logic [13:0] MEM_INPUT_BASE = 14'h1000;  // input buffer:  0x1000 + 4*i (up to 0x1C3F)
  parameter logic [13:0] MEM_BIAS_BASE = 14'h2800;  // bias buffer:   0x2000 + 4*i (up to 0x21FF)
  // Weight SRAM uses a separate AXI-Full or burst interface (too wide for CSR)
  // For simplicity, we provide a DMA-style interface:
  parameter logic [13:0] CSR_WDMA_ADDR = 14'h044;  // weight SRAM write address (tile index)
  parameter logic [13:0] CSR_WDMA_DATA = 14'h048;  // weight SRAM write data (32-bit chunk)
  parameter logic [13:0] CSR_WDMA_CTRL = 14'h04C;  // [0]=wr_en, [7:4]=chunk_idx

  // --- C3: AXI4-Stream Sink Control (active when CSR_CTRL[3]=1) ---
  // Writing CSR_STREAM_LEN pulses cfg_start (design §3.3 scheme A); software
  // must program CSR_STREAM_DEST first, then CSR_STREAM_LEN last.
  parameter logic [13:0] CSR_STREAM_DEST = 14'h050;     // [1:0]=dest, [31:16]=base_addr
  parameter logic [13:0] CSR_STREAM_LEN = 14'h054;      // [15:0]=len (beats); write triggers cfg_start
  parameter logic [13:0] CSR_STREAM_STATUS = 14'h058;   // [0]=busy, [1]=done, [2]=overflow, [3]=underflow (W1C on done/ovf/und)
  parameter logic [13:0] CSR_STREAM_CONTINUE = 14'h05C; // [0]=continue (0=reset addr ptrs, 1=continue from current position)

  // --- P0: AXI4-Stream Source (result read-back via DMA S2MM) ---
  // Writing CSR_RESULT_LEN configures the number of INT8 output elements to
  // stream back. Writing CSR_RESULT_CTRL[0]=1 triggers the stream.
  parameter logic [13:0] CSR_RESULT_LEN    = 14'h060;  // [15:0]=n_elements (INT8 count)
  parameter logic [13:0] CSR_RESULT_CTRL   = 14'h064;  // [0]=start (write-1 triggers)
  parameter logic [13:0] CSR_RESULT_STATUS = 14'h068;  // [0]=busy, [1]=done

  // --- Phase B: Ping-pong bank select ---
  parameter logic [13:0] CSR_PING_CTRL = 14'h06C;  // [0]=bank_sel; write 1 toggles

  // --- Phase C: Layer Fusion — OBUF→IBUF direct copy ---
  parameter logic [13:0] CSR_FUSION_CTRL  = 14'h070;  // [0]=start; write 1 triggers copy
  parameter logic [13:0] CSR_FUSION_LEN   = 14'h074;  // [15:0]=n_elements (INT8 count to copy)
  parameter logic [13:0] CSR_FUSION_STATUS = 14'h078; // [0]=busy, [1]=done

  // --- Phase C: Multi-layer base offsets for weight/bias SRAM ---
  parameter logic [13:0] CSR_WEIGHT_BASE = 14'h07C;  // [10:0]=tile offset for weight reads
  parameter logic [13:0] CSR_BIAS_BASE   = 14'h080;  // [7:0]=word offset for bias reads
  // Phase C debug registers
  parameter logic [13:0] CSR_FUSION_DBG0 = 14'h084;  // [15:0]=fusion cycle counter
  parameter logic [13:0] CSR_FUSION_DBG1 = 14'h088;  // [7:0]=fusion tile-write counter

  // ==========================================================================
  // 8. Activation Function Modes
  // ==========================================================================
  typedef enum logic [1:0] {
    ACT_NONE  = 2'b00,
    ACT_RELU  = 2'b01,
    ACT_CLAMP = 2'b10   // clamp to [min, max] (for output layer)
  } act_mode_t;

  // C3 stream sink destination — shared between axi_lite_slave and cim_axi_stream_sink
  typedef enum logic [1:0] {
    STREAM_DEST_WEIGHT = 2'd0,
    STREAM_DEST_INPUT  = 2'd1,
    STREAM_DEST_BIAS   = 2'd2
  } stream_dest_t;

  // ==========================================================================
  // 9. Accelerator FSM States
  // ==========================================================================
  typedef enum logic [5:0] {
    ST_IDLE        = 6'd0,
    ST_LOAD_CFG    = 6'd1,
    ST_CLEAR_PSUM  = 6'd2,
    ST_FETCH       = 6'd3,
    ST_WAIT_SRAM   = 6'd4,
    ST_XEFF_REG    = 6'd5,
    ST_XEFF_LATCH  = 6'd6,   // C1: extra pipeline stage for ibuf BRAM→x_eff timing
    ST_MAC         = 6'd7,   // SPLIT=1: full 16-wide MAC
    ST_MAC_LO      = 6'd8,   // SPLIT=2: low half (cols 0-7)
    ST_MAC_HI      = 6'd9,   // SPLIT=2: high half (cols 8-15)
    ST_MAC_Q0      = 6'd10,  // SPLIT=4: quarter 0 (cols 0-3)
    ST_MAC_Q1      = 6'd11,  // SPLIT=4: quarter 1 (cols 4-7)
    ST_MAC_Q2      = 6'd12,  // SPLIT=4: quarter 2 (cols 8-11)
    ST_MAC_Q3      = 6'd13,  // SPLIT=4: quarter 3 (cols 12-15)
    // C4 phase_sel pipeline latch states
    ST_MAC_Q0_L    = 6'd14,  // latch Q0 x_eff/w
    ST_MAC_Q1_L    = 6'd15,  // latch Q1 x_eff/w
    ST_MAC_Q2_L    = 6'd16,  // latch Q2 x_eff/w
    ST_MAC_Q3_L    = 6'd17,  // latch Q3 x_eff/w
    // C4_MUL_PIPE: multiply states (register DSP48 products in cim_tile)
    ST_MAC_Q0_M    = 6'd18,  // multiply Q0
    ST_MAC_Q1_M    = 6'd19,  // multiply Q1
    ST_MAC_Q2_M    = 6'd20,  // multiply Q2
    ST_MAC_Q3_M    = 6'd21,  // multiply Q3
    ST_COMPUTE     = 6'd22,  // merge + psum_accum
    ST_NEXT_IB     = 6'd23,
    ST_BIAS_ADD    = 6'd24,
    ST_ACTIVATE    = 6'd25,
    ST_REQUANT     = 6'd26,
    ST_STORE       = 6'd27,
    ST_SHIFT       = 6'd28,
    ST_CLAMP       = 6'd29,
    ST_WRITE_OBUF  = 6'd30,
    ST_NEXT_OB     = 6'd31,
    ST_DONE        = 6'd32
  } accel_state_t;

  // ==========================================================================
  // 10. Helper Functions
  // ==========================================================================

  // Safe clog2 that returns 1 for input <= 1 (avoid zero-width signals)
  function automatic int clog2_safe(input int val);
    if (val <= 1) return 1;
    else return $clog2(val);
  endfunction

  // Requantize INT32 → INT8 with rounding
  function automatic logic signed [OUTPUT_W-1:0] requantize(
      input logic signed [PSUM_W-1:0] x, input logic [31:0] mult, input logic [31:0] rshift);
    longint signed prod;
    longint signed shifted;

    prod = longint'(x) * longint'($signed(mult));

    if (rshift == 0) shifted = prod;
    else shifted = (prod + (longint'(1) <<< (rshift - 1))) >>> rshift;

    // Clamp to INT8 range
    if (shifted > 127) return 8'sd127;
    else if (shifted < -128) return -8'sd128;
    else return shifted[OUTPUT_W-1:0];
  endfunction

endpackage
