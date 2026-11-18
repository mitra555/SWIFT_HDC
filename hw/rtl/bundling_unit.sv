// =============================================================================
// bundling_unit.sv  (Section III-B, b; Fig. 3; Eq. 1)
//
// Bundling (⊕): array of M-bit counters, one per output element.
//   Counters = SIMD / M
// Operand A (rs1) is the WIDENED accumulator (each element M bits),
// operand B (rs2) is a plain binary HV chunk. Each counter holds its
// initial value from A and increments by 1 whenever the corresponding
// bit of B is '1'. This lets hvbundle be applied iteratively
// (cumulative bundling) before a final hvclip binarizes the result.
// =============================================================================
import hdcu_pkg::*;

module bundling_unit #(
  parameter int SIMD_W = SIMD,
  parameter int M      = M_BITS
) (
  input  logic [SIMD_W-1:0]        b_bits,          // plain binary operand (rs2)
  input  logic [SIMD_W/M*M-1:0]    a_widened,        // widened accumulator (rs1), packed M-bit lanes
  output logic [SIMD_W/M*M-1:0]    y_widened         // updated accumulator
);

  localparam int N_COUNTERS = SIMD_W / M;   // Eq. (1)

  genvar i;
  generate
    for (i = 0; i < N_COUNTERS; i++) begin : g_counters
      logic [M-1:0] cnt_in, cnt_out;
      assign cnt_in  = a_widened[i*M +: M];
      // saturate rather than silently wrap, since BC = 2^M is the max
      assign cnt_out = (b_bits[i] && cnt_in != {M{1'b1}}) ? (cnt_in + 1'b1) : cnt_in;
      assign y_widened[i*M +: M] = cnt_out;
    end
  endgenerate

endmodule : bundling_unit
