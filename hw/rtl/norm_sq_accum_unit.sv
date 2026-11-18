// =============================================================================
// norm_sq_accum_unit.sv  (NOVELTY EXTENSION)
//
// Computes sum_i (proto_lane_i)^2 across an entire HV, one SIMD-wide
// chunk per cycle, accumulating into a wide unsigned register. This is
// the first phase of the L2-normalize finalize step used by the
// notebook's "binary + int32 AM" mode:
//
//   n = norm(best_h[c])       # = sqrt(sum_i best_h[c][i]^2)
//   if n > 0: best_h[c] /= n
//
// Unlike dot_accum_unit (which multiplies a prototype lane by a +-1
// query bit -- a trivial select, no real multiplier needed), this unit
// needs a genuine signed-square (widening multiply) per lane, since
// we're computing a prototype's norm against ITSELF.
// =============================================================================
import hdcu_pkg::*;

module norm_sq_accum_unit #(
  parameter int SIMD_W   = SIMD,
  parameter int ACC_W    = NOV_ACC_W,
  parameter int NORMSQ_W = NOV_NORMSQ_W
) (
  input  logic                       clk,
  input  logic                       rst_n,
  input  logic                       clear,     // start a new sum-of-squares accumulation
  input  logic                       valid,     // lane `lane` of this chunk is valid this cycle
  input  logic [SIMD_W*ACC_W-1:0]    proto_word,
  input  logic [$clog2(SIMD_W)-1:0]  lane,      // serialized: one lane per cycle
  output logic [NORMSQ_W-1:0]        normsq_acc
);

  logic [NORMSQ_W-1:0] chunk_sum;
  logic [NORMSQ_W-1:0] acc_r;

  // Serialized: ONE lane squared per cycle (SIMD_W cycles per chunk) through a
  // single ACC_W x ACC_W multiplier. The fully parallel version (SIMD_W
  // multipliers plus an adder tree) was ~85% of the novelty core's logic, for an
  // operation that runs once per prototype after training; serializing adds
  // SIMD_W cycles per chunk, small next to NOV_NORMALIZE's per-lane divides.
  logic signed [ACC_W-1:0] lane_v;
  logic [ACC_W-1:0]        lane_mag;
  logic [2*ACC_W-1:0]      lane_sq;
  assign lane_v    = proto_word[lane*ACC_W +: ACC_W];
  assign lane_mag  = lane_v[ACC_W-1] ? (~lane_v + 1'b1) : lane_v;  // |lane|
  assign lane_sq   = lane_mag * lane_mag;
  assign chunk_sum = {{(NORMSQ_W-2*ACC_W){1'b0}}, lane_sq};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      acc_r <= '0;
    else if (clear)
      acc_r <= valid ? chunk_sum : '0;
    else if (valid)
      acc_r <= acc_r + chunk_sum;
  end

  assign normsq_acc = acc_r;

endmodule : norm_sq_accum_unit
