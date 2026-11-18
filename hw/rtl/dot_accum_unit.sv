// =============================================================================
// dot_accum_unit.sv  (NOVELTY EXTENSION)
//
// The paper's Similarity Unit (Section III-B e) computes Hamming distance
// via XOR + pop-count, which is only meaningful when BOTH operands are
// binary HVs. During perceptron retraining (`train_eval` in the reference
// notebook), the class-prototype memory `hvs` is a running int32
// accumulator that is NOT binarized until training finishes -- so
// similarity against it must be a genuine signed dot product:
//
//   dot(hv, hvs_class) = sum_i ( hv_bit[i] ? -hvs_class[i] : +hvs_class[i] )
//
// This unit computes that per chunk and accumulates across the whole HV,
// mirroring the structure of similarity_unit (XOR+popcount+accumulate)
// but with a signed multiply-style contribution per lane instead of a
// simple population count. Prototype lanes arrive packed (matching
// signed_mac_unit's convention) rather than as an unpacked array.
// =============================================================================
import hdcu_pkg::*;

module dot_accum_unit #(
  parameter int SIMD_W = SIMD,
  parameter int ACC_W  = NOV_ACC_W,
  parameter int DIST_W = NOV_DIST_W
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     clear,
  input  logic                     valid,
  input  logic [SIMD_W-1:0]        query_bits,           // bipolar query HV bits (0=+1, 1=-1)
  input  logic [SIMD_W*ACC_W-1:0]  proto_word,           // packed prototype lanes for this chunk
  output logic signed [DIST_W-1:0] dot_acc
);

  logic signed [DIST_W-1:0] chunk_sum;
  logic signed [DIST_W-1:0] acc_r;

  always_comb begin
    chunk_sum = '0;
    for (int i = 0; i < SIMD_W; i++) begin
      logic signed [ACC_W-1:0] lane;
      logic signed [DIST_W-1:0] lane_ext;
      lane     = proto_word[i*ACC_W +: ACC_W];
      lane_ext = {{(DIST_W-ACC_W){lane[ACC_W-1]}}, lane};
      chunk_sum += query_bits[i] ? -lane_ext : lane_ext;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      acc_r <= '0;
    else if (clear)
      acc_r <= valid ? chunk_sum : '0;
    else if (valid)
      acc_r <= acc_r + chunk_sum;
  end

  assign dot_acc = acc_r;

endmodule : dot_accum_unit
