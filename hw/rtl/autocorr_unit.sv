// =============================================================================
// autocorr_unit.sv  (VIDEO FRONT-END, stage (4))
//
// Replicates the notebook's `autocorr(x, n)` exactly:
//   x = x - x.mean()
//   v = dot(x, x)
//   if v < 1e-8: return zeros
//   return [dot(x[:T-k], x[k:]) / v  for k in 1..n]
//
// Fixed point Q16.16 throughout. Uses generous intermediate widths
// (80-bit accumulators, 128-bit final ratio divider) rather than a
// tightly-optimized datapath -- correctness first; an area-optimized
// version would narrow these once real dataset magnitude bounds are
// derived (same caveat as flagged for the HDC accumulators earlier).
// =============================================================================
module autocorr_unit #(
  parameter int MAX_T    = 64,   // matches notebook's NUM_FRAMES-1 = 63 samples max
  parameter int N_LAGS    = 16,  // matches notebook's AC_LAGS
  parameter int VAL_W     = 32,  // Q16.16 signed sample width
  parameter int ACC_W     = 80,  // wide accumulator for sums of squares/products
  parameter int DIV_W     = 128  // wide divider for the final (dot<<16)/v ratio
) (
  input  logic clk,
  input  logic rst_n,

  input  logic                    load_we,
  input  logic [$clog2(MAX_T)-1:0] load_addr,
  input  logic signed [VAL_W-1:0] load_data,

  input  logic                    start,
  input  logic [$clog2(MAX_T+1)-1:0] num_samples,   // T (actual sample count <= MAX_T)

  output logic         busy,
  output logic         done,
  output logic [N_LAGS*VAL_W-1:0] result_packed   // packed: lane i (0-based, notebook lag i+1) at result_packed[i*VAL_W +: VAL_W]
);

  logic signed [VAL_W-1:0] x_mem [0:MAX_T-1];

  typedef enum logic [3:0] {
    S_IDLE, S_SUM, S_DIV_MEAN_START, S_DIV_MEAN_WAIT, S_CENTER,
    S_VSUM, S_LAGSUM, S_DIV_RATIO_START, S_DIV_RATIO_WAIT, S_NEXT_LAG, S_DONE
  } state_e;
  state_e state_r, state_n;

  logic [$clog2(MAX_T+1)-1:0] t_r;
  logic [$clog2(MAX_T)-1:0]   i_r;
  logic signed [ACC_W-1:0]    sum_r;         // running sum of x[i] (for mean)
  logic signed [VAL_W-1:0]    mean_r;
  logic signed [ACC_W-1:0]    v_r;           // sum of x_c[i]^2
  logic [$clog2(N_LAGS+1)-1:0] lag_r;
  logic signed [ACC_W-1:0]    dot_r;

  logic div1_start, div1_busy, div1_done;
  logic signed [ACC_W-1:0] div1_quotient;
  wire signed [ACC_W-1:0] div1_dividend = sum_r;
  wire signed [ACC_W-1:0] div1_divisor  = {{(ACC_W-$clog2(MAX_T+1)){1'b0}}, t_r};
  seq_divider #(.W(ACC_W)) u_div_mean (
    .clk(clk), .rst_n(rst_n), .start(div1_start),
    .dividend(div1_dividend), .divisor(div1_divisor),
    .busy(div1_busy), .done(div1_done), .quotient(div1_quotient)
  );

  logic div2_start, div2_busy, div2_done;
  logic signed [DIV_W-1:0] div2_quotient;
  wire signed [DIV_W-1:0] div2_dividend = ({{(DIV_W-ACC_W){dot_r[ACC_W-1]}}, dot_r}) <<< 16;
  wire signed [DIV_W-1:0] div2_divisor  = {{(DIV_W-ACC_W){v_r[ACC_W-1]}}, v_r};
  seq_divider #(.W(DIV_W)) u_div_ratio (
    .clk(clk), .rst_n(rst_n), .start(div2_start),
    .dividend(div2_dividend), .divisor(div2_divisor),
    .busy(div2_busy), .done(div2_done), .quotient(div2_quotient)
  );

  // Packed so it can be cleared with one assignment in every simulator and
  // synthesis tool. Cleared on every start so a v==0 (constant-series)
  // call returns zeros, as the notebook does, instead of the previous call's
  // results.
  logic [N_LAGS*VAL_W-1:0] result_vec;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_r <= S_IDLE;
      lag_r <= '0;
      v_r <= '0;
      dot_r <= '0;
      result_vec <= '0;
    end else begin
      state_r <= state_n;

      case (state_r)
        S_IDLE: begin
          if (load_we) x_mem[load_addr] <= load_data;
          if (start) begin
            t_r <= num_samples;
            i_r <= '0;
            sum_r <= '0;
            result_vec <= '0;
            lag_r <= '0;
            v_r <= '0;
            dot_r <= '0;
          end
        end

        S_SUM: begin
          sum_r <= sum_r + {{(ACC_W-VAL_W){x_mem[i_r][VAL_W-1]}}, x_mem[i_r]};
          i_r <= i_r + 1'b1;
        end

        S_DIV_MEAN_START: ;  // dividend/divisor driven combinationally below

        S_DIV_MEAN_WAIT: if (div1_done) begin
          mean_r <= div1_quotient[VAL_W-1:0];
          i_r <= '0;
        end

        S_CENTER: begin
          x_mem[i_r] <= x_mem[i_r] - mean_r;
          if (i_r == t_r[$clog2(MAX_T)-1:0] - 1'b1) i_r <= '0;
          else i_r <= i_r + 1'b1;
        end

        S_VSUM: begin
          logic signed [ACC_W-1:0] xi;
          xi = {{(ACC_W-VAL_W){x_mem[i_r][VAL_W-1]}}, x_mem[i_r]};
          v_r <= v_r + xi*xi;
          if (i_r == t_r[$clog2(MAX_T)-1:0] - 1'b1) i_r <= '0;
          else i_r <= i_r + 1'b1;
        end

        S_LAGSUM: begin
          logic signed [ACC_W-1:0] xi, xik;
          xi  = {{(ACC_W-VAL_W){x_mem[i_r][VAL_W-1]}}, x_mem[i_r]};
          xik = {{(ACC_W-VAL_W){x_mem[i_r+lag_r+1'b1][VAL_W-1]}}, x_mem[i_r+lag_r+1'b1]};
          // Only accumulate pairs that exist: index i_r+lag must be < T.
          // Without this guard the exit cycle still added one product, which
          // for lags >= T read x_mem past the valid samples (stale data from
          // the previous call, or out of range when T == MAX_T).
          if (int'(i_r) + int'(lag_r) + 1 < int'(t_r)) dot_r <= dot_r + xi*xik;
          i_r <= i_r + 1'b1;
        end

        S_DIV_RATIO_START: ;  // dividend/divisor driven combinationally below

        S_DIV_RATIO_WAIT: if (div2_done) begin
          result_vec[lag_r*VAL_W +: VAL_W] <= div2_quotient[VAL_W-1:0];
        end

        S_NEXT_LAG: begin
          lag_r <= lag_r + 1'b1;
          i_r <= '0;
          dot_r <= '0;
        end

        default: ;
      endcase
    end
  end

  // Last valid i for the current lag: T - (lag_r+1) - 1. Sized 32-bit signed:
  // it was originally sized from MAX_T alone, but lag_r (bounded by N_LAGS)
  // dominates when N_LAGS > MAX_T, and the narrow version wrapped negative
  // values to positive ones, stalling S_LAGSUM forever. Declared at module
  // scope (not inside the case branch) so no latch is inferred.
  logic signed [31:0] last_valid_i;
  assign last_valid_i = $signed({1'b0, t_r}) - $signed({1'b0, lag_r}) - 2;

  always_comb begin
    state_n = state_r;
    div1_start = 1'b0;
    div2_start = 1'b0;

    unique case (state_r)
      S_IDLE:  if (start) state_n = S_SUM;

      S_SUM:   if (i_r == t_r[$clog2(MAX_T)-1:0] - 1'b1 || t_r <= 1) state_n = S_DIV_MEAN_START;
               // (guard: with i_r starting at 0, this transitions once i_r reaches t_r-1
               //  on THIS cycle's use of i_r, i.e. after t_r accumulations complete)

      S_DIV_MEAN_START: begin
        div1_start = 1'b1;
        state_n = S_DIV_MEAN_WAIT;
      end

      S_DIV_MEAN_WAIT: if (div1_done) state_n = S_CENTER;

      S_CENTER: if (i_r == t_r[$clog2(MAX_T)-1:0] - 1'b1) state_n = S_VSUM;

      S_VSUM:   if (i_r == t_r[$clog2(MAX_T)-1:0] - 1'b1) begin
                  if (v_r == 0) state_n = S_DONE;
                  else state_n = S_LAGSUM;
                end

      S_LAGSUM: begin
        if (last_valid_i < 0) state_n = S_DIV_RATIO_START;
        else if ($signed({1'b0, i_r}) >= last_valid_i) state_n = S_DIV_RATIO_START;
      end

      S_DIV_RATIO_START: begin
        div2_start = 1'b1;
        state_n = S_DIV_RATIO_WAIT;
      end

      S_DIV_RATIO_WAIT: if (div2_done) state_n = S_NEXT_LAG;

      S_NEXT_LAG: if (lag_r + 1'b1 == N_LAGS[$clog2(N_LAGS+1)-1:0]) state_n = S_DONE;
                  else state_n = S_LAGSUM;

      S_DONE: state_n = S_IDLE;

      default: state_n = S_IDLE;
    endcase
  end

  assign busy = (state_r != S_IDLE) && (state_r != S_DONE);
  assign done = (state_r == S_DONE);

  genvar gi;
  generate
    for (gi = 0; gi < N_LAGS; gi++) begin : g_pack
      assign result_packed[gi*VAL_W +: VAL_W] = result_vec[gi*VAL_W +: VAL_W];
    end
  endgenerate

endmodule : autocorr_unit
