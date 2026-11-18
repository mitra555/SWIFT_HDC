// =============================================================================
// dot_search_unit.sv  (NOVELTY EXTENSION)
//
// Mirrors the structure of the paper's Search Unit (Section III-B f: "we
// decided to reuse the similarity unit and introduce a dedicated hardware
// instruction") but built on dot_accum_unit instead of the XOR+popcount
// similarity unit, and tracking the MAXIMUM (best match = largest dot
// product) instead of the paper's MINIMUM Hamming distance.
//
// Why a separate unit rather than reusing the paper's hvsearch: once
// training has converged and prototypes are sign()-ed into true binary
// HVs, argmax(dot product) and argmin(Hamming distance) are equivalent
// (dot = D - 2*HammingDist for bipolar vectors) and the paper's hvsearch
// is the right, cheaper primitive for that inference-time case. But
// DURING perceptron retraining the prototypes are wide signed integers,
// not binary -- Hamming distance isn't even defined against them -- so
// this unit is required for the training loop itself.
// =============================================================================
import hdcu_pkg::*;

module dot_search_unit #(
  parameter int SIMD_W = SIMD,
  parameter int ACC_W  = NOV_ACC_W,
  parameter int DIST_W = NOV_DIST_W,
  parameter int PROT_W = 16
) (
  input  logic               clk,
  input  logic               rst_n,

  input  logic               start,
  input  logic [PROT_W-1:0]  k_prototypes,   // NUM_CLASSES

  input  logic               chunk_valid,
  input  logic               new_prototype,  // pulses on the first chunk of each class prototype
  input  logic [SIMD_W-1:0]  query_bits,
  input  logic [SIMD_W*ACC_W-1:0] proto_word,

  output logic               busy,
  output logic               done,
  output logic [PROT_W-1:0]  best_idx,       // argmax class index (predicted label)
  output logic signed [DIST_W-1:0] best_dot  // its dot-product value, for diagnostics
);

  logic                     dot_clear;
  logic signed [DIST_W-1:0] dot_val;

  dot_accum_unit #(.SIMD_W(SIMD_W), .ACC_W(ACC_W), .DIST_W(DIST_W)) u_dot (
    .clk(clk), .rst_n(rst_n), .clear(dot_clear), .valid(chunk_valid),
    .query_bits(query_bits), .proto_word(proto_word), .dot_acc(dot_val)
  );
  assign dot_clear = new_prototype;

  logic signed [DIST_W-1:0] best_dot_r;
  logic [PROT_W-1:0]        best_idx_r, proto_cnt_r;
  logic                     busy_r;

  localparam signed [DIST_W-1:0] NEG_INF = {1'b1, {(DIST_W-1){1'b0}}};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy_r      <= 1'b0;
      best_dot_r  <= NEG_INF;
      best_idx_r  <= '0;
      proto_cnt_r <= '0;
    end else if (start) begin
      busy_r      <= 1'b1;
      best_dot_r  <= NEG_INF;
      best_idx_r  <= '0;
      proto_cnt_r <= '0;
    end else if (busy_r && new_prototype) begin
      if (dot_val > best_dot_r) begin
        best_dot_r <= dot_val;
        best_idx_r <= proto_cnt_r;
      end
      proto_cnt_r <= proto_cnt_r + 1'b1;
      if (proto_cnt_r + 1'b1 == k_prototypes)
        busy_r <= 1'b0;
    end
  end

  assign busy     = busy_r;
  assign done     = busy_r && new_prototype && (proto_cnt_r + 1'b1 == k_prototypes);
  assign best_idx = best_idx_r;
  assign best_dot = best_dot_r;

endmodule : dot_search_unit
