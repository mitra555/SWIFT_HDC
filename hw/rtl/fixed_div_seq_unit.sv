// =============================================================================
// fixed_div_seq_unit.sv  (NOVELTY EXTENSION)
//
// Computes result = proto_lane / norm as a signed Q1.QFRAC fixed-point
// value (QFRAC = NOV_ACC_W-1), via classic bit-serial restoring division
// on the magnitude, then reapplies the original sign. Because
// |proto_lane| <= norm always holds (a single vector component can never
// exceed the vector's own L2 norm), the quotient is guaranteed to fit in
// [0, 2^QFRAC], with the single boundary case (proto_lane == +-norm)
// saturated to the largest representable magnitude to stay a valid
// signed Q1.QFRAC word.
//
// This is one shared, sequential instance reused across all lanes and
// chunks by nov_ctrl (Section III-A's own "trade time for resources"
// philosophy) -- a synthesis-time-replicated SIMD-parallel version is a
// straightforward extension (instantiate SIMD copies, matching how the
// paper scales its own functional units by SIMD).
// =============================================================================
import hdcu_pkg::*;

module fixed_div_seq_unit #(
  parameter int ACC_W  = NOV_ACC_W,
  parameter int NORM_W = NOV_NORM_W,
  parameter int QFRAC  = NOV_QFRAC
) (
  input  logic                     clk,
  input  logic                     rst_n,

  input  logic                     start,
  input  logic signed [ACC_W-1:0]  proto_lane,
  input  logic [NORM_W-1:0]        norm,        // caller guarantees norm != 0

  output logic                     busy,
  output logic                     done,        // one-cycle pulse
  output logic signed [ACC_W-1:0]  result       // Q1.QFRAC fixed-point, same sign as proto_lane
);

  localparam int DIVW  = ACC_W + QFRAC;   // dividend width: magnitude (ACC_W bits) << QFRAC
  localparam int REM_W = NORM_W + 1;
  localparam int ITER_W = $clog2(DIVW+1);

  logic                sign_r;
  logic [ACC_W-1:0]    mag_r;
  logic [NORM_W-1:0]   norm_r;
  logic [DIVW-1:0]     div_sr;    // remaining dividend bits, shifts left, MSB consumed each cycle
  logic [REM_W-1:0]    rem_r;
  logic [DIVW-1:0]     quot_r;
  logic [ITER_W-1:0]   iter_r;
  logic                busy_r, done_r;

  localparam logic [ACC_W-1:0] MAX_MAG = {1'b0, {(ACC_W-1){1'b1}}};  // largest safe positive magnitude

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy_r <= 1'b0;
      done_r <= 1'b0;
    end else if (start) begin
      sign_r <= proto_lane[ACC_W-1];
      mag_r  <= proto_lane[ACC_W-1] ? (~proto_lane + 1'b1) : proto_lane;
      norm_r <= norm;
      div_sr <= {(proto_lane[ACC_W-1] ? (~proto_lane + 1'b1) : proto_lane), {QFRAC{1'b0}}};
      rem_r  <= '0;
      quot_r <= '0;
      iter_r <= DIVW[ITER_W-1:0];
      busy_r <= 1'b1;
      done_r <= 1'b0;
    end else if (busy_r) begin
      logic               msb;
      logic [REM_W-1:0]   rem_shifted;
      msb         = div_sr[DIVW-1];
      rem_shifted = {rem_r[REM_W-2:0], msb};
      div_sr      <= div_sr << 1;
      if (rem_shifted >= {1'b0, norm_r}) begin
        rem_r  <= rem_shifted - {1'b0, norm_r};
        quot_r <= {quot_r[DIVW-2:0], 1'b1};
      end else begin
        rem_r  <= rem_shifted;
        quot_r <= {quot_r[DIVW-2:0], 1'b0};
      end
      iter_r <= iter_r - 1'b1;
      if (iter_r == ITER_W'(1)) begin
        busy_r <= 1'b0;
        done_r <= 1'b1;
      end
    end else begin
      done_r <= 1'b0;
    end
  end

  logic [ACC_W-1:0] mag_result;
  assign mag_result = (quot_r[ACC_W-1:0] > MAX_MAG) ? MAX_MAG : quot_r[ACC_W-1:0];

  assign busy   = busy_r;
  assign done   = done_r;
  assign result = sign_r ? (-$signed({1'b0, mag_result})) : $signed({1'b0, mag_result});

endmodule : fixed_div_seq_unit
