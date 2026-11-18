// =============================================================================
// signed_mac_unit.sv  (NOVELTY EXTENSION)
//
// Generalizes the paper's Bundling Unit (Section III-B b, Fig. 3) from a
// saturating "increment-if-bit-set" M-bit counter array to a signed,
// integer-weighted multiply-accumulate array. Required by two operations
// in the reference Python (`encode_multigroup`, `train_eval`) that the
// paper's ISE cannot express:
//
//   1. Weighted multi-group encoding:
//        X += w_g * bind(lvl_bit, pos_bit)
//      bind(a,b) in bipolar {-1,+1} is XOR on the sign bits (0 -> +1,
//      1 -> -1); w_g is a small signed integer (the W_BASE_SWEEP
//      values). The paper's hvbundle only ever adds a fixed +1 when
//      rs2's bit is set -- it cannot scale a whole group's already-
//      bundled contribution by an arbitrary weight before folding it
//      into a SHARED accumulator across groups.
//
//   2. Perceptron-style prototype retraining:
//        hvs[true] += hv ; hvs[pred] -= hv
//      Setting pos_chunk to all-zero and do_bind=0 makes this unit pass
//      `lvl_chunk` (the hv) straight through, with `weight` supplying
//      the +1/-1 sign of the update.
//
// Both cases reduce to: contribution = bit_to_use ? -weight : +weight;
// acc_out = saturate(acc_in + contribution). Lane accumulators are
// packed into a single [SIMD_W*ACC_W-1:0] vector (rather than an
// unpacked array) on the port boundary, matching the paper's own
// widened-lane convention (Section III-B b) and avoiding a simulator
// limitation with per-element writes to unpacked-array ports from
// inside generate blocks.
// =============================================================================
import hdcu_pkg::*;

module signed_mac_unit #(
  parameter int SIMD_W = SIMD,
  parameter int ACC_W  = NOV_ACC_W,
  parameter int WGT_W  = NOV_WEIGHT_W
) (
  input  logic                          clear,
  input  logic                          do_bind,
  input  logic [SIMD_W-1:0]             lvl_chunk,
  input  logic [SIMD_W-1:0]             pos_chunk,
  input  logic signed [WGT_W-1:0]       weight,
  input  logic [SIMD_W*ACC_W-1:0]       acc_in,   // packed lanes, lane i = acc_in[i*ACC_W +: ACC_W]
  output logic [SIMD_W*ACC_W-1:0]       acc_out
);

  localparam signed [ACC_W-1:0] ACC_MAX     = {1'b0, {(ACC_W-1){1'b1}}};
  localparam signed [ACC_W-1:0] ACC_MIN     = {1'b1, {(ACC_W-1){1'b0}}};
  // NOTE: comparing a signed value against an inline concatenation like
  // {1'b0, ACC_MAX} silently forces an UNSIGNED comparison in Verilog
  // (concatenation results are always unsigned, and a comparison is
  // unsigned if either side is), which corrupts the negative bound.
  // Build the width-extended bounds with signed arithmetic instead.
  localparam signed [ACC_W:0]   ACC_MAX_EXT = ((ACC_W+1)'(1) <<< (ACC_W-1)) - 1;
  localparam signed [ACC_W:0]   ACC_MIN_EXT = -((ACC_W+1)'(1) <<< (ACC_W-1));

  genvar i;
  generate
    for (i = 0; i < SIMD_W; i++) begin : g_lane
      logic                    bit_to_use;
      logic signed [WGT_W-1:0] contrib;
      logic signed [ACC_W-1:0] lane_in;
      logic signed [ACC_W:0]   base_ext, contrib_ext, sum_ext;
      logic signed [ACC_W-1:0] lane_out;

      assign lane_in     = acc_in[i*ACC_W +: ACC_W];
      assign bit_to_use  = do_bind ? (lvl_chunk[i] ^ pos_chunk[i]) : lvl_chunk[i];
      assign contrib     = bit_to_use ? -weight : weight;
      assign contrib_ext = {{(ACC_W+1-WGT_W){contrib[WGT_W-1]}}, contrib};
      assign base_ext    = clear ? '0 : {lane_in[ACC_W-1], lane_in};
      assign sum_ext     = base_ext + contrib_ext;

      always_comb begin
        if (sum_ext > ACC_MAX_EXT)      lane_out = ACC_MAX;
        else if (sum_ext < ACC_MIN_EXT) lane_out = ACC_MIN;
        else                            lane_out = sum_ext[ACC_W-1:0];
      end

      assign acc_out[i*ACC_W +: ACC_W] = lane_out;
    end
  endgenerate

endmodule : signed_mac_unit
