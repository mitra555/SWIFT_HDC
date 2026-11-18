// =============================================================================
// vecnorm_unit.sv  (VIDEO FRONT-END GLUE -- new, not in any prior round)
//
// Replicates the notebook's `norm(f)`:
//   n = ||f||_2 ;  return f / n if n > 0 else f  (i.e. f/1.0, which is a
//   no-op for the all-zero vector that produces n==0 in the first place)
//
// Applied once per feature group (F_base, F_dx, F_dy, F_acd, F_acx, F_pct)
// BEFORE per-feature quantization -- this step existed in the notebook's
// `encode_multigroup` call site (`new_groups=[norm(F_dx),...]`) but had
// no RTL counterpart anywhere in this project until now.
//
// Fixed length N (elaboration-time parameter, one instance per feature
// group size actually used: 904/32/32/16/16/10). Packed vector ports
// throughout (Icarus does not support unpacked-array ports, a limitation
// already hit and fixed several times elsewhere in this project).
// =============================================================================
module vecnorm_unit #(
  parameter int N     = 32,
  parameter int VAL_W = 32     // Q16.16 signed
) (
  input  logic clk,
  input  logic rst_n,

  input  logic                     load_we,
  input  logic [$clog2(N)-1:0]     load_addr,
  input  logic signed [VAL_W-1:0]  load_data,

  input  logic         start,
  output logic         busy,
  output logic         done,
  output logic [N*VAL_W-1:0] result_packed   // Q16.16, normalized
);

  localparam int NW      = $clog2(N+1);
  localparam int SQ_W    = 2*VAL_W;
  localparam int SUMSQ_W = SQ_W + NW + 4;
  localparam int ISQRT_W = SUMSQ_W + 16;   // room for sumsq_r << 16, no truncation
  localparam int ROOT_W  = (ISQRT_W+1)/2;

  logic signed [VAL_W-1:0] x_mem [0:N-1];

  always_ff @(posedge clk) begin
    if (load_we) x_mem[load_addr] <= load_data;
  end

  typedef enum logic [3:0] {
    S_IDLE, S_SQ_LOOP, S_SQRT_START, S_SQRT_WAIT,
    S_DIV_START, S_DIV_WAIT, S_WRITE, S_NEXT, S_DONE
  } state_e;
  state_e state_r, state_n;

  logic [NW-1:0] i_r;
  logic signed [SUMSQ_W-1:0] sumsq_r;
  logic [ROOT_W-1:0] norm_r;
  logic norm_is_zero_r;
  logic signed [VAL_W-1:0] result_r [0:N-1];

  wire signed [SQ_W-1:0] sq_raw = x_mem[i_r] * x_mem[i_r];
  wire signed [SQ_W-1:0] sq_q16 = sq_raw >>> 16;

  logic isqrt_start, isqrt_done;
  logic [ISQRT_W-1:0] isqrt_value;
  isqrt_seq_unit #(.NORMSQ_W(ISQRT_W), .ROOT_W(ROOT_W)) u_isqrt (
    .clk(clk), .rst_n(rst_n), .start(isqrt_start), .value(isqrt_value),
    .busy(), .done(isqrt_done), .root(norm_r)
  );

  // Dividing two Q16.16 values directly yields an UNSCALED integer quotient
  // (the 2^16 factors cancel), so the dividend must be pre-shifted left by
  // 16 to recover a Q16.16 result -- which needs a wider register than
  // VAL_W to avoid silently overflowing (the exact bug class already
  // documented in this project's percentile_unit README).
  localparam int DIV_W = VAL_W + 32;
  logic div_start, div_done;
  logic signed [DIV_W-1:0] div_dividend, div_divisor, div_quotient;
  seq_divider #(.W(DIV_W)) u_div (
    .clk(clk), .rst_n(rst_n), .start(div_start),
    .dividend(div_dividend), .divisor(div_divisor),
    .busy(), .done(div_done), .quotient(div_quotient)
  );

  assign isqrt_value = {{16{1'b0}}, sumsq_r} <<< 16;
  assign div_dividend = ({{32{x_mem[i_r][VAL_W-1]}}, x_mem[i_r]}) <<< 16;
  assign div_divisor  = norm_is_zero_r ? {{(DIV_W-1){1'b0}}, 1'b1}
                                       : {{(DIV_W-ROOT_W){1'b0}}, norm_r};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_r <= S_IDLE;
    end else begin
      state_r <= state_n;
      case (state_r)
        S_IDLE: if (start) begin
          i_r <= '0;
          sumsq_r <= '0;
        end

        S_SQ_LOOP: begin
          sumsq_r <= sumsq_r + sq_q16;
          i_r <= i_r + 1'b1;
        end

        S_SQRT_WAIT: if (isqrt_done) begin
          norm_is_zero_r <= (norm_r == '0);
          i_r <= '0;
        end

        S_WRITE: begin
          if (norm_is_zero_r) result_r[i_r] <= x_mem[i_r];
          else                 result_r[i_r] <= div_quotient[VAL_W-1:0];
        end

        S_NEXT: i_r <= i_r + 1'b1;

        default: ;
      endcase
    end
  end

  always_comb begin
    state_n = state_r;
    isqrt_start = 1'b0;
    div_start = 1'b0;

    unique case (state_r)
      S_IDLE: if (start) state_n = S_SQ_LOOP;

      S_SQ_LOOP: if (i_r + 1'b1 == N[NW-1:0]) state_n = S_SQRT_START;

      S_SQRT_START: begin
        isqrt_start = 1'b1;
        state_n = S_SQRT_WAIT;
      end
      S_SQRT_WAIT: if (isqrt_done) state_n = S_DIV_START;

      S_DIV_START: begin
        if (norm_is_zero_r) state_n = S_WRITE;
        else begin
          div_start = 1'b1;
          state_n = S_DIV_WAIT;
        end
      end
      S_DIV_WAIT: if (div_done) state_n = S_WRITE;

      S_WRITE: state_n = S_NEXT;

      S_NEXT: if (i_r + 1'b1 == N[NW-1:0]) state_n = S_DONE;
              else state_n = S_DIV_START;

      S_DONE: state_n = S_IDLE;
      default: state_n = S_IDLE;
    endcase
  end

  assign busy = (state_r != S_IDLE) && (state_r != S_DONE);
  assign done = (state_r == S_DONE);

  genvar gi;
  generate
    for (gi = 0; gi < N; gi++) begin : g_pack
      assign result_packed[gi*VAL_W +: VAL_W] = result_r[gi];
    end
  endgenerate

endmodule : vecnorm_unit
