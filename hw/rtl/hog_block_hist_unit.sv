// =============================================================================
// hog_block_hist_unit.sv  (VIDEO FRONT-END, stage (2))
//
// Accumulates ONE block's 36-value histogram (2x2 cells x 9 bins) from
// that block's 256 pixel gradients, replicating OpenCV's HOGCache::getBlock
// exactly: for each pixel, magnitude * Gaussian-spatial-weight is split
// across up to 4 cells (precomputed bilinear splat, hog_rom.sv) and 2
// adjacent angle bins (linear interpolation via fastatan2_unit's angle).
//
// Verified against hog_golden.py's compute_block_hist() (itself already
// validated to ~1.3e-7 against real cv2.HOGDescriptor.compute()).
// =============================================================================
import hdcu_pkg::*;

module hog_block_hist_unit #(
  parameter int NBINS = 9,
  parameter int NCELLS = 4,     // 2x2
  parameter int VAL_W = 32      // Q16.16
) (
  input  logic clk,
  input  logic rst_n,

  input  logic                start,
  input  logic signed [VAL_W-1:0] dx [256],   // block-local gradient, row-major i*16+j
  input  logic signed [VAL_W-1:0] dy [256],

  output logic                 busy,
  output logic                 done,
  output logic [NCELLS*NBINS*VAL_W-1:0] hist_packed  // Q16.16, cell-major (matches OpenCV histOfs layout)
);

  localparam int MAGSQ_W = 2*VAL_W + 1;     // headroom for dx^2+dy^2 in Q32.32-ish domain... see note
  // NOTE: dx,dy here are Q16.16 already (gradient values, typically small
  // integers in practice for 8-bit pixel differences); squaring keeps
  // ample headroom for this magnitude range without needing the full
  // generality of a 64-bit accumulator.

  logic [31:0] hist_mem [0:NCELLS*NBINS-1];

  typedef enum logic [3:0] {
    S_IDLE, S_MAGSQ, S_SQRT_START, S_SQRT_WAIT, S_ATAN_START, S_ATAN_WAIT,
    S_BINCALC, S_SLOT_ACCUM, S_NEXT_SLOT, S_NEXT_PIXEL, S_DONE
  } state_e;
  state_e state_r, state_n;

  logic [7:0] pix_r;
  logic [1:0] slot_r;
  logic signed [VAL_W-1:0] dx_r, dy_r;
  logic [63:0] magsq_r;
  logic [31:0] mag_r;         // Q16.16 magnitude
  logic [31:0] angle_deg_r;
  logic signed [31:0] hidx_r;
  logic signed [31:0] frac_r; // Q16.16, [0,1)

  // ---- magnitude via isqrt on a pre-scaled Q16.16^2*2^16 value for Q16.16 precision ----
  logic sqrt_start, sqrt_done;
  logic [63:0] sqrt_value;
  logic [31:0] sqrt_root;
  assign sqrt_value = magsq_r;  // dx,dy are Q16.16, so dx^2+dy^2 = real_magsq*2^32 (raw integer),
                                  // and sqrt(that) = real_mag*2^16 = Q16.16 directly, no extra shift
  isqrt_seq_unit #(.NORMSQ_W(64), .ROOT_W(32)) u_isqrt (
    .clk(clk), .rst_n(rst_n), .start(sqrt_start), .value(sqrt_value),
    .busy(), .done(sqrt_done), .root(sqrt_root)
  );

  logic atan_start, atan_busy, atan_done;
  logic [31:0] atan_angle;
  fastatan2_unit #(.W(32)) u_atan (
    .clk(clk), .rst_n(rst_n), .start(atan_start),
    .dx(dx_r), .dy(dy_r), .busy(atan_busy), .done(atan_done), .angle_deg(atan_angle)
  );

  logic [1:0] rom_cell;
  logic signed [31:0] rom_weight;
  hog_rom u_rom (
    .pixel_idx(pix_r), .slot(slot_r), .cell_idx(rom_cell), .weight(rom_weight)
  );

  // angleScale = NBINS/pi (unsigned gradient), Q16.16: 9/pi = 2.864789...
  localparam signed [31:0] ANGLE_SCALE_Q16 = 32'sd187747;   // (9/pi)*65536, precisely computed
  localparam signed [31:0] HALF_Q16 = 32'sd32768;           // 0.5 in Q16.16
  localparam signed [31:0] DEG_TO_RAD_Q16 = 32'sd1144;      // (pi/180)*65536, precisely computed

  function automatic signed [63:0] qmul64(input signed [31:0] a, input signed [31:0] b);
    logic signed [63:0] p;
    begin
      p = a * b;
      qmul64 = p >>> 16;
    end
  endfunction

  wire signed [63:0] angle_rad_wide = qmul64(angle_deg_r, DEG_TO_RAD_Q16);
  wire signed [31:0] angle_rad_q16 = angle_rad_wide[31:0];
  wire signed [63:0] a_scaled_wide = qmul64(angle_rad_q16, ANGLE_SCALE_Q16);
  wire signed [31:0] a_scaled = a_scaled_wide[31:0] - HALF_Q16;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_r <= S_IDLE;
    end else begin
      state_r <= state_n;
      case (state_r)
        S_IDLE: if (start) begin
          pix_r <= '0;
          for (int k = 0; k < NCELLS*NBINS; k++) hist_mem[k] <= '0;
        end

        S_MAGSQ: begin
          dx_r <= dx[pix_r];
          dy_r <= dy[pix_r];
          magsq_r <= dx[pix_r]*dx[pix_r] + dy[pix_r]*dy[pix_r];
        end

        S_SQRT_WAIT: if (sqrt_done) mag_r <= sqrt_root;

        S_ATAN_WAIT: if (atan_done) angle_deg_r <= atan_angle;

        S_BINCALC: begin
          hidx_r <= a_scaled >>> 16;                      // floor (arithmetic shift, a_scaled may be negative)
          frac_r <= a_scaled - ((a_scaled >>> 16) <<< 16); // fractional part, Q16.16
          slot_r <= '0;
        end

        S_SLOT_ACCUM: begin
          if (rom_weight != 0) begin
            logic signed [31:0] h0, h1;
            logic signed [63:0] mag_w, contrib0_wide, contrib1_wide;
            logic signed [31:0] hidx_wrapped;
            hidx_wrapped = hidx_r % NBINS;
            if (hidx_wrapped < 0) hidx_wrapped = hidx_wrapped + NBINS;
            h0 = hidx_wrapped;
            h1 = (hidx_wrapped + 1) % NBINS;
            mag_w = qmul64(mag_r, rom_weight);
            contrib0_wide = qmul64(mag_w[31:0], HALF_Q16*2 - frac_r);
            contrib1_wide = qmul64(mag_w[31:0], frac_r);
            hist_mem[rom_cell*NBINS + h0] <= hist_mem[rom_cell*NBINS + h0] + contrib0_wide[31:0];
            hist_mem[rom_cell*NBINS + h1] <= hist_mem[rom_cell*NBINS + h1] + contrib1_wide[31:0];
          end
          if (slot_r != 2'd3) slot_r <= slot_r + 1'b1;
        end

        S_NEXT_PIXEL: pix_r <= pix_r + 1'b1;

        default: ;
      endcase
    end
  end

  always_comb begin
    state_n = state_r;
    sqrt_start = 1'b0;
    atan_start = 1'b0;

    unique case (state_r)
      S_IDLE:        if (start) state_n = S_MAGSQ;
      S_MAGSQ:       state_n = S_SQRT_START;
      S_SQRT_START:  begin sqrt_start = 1'b1; state_n = S_SQRT_WAIT; end
      S_SQRT_WAIT:   if (sqrt_done) state_n = S_ATAN_START;
      S_ATAN_START:  begin atan_start = 1'b1; state_n = S_ATAN_WAIT; end
      S_ATAN_WAIT:   if (atan_done) state_n = S_BINCALC;
      S_BINCALC:     state_n = S_SLOT_ACCUM;
      S_SLOT_ACCUM:  if (slot_r == 2'd3) state_n = S_NEXT_PIXEL;
                     else state_n = S_SLOT_ACCUM;
      S_NEXT_PIXEL:  if (pix_r == 8'd255) state_n = S_DONE;
                     else state_n = S_MAGSQ;
      S_DONE:        state_n = S_IDLE;
      default:       state_n = S_IDLE;
    endcase
  end

  assign busy = (state_r != S_IDLE) && (state_r != S_DONE);
  assign done = (state_r == S_DONE);

  genvar gi;
  generate
    for (gi = 0; gi < NCELLS*NBINS; gi++) begin : g_pack
      assign hist_packed[gi*VAL_W +: VAL_W] = hist_mem[gi];
    end
  endgenerate

endmodule : hog_block_hist_unit
