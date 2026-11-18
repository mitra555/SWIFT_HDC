// =============================================================================
// cellnorm_unit.sv  (VIDEO FRONT-END GLUE -- new, not in any prior round)
//
// Replicates the notebook's `norm_hof_cells(h)`:
//   for each cell: s = sum(h[cell]); if s > 1e-6: h[cell] /= s
//
// hof_unit.sv already implements exactly this per-frame (for hof_seq),
// but the notebook ALSO applies it once to the frame-summed accumulator
// (`hof_global = norm_hof_cells(hof_accum)`), which is a different call
// site operating on a different (much larger-magnitude) input. Rather
// than risk touching the already-verified hof_unit's internal per-frame
// FSM, this is a small standalone unit for that second call site,
// reusing the identical sum-then-divide arithmetic.
// =============================================================================
module cellnorm_unit #(
  parameter int N_CELLS      = 16,
  parameter int N_ANGLE_BINS = 8,
  parameter int VAL_W        = 32   // Q16.16 signed
) (
  input  logic clk,
  input  logic rst_n,

  input  logic                     load_we,
  input  logic [$clog2(N_CELLS*N_ANGLE_BINS)-1:0] load_addr,
  input  logic signed [VAL_W-1:0]  load_data,

  input  logic         start,
  output logic         busy,
  output logic         done,
  output logic [N_CELLS*N_ANGLE_BINS*VAL_W-1:0] result_packed
);

  localparam int NCW = $clog2(N_CELLS+1);
  localparam int NBW = $clog2(N_ANGLE_BINS+1);
  localparam int SUM_W = VAL_W + NBW + 4;

  logic signed [VAL_W-1:0] x_mem [0:N_CELLS*N_ANGLE_BINS-1];

  always_ff @(posedge clk) begin
    if (load_we) x_mem[load_addr] <= load_data;
  end

  typedef enum logic [2:0] {
    S_IDLE, S_SUM_LOOP, S_DIV_START, S_DIV_WAIT, S_WRITE, S_NEXT, S_DONE
  } state_e;
  state_e state_r, state_n;

  logic [NCW-1:0] ncell_r;
  logic [NBW-1:0] nbin_r;
  logic signed [SUM_W-1:0] sum_r;
  logic signed [VAL_W-1:0] result_r [0:N_CELLS*N_ANGLE_BINS-1];

  localparam int DIV_W = VAL_W + 32;
  logic div_start, div_done;
  logic signed [DIV_W-1:0] div_dividend, div_divisor, div_quotient;
  seq_divider #(.W(DIV_W)) u_div (
    .clk(clk), .rst_n(rst_n), .start(div_start),
    .dividend(div_dividend), .divisor(div_divisor),
    .busy(), .done(div_done), .quotient(div_quotient)
  );

  wire signed [VAL_W-1:0] cur_val = x_mem[ncell_r*N_ANGLE_BINS + nbin_r];
  wire sum_is_zero = (sum_r == 0);

  assign div_dividend = ({{32{cur_val[VAL_W-1]}}, cur_val}) <<< 16;
  assign div_divisor  = sum_is_zero ? {{(DIV_W-1){1'b0}}, 1'b1}
                                    : {{(DIV_W-SUM_W){sum_r[SUM_W-1]}}, sum_r};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_r <= S_IDLE;
    end else begin
      state_r <= state_n;
      case (state_r)
        S_IDLE: if (start) begin
          ncell_r <= '0;
          nbin_r  <= '0;
          sum_r   <= '0;
        end

        S_SUM_LOOP: begin
          sum_r <= sum_r + x_mem[ncell_r*N_ANGLE_BINS + nbin_r];
          if (nbin_r + 1'b1 == N_ANGLE_BINS[NBW-1:0]) nbin_r <= '0;
          else nbin_r <= nbin_r + 1'b1;
        end

        S_WRITE: begin
          if (sum_is_zero) result_r[ncell_r*N_ANGLE_BINS + nbin_r] <= '0;
          else              result_r[ncell_r*N_ANGLE_BINS + nbin_r] <= div_quotient[VAL_W-1:0];
        end

        S_NEXT: begin
          if (nbin_r + 1'b1 == N_ANGLE_BINS[NBW-1:0]) begin
            nbin_r  <= '0;
            ncell_r <= ncell_r + 1'b1;
            sum_r   <= '0;
          end else begin
            nbin_r <= nbin_r + 1'b1;
          end
        end

        default: ;
      endcase
    end
  end

  always_comb begin
    state_n = state_r;
    div_start = 1'b0;

    unique case (state_r)
      S_IDLE: if (start) state_n = S_SUM_LOOP;

      S_SUM_LOOP: if (nbin_r + 1'b1 == N_ANGLE_BINS[NBW-1:0]) state_n = S_DIV_START;

      S_DIV_START: begin
        if (sum_is_zero) state_n = S_WRITE;
        else begin
          div_start = 1'b1;
          state_n = S_DIV_WAIT;
        end
      end
      S_DIV_WAIT: if (div_done) state_n = S_WRITE;

      S_WRITE: state_n = S_NEXT;

      S_NEXT: begin
        if (nbin_r + 1'b1 == N_ANGLE_BINS[NBW-1:0] && ncell_r + 1'b1 == N_CELLS[NCW-1:0])
          state_n = S_DONE;
        else if (nbin_r + 1'b1 == N_ANGLE_BINS[NBW-1:0])
          state_n = S_SUM_LOOP;
        else
          state_n = S_DIV_START;
      end

      S_DONE: state_n = S_IDLE;
      default: state_n = S_IDLE;
    endcase
  end

  assign busy = (state_r != S_IDLE) && (state_r != S_DONE);
  assign done = (state_r == S_DONE);

  genvar gi;
  generate
    for (gi = 0; gi < N_CELLS*N_ANGLE_BINS; gi++) begin : g_pack
      assign result_packed[gi*VAL_W +: VAL_W] = result_r[gi];
    end
  endgenerate

endmodule : cellnorm_unit
