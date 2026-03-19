// ============================================================================
// output_buffer.sv — Output activation storage
// ============================================================================
// CIM writes computed output neurons (INT8 after requantize)
// CPU reads results via AXI
// Also provides argmax output for classification tasks
// ============================================================================

module output_buffer
  import cim_pkg::*;
#(
  parameter int MAX_LEN = MAX_OUT_DIM
) (
  input  logic                             clk,
  input  logic                             rst_n,

  // --- Write port (from CIM accelerator) ---
  input  logic                             wr_en,
  input  logic [clog2_safe(MAX_LEN)-1:0]   wr_addr,
  input  logic signed [OUTPUT_W-1:0]       wr_data,

  // --- Read port (CPU/AXI) ---
  input  logic [clog2_safe(MAX_LEN)-1:0]   rd_addr,
  output logic signed [OUTPUT_W-1:0]       rd_data,

  // --- Argmax (continuously computed over valid range) ---
  input  logic [clog2_safe(MAX_LEN)-1:0]   out_dim,    // actual output dimension
  output logic [clog2_safe(MAX_LEN)-1:0]   pred_class
);

  logic signed [OUTPUT_W-1:0] buf_mem [MAX_LEN];

  // Write
  always_ff @(posedge clk) begin
    if (wr_en)
      buf_mem[wr_addr] <= wr_data;
  end

  // Read (registered for timing)
  always_ff @(posedge clk) begin
    rd_data <= buf_mem[rd_addr];
  end

  // Argmax — combinational over buf_mem[0..out_dim-1]
  logic signed [OUTPUT_W-1:0]        argmax_val;
  logic [clog2_safe(MAX_LEN)-1:0]    argmax_idx;

  always_comb begin
    argmax_val = buf_mem[0];
    argmax_idx = '0;
    for (int i = 1; i < MAX_LEN; i++) begin
      if (i < int'(out_dim) && buf_mem[i] > argmax_val) begin
        argmax_val = buf_mem[i];
        argmax_idx = clog2_safe(MAX_LEN)'(i);
      end
    end
    pred_class = argmax_idx;
  end

endmodule
