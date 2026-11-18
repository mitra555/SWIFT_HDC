// =============================================================================
// isqrt_seq_unit.sv  (NOVELTY EXTENSION)
//
// Sequential (one-iteration-per-cycle) integer square root:
// root = floor(sqrt(value)), via the standard shift-subtract digit-by-digit
// algorithm (each iteration resolves one bit of the root, testing against
// a shrinking power-of-4 "bit" term). Runs in a fixed number of cycles
// (independent of the input value), which keeps the controller's timing
// simple at the cost of a few "wasted" leading iterations for small
// inputs -- an intentional simplicity/latency trade-off in the same
// spirit as the paper's own configurable time/resource trade-offs
// (Section III-A).
//
// Used as the middle phase of the L2-normalize finalize step:
//   normsq = sum_i proto[i]^2      (norm_sq_accum_unit)
//   norm   = floor(sqrt(normsq))   (this unit)
//   out[i] = proto[i] / norm       (fixed_div_seq_unit, per lane)
// =============================================================================
import hdcu_pkg::*;

module isqrt_seq_unit #(
  parameter int NORMSQ_W = NOV_NORMSQ_W,
  parameter int ROOT_W   = (NORMSQ_W+1)/2
) (
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    start,
  input  logic [NORMSQ_W-1:0]     value,
  output logic                    busy,
  output logic                    done,      // one-cycle pulse
  output logic [ROOT_W-1:0]       root
);

  // largest even exponent <= NORMSQ_W-1, so the initial test bit
  // (1 << START_EXP) is the largest power of 4 that could possibly be
  // <= a NORMSQ_W-bit value
  localparam int START_EXP = (NORMSQ_W-1) - ((NORMSQ_W-1) % 2);
  localparam int ITERS     = START_EXP/2 + 1;
  localparam int ITER_W    = $clog2(ITERS+1);

  logic [NORMSQ_W-1:0] num_r, res_r, bit_r;
  logic [ITER_W-1:0]   iter_r;
  logic                busy_r, done_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy_r <= 1'b0;
      done_r <= 1'b0;
      num_r  <= '0;
      res_r  <= '0;
      bit_r  <= '0;
      iter_r <= '0;
    end else if (start) begin
      num_r  <= value;
      res_r  <= '0;
      bit_r  <= (NORMSQ_W)'(1) <<< START_EXP;
      iter_r <= ITERS[ITER_W-1:0];
      busy_r <= 1'b1;
      done_r <= 1'b0;
    end else if (busy_r) begin
      if (num_r >= (res_r + bit_r)) begin
        num_r <= num_r - (res_r + bit_r);
        res_r <= (res_r >> 1) + bit_r;
      end else begin
        res_r <= res_r >> 1;
      end
      bit_r  <= bit_r >> 2;
      iter_r <= iter_r - 1'b1;
      if (iter_r == ITER_W'(1)) begin
        busy_r <= 1'b0;
        done_r <= 1'b1;
      end
    end else begin
      done_r <= 1'b0;
    end
  end

  assign busy = busy_r;
  assign done = done_r;
  assign root = res_r[ROOT_W-1:0];

endmodule : isqrt_seq_unit
