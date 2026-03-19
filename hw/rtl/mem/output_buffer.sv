// ============================================================================
// output_buffer.sv — Output activation storage (FIX4: registered argmax)
// ============================================================================
// FIX4 vs previous version:
//   Old: Combinational argmax across ALL MAX_LEN entries every cycle.
//        With MAX_LEN=1024, this is a 1024-way comparison chain → huge
//        critical path and may fail timing at 100MHz.
//   New: Incremental argmax updated on each write. A clear signal resets
//        the tracker when a new inference starts. The argmax register is
//        always up-to-date after the last write of each inference.
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

  // --- Argmax ---
  input  logic [clog2_safe(MAX_LEN)-1:0]   out_dim,
  output logic [clog2_safe(MAX_LEN)-1:0]   pred_class
);

  localparam int ADDR_W = clog2_safe(MAX_LEN);

  (* ram_style = "block" *)
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

  // -----------------------------------------------------------------------
  // FIX4: Incremental argmax — update on each write
  // -----------------------------------------------------------------------
  // When wr_addr == 0 and wr_en: this is the first output neuron of a new
  // ob_group or a new inference. Reset the tracker.
  // For subsequent writes: compare incoming value against current max.
  //
  // Note: cim_accel_core writes outputs sequentially from addr 0 upward
  // within each inference pass, so addr==0 is a reliable reset trigger.
  // -----------------------------------------------------------------------
  logic signed [OUTPUT_W-1:0]  argmax_val_r;
  logic [ADDR_W-1:0]           argmax_idx_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      argmax_val_r <= {OUTPUT_W{1'b1}};  // most negative value
      argmax_idx_r <= '0;
    end else if (wr_en) begin
      if (wr_addr == '0) begin
        // First element: unconditionally becomes the current max
        argmax_val_r <= wr_data;
        argmax_idx_r <= '0;
      end else if (wr_data > argmax_val_r) begin
        // New maximum found
        argmax_val_r <= wr_data;
        argmax_idx_r <= wr_addr;
      end
    end
  end

  assign pred_class = argmax_idx_r;

endmodule
