// ============================================================================
// activation_unit.sv — Post-computation activation + requantization
// ============================================================================
// Takes PSUM_W-bit accumulated result (after bias), applies:
//   1. Activation function (none / ReLU / clamp)
//   2. Requantization: INT32 → INT8 using multiply-shift
//
// Single-cycle combinational for simplicity.
// Can be pipelined later if timing is tight.
// ============================================================================

module activation_unit
  import cim_pkg::*;
(
  input  logic signed [PSUM_W-1:0]   acc_in,          // accumulated value (with bias)
  input  act_mode_t                  act_mode,         // activation function select
  input  logic [31:0]                requant_mult,     // requantize multiplier
  input  logic [31:0]                requant_shift,    // requantize right-shift

  output logic signed [PSUM_W-1:0]   after_act,       // value after activation (for debug)
  output logic signed [OUTPUT_W-1:0] out_val           // final INT8 output
);

  // Stage 1: Activation
  always_comb begin
    case (act_mode)
      ACT_RELU:  after_act = (acc_in > 0) ? acc_in : '0;
      ACT_CLAMP: after_act = acc_in;  // clamp done in requantize
      default:   after_act = acc_in;  // ACT_NONE: pass through
    endcase
  end

  // Stage 2: Requantize INT32 → INT8
  assign out_val = requantize(after_act, requant_mult, requant_shift);

endmodule
