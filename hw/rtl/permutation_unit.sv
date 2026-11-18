// =============================================================================
// permutation_unit.sv  (Section III-B, d; Fig. 4)
//
// HDC permutation (ρ) = cyclic right shift (rotation) of the whole HV
// by `s` positions. The unit is HV-length agnostic: it processes the
// vector SIMD_W bits at a time and carries the bits that "fall off"
// the current chunk into a buffer register, to be prepended to the
// next chunk. The very first chunk is re-processed at the end once
// the buffer from the last chunk is known (wrap-around).
//
// This module implements ONE chunk step of the scheme in Fig. 4; the
// controller (hdcu_ctrl) sequences it over HVSIZE/SIMD chunks and
// re-issues the first chunk at the end to close the rotation.
// =============================================================================
import hdcu_pkg::*;

module permutation_unit #(
  parameter int SIMD_W = SIMD
) (
  input  logic [SIMD_W-1:0] chunk_in,     // current HV chunk (MSB-first order)
  input  logic [SIMD_W-1:0] buf_in,       // carry-in buffer from previous chunk
  input  logic [$clog2(SIMD_W+1)-1:0] s,  // shift amount, s <= SIMD_W assumed per step
  output logic [SIMD_W-1:0] chunk_out,    // this chunk's rotated output (write back)
  output logic [SIMD_W-1:0] buf_out       // carry-out buffer for the next chunk
);

  // {chunk_in , buf_in} viewed conceptually as a 2*SIMD_W bit shift
  // register: the top s bits carried in from buf_in become the new
  // MSBs of chunk_out, and the bottom s bits of chunk_in become the
  // new buf_out. Variable-width part-selects (e.g. chunk_in[s-1:0])
  // require a constant width, so the rotation is built instead from
  // variable-amount shifts/masks (a standard barrel-shifter pattern),
  // which is both simulator- and synthesis-tool friendly.
  // Assumption: 0 <= s < SIMD_W (a shift spanning >= SIMD_W bits is
  // decomposed by the controller into multiple whole-chunk carries).
  logic [SIMD_W:0] mask_lo;   // low-s-bits mask, needs SIMD_W+1 bits for s=SIMD_W edge case

  always_comb begin
    mask_lo = (SIMD_W+1)'(1'b1 << s) - 1'b1;

    if (s == 0) begin
      chunk_out = chunk_in;
      buf_out   = '0;
    end else begin
      chunk_out = (chunk_in >> s) | (buf_in << (SIMD_W - s));
      buf_out   = chunk_in & mask_lo[SIMD_W-1:0];
    end
  end

endmodule : permutation_unit
