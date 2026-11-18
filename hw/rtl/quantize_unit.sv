// =============================================================================
// quantize_unit.sv  (INPUT ENCODER)
//
// This is the piece that was explicitly absent from every prior round:
// hardware that turns a RAW FEATURE VALUE into a level-vector index,
// rather than assuming the host already did it. Implements exactly the
// notebook's quantization formula from `encode_multigroup`:
//
//   idx = clip( round( (feat - fmin) / span * (nlvl-1) ), 0, nlvl-1 )
//   where span = fmax - fmin  (per-group, per-feature, precomputed on
//   the host from the training set's min/max -- those two scalars ARE
//   still a host responsibility, same as the paper's own convention;
//   what's now real hardware is the divide-multiply-round-clamp that
//   turns a live feature reading into an index using them)
//
// Fixed-point format: Q16.16 signed for feat/fmin/span (FEAT_W=32),
// which comfortably covers the notebook's feature ranges (HOG/HOF bins
// in [0,1], block-matching displacements in pixels, autocorrelation in
// [-1,1], percentiles) with 16 fractional bits of precision and a
// magnitude range of +-32768.0.
//
// Rounding matches Python's round-half-away-from-zero via the classic
// "add half the divisor before truncating divide" trick, done on a
// wide SIGNED numerator so it's correct for feat < fmin too (clamped
// away by the final clip stage regardless).
//
// Sequential (bit-serial) magnitude divider, in the same architectural
// spirit as fixed_div_seq_unit.sv -- trading a few dozen cycles of
// latency for a much smaller divider footprint, consistent with the
// paper's own philosophy of trading time for area (Section III-A).
// =============================================================================
import hdcu_pkg::*;

module quantize_unit #(
  parameter int FEAT_W = 32,   // Q16.16 signed
  parameter int NLVL_W = 8,    // unsigned level count (nlvl-1 fits comfortably)
  parameter int IDX_W  = 8     // output index width
) (
  input  logic                     clk,
  input  logic                     rst_n,

  input  logic                     start,
  input  logic signed [FEAT_W-1:0] feat,      // raw feature value, Q16.16
  input  logic signed [FEAT_W-1:0] fmin,      // Q16.16
  input  logic signed [FEAT_W-1:0] span,      // Q16.16, caller guarantees span > 0
  input  logic [NLVL_W-1:0]        nlvl,      // number of levels (>=2)

  output logic                     busy,
  output logic                     done,      // one-cycle pulse
  output logic [IDX_W-1:0]         idx        // clamped to [0, nlvl-1]
);

  localparam int PROD_W = FEAT_W + NLVL_W + 2;   // diff * (nlvl-1), signed, with margin
  localparam int DIVW   = PROD_W;                // dividend width for the serial divider
  localparam int ITER_W = $clog2(DIVW+1);

  // -------------------------------------------------------------------
  // Stage 0 (combinational): diff = feat - fmin ; numerator = diff*(nlvl-1)
  // -------------------------------------------------------------------
  logic signed [FEAT_W:0]      diff;
  // nlvl-1 needs NLVL_W+1 bits as a signed value: with NLVL_W bits, nlvl >= 129
  // made nlvl-1 negative and every feature quantized to level 0.
  logic signed [NLVL_W:0]      nlvl_m1;
  logic signed [PROD_W-1:0]    numerator;

  assign diff      = feat - fmin;
  assign nlvl_m1   = $signed({1'b0, nlvl}) - $signed((NLVL_W+1)'(1));
  assign numerator = diff * nlvl_m1;

  // half-divisor rounding: nudge the numerator toward +-span/2 (sign
  // matching the numerator) before the truncating divide below, which
  // turns truncation into round-half-away-from-zero.
  logic signed [PROD_W-1:0] span_ext, half_span, numerator_adj;
  assign span_ext  = {{(PROD_W-FEAT_W){span[FEAT_W-1]}}, span};
  assign half_span = span_ext >>> 1;
  assign numerator_adj = (numerator >= 0) ? (numerator + half_span) : (numerator - half_span);

  // -------------------------------------------------------------------
  // Stage 1 (sequential): magnitude divide |numerator_adj| / |span|,
  // restoring bit-serial division, then reapply sign.
  // -------------------------------------------------------------------
  logic               sign_r;
  logic [PROD_W-1:0]  mag_r;
  logic [PROD_W-1:0]  div_sr;      // shifting dividend magnitude
  logic [PROD_W-1:0]  divisor_r;
  logic [PROD_W:0]    rem_r;
  logic [PROD_W-1:0]  quot_r;
  logic [ITER_W-1:0]  iter_r;
  logic               busy_r, done_r;
  logic [NLVL_W-1:0]  nlvl_r;

  logic signed [PROD_W:0] signed_quot;
  logic [IDX_W-1:0]       idx_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy_r <= 1'b0;
      done_r <= 1'b0;
      idx_r  <= '0;
    end else if (start) begin
      sign_r    <= numerator_adj[PROD_W-1];
      mag_r     <= numerator_adj[PROD_W-1] ? (~numerator_adj + 1'b1) : numerator_adj;
      div_sr    <= numerator_adj[PROD_W-1] ? (~numerator_adj + 1'b1) : numerator_adj;
      divisor_r <= span[FEAT_W-1] ? (~span_ext + 1'b1) : span_ext;   // |span|, defensively
      rem_r     <= '0;
      quot_r    <= '0;
      iter_r    <= DIVW[ITER_W-1:0];
      nlvl_r    <= nlvl;
      busy_r    <= 1'b1;
      done_r    <= 1'b0;
    end else if (busy_r) begin
      logic             msb;
      logic [PROD_W:0]  rem_shifted;
      logic [PROD_W-1:0] next_quot;
      msb         = div_sr[PROD_W-1];
      rem_shifted = {rem_r[PROD_W-1:0], msb};
      div_sr      <= div_sr << 1;
      if (rem_shifted >= {1'b0, divisor_r}) begin
        rem_r     <= rem_shifted - {1'b0, divisor_r};
        next_quot =  {quot_r[PROD_W-2:0], 1'b1};
      end else begin
        rem_r     <= rem_shifted;
        next_quot =  {quot_r[PROD_W-2:0], 1'b0};
      end
      quot_r <= next_quot;
      iter_r <= iter_r - 1'b1;
      if (iter_r == ITER_W'(1)) begin
        busy_r <= 1'b0;
        done_r <= 1'b1;
        // compute the final clamp in THIS same cycle (using next_quot,
        // the value quot_r is about to become) so idx_r updates on the
        // identical edge that done_r does -- a separate always_ff
        // reacting to done_r one cycle later would make idx_r lag one
        // cycle behind the externally-visible `done` pulse.
        signed_quot = sign_r ? -{1'b0, next_quot} : {1'b0, next_quot};
        if (signed_quot <= 0)
          idx_r <= '0;
        else if (signed_quot >= $signed({1'b0, nlvl_r}) - 1)
          idx_r <= nlvl_r - 1'b1;
        else
          idx_r <= signed_quot[IDX_W-1:0];
      end
    end else begin
      done_r <= 1'b0;
    end
  end

  assign busy = busy_r;
  assign done = done_r;
  assign idx  = idx_r;

endmodule : quantize_unit
