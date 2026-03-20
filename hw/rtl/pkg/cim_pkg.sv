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
  // 2. Parallelism — how many tiles compute simultaneously
  // ==========================================================================
  // PAR_OB = number of output-block tiles active in parallel
  // Total output neurons computed per input-block iteration = PAR_OB * TILE_ROWS
  //
  // Trade-off: higher PAR_OB → more area (weight BRAM * PAR_OB) but fewer cycles
  //
  // Example for FC1 (784→128): N_OB = 128/16 = 8
  //   PAR_OB=1  → 8 passes over output blocks, each 49 input iterations = 392 tile-cycles
  //   PAR_OB=4  → 2 passes, each 49 iterations = 98 tile-cycles
  //   PAR_OB=8  → 1 pass,  49 iterations = 49 tile-cycles (max parallel for this layer)

  parameter int PAR_OB = 4;  // tunable: 1, 2, 4, 8 (must divide N_OB of target layer)

  // ==========================================================================
  // 3. Data Widths
  // ==========================================================================
  parameter int INPUT_W = 8;  // input activation width (INT8)
  parameter int WEIGHT_W = 8;  // weight width (INT8)
  parameter int BIAS_W = 32;  // bias width (INT32)
  parameter int PSUM_W = 32;  // partial sum accumulator width
  parameter int OUTPUT_W = 8;  // output activation width (INT8 after requantize)

  // Effective input width after zero-point subtraction
  // INT8 unsigned [0,255] - zp → signed range needs 9 bits
  parameter int X_EFF_W = 9;

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

  parameter int MAX_IN_DIM = 784;  // max input vector length
  parameter int MAX_OUT_DIM = 128;  // max output vector length
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
  parameter logic [13:0] CSR_CTRL = 14'h000;  // [0]=start, [1]=clear_done, [2]=soft_rst
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
  parameter logic [13:0] MEM_BIAS_BASE = 14'h2000;  // bias buffer:   0x2000 + 4*i (up to 0x21FF)
  // Weight SRAM uses a separate AXI-Full or burst interface (too wide for CSR)
  // For simplicity, we provide a DMA-style interface:
  parameter logic [13:0] CSR_WDMA_ADDR = 14'h044;  // weight SRAM write address (tile index)
  parameter logic [13:0] CSR_WDMA_DATA = 14'h048;  // weight SRAM write data (32-bit chunk)
  parameter logic [13:0] CSR_WDMA_CTRL = 14'h04C;  // [0]=wr_en, [7:4]=chunk_idx

  // ==========================================================================
  // 8. Activation Function Modes
  // ==========================================================================
  typedef enum logic [1:0] {
    ACT_NONE  = 2'b00,
    ACT_RELU  = 2'b01,
    ACT_CLAMP = 2'b10   // clamp to [min, max] (for output layer)
  } act_mode_t;

  // ==========================================================================
  // 9. Accelerator FSM States
  // ==========================================================================
  typedef enum logic [3:0] {
    ST_IDLE       = 4'd0,
    ST_LOAD_CFG   = 4'd1,
    ST_CLEAR_PSUM = 4'd2,
    ST_FETCH      = 4'd3,   // fetch weight tile + input tile from SRAM
    ST_WAIT_SRAM  = 4'd4,   // 1-cycle BRAM read latency
    ST_COMPUTE    = 4'd5,   // CIM tile array computes + accumulate
    ST_NEXT_IB    = 4'd6,   // advance input block pointer
    ST_BIAS_ADD   = 4'd7,   // pipeline stage 1: MUX psum + set bias addr
    ST_ACTIVATE   = 4'd8,   // pipeline stage 2: latch bias from BRAM
    ST_REQUANT    = 4'd9,   // pipeline stage 3: bias add + ReLU (registered)
    ST_STORE      = 4'd10,  // pipeline stage 4: requantize + write obuf
    ST_NEXT_OB    = 4'd11,  // advance output block group pointer
    ST_DONE       = 4'd12
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
