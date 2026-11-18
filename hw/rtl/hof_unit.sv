// =============================================================================
// hof_unit.sv  (VIDEO FRONT-END, stage (3))
//
// Replicates the notebook's per-frame HOF construction EXACTLY, building
// directly on the already-verified block_match_unit's dx/dy outputs
// (which the notebook itself passes abs()-valued -- so angle_bin8_unit's
// classification only ever lands in bins 0/1/2 for this specific call
// site, which is a real, faithfully-reproduced property of the
// notebook's own design, not a limitation of the angle classifier
// itself, which was verified generally over the full 8-bin range):
//
//   for each cell:
//     mag = sqrt(dx[cell]^2 + dy[cell]^2)
//     if mag > 0.5:                    (== dx^2+dy^2 >= 1 for integer dx,dy)
//       ang = atan2(dy[cell], dx[cell]) % 2pi
//       b = floor(ang/2pi*8) % 8
//       hist[cell][b] += mag
//   norm_hof_cells(hist):
//     for each cell: s = sum(hist[cell][:]); if s>1e-6: hist[cell][:] /= s
//
// Magnitude computed via isqrt_seq_unit (already verified elsewhere in
// this project) on a pre-scaled input for fixed-point precision;
// per-cell L1 normalization via seq_divider (also already verified).
// =============================================================================
import hdcu_pkg::*;

