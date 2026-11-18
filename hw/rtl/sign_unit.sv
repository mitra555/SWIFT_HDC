// =============================================================================
// sign_unit.sv  (NOVELTY EXTENSION)
//
// Final binarization for the shared multi-group accumulator: `s = sign(X);
// s[s==0] = 1`. Because the accumulator is two's-complement signed,
// X < 0 is exactly "MSB set" and X >= 0 (including the X==0 tie case,
// which the notebook resolves to +1) is exactly "MSB clear" -- so this
// reduces to reading the sign bit of each packed lane. No comparator
// array or explicit tie-break RNG is needed here, unlike the paper's
// Clipping Unit (Section III-B c), which compares an UNSIGNED widened
// value against an explicit runtime threshold with a random tie-break
// because its M-bit counters never go negative.
// =============================================================================
import hdcu_pkg::*;

module sign_unit #(
  parameter int SIMD_W = SIMD,
  parameter int ACC_W  = NOV_ACC_W
) (
  input  logic [SIMD_W*ACC_W-1:0] acc_in,   // packed lanes, lane i = acc_in[i*ACC_W +: ACC_W]
  output logic [SIMD_W-1:0]       y_bits    // 0 -> +1, 1 -> -1  (bipolar sign convention)
);

  genvar i;
  generate
    for (i = 0; i < SIMD_W; i++) begin : g_lane
      assign y_bits[i] = acc_in[i*ACC_W + ACC_W - 1];   // sign bit of lane i
    end
  endgenerate

endmodule : sign_unit
