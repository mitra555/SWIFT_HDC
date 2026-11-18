// =============================================================================
// meanstd_unit.sv  (VIDEO FRONT-END GLUE -- new, not in any prior round)
//
// Computes mean and population std (ddof=0, matching numpy's default
// `.mean(0)` / `.std(0)`) of a stream of up to MAX_T Q16.16 signed samples,
// for ONE lane at a time. The caller (video_frontend_top) re-runs this
// unit once per lane of hog_seq (324 lanes), hof_seq (128 lanes),
// dx_c/dy_c (16 lanes each) -- exactly the temporal-aggregation step the
// notebook does with `.mean(0)`/`.std(0)` across the T-1 frame axis,
// which no earlier round of this project built at all.
//
// Two-pass algorithm (matches numpy's actual two-pass mean-then-variance,
// not the single-pass E[x^2]-mean^2 shortcut, to avoid its cancellation
// error):
//   mean = (sum x_i) / T
//   var  = (sum (x_i-mean)^2) / T
//   std  = sqrt(var)
// All arithmetic in Q16.16 fixed point.
// =============================================================================
module meanstd_unit #(
  parameter int MAX_T = 64,
  parameter int VAL_W = 32     // Q16.16 signed
) (
  input  logic clk,
  input  logic rst_n,

  input  logic                        load_we,
  input  logic [$clog2(MAX_T)-1:0]    load_addr,
  input  logic signed [VAL_W-1:0]     load_data,

  input  logic                        start,
  input  logic [$clog2(MAX_T+1)-1:0]  num_samples,   // T (actual sample count <= MAX_T)

  output logic                        busy,
  output logic                        done,
  output logic signed [VAL_W-1:0]     mean_out,   // Q16.16
  output logic signed [VAL_W-1:0]     std_out     // Q16.16 (unsigned magnitude in a signed field)
);

  localparam int TW      = $clog2(MAX_T+1);
  localparam int SUM_W   = VAL_W + TW + 4;   // sum of up to MAX_T Q16.16 values
  localparam int SQ_W    = 2*VAL_W;          // one (x-mean)^2 product, Q32.32 raw
  localparam int SUMSQ_W = SQ_W + TW + 4;    // sum of up to MAX_T squared terms

  logic signed [VAL_W-1:0] x_mem [0:MAX_T-1];

  always_ff @(posedge clk) begin
    if (load_we) x_mem[load_addr] <= load_data;
  end

  typedef enum logic [3:0] {
    S_IDLE, S_SUM_LOOP, S_DIV_MEAN_START, S_DIV_MEAN_WAIT,
    S_SQ_LOOP, S_DIV_VAR_START, S_DIV_VAR_WAIT,
    S_SQRT_START, S_SQRT_WAIT, S_DONE
  } state_e;
  state_e state_r, state_n;

  logic [TW-1:0] t_r;
  logic signed [SUM_W-1:0] sum_r;
  logic signed [VAL_W-1:0] mean_r;
  logic signed [SUMSQ_W-1:0] sumsq_r;
  logic signed [VAL_W-1:0] var_r;
  logic signed [VAL_W-1:0] std_r;

  // divider for mean = sum/T and var = sumsq/T (plain integer T divisor,
  // dividend already carries the Q16.16 scale, exactly like autocorr_unit)
  logic div_start, div_done;
  logic signed [SUMSQ_W-1:0] div_dividend;
  logic signed [SUMSQ_W-1:0] div_divisor;
  logic signed [SUMSQ_W-1:0] div_quotient;
  seq_divider #(.W(SUMSQ_W)) u_div (
    .clk(clk), .rst_n(rst_n), .start(div_start),
    .dividend(div_dividend), .divisor(div_divisor),
    .busy(), .done(div_done), .quotient(div_quotient)
  );

  logic isqrt_start, isqrt_done;
  logic [VAL_W+15:0] isqrt_value;    // variance (Q16.16) << 16 -> sqrt result is Q16.16
  logic [(VAL_W+15+1)/2-1:0] isqrt_root;
  isqrt_seq_unit #(.NORMSQ_W(VAL_W+16), .ROOT_W((VAL_W+16+1)/2)) u_isqrt (
    .clk(clk), .rst_n(rst_n), .start(isqrt_start), .value(isqrt_value[VAL_W+15:0]),
    .busy(), .done(isqrt_done), .root(isqrt_root)
  );

  wire signed [VAL_W-1:0] diff = x_mem[t_r] - mean_r;
  // (x-mean)^2 in Q16.16: (Q16.16 * Q16.16 = Q32.32 raw) >> 16, keep lower VAL_W bits worth
  wire signed [SQ_W-1:0]  diff_sq_raw = diff * diff;
  wire signed [SQ_W-1:0]  diff_sq_q16 = diff_sq_raw >>> 16;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_r <= S_IDLE;
    end else begin
      state_r <= state_n;

      case (state_r)
        S_IDLE: if (start) begin
          t_r   <= '0;
          sum_r <= '0;
        end

        S_SUM_LOOP: begin
          sum_r <= sum_r + x_mem[t_r];
          t_r   <= t_r + 1'b1;
        end

        S_DIV_MEAN_WAIT: if (div_done) begin
          mean_r <= div_quotient[VAL_W-1:0];
          t_r    <= '0;
          sumsq_r <= '0;
        end

        S_SQ_LOOP: begin
          sumsq_r <= sumsq_r + diff_sq_q16;
          t_r     <= t_r + 1'b1;
        end

        S_DIV_VAR_WAIT: if (div_done) var_r <= div_quotient[VAL_W-1:0];

        S_SQRT_WAIT: if (isqrt_done) std_r <= {{(VAL_W-((VAL_W+16+1)/2)){1'b0}}, isqrt_root};

        default: ;
      endcase
    end
  end

  assign isqrt_value  = {{16{1'b0}}, var_r} <<< 16;
  assign div_dividend = (state_r == S_DIV_MEAN_START || state_r == S_DIV_MEAN_WAIT)
                        ? {{(SUMSQ_W-SUM_W){sum_r[SUM_W-1]}}, sum_r}
                        : sumsq_r;
  assign div_divisor  = {{(SUMSQ_W-TW){1'b0}}, num_samples};

  always_comb begin
    state_n = state_r;
    div_start = 1'b0;
    isqrt_start = 1'b0;

    unique case (state_r)
      S_IDLE: if (start) state_n = S_SUM_LOOP;

      S_SUM_LOOP: if (t_r + 1'b1 == num_samples[TW-1:0]) state_n = S_DIV_MEAN_START;

      S_DIV_MEAN_START: begin
        div_start = 1'b1;
        state_n = S_DIV_MEAN_WAIT;
      end
      S_DIV_MEAN_WAIT: if (div_done) state_n = S_SQ_LOOP;

      S_SQ_LOOP: if (t_r + 1'b1 == num_samples[TW-1:0]) state_n = S_DIV_VAR_START;

      S_DIV_VAR_START: begin
        div_start = 1'b1;
        state_n = S_DIV_VAR_WAIT;
      end
      S_DIV_VAR_WAIT: if (div_done) state_n = S_SQRT_START;

      S_SQRT_START: begin
        isqrt_start = 1'b1;
        state_n = S_SQRT_WAIT;
      end
      S_SQRT_WAIT: if (isqrt_done) state_n = S_DONE;

      S_DONE: state_n = S_IDLE;
      default: state_n = S_IDLE;
    endcase
  end

  assign busy = (state_r != S_IDLE) && (state_r != S_DONE);
  assign done = (state_r == S_DONE);
  assign mean_out = mean_r;
  assign std_out   = std_r;

endmodule : meanstd_unit