module hof_unit #(
  parameter int N_CELLS      = 16,
  parameter int N_ANGLE_BINS = 8,
  parameter int DXDY_W       = 5,    // unsigned, matches BLOCK_SEARCH range 0..8
  parameter int VAL_W        = 32,   // Q16.16 output format for the normalized histogram
  parameter int MAG_FRAC     = 8     // fractional bits carried through the sqrt
) (
  input  logic clk,
  input  logic rst_n,

  input  logic                start,
  input  logic [DXDY_W-1:0]    dx [N_CELLS],   // from block_match_unit, already abs()-valued
  input  logic [DXDY_W-1:0]    dy [N_CELLS],

  output logic                 busy,
  output logic                 done,
  output logic [N_CELLS*N_ANGLE_BINS*VAL_W-1:0] result_packed,  // Q16.16, cell-major then bin
  // Purely additive port (does not affect any existing logic/timing):
  // exposes the RAW (pre-per-frame-normalization) accumulated magnitude
  // histogram -- i.e. hist_mem at the moment `done` pulses -- which is
  // exactly what the notebook's `hof_accum[...] += mag` sums across many
  // frame calls before the one-time global `norm_hof_cells(hof_accum)`.
  output logic [N_CELLS*N_ANGLE_BINS*VAL_W-1:0] raw_hist_packed
);

  localparam int MAGSQ_W    = 2*DXDY_W + 1;
  localparam int ISQRT_IN_W = MAGSQ_W + 2*MAG_FRAC;
  localparam int MAG_W      = (ISQRT_IN_W+1)/2;
  localparam int NBW        = $clog2(N_ANGLE_BINS+1);
  localparam int NCW        = $clog2(N_CELLS+1);

  logic [31:0] hist_mem [0:N_CELLS*N_ANGLE_BINS-1];

  typedef enum logic [3:0] {
    S_IDLE, S_CELL_MAGSQ, S_CELL_SQRT_START, S_CELL_SQRT_WAIT, S_CELL_BIN,
    S_CELL_ACCUM, S_NEXT_CELL,
    S_SUM_LOOP, S_SUM_DONE, S_DIV_START, S_DIV_WAIT, S_WRITE, S_NEXT_BIN_OR_CELL, S_DONE
  } state_e;
  state_e state_r, state_n;

  logic [NCW-1:0] cell_r;
  logic [MAGSQ_W-1:0] magsq_r;
  logic [MAG_W-1:0]   mag_r;
  logic [2:0]          bin_r;

  logic isqrt_start, isqrt_done;
  logic [ISQRT_IN_W-1:0] isqrt_value;
  logic [MAG_W-1:0]       isqrt_root;
  assign isqrt_value = ({{(ISQRT_IN_W-MAGSQ_W){1'b0}}, magsq_r}) << (2*MAG_FRAC);

  isqrt_seq_unit #(.NORMSQ_W(ISQRT_IN_W), .ROOT_W(MAG_W)) u_isqrt (
    .clk(clk), .rst_n(rst_n), .start(isqrt_start), .value(isqrt_value),
    .busy(), .done(isqrt_done), .root(isqrt_root)
  );

  logic div_start, div_done;
  logic signed [31:0] div_dividend, div_divisor, div_quotient;
  seq_divider #(.W(32)) u_div (
    .clk(clk), .rst_n(rst_n), .start(div_start),
    .dividend(div_dividend), .divisor(div_divisor),
    .busy(), .done(div_done), .quotient(div_quotient)
  );

  logic [31:0] sum_r;
  logic [NCW-1:0] ncell_r;
  logic [NBW-1:0] nbin_r;
  logic signed [VAL_W-1:0] result_r [N_CELLS*N_ANGLE_BINS];

  wire [2:0] bin_comb;
  angle_bin8_unit #(.W(DXDY_W+1)) u_angle (
    .dx($signed({1'b0, dx[cell_r]})), .dy($signed({1'b0, dy[cell_r]})), .bin(bin_comb)
  );

  wire do_accum = (magsq_r >= 1);

  assign div_dividend = ({{16{1'b0}}, hist_mem[ncell_r*N_ANGLE_BINS + nbin_r]}) <<< 16;
  assign div_divisor  = $signed({1'b0, sum_r});

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_r <= S_IDLE;
    end else begin
      state_r <= state_n;

      case (state_r)
        S_IDLE: if (start) begin
          cell_r <= '0;
          for (int i = 0; i < N_CELLS*N_ANGLE_BINS; i++) hist_mem[i] <= '0;
        end

        S_CELL_MAGSQ: magsq_r <= dx[cell_r]*dx[cell_r] + dy[cell_r]*dy[cell_r];

        S_CELL_BIN: bin_r <= bin_comb;

        S_CELL_SQRT_WAIT: if (isqrt_done) mag_r <= isqrt_root;

        S_CELL_ACCUM: if (do_accum)
          hist_mem[cell_r*N_ANGLE_BINS + bin_r] <= hist_mem[cell_r*N_ANGLE_BINS + bin_r]
                                                   + {{(32-MAG_W){1'b0}}, mag_r};

        S_NEXT_CELL: begin
          if (cell_r + 1'b1 == N_CELLS[NCW-1:0]) begin
            ncell_r <= '0;
            nbin_r  <= '0;
            sum_r   <= '0;
          end
          cell_r <= cell_r + 1'b1;
        end

        S_SUM_LOOP: begin
          sum_r <= sum_r + hist_mem[ncell_r*N_ANGLE_BINS + nbin_r];
          if (nbin_r == N_ANGLE_BINS[NBW-1:0] - 1'b1) nbin_r <= '0;
          else nbin_r <= nbin_r + 1'b1;
        end

        S_WRITE: begin
          if (sum_r == 0) result_r[ncell_r*N_ANGLE_BINS + nbin_r] <= '0;
          else            result_r[ncell_r*N_ANGLE_BINS + nbin_r] <= div_quotient[VAL_W-1:0];
        end

        S_NEXT_BIN_OR_CELL: begin
          if (nbin_r == N_ANGLE_BINS[NBW-1:0] - 1'b1) begin
            nbin_r <= '0;
            ncell_r <= ncell_r + 1'b1;
            sum_r <= '0;
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
    isqrt_start = 1'b0;
    div_start = 1'b0;

    unique case (state_r)
      S_IDLE: if (start) state_n = S_CELL_MAGSQ;

      S_CELL_MAGSQ: state_n = S_CELL_SQRT_START;

      S_CELL_SQRT_START: begin
        isqrt_start = 1'b1;
        state_n = S_CELL_SQRT_WAIT;
      end

      S_CELL_SQRT_WAIT: if (isqrt_done) state_n = S_CELL_BIN;

      S_CELL_BIN: state_n = S_CELL_ACCUM;

      S_CELL_ACCUM: state_n = S_NEXT_CELL;

      S_NEXT_CELL: if (cell_r + 1'b1 == N_CELLS[NCW-1:0]) state_n = S_SUM_LOOP;
                   else state_n = S_CELL_MAGSQ;

      // ---- normalization: for each cell, sum its N_ANGLE_BINS bins ----
      S_SUM_LOOP: if (nbin_r == N_ANGLE_BINS[NBW-1:0] - 1'b1) state_n = S_DIV_START;

      // ---- then for each bin: divide by the sum and write back ----
      S_DIV_START: begin
        if (sum_r == 0) state_n = S_WRITE;   // skip the divider entirely, avoid div-by-zero
        else begin
          div_start = 1'b1;
          state_n = S_DIV_WAIT;
        end
      end

      S_DIV_WAIT: if (div_done) state_n = S_WRITE;

      S_WRITE: state_n = S_NEXT_BIN_OR_CELL;

      S_NEXT_BIN_OR_CELL: begin
        if (nbin_r == N_ANGLE_BINS[NBW-1:0] - 1'b1) begin
          if (ncell_r + 1'b1 == N_CELLS[NCW-1:0]) state_n = S_DONE;
          else state_n = S_SUM_LOOP;
        end else begin
          state_n = S_DIV_START;
        end
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
      assign raw_hist_packed[gi*VAL_W +: VAL_W] = hist_mem[gi];
    end
  endgenerate

endmodule : hof_unit
