// =============================================================================
// fastatan2_unit.sv  (VIDEO FRONT-END, stage (2) - HOG angle)
//
// Exact replication of OpenCV's cv::fastAtan2 polynomial approximation
// (modules/core/src/mathfuncs_core.simd.hpp), NOT a mathematically "better"
// atan2 -- OpenCV's own HOG output is built on this SPECIFIC ~0.3-degree
// approximation, so matching cv2 means matching this polynomial exactly,
// coefficient for coefficient:
//
//   c = min(ax,ay)/max(ax,ay);  c2 = c*c
//   poly = (((p7*c2+p5)*c2+p3)*c2+p1)*c
//   a = (ax>=ay) ? poly : 90-poly
//   if (x<0) a = 180-a
//   if (y<0) a = 360-a
//
// Verified (as a from-scratch Python reimplementation, hog_golden.py) to
// agree with real cv2.HOGDescriptor.compute() output to ~1.3e-7 (float32
// precision floor) across 6 random seeds, BEFORE this RTL was written --
// this module replicates that already-validated Python exactly.
//
// Q16.16 fixed point throughout. Division (for c) via the already-verified
// seq_divider; polynomial evaluation via a short sequential multiply-
// accumulate chain (4 Q16.16 multiplies with right-shift-by-16 rescaling
// at each step, the same pattern used in quantize_unit/autocorr_unit).
// =============================================================================
module fastatan2_unit #(
  parameter int W = 32   // Q16.16 signed
) (
  input  logic clk,
  input  logic rst_n,

  input  logic         start,
  input  logic signed [W-1:0] dx,
  input  logic signed [W-1:0] dy,

  output logic         busy,
  output logic         done,
  output logic [W-1:0] angle_deg   // Q16.16, unsigned, range [0, 360*65536)
);

  // coefficients: p_k * (180/pi), Q16.16 (precisely computed, not hand-estimated)
  localparam signed [W-1:0] P1 = 32'sd3754140;    //  0.9997878412794807 * (180/pi) * 65536
  localparam signed [W-1:0] P3 = -32'sd1223390;    // -0.3258083974640975 * (180/pi) * 65536
  localparam signed [W-1:0] P5 = 32'sd584188;      //  0.1555786518463281 * (180/pi) * 65536
  localparam signed [W-1:0] P7 = -32'sd166443;     // -0.04432655554792128 * (180/pi) * 65536
  localparam signed [W-1:0] DEG90  = 32'sd5898240;   // 90  * 65536
  localparam signed [W-1:0] DEG180 = 32'sd11796480;  // 180 * 65536
  localparam signed [W-1:0] DEG360 = 32'sd23592960;  // 360 * 65536

  wire signed [W-1:0] ax = dx[W-1] ? (-dx) : dx;
  wire signed [W-1:0] ay = dy[W-1] ? (-dy) : dy;
  wire                use_ax = (ax >= ay);
  wire signed [W-1:0] numerator_raw = use_ax ? ay : ax;
  wire signed [W-1:0] denominator   = (use_ax ? ax : ay) + 32'sd1;  // +1 ULP guards exact 0/0

  // c = numerator/denominator is bounded in [0,1] by construction (we always
  // pick the smaller of ax,ay as the numerator), so the RESULT fits easily
  // in W bits -- but shifting the numerator left by 16 (to get a Q16.16
  // fractional quotient rather than a truncated-to-0-or-1 integer one)
  // needs headroom beyond W bits if the numerator itself has any sizeable
  // integer part. Do the shift+divide at double width, then take the
  // bounded result back down.
  localparam int WIDE_W = 2*W;
  logic div_start, div_done;
  logic signed [W-1:0] c_r;
  logic signed [WIDE_W-1:0] div_quotient_wide;
  seq_divider #(.W(WIDE_W)) u_div (
    .clk(clk), .rst_n(rst_n), .start(div_start),
    .dividend({{W{numerator_raw[W-1]}}, numerator_raw} <<< 16),
    .divisor({{W{denominator[W-1]}}, denominator}),
    .busy(), .done(div_done), .quotient(div_quotient_wide)
  );
  assign c_r = div_quotient_wide[W-1:0];

  typedef enum logic [2:0] {S_IDLE, S_DIV_START, S_DIV_WAIT, S_POLY, S_FINAL, S_DONE} state_e;
  state_e state_r, state_n;

  logic use_ax_r, xneg_r, yneg_r;
  logic signed [W-1:0] c2_r, acc_r, poly_r, result_r;

  function automatic signed [W-1:0] qmul(input signed [W-1:0] a, input signed [W-1:0] b);
    logic signed [2*W-1:0] p;
    begin
      p = a * b;
      qmul = p[W+15 -: W];   // >>16 rescale
    end
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_r <= S_IDLE;
    end else begin
      state_r <= state_n;
      case (state_r)
        S_IDLE: if (start) begin
          use_ax_r <= use_ax;
          xneg_r   <= dx[W-1];
          yneg_r   <= dy[W-1];
        end
        S_DIV_WAIT: if (div_done) begin
          c2_r <= qmul(c_r, c_r);
        end
        S_POLY: begin
          acc_r  <= qmul(qmul(qmul(qmul(P7, c2_r) + P5, c2_r) + P3, c2_r) + P1, c_r);
        end
        S_FINAL: begin
          // compute the FULLY adjusted result in the SAME cycle that
          // transitions into S_DONE (where `done` is asserted), rather
          // than lagging it one more cycle behind -- the bug this fixes
          // was masked in earlier standalone testing by an extra
          // settling cycle in that testbench's own wait sequence, and
          // only surfaced once this unit was driven back-to-back inside
          // a larger controller with no such slack.
          logic signed [W-1:0] tmp;
          tmp = use_ax_r ? acc_r : (DEG90 - acc_r);
          if (xneg_r) tmp = DEG180 - tmp;
          if (yneg_r) tmp = DEG360 - tmp;
          result_r <= tmp;
        end
        default: ;
      endcase
    end
  end

  always_comb begin
    state_n = state_r;
    div_start = 1'b0;
    unique case (state_r)
      S_IDLE:      if (start) state_n = S_DIV_START;
      S_DIV_START: begin div_start = 1'b1; state_n = S_DIV_WAIT; end
      S_DIV_WAIT:  if (div_done) state_n = S_POLY;
      S_POLY:      state_n = S_FINAL;
      S_FINAL:     state_n = S_DONE;
      S_DONE:      state_n = S_IDLE;
      default:     state_n = S_IDLE;
    endcase
  end

  assign busy      = (state_r != S_IDLE) && (state_r != S_DONE);
  assign done      = (state_r == S_DONE);
  assign angle_deg = result_r;

endmodule : fastatan2_unit
