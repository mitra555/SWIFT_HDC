// =============================================================================
// clipping_unit.sv  (Section III-B, c; Eq. 3)
//
// Binary normalization by majority vote. Structurally identical to the
// bundling unit but the array of counters is replaced by an array of
// comparators: each M-bit widened element is compared against an
// explicit runtime threshold (rs2 / imm), producing one binary output
// bit per lane. Ties are broken pseudo-randomly using an LFSR bit so
// results don't bias toward always-0 or always-1 on exact ties.
// =============================================================================
import hdcu_pkg::*;

module clipping_unit #(
  parameter int SIMD_W = SIMD,
  parameter int M      = M_BITS
) (
  input  logic [SIMD_W/M*M-1:0] a_widened,   // widened input HV chunk (rs1)
  input  logic [M-1:0]          threshold,   // explicit threshold (Section III-B c)
  input  logic [SIMD_W/M-1:0]   tie_rand,    // 1 pseudo-random bit per lane, for ties
  output logic [SIMD_W/M-1:0]   y_bits       // binarized output chunk
);

  localparam int N_COMPARATORS = SIMD_W / M;

  genvar i;
  generate
    for (i = 0; i < N_COMPARATORS; i++) begin : g_comparators
      logic [M-1:0] val;
      assign val = a_widened[i*M +: M];
      assign y_bits[i] = (val > threshold) ? 1'b1 :
                         (val < threshold) ? 1'b0 :
                         tie_rand[i];               // exact tie -> random
    end
  endgenerate

endmodule : clipping_unit
