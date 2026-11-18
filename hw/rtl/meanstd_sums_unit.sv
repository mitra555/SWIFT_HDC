// =============================================================================
// meanstd_sums_unit.sv  (VIDEO FRONT-END, streaming temporal aggregation)
//
// Population mean and std (ddof=0, numpy .mean(0)/.std(0)) of one lane, from
// running sums accumulated while frames stream in, so no per-frame history
// needs to be stored:
//   S1 = sum x_t,  S2 = sum x_t^2     (x_t Q16.16, t = 0..T-1)
//   mean = trunc(S1 / T)                                   Q16.16
//   SSD  = S2 - 2*mean*S1 + T*mean^2  = sum (x_t - mean)^2  exact integer, Q32.32
//   var  = trunc((SSD >> 16) / T)                          Q16.16
//   std  = floor(sqrt(var << 16))                          Q16.16
// SSD is the exact sum of squared deviations from the (truncated) mean, so this
// avoids the cancellation problem of E[x^2]-E[x]^2 in floating point. It differs
// from the old two-pass meanstd_unit only in where the >>16 truncation happens
// (once on the sum here, per term there): at most a 1-LSB difference in var.
// Range: var is held in VAL_W bits (Q16.16), as in meanstd_unit, so the
// population std must stay below 2^(VAL_W/2-1) in real units (e.g. |x| < 256.0
// in practice). Front-end lanes are HOG/HOF in [0,1] and |dx|,|dy| <= 8.
// =============================================================================
import hdcu_pkg::*;

module meanstd_sums_unit #(
  parameter int VAL_W = 32,      // Q16.16 sample width
  parameter int S1_W  = 40,      // signed sum of up to 2^(S1_W-VAL_W) samples
  parameter int S2_W  = 72,      // unsigned sum of squares
  parameter int TW    = 7        // width of T
) (
  input  logic clk,
  input  logic rst_n,

  input  logic                     start,
  input  logic signed [S1_W-1:0]   s1,
  input  logic        [S2_W-1:0]   s2,
  input  logic        [TW-1:0]     num_samples,   // T

  output logic                     busy,
  output logic                     done,
  output logic signed [VAL_W-1:0]  mean_out,
  output logic signed [VAL_W-1:0]  std_out
);

  localparam int SSD_W = S2_W + 4;
  localparam int DIV_W = SSD_W;

  typedef enum logic [3:0] {
    S_IDLE, S_DIV_MEAN_START, S_DIV_MEAN_WAIT, S_SSD,
    S_DIV_VAR_START, S_DIV_VAR_WAIT, S_SQRT_START, S_SQRT_WAIT, S_DONE
  } state_e;
  state_e state_r, state_n;

  logic signed [S1_W-1:0]  s1_r;
  logic        [S2_W-1:0]  s2_r;
  logic        [TW-1:0]    t_r;
  logic signed [VAL_W-1:0] mean_r, var_r, std_r;
  logic signed [SSD_W-1:0] ssd_r;

  logic div_start, div_done;
  logic signed [DIV_W-1:0] div_dividend, div_divisor, div_quotient;
  seq_divider #(.W(DIV_W)) u_div (
    .clk(clk), .rst_n(rst_n), .start(div_start),
    .dividend(div_dividend), .divisor(div_divisor),
    .busy(), .done(div_done), .quotient(div_quotient)
  );

  logic isqrt_start, isqrt_done;
  logic [VAL_W+15:0] isqrt_value;
  logic [(VAL_W+16+1)/2-1:0] isqrt_root;
  isqrt_seq_unit #(.NORMSQ_W(VAL_W+16), .ROOT_W((VAL_W+16+1)/2)) u_isqrt (
    .clk(clk), .rst_n(rst_n), .start(isqrt_start), .value(isqrt_value),
    .busy(), .done(isqrt_done), .root(isqrt_root)
  );

  // exact sum of squared deviations, with each product sized to its operands
  // (VAL_W x S1_W, VAL_W x VAL_W, TW x 2*VAL_W) rather than to SSD_W
  logic signed [VAL_W+S1_W-1:0]    m_s1;
  logic signed [2*VAL_W-1:0]       m_sq;
  logic signed [2*VAL_W+TW:0]      t_m_sq;
  logic signed [SSD_W-1:0]         ssd_c;
  assign m_s1   = mean_r * s1_r;
  assign m_sq   = mean_r * mean_r;
  assign t_m_sq = $signed({1'b0, t_r}) * m_sq;
  assign ssd_c  = $signed({{(SSD_W-S2_W){1'b0}}, s2_r}) - (SSD_W'(m_s1) <<< 1) + SSD_W'(t_m_sq);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_r <= S_IDLE;
      mean_r <= '0; var_r <= '0; std_r <= '0;
    end else begin
      state_r <= state_n;
      case (state_r)
        S_IDLE: if (start) begin s1_r <= s1; s2_r <= s2; t_r <= num_samples; end
        S_DIV_MEAN_WAIT: if (div_done) mean_r <= div_quotient[VAL_W-1:0];
        S_SSD: ssd_r <= ssd_c;
        S_DIV_VAR_WAIT: if (div_done) var_r <= div_quotient[VAL_W-1:0];
        S_SQRT_WAIT: if (isqrt_done) std_r <= VAL_W'(isqrt_root);
        default: ;
      endcase
    end
  end

  assign isqrt_value  = {{16{1'b0}}, var_r} <<< 16;
  assign div_dividend = (state_r == S_DIV_MEAN_START || state_r == S_DIV_MEAN_WAIT)
                        ? DIV_W'(s1_r) : (ssd_r >>> 16);
  assign div_divisor  = DIV_W'({1'b0, t_r});

  always_comb begin
    state_n = state_r; div_start = 1'b0; isqrt_start = 1'b0;
    unique case (state_r)
      S_IDLE:           if (start) state_n = S_DIV_MEAN_START;
      S_DIV_MEAN_START: begin div_start = 1'b1; state_n = S_DIV_MEAN_WAIT; end
      S_DIV_MEAN_WAIT:  if (div_done) state_n = S_SSD;
      S_SSD:            state_n = S_DIV_VAR_START;
      S_DIV_VAR_START:  begin div_start = 1'b1; state_n = S_DIV_VAR_WAIT; end
      S_DIV_VAR_WAIT:   if (div_done) state_n = S_SQRT_START;
      S_SQRT_START:     begin isqrt_start = 1'b1; state_n = S_SQRT_WAIT; end
      S_SQRT_WAIT:      if (isqrt_done) state_n = S_DONE;
      S_DONE:           state_n = S_IDLE;
      default:          state_n = S_IDLE;
    endcase
  end

  assign busy     = (state_r != S_IDLE) && (state_r != S_DONE);
  assign done     = (state_r == S_DONE);
  assign mean_out = mean_r;
  assign std_out  = std_r;

endmodule : meanstd_sums_unit
