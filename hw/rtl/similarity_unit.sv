// =============================================================================
// similarity_unit.sv  (Section III-B, e)
//
// Hamming distance between two binary HVs:
//   1) bit-wise XOR across SIMD bits of the two operand chunks
//   2) pop-count (basic loop-based design, chosen in the paper for its
//      scalability at synthesis-time-fixed parallelism)
//   3) accumulate the per-chunk pop-count into a 13-bit accumulator
//      (POPCNT_ACC_W) over the whole HV
// Total latency across an HV is (SIMD/HVSIZE + 2) chunks, per the paper;
// the controller sequences chunk_in over HVSIZE/SIMD cycles and holds
// `clear` for the first chunk of a new comparison.
// =============================================================================
import hdcu_pkg::*;

module similarity_unit #(
  parameter int SIMD_W = SIMD,
  parameter int ACC_W  = POPCNT_ACC_W
) (
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic                 clear,       // start a new Hamming-distance accumulation
  input  logic                 valid,       // this chunk pair is valid this cycle
  input  logic [SIMD_W-1:0]    a_chunk,
  input  logic [SIMD_W-1:0]    b_chunk,
  output logic [ACC_W-1:0]     hamming_dist // valid HVSIZE/SIMD + 2 cycles after clear
);

  logic [SIMD_W-1:0]        xor_res;
  logic [$clog2(SIMD_W+1)-1:0] popcnt;
  logic [ACC_W-1:0]          acc_r;

  assign xor_res = a_chunk ^ b_chunk;

  // basic loop-based population count (paper Section III-B e / [36])
  always_comb begin
    popcnt = '0;
    for (int i = 0; i < SIMD_W; i++)
      popcnt += xor_res[i];
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      acc_r <= '0;
    else if (clear)
      acc_r <= valid ? {{(ACC_W-$clog2(SIMD_W+1)){1'b0}}, popcnt} : '0;
    else if (valid)
      acc_r <= acc_r + {{(ACC_W-$clog2(SIMD_W+1)){1'b0}}, popcnt};
  end

  assign hamming_dist = acc_r;

endmodule : similarity_unit
