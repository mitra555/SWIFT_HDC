// =============================================================================
// l2hys_unit.sv  (VIDEO FRONT-END, stage (2) - HOG block normalization)
//
// Exact replication of OpenCV's L2-Hys block normalization (confirmed
// formula, from OpenCV's own issue tracker discussion of normalizeBlockHistogram):
//   n1 = sqrt(sum(h^2)) + sz*0.1
//   h' = h / n1
//   h' = min(h', 0.2)              (L2HysThreshold, default)
//   n2 = sqrt(sum(h'^2)) + 1e-3
//   out = h' / n2
//
// Reuses isqrt_seq_unit and seq_divider (both already verified elsewhere
// in this project) rather than re-deriving sqrt/divide primitives.
// =============================================================================
import hdcu_pkg::*;

module l2hys_unit #(
  parameter int SZ = 36,
  parameter int VAL_W = 32
) (
  input  logic clk,
  input  logic rst_n,

  input  logic         start,
  input  logic [SZ*VAL_W-1:0] hist_in_packed,   // Q16.16

  output logic         busy,
  output logic         done,
  output logic [SZ*VAL_W-1:0] hist_out_packed   // Q16.16
);

  localparam signed [VAL_W-1:0] SZ_TIMES_0P1_Q16 = (SZ*6554);  // sz*0.1 in Q16.16 (0.1*65536=6553.6 ~ 6554)
  localparam signed [VAL_W-1:0] EPS_1EM3_Q16      = 32'sd66;    // 1e-3*65536 ~ 66
  localparam signed [VAL_W-1:0] THRESH_0P2_Q16    = 32'sd13107; // 0.2*65536

  logic signed [VAL_W-1:0] h_mem [0:SZ-1];   // working buffer

  typedef enum logic [4:0] {
    S_IDLE, S_SUMSQ1, S_SQRT1_START, S_SQRT1_WAIT, S_ADD_EPS1,
    S_DIV1_START, S_DIV1_WAIT, S_CLIP, S_NEXT_DIV1,
    S_SUMSQ2, S_SQRT2_START, S_SQRT2_WAIT, S_ADD_EPS2,
    S_DIV2_START, S_DIV2_WAIT, S_NEXT_DIV2, S_DONE
  } state_e;
  state_e state_r, state_n;

  logic [5:0] i_r;
  logic [63:0] sumsq_r;
  logic [31:0] norm_r;      // Q16.16, current normalization divisor (n1 then n2)
  logic [31:0] sqrt_result;

  logic sqrt_start, sqrt_done;
  logic [63:0] sqrt_value;
  isqrt_seq_unit #(.NORMSQ_W(64), .ROOT_W(32)) u_isqrt (
    .clk(clk), .rst_n(rst_n), .start(sqrt_start), .value(sqrt_value),
    .busy(), .done(sqrt_done), .root(sqrt_result)
  );
  assign sqrt_value = sumsq_r;   // h values Q16.16 -> h^2 raw = real^2 * 2^32, sqrt of that = real*2^16 = Q16.16

  logic div_start, div_done;
  logic signed [63:0] div_dividend, div_divisor, div_quotient;
  seq_divider #(.W(64)) u_div (
    .clk(clk), .rst_n(rst_n), .start(div_start),
    .dividend(div_dividend), .divisor(div_divisor),
    .busy(), .done(div_done), .quotient(div_quotient)
  );
  assign div_dividend = ({{32{h_mem[i_r][VAL_W-1]}}, h_mem[i_r]}) <<< 16;
  assign div_divisor  = {{32{norm_r[VAL_W-1]}}, norm_r};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_r <= S_IDLE;
    end else begin
      state_r <= state_n;
      case (state_r)
        S_IDLE: if (start) begin
          i_r <= '0;
          sumsq_r <= '0;
          for (int k = 0; k < SZ; k++)
            h_mem[k] <= hist_in_packed[k*VAL_W +: VAL_W];
        end

        S_SUMSQ1: begin
          logic signed [63:0] xi;
          xi = {{32{h_mem[i_r][VAL_W-1]}}, h_mem[i_r]};
          sumsq_r <= sumsq_r + xi*xi;
          i_r <= i_r + 1'b1;
        end

        S_ADD_EPS1: begin
          norm_r <= sqrt_result + SZ_TIMES_0P1_Q16;
          i_r <= '0;
        end

        S_DIV1_WAIT: if (div_done) begin
          h_mem[i_r] <= div_quotient[VAL_W-1:0];
        end

        S_CLIP: begin
          if (h_mem[i_r] > THRESH_0P2_Q16) h_mem[i_r] <= THRESH_0P2_Q16;
          i_r <= i_r + 1'b1;
        end

        S_NEXT_DIV1: begin
          i_r <= '0;
          sumsq_r <= '0;
        end

        S_SUMSQ2: begin
          logic signed [63:0] xi;
          xi = {{32{h_mem[i_r][VAL_W-1]}}, h_mem[i_r]};
          sumsq_r <= sumsq_r + xi*xi;
          i_r <= i_r + 1'b1;
        end

        S_ADD_EPS2: begin
          norm_r <= sqrt_result + EPS_1EM3_Q16;
          i_r <= '0;
        end

        S_DIV2_WAIT: if (div_done) begin
          h_mem[i_r] <= div_quotient[VAL_W-1:0];
        end

        S_NEXT_DIV2: i_r <= i_r + 1'b1;

        default: ;
      endcase
    end
  end

  always_comb begin
    state_n = state_r;
    sqrt_start = 1'b0;
    div_start = 1'b0;

    unique case (state_r)
      S_IDLE: if (start) state_n = S_SUMSQ1;

      S_SUMSQ1: if (i_r == SZ[5:0]-1) state_n = S_SQRT1_START;

      S_SQRT1_START: begin sqrt_start = 1'b1; state_n = S_SQRT1_WAIT; end
      S_SQRT1_WAIT:  if (sqrt_done) state_n = S_ADD_EPS1;
      S_ADD_EPS1:    state_n = S_DIV1_START;

      S_DIV1_START: begin div_start = 1'b1; state_n = S_DIV1_WAIT; end
      S_DIV1_WAIT:  if (div_done) state_n = S_CLIP;
      S_CLIP:       if (i_r == SZ[5:0]-1) state_n = S_NEXT_DIV1;
                    else state_n = S_DIV1_START;
      S_NEXT_DIV1:  state_n = S_SUMSQ2;   // i_r/sumsq reset happens in S_ADD_EPS1... see note below

      S_SUMSQ2: if (i_r == SZ[5:0]-1) state_n = S_SQRT2_START;

      S_SQRT2_START: begin sqrt_start = 1'b1; state_n = S_SQRT2_WAIT; end
      S_SQRT2_WAIT:  if (sqrt_done) state_n = S_ADD_EPS2;
      S_ADD_EPS2:    state_n = S_DIV2_START;

      S_DIV2_START: begin div_start = 1'b1; state_n = S_DIV2_WAIT; end
      S_DIV2_WAIT:  if (div_done) state_n = S_NEXT_DIV2;
      S_NEXT_DIV2:  if (i_r == SZ[5:0]-1) state_n = S_DONE;
                    else state_n = S_DIV2_START;

      S_DONE: state_n = S_IDLE;

      default: state_n = S_IDLE;
    endcase
  end

  assign busy = (state_r != S_IDLE) && (state_r != S_DONE);
  assign done = (state_r == S_DONE);

  genvar gi;
  generate
    for (gi = 0; gi < SZ; gi++) begin : g_pack
      assign hist_out_packed[gi*VAL_W +: VAL_W] = h_mem[gi];
    end
  endgenerate

endmodule : l2hys_unit
