// =============================================================================
// percentile_unit.sv  (VIDEO FRONT-END, stage (4) - percentiles)
//
// Replicates numpy's `np.percentile(x, p)` default linear-interpolation
// method exactly, for the notebook's fixed percentile list [10,25,50,75,90]:
//   rank = p/100 * (n-1)
//   lo = floor(rank); hi = ceil(rank); frac = rank - lo
//   result = sorted[lo] + frac * (sorted[hi] - sorted[lo])
//
// Sorting: sequential bubble sort (O(n^2) compare-swaps, simple control
// flow, ample for the notebook's n <= 63). Fixed point Q16.16 throughout;
// rank/frac computed via integer division (seq_divider) since p and
// (n-1) are both small plain integers -- no transcendental functions
// needed, so an exact match to numpy's arithmetic is achievable, unlike
// HOG's gradient angle.
// =============================================================================
module percentile_unit #(
  parameter int MAX_T = 64,
  parameter int VAL_W = 32     // Q16.16 signed
) (
  input  logic clk,
  input  logic rst_n,

  input  logic                     load_we,
  input  logic [$clog2(MAX_T)-1:0] load_addr,
  input  logic signed [VAL_W-1:0]  load_data,

  input  logic                        start,
  input  logic [$clog2(MAX_T+1)-1:0]  num_samples,

  output logic         busy,
  output logic         done,
  output logic [5*VAL_W-1:0] result_packed   // 5 lanes, p=[10,25,50,75,90], Q16.16
);

  logic signed [VAL_W-1:0] x_mem [0:MAX_T-1];

  // -------------------------------------------------------------------
  // Bubble sort ascending: for pass in 0..n-2, for j in 0..n-2-pass:
  // if x[j] > x[j+1] swap.
  // -------------------------------------------------------------------
  typedef enum logic [3:0] {
    S_IDLE, S_SORT, S_RANK_NUM, S_DIV_LO_START, S_DIV_LO_WAIT,
    S_REM_CALC, S_DIV_FRAC_START, S_DIV_FRAC_WAIT, S_INTERP, S_NEXT_P, S_DONE
  } state_e;
  state_e state_r, state_n;

  logic [$clog2(MAX_T+1)-1:0] t_r;
  logic [$clog2(MAX_T)-1:0]   pass_r, j_r;
  logic                       sort_done_r;

  localparam int NUM_P = 5;
  // Percentile list [10,25,50,75,90] as a constant function. It was previously
  // set in an `initial` block, which ASIC synthesis ignores (p would be 0 in silicon).
  function automatic logic [7:0] p_list(input logic [$clog2(NUM_P+1)-1:0] i);
    case (i)
      0: return 8'd10;
      1: return 8'd25;
      2: return 8'd50;
      3: return 8'd75;
      default: return 8'd90;
    endcase
  endfunction
  logic [$clog2(NUM_P+1)-1:0] pidx_r;

  logic [15:0] rank_num_r;     // p*(n-1), small integer
  logic [$clog2(MAX_T)-1:0] lo_r, hi_r;
  logic [15:0] rem_r;
  logic signed [VAL_W-1:0] frac_q16_r;
  logic signed [VAL_W-1:0] result_r [NUM_P];

  logic div1_start, div1_done;
  logic signed [31:0] div1_dividend, div1_divisor, div1_quotient;
  seq_divider #(.W(32)) u_div_lo (
    .clk(clk), .rst_n(rst_n), .start(div1_start),
    .dividend(div1_dividend), .divisor(div1_divisor),
    .busy(), .done(div1_done), .quotient(div1_quotient)
  );
  assign div1_dividend = {{16{1'b0}}, rank_num_r};
  assign div1_divisor  = 32'd100;

  logic div2_start, div2_done;
  logic signed [31:0] div2_dividend, div2_divisor, div2_quotient;
  seq_divider #(.W(32)) u_div_frac (
    .clk(clk), .rst_n(rst_n), .start(div2_start),
    .dividend(div2_dividend), .divisor(div2_divisor),
    .busy(), .done(div2_done), .quotient(div2_quotient)
  );
  assign div2_dividend = ({{16{1'b0}}, rem_r}) <<< 16;
  assign div2_divisor  = 32'd100;

  wire signed [VAL_W-1:0] xj  = x_mem[j_r];
  wire signed [VAL_W-1:0] xj1 = x_mem[j_r+1'b1];
  wire do_swap = (t_r > 1) && (xj > xj1);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_r <= S_IDLE;
    end else begin
      state_r <= state_n;

      case (state_r)
        S_IDLE: begin
          if (load_we) x_mem[load_addr] <= load_data;
          if (start) begin
            t_r <= num_samples;
            pass_r <= '0;
            j_r <= '0;
            pidx_r <= '0;
          end
        end

        S_SORT: begin
          if (do_swap) begin
            x_mem[j_r]   <= xj1;
            x_mem[j_r+1] <= xj;
          end
          if (j_r == t_r - pass_r - 2'd2) begin
            j_r <= '0;
            pass_r <= pass_r + 1'b1;
          end else begin
            j_r <= j_r + 1'b1;
          end
        end

        S_RANK_NUM: begin
          rank_num_r <= {8'b0, p_list(pidx_r)} * ({8'b0, t_r} - 1'b1);
        end

        S_REM_CALC: begin
          rem_r <= rank_num_r - {8'b0, lo_r} * 16'd100;
        end

        S_DIV_LO_WAIT: if (div1_done) begin
          lo_r <= div1_quotient[$clog2(MAX_T)-1:0];
        end

        S_DIV_FRAC_WAIT: if (div2_done) begin
          frac_q16_r <= div2_quotient[VAL_W-1:0];
        end

        S_INTERP: begin
          logic signed [VAL_W-1:0] sorted_lo, sorted_hi, diff;
          logic signed [2*VAL_W-1:0] prod;
          sorted_lo = x_mem[lo_r];
          sorted_hi = (rem_r == 0) ? x_mem[lo_r] : x_mem[lo_r+1'b1];
          diff = sorted_hi - sorted_lo;
          prod = diff * frac_q16_r;
          result_r[pidx_r] <= sorted_lo + prod[16 +: VAL_W];
        end

        S_NEXT_P: pidx_r <= pidx_r + 1'b1;

        default: ;
      endcase
    end
  end

  always_comb begin
    state_n = state_r;
    div1_start = 1'b0;
    div2_start = 1'b0;

    unique case (state_r)
      S_IDLE: if (start) begin
        if (num_samples <= 1) state_n = S_DONE;
        else state_n = S_SORT;
      end

      S_SORT: if (pass_r == t_r - 1'b1) state_n = S_RANK_NUM;

      S_RANK_NUM: state_n = S_DIV_LO_START;

      S_DIV_LO_START: begin
        div1_start = 1'b1;
        state_n = S_DIV_LO_WAIT;
      end

      S_DIV_LO_WAIT: if (div1_done) state_n = S_REM_CALC;

      S_REM_CALC: state_n = S_DIV_FRAC_START;

      S_DIV_FRAC_START: begin
        div2_start = 1'b1;
        state_n = S_DIV_FRAC_WAIT;
      end

      S_DIV_FRAC_WAIT: if (div2_done) state_n = S_INTERP;

      S_INTERP: state_n = S_NEXT_P;

      S_NEXT_P: if (pidx_r + 1'b1 == NUM_P[$clog2(NUM_P+1)-1:0]) state_n = S_DONE;
                else state_n = S_RANK_NUM;

      S_DONE: state_n = S_IDLE;

      default: state_n = S_IDLE;
    endcase
  end

  assign busy = (state_r != S_IDLE) && (state_r != S_DONE);
  assign done = (state_r == S_DONE);

  genvar gi;
  generate
    for (gi = 0; gi < NUM_P; gi++) begin : g_pack
      assign result_packed[gi*VAL_W +: VAL_W] = result_r[gi];
    end
  endgenerate

endmodule : percentile_unit
