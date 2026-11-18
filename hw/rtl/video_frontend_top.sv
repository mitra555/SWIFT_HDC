// =============================================================================
// video_frontend_top.sv  (streaming version)
//
// Takes NUM_FRAMES raw 8-bit grayscale frames (FRAME_SIZE x FRAME_SIZE) and
// produces the notebook's 6 L2-normalized feature groups
// (base, f_dx, f_dy, f_acd, f_acx, f_pct), replicating `extract_all()` +
// the per-group `norm()` calls in fixed-point (Q16.16) hardware.
//
// STREAMING: the clip is never stored whole.
//   * Frames: a 2-slot store (frame f lives in slot f[0]). The host loads frames
//     0 and 1, pulses start, and loads each further frame whenever ld_ready=1.
//     Frame f+2 may overwrite frame f once pair f has been copied into the
//     block-match / HOG units (ld_ready = frames_loaded < pairs_copied + 2).
//   * Temporal mean/std: instead of keeping every frame's HOG (324), HOF (128),
//     |dx| and |dy| (16+16) vectors, each pair adds x and x^2 into running
//     sums (484 lanes, one lane per cycle, one shared multiplier), and
//     meanstd_sums_unit derives mean/std from the sums at the end.
//   * Kept: gdx/gdy (one value per pair) for autocorrelation and percentiles,
//     and the HOF global accumulator.
// Storage at NUM_FRAMES=64: ~16 Kbit frames + ~52 Kbit sums + ~4 Kbit gdx/gdy,
// versus ~1.5 Mbit (64 frames + 63 x 484 history words) before.
//
// Mean/std arithmetic: see meanstd_sums_unit.sv (exact sum of squared
// deviations; differs from the previous two-pass unit by <= 1 LSB in var).
// =============================================================================
import hdcu_pkg::*;

module video_frontend_top #(
  parameter int NUM_FRAMES   = 64,
  parameter int FRAME_SIZE   = 32,
  parameter int FLOW_GRID    = 4,
  parameter int BLOCK_SEARCH = 8,
  parameter int N_ANGLE_BINS = 8,
  parameter int HOG_DIM      = 324,
  parameter int AC_LAGS      = 16
)(
  input  logic clk,
  input  logic rst_n,

  input  logic                                   ld_frame_we,
  input  logic [$clog2(NUM_FRAMES)-1:0]          ld_frame_idx,
  input  logic [$clog2(FRAME_SIZE*FRAME_SIZE)-1:0] ld_pix_idx,
  input  logic [7:0]                             ld_pix_data,
  output logic                                   ld_ready,   // a frame slot is free for the next frame

  input  logic start,
  output logic busy,
  output logic done,

  output logic [903:0][31:0] base_norm,
  output logic [31:0][31:0]  dx_norm,
  output logic [31:0][31:0]  dy_norm,
  output logic [15:0][31:0]  acd_norm,
  output logic [15:0][31:0]  acx_norm,
  output logic [9:0][31:0]   pct_norm
);

  localparam int N_CELLS = FLOW_GRID*FLOW_GRID;
  localparam int HOF_DIM = N_CELLS*N_ANGLE_BINS;
  localparam int NPAIRS  = NUM_FRAMES-1;
  localparam int PIXW    = FRAME_SIZE*FRAME_SIZE;
  localparam int DXDY_W  = 5;

  localparam int BASE_LEN = HOF_DIM + HOG_DIM + HOF_DIM + HOG_DIM;

  // streaming statistics lanes: HOG | HOF | |dx| per cell | |dy| per cell
  localparam int L_HOF   = HOG_DIM;
  localparam int L_DX    = HOG_DIM + HOF_DIM;
  localparam int L_DY    = L_DX + N_CELLS;
  localparam int NLANE   = L_DY + N_CELLS;          // 484
  localparam int S1_W    = 32 + $clog2(NPAIRS+1) + 1;
  localparam int S2_W    = 64 + $clog2(NPAIRS+1) + 1;
  localparam int TW      = $clog2(NPAIRS+1);
  localparam int FCW     = $clog2(NUM_FRAMES+1) + 1;

  // -------------------------------------------------------------------
  // 2-slot frame store + load flow control
  // -------------------------------------------------------------------
  logic [7:0] frame_store [0:1][0:PIXW-1];
  always_ff @(posedge clk) begin
    if (ld_frame_we) frame_store[ld_frame_idx[0]][ld_pix_idx] <= ld_pix_data;
  end

  logic [FCW-1:0] frames_loaded_r, pairs_copied_r;
  logic           pair_copied_pulse, clip_done_pulse;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      frames_loaded_r <= '0;
      pairs_copied_r  <= '0;
    end else if (clip_done_pulse) begin
      frames_loaded_r <= '0;
      pairs_copied_r  <= '0;
    end else begin
      if (ld_frame_we && ld_pix_idx == ($bits(ld_pix_idx))'(PIXW-1)) frames_loaded_r <= frames_loaded_r + 1'b1;
      if (pair_copied_pulse) pairs_copied_r <= pairs_copied_r + 1'b1;
    end
  end
  assign ld_ready = (frames_loaded_r < pairs_copied_r + 2) && (frames_loaded_r < FCW'(NUM_FRAMES));

  localparam int CW  = $clog2(N_CELLS+1);
  localparam int PW  = $clog2(2*PIXW+1);
  localparam int BW  = $clog2(BASE_LEN+1);

  logic [TW-1:0] t_r;
  logic [CW-1:0] cell_r;
  logic [PW-1:0] pix_r;
  logic [BW-1:0] lane_r;

  logic signed [31:0] gdx_buf [0:NPAIRS-1];
  logic signed [31:0] gdy_buf [0:NPAIRS-1];

  logic [31:0] hof_accum_r [0:HOF_DIM-1];

  // running sums for temporal mean/std
  logic signed [S1_W-1:0] acc_s1 [0:NLANE-1];
  logic        [S2_W-1:0] acc_s2 [0:NLANE-1];

  logic bm_load_we, bm_load_is_curr;
  logic [$clog2(PIXW)-1:0] bm_load_addr;
  logic [7:0] bm_load_data;
  logic bm_start, bm_busy, bm_done;
  logic [1:0] bm_cell_gy, bm_cell_gx;
  logic signed [$clog2(BLOCK_SEARCH*2+2)-1:0] bm_best_dx, bm_best_dy;
  logic [31:0] bm_best_sad;

  // abs(bm_best_dx), abs(bm_best_dy), computed as plain sign-extend + negate
  logic signed [31:0] bm_dx_ext, bm_dy_ext;
  logic signed [31:0] bm_dx_abs, bm_dy_abs;
  assign bm_dx_ext = {{(32-$bits(bm_best_dx)){bm_best_dx[$bits(bm_best_dx)-1]}}, bm_best_dx};
  assign bm_dy_ext = {{(32-$bits(bm_best_dy)){bm_best_dy[$bits(bm_best_dy)-1]}}, bm_best_dy};
  assign bm_dx_abs = bm_dx_ext[31] ? -bm_dx_ext : bm_dx_ext;
  assign bm_dy_abs = bm_dy_ext[31] ? -bm_dy_ext : bm_dy_ext;

  block_match_unit #(.FRAME_SIZE(FRAME_SIZE), .FLOW_GRID(FLOW_GRID), .BLOCK_SEARCH(BLOCK_SEARCH)) u_bm (
    .clk(clk), .rst_n(rst_n),
    .load_we(bm_load_we), .load_is_curr(bm_load_is_curr), .load_addr(bm_load_addr), .load_data(bm_load_data),
    .start(bm_start), .cell_gy(bm_cell_gy), .cell_gx(bm_cell_gx),
    .busy(bm_busy), .done(bm_done), .best_dx(bm_best_dx), .best_dy(bm_best_dy), .best_sad(bm_best_sad)
  );

  logic hof_start, hof_busy, hof_done;
  logic [DXDY_W-1:0] hof_dx [0:N_CELLS-1];
  logic [DXDY_W-1:0] hof_dy [0:N_CELLS-1];
  logic [HOF_DIM*32-1:0] hof_result_packed, hof_raw_packed;

  hof_unit #(.N_CELLS(N_CELLS), .N_ANGLE_BINS(N_ANGLE_BINS), .DXDY_W(DXDY_W), .VAL_W(32), .MAG_FRAC(8)) u_hof (
    .clk(clk), .rst_n(rst_n), .start(hof_start), .dx(hof_dx), .dy(hof_dy),
    .busy(hof_busy), .done(hof_done), .result_packed(hof_result_packed), .raw_hist_packed(hof_raw_packed)
  );

  logic hog_load_we;
  logic [$clog2(PIXW)-1:0] hog_load_addr;
  logic [7:0] hog_load_data;
  logic hog_start, hog_busy, hog_done;
  logic [HOG_DIM*32-1:0] hog_out_packed;

  hog_top #(.WIN_SIZE(FRAME_SIZE), .BLOCK_SIZE(16), .STRIDE(8), .CELL_SIZE(8), .NBINS(9)) u_hog (
    .clk(clk), .rst_n(rst_n),
    .load_we(hog_load_we), .load_addr(hog_load_addr), .load_data(hog_load_data),
    .start(hog_start), .busy(hog_busy), .done(hog_done), .hog_out_packed(hog_out_packed)
  );

  logic cn_load_we;
  logic [$clog2(HOF_DIM)-1:0] cn_load_addr;
  logic signed [31:0] cn_load_data;
  logic cn_start, cn_busy, cn_done;
  logic [HOF_DIM*32-1:0] cn_result_packed;

  cellnorm_unit #(.N_CELLS(N_CELLS), .N_ANGLE_BINS(N_ANGLE_BINS), .VAL_W(32)) u_cellnorm (
    .clk(clk), .rst_n(rst_n),
    .load_we(cn_load_we), .load_addr(cn_load_addr), .load_data(cn_load_data),
    .start(cn_start), .busy(cn_busy), .done(cn_done), .result_packed(cn_result_packed)
  );

  // streaming mean/std from running sums
  logic ms_start, ms_busy, ms_done;
  logic signed [31:0] ms_mean_out, ms_std_out;
  meanstd_sums_unit #(.VAL_W(32), .S1_W(S1_W), .S2_W(S2_W), .TW(TW)) u_meanstd (
    .clk(clk), .rst_n(rst_n), .start(ms_start),
    .s1(acc_s1[lane_r]), .s2(acc_s2[lane_r]), .num_samples(TW'(NPAIRS)),
    .busy(ms_busy), .done(ms_done), .mean_out(ms_mean_out), .std_out(ms_std_out)
  );

  logic ac_load_we;
  logic [$clog2(NPAIRS)-1:0] ac_load_addr;
  logic signed [31:0] ac_load_data;
  logic ac_start, ac_busy, ac_done;
  logic [$clog2(NPAIRS+1)-1:0] ac_num_samples;
  logic [AC_LAGS*32-1:0] ac_result_packed;

  autocorr_unit #(.MAX_T(NPAIRS), .N_LAGS(AC_LAGS), .VAL_W(32), .ACC_W(80), .DIV_W(128)) u_autocorr (
    .clk(clk), .rst_n(rst_n),
    .load_we(ac_load_we), .load_addr(ac_load_addr), .load_data(ac_load_data),
    .start(ac_start), .num_samples(ac_num_samples),
    .busy(ac_busy), .done(ac_done), .result_packed(ac_result_packed)
  );

  logic pc_load_we;
  logic [$clog2(NPAIRS)-1:0] pc_load_addr;
  logic signed [31:0] pc_load_data;
  logic pc_start, pc_busy, pc_done;
  logic [$clog2(NPAIRS+1)-1:0] pc_num_samples;
  logic [5*32-1:0] pc_result_packed;

  percentile_unit #(.MAX_T(NPAIRS), .VAL_W(32)) u_pct (
    .clk(clk), .rst_n(rst_n),
    .load_we(pc_load_we), .load_addr(pc_load_addr), .load_data(pc_load_data),
    .start(pc_start), .num_samples(pc_num_samples),
    .busy(pc_busy), .done(pc_done), .result_packed(pc_result_packed)
  );

  logic vn_base_we, vn_dx_we, vn_dy_we, vn_acd_we, vn_acx_we, vn_pct_we;
  logic [$clog2(BASE_LEN)-1:0] vn_base_addr;
  logic [$clog2(32)-1:0]       vn_dx_addr, vn_dy_addr;
  logic [$clog2(16)-1:0]       vn_acd_addr, vn_acx_addr;
  logic [$clog2(10)-1:0]       vn_pct_addr;
  logic signed [31:0] vn_load_data;
  logic vn_base_start, vn_dx_start, vn_dy_start, vn_acd_start, vn_acx_start, vn_pct_start;
  logic vn_base_done, vn_dx_done, vn_dy_done, vn_acd_done, vn_acx_done, vn_pct_done;
  logic [BASE_LEN*32-1:0] vn_base_packed;
  logic [32*32-1:0]       vn_dx_packed, vn_dy_packed;
  logic [16*32-1:0]       vn_acd_packed, vn_acx_packed;
  logic [10*32-1:0]       vn_pct_packed;

  vecnorm_unit #(.N(BASE_LEN), .VAL_W(32)) u_vn_base (
    .clk(clk), .rst_n(rst_n), .load_we(vn_base_we), .load_addr(vn_base_addr), .load_data(vn_load_data),
    .start(vn_base_start), .busy(), .done(vn_base_done), .result_packed(vn_base_packed)
  );
  vecnorm_unit #(.N(32), .VAL_W(32)) u_vn_dx (
    .clk(clk), .rst_n(rst_n), .load_we(vn_dx_we), .load_addr(vn_dx_addr), .load_data(vn_load_data),
    .start(vn_dx_start), .busy(), .done(vn_dx_done), .result_packed(vn_dx_packed)
  );
  vecnorm_unit #(.N(32), .VAL_W(32)) u_vn_dy (
    .clk(clk), .rst_n(rst_n), .load_we(vn_dy_we), .load_addr(vn_dy_addr), .load_data(vn_load_data),
    .start(vn_dy_start), .busy(), .done(vn_dy_done), .result_packed(vn_dy_packed)
  );
  vecnorm_unit #(.N(16), .VAL_W(32)) u_vn_acd (
    .clk(clk), .rst_n(rst_n), .load_we(vn_acd_we), .load_addr(vn_acd_addr), .load_data(vn_load_data),
    .start(vn_acd_start), .busy(), .done(vn_acd_done), .result_packed(vn_acd_packed)
  );
  vecnorm_unit #(.N(16), .VAL_W(32)) u_vn_acx (
    .clk(clk), .rst_n(rst_n), .load_we(vn_acx_we), .load_addr(vn_acx_addr), .load_data(vn_load_data),
    .start(vn_acx_start), .busy(), .done(vn_acx_done), .result_packed(vn_acx_packed)
  );
  vecnorm_unit #(.N(10), .VAL_W(32)) u_vn_pct (
    .clk(clk), .rst_n(rst_n), .load_we(vn_pct_we), .load_addr(vn_pct_addr), .load_data(vn_load_data),
    .start(vn_pct_start), .busy(), .done(vn_pct_done), .result_packed(vn_pct_packed)
  );

  logic [31:0] base_raw [0:BASE_LEN-1];
  logic [31:0] dx_raw   [0:31];
  logic [31:0] dy_raw   [0:31];
  logic [31:0] acd_raw  [0:15];
  logic [31:0] acx_raw  [0:15];
  logic [31:0] pct_raw  [0:9];

  typedef enum logic [5:0] {
    S_IDLE,
    S_T_WAITFRAME, S_T_MEMLOAD, S_T_HOGSTART,
    S_T_BM_START, S_T_BM_WAIT, S_T_BM_CAPTURE, S_T_BM_NEXT,
    S_T_HOF_START, S_T_HOF_WAIT, S_T_HOF_CAPTURE,
    S_T_HOG_WAIT, S_T_HOG_CAPTURE,
    S_T_ACC_LOOP,
    S_T_NEXT,
    S_FIN_CELLNORM_LOAD, S_FIN_CELLNORM_START, S_FIN_CELLNORM_WAIT, S_FIN_CELLNORM_CAPTURE,
    S_FIN_MS_START, S_FIN_MS_WAIT, S_FIN_MS_CAPTURE, S_FIN_MS_NEXT,
    S_FIN_AC_ACD_LOAD, S_FIN_AC_ACD_START, S_FIN_AC_ACD_WAIT, S_FIN_AC_ACD_CAPTURE,
    S_FIN_AC_ACX_LOAD, S_FIN_AC_ACX_START, S_FIN_AC_ACX_WAIT, S_FIN_AC_ACX_CAPTURE,
    S_FIN_PC_DX_LOAD,  S_FIN_PC_DX_START,  S_FIN_PC_DX_WAIT,  S_FIN_PC_DX_CAPTURE,
    S_FIN_PC_DY_LOAD,  S_FIN_PC_DY_START,  S_FIN_PC_DY_WAIT,  S_FIN_PC_DY_CAPTURE,
    S_FIN_VN_BASE_LOAD, S_FIN_VN_BASE_START, S_FIN_VN_BASE_WAIT,
    S_FIN_VN_DX_LOAD,   S_FIN_VN_DX_START,   S_FIN_VN_DX_WAIT,
    S_FIN_VN_DY_LOAD,   S_FIN_VN_DY_START,   S_FIN_VN_DY_WAIT,
    S_FIN_VN_ACD_LOAD,  S_FIN_VN_ACD_START,  S_FIN_VN_ACD_WAIT,
    S_FIN_VN_ACX_LOAD,  S_FIN_VN_ACX_START,  S_FIN_VN_ACX_WAIT,
    S_FIN_VN_PCT_LOAD,  S_FIN_VN_PCT_START,  S_FIN_VN_PCT_WAIT,
    S_DONE
  } state_e;
  state_e state_r, state_n;

  assign pair_copied_pulse = (state_r == S_T_MEMLOAD) && (pix_r == PW'(2*PIXW-1));
  assign clip_done_pulse   = (state_r == S_DONE);

  // hog_done is a one-cycle pulse and HOG runs concurrently with block-match;
  // latch it.
  logic hog_done_latched_r;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) hog_done_latched_r <= 1'b0;
    else if (state_r == S_T_HOGSTART) hog_done_latched_r <= 1'b0;
    else if (hog_done) hog_done_latched_r <= 1'b1;
  end

  logic signed [39:0] cell_dx_sum, cell_dy_sum;

  // -------------------------------------------------------------------
  // value of statistics lane lane_r for the current pair
  // -------------------------------------------------------------------
  logic signed [31:0] lane_x;
  always_comb begin
    if (lane_r < BW'(L_HOF))     lane_x = hog_out_packed[lane_r*32 +: 32];
    else if (lane_r < BW'(L_DX)) lane_x = hof_result_packed[(lane_r - BW'(L_HOF))*32 +: 32];
    else if (lane_r < BW'(L_DY)) lane_x = {{(32-DXDY_W-16){1'b0}}, hof_dx[lane_r - BW'(L_DX)], 16'b0};
    else                         lane_x = {{(32-DXDY_W-16){1'b0}}, hof_dy[lane_r - BW'(L_DY)], 16'b0};
  end
  logic signed [63:0] lane_x_sq;
  assign lane_x_sq = lane_x * lane_x;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_r <= S_IDLE;
      t_r    <= '0;
      pix_r  <= '0;
      cell_r <= '0;
      lane_r <= '0;
    end else begin
      state_r <= state_n;

      case (state_r)
        S_IDLE: if (start) begin
          t_r    <= '0;
          pix_r  <= '0;
          cell_r <= '0;
          lane_r <= '0;
        end

        S_T_MEMLOAD: begin
          pix_r <= (pix_r == PW'(2*PIXW-1)) ? '0 : pix_r + 1'b1;
          if (pix_r == '0) begin
            cell_dx_sum <= '0;
            cell_dy_sum <= '0;
          end
        end

        S_T_BM_CAPTURE: begin
          hof_dx[cell_r] <= bm_dx_abs[DXDY_W-1:0];
          hof_dy[cell_r] <= bm_dy_abs[DXDY_W-1:0];
          cell_dx_sum <= cell_dx_sum + {{8{1'b0}}, bm_dx_abs};
          cell_dy_sum <= cell_dy_sum + {{8{1'b0}}, bm_dy_abs};
        end

        S_T_BM_NEXT: cell_r <= cell_r + 1'b1;

        S_T_HOF_CAPTURE: begin
          gdx_buf[t_r] <= (cell_dx_sum <<< 16) >>> 4;
          gdy_buf[t_r] <= (cell_dy_sum <<< 16) >>> 4;
        end

        S_T_HOG_CAPTURE: ;

        S_T_ACC_LOOP: begin
          // first pair initialises the sums, later pairs add to them
          acc_s1[lane_r] <= (t_r == '0 ? '0 : acc_s1[lane_r]) + S1_W'(lane_x);
          acc_s2[lane_r] <= (t_r == '0 ? '0 : acc_s2[lane_r]) + S2_W'($unsigned(lane_x_sq));
          lane_r <= (lane_r == BW'(NLANE-1)) ? '0 : lane_r + 1'b1;
        end

        S_T_NEXT: begin
          t_r    <= (t_r == TW'(NPAIRS-1)) ? '0 : t_r + 1'b1;
          cell_r <= '0;
          pix_r  <= '0;
        end

        S_FIN_CELLNORM_LOAD: pix_r <= (pix_r == PW'(HOF_DIM-1)) ? '0 : pix_r + 1'b1;
        S_FIN_CELLNORM_CAPTURE: begin
          for (int gh2 = 0; gh2 < HOF_DIM; gh2++) base_raw[gh2] <= cn_result_packed[gh2*32 +: 32];
        end

        S_FIN_MS_CAPTURE: begin
          if (lane_r < BW'(L_HOF)) begin
            base_raw[HOF_DIM + lane_r]                    <= ms_mean_out;
            base_raw[HOF_DIM + HOG_DIM + HOF_DIM + lane_r] <= ms_std_out;
          end else if (lane_r < BW'(L_DX)) begin
            base_raw[HOF_DIM + HOG_DIM + (lane_r - BW'(L_HOF))] <= ms_std_out;
          end else if (lane_r < BW'(L_DY)) begin
            dx_raw[lane_r - BW'(L_DX)]      <= ms_mean_out;
            dx_raw[16 + lane_r - BW'(L_DX)] <= ms_std_out;
          end else begin
            dy_raw[lane_r - BW'(L_DY)]      <= ms_mean_out;
            dy_raw[16 + lane_r - BW'(L_DY)] <= ms_std_out;
          end
        end
        S_FIN_MS_NEXT: lane_r <= (lane_r == BW'(NLANE-1)) ? '0 : lane_r + 1'b1;

        S_FIN_AC_ACD_LOAD: t_r <= (t_r == TW'(NPAIRS-1)) ? '0 : t_r + 1'b1;
        S_FIN_AC_ACX_LOAD: t_r <= (t_r == TW'(NPAIRS-1)) ? '0 : t_r + 1'b1;
        S_FIN_PC_DX_LOAD:  t_r <= (t_r == TW'(NPAIRS-1)) ? '0 : t_r + 1'b1;
        S_FIN_PC_DY_LOAD:  t_r <= (t_r == TW'(NPAIRS-1)) ? '0 : t_r + 1'b1;

        S_FIN_VN_BASE_LOAD: lane_r <= (lane_r == BW'(BASE_LEN-1)) ? '0 : lane_r + 1'b1;
        S_FIN_VN_DX_LOAD:   lane_r <= (lane_r == BW'(31)) ? '0 : lane_r + 1'b1;
        S_FIN_VN_DY_LOAD:   lane_r <= (lane_r == BW'(31)) ? '0 : lane_r + 1'b1;
        S_FIN_VN_ACD_LOAD:  lane_r <= (lane_r == BW'(15)) ? '0 : lane_r + 1'b1;
        S_FIN_VN_ACX_LOAD:  lane_r <= (lane_r == BW'(15)) ? '0 : lane_r + 1'b1;
        S_FIN_VN_PCT_LOAD:  lane_r <= (lane_r == BW'(9))  ? '0 : lane_r + 1'b1;

        default: ;
      endcase
    end
  end

  always_comb begin
    state_n = state_r;

    bm_load_we = 1'b0; bm_load_is_curr = 1'b0; bm_load_addr = '0; bm_load_data = '0;
    bm_start = 1'b0; bm_cell_gy = cell_r[3:2]; bm_cell_gx = cell_r[1:0];

    hof_start = 1'b0;
    hog_load_we = 1'b0; hog_load_addr = '0; hog_load_data = '0; hog_start = 1'b0;

    cn_load_we = 1'b0; cn_load_addr = '0; cn_load_data = '0; cn_start = 1'b0;
    ms_start = 1'b0;
    ac_load_we = 1'b0; ac_load_addr = '0; ac_load_data = '0; ac_start = 1'b0; ac_num_samples = NPAIRS[$bits(ac_num_samples)-1:0];
    pc_load_we = 1'b0; pc_load_addr = '0; pc_load_data = '0; pc_start = 1'b0; pc_num_samples = NPAIRS[$bits(pc_num_samples)-1:0];

    vn_base_we=1'b0; vn_dx_we=1'b0; vn_dy_we=1'b0; vn_acd_we=1'b0; vn_acx_we=1'b0; vn_pct_we=1'b0;
    vn_base_start=1'b0; vn_dx_start=1'b0; vn_dy_start=1'b0; vn_acd_start=1'b0; vn_acx_start=1'b0; vn_pct_start=1'b0;
    vn_base_addr = '0; vn_dx_addr='0; vn_dy_addr='0; vn_acd_addr='0; vn_acx_addr='0; vn_pct_addr='0;
    vn_load_data = '0;

    unique case (state_r)
      S_IDLE: if (start) state_n = S_T_WAITFRAME;

      // wait until both frames of pair t (frames t and t+1) have been loaded
      S_T_WAITFRAME: if (int'(frames_loaded_r) >= int'(t_r) + 2) state_n = S_T_MEMLOAD;

      S_T_MEMLOAD: begin
        bm_load_we = 1'b1;
        bm_load_is_curr = (pix_r >= PW'(PIXW)) ? 1'b1 : 1'b0;
        bm_load_addr = pix_r[$bits(bm_load_addr)-1:0];
        // frame t is in slot t[0], frame t+1 in slot ~t[0]
        bm_load_data = (pix_r >= PW'(PIXW)) ? frame_store[~t_r[0]][pix_r[$bits(bm_load_addr)-1:0]]
                                             : frame_store[ t_r[0]][pix_r[$bits(bm_load_addr)-1:0]];
        if (pix_r < PW'(PIXW)) begin
          hog_load_we = 1'b1; hog_load_addr = pix_r[$bits(hog_load_addr)-1:0];
          hog_load_data = frame_store[~t_r[0]][pix_r[$bits(hog_load_addr)-1:0]];
        end
        if (pix_r == PW'(2*PIXW-1)) state_n = S_T_HOGSTART;
      end

      S_T_HOGSTART: begin
        hog_start = 1'b1;
        state_n = S_T_BM_START;
      end

      S_T_BM_START: begin
        bm_start = 1'b1;
        state_n = S_T_BM_WAIT;
      end
      S_T_BM_WAIT: if (bm_done) state_n = S_T_BM_CAPTURE;
      S_T_BM_CAPTURE: state_n = S_T_BM_NEXT;
      S_T_BM_NEXT: if (cell_r == CW'(N_CELLS-1)) state_n = S_T_HOF_START;
                   else state_n = S_T_BM_START;

      S_T_HOF_START: begin
        hof_start = 1'b1;
        state_n = S_T_HOF_WAIT;
      end
      S_T_HOF_WAIT: if (hof_done) state_n = S_T_HOF_CAPTURE;
      S_T_HOF_CAPTURE: state_n = S_T_HOG_WAIT;

      S_T_HOG_WAIT: if (hog_done_latched_r) state_n = S_T_HOG_CAPTURE;
      S_T_HOG_CAPTURE: state_n = S_T_ACC_LOOP;

      S_T_ACC_LOOP: if (lane_r == BW'(NLANE-1)) state_n = S_T_NEXT;

      S_T_NEXT: if (t_r == TW'(NPAIRS-1)) state_n = S_FIN_CELLNORM_LOAD;
                else state_n = S_T_WAITFRAME;

      S_FIN_CELLNORM_LOAD: begin
        cn_load_we = 1'b1; cn_load_addr = pix_r[$bits(cn_load_addr)-1:0]; cn_load_data = hof_accum_r[pix_r];
        if (pix_r == PW'(HOF_DIM-1)) state_n = S_FIN_CELLNORM_START;
      end
      S_FIN_CELLNORM_START: begin cn_start = 1'b1; state_n = S_FIN_CELLNORM_WAIT; end
      S_FIN_CELLNORM_WAIT: if (cn_done) state_n = S_FIN_CELLNORM_CAPTURE;
      S_FIN_CELLNORM_CAPTURE: state_n = S_FIN_MS_START;

      S_FIN_MS_START: begin ms_start = 1'b1; state_n = S_FIN_MS_WAIT; end
      S_FIN_MS_WAIT: if (ms_done) state_n = S_FIN_MS_CAPTURE;
      S_FIN_MS_CAPTURE: state_n = S_FIN_MS_NEXT;
      S_FIN_MS_NEXT: if (lane_r == BW'(NLANE-1)) state_n = S_FIN_AC_ACD_LOAD;
                     else state_n = S_FIN_MS_START;

      S_FIN_AC_ACD_LOAD: begin
        ac_load_we = 1'b1; ac_load_addr = t_r[$bits(ac_load_addr)-1:0]; ac_load_data = gdy_buf[t_r];
        if (t_r == TW'(NPAIRS-1)) state_n = S_FIN_AC_ACD_START;
      end
      S_FIN_AC_ACD_START: begin ac_start = 1'b1; state_n = S_FIN_AC_ACD_WAIT; end
      S_FIN_AC_ACD_WAIT: if (ac_done) state_n = S_FIN_AC_ACD_CAPTURE;
      S_FIN_AC_ACD_CAPTURE: state_n = S_FIN_AC_ACX_LOAD;

      S_FIN_AC_ACX_LOAD: begin
        ac_load_we = 1'b1; ac_load_addr = t_r[$bits(ac_load_addr)-1:0]; ac_load_data = gdx_buf[t_r];
        if (t_r == TW'(NPAIRS-1)) state_n = S_FIN_AC_ACX_START;
      end
      S_FIN_AC_ACX_START: begin ac_start = 1'b1; state_n = S_FIN_AC_ACX_WAIT; end
      S_FIN_AC_ACX_WAIT: if (ac_done) state_n = S_FIN_AC_ACX_CAPTURE;
      S_FIN_AC_ACX_CAPTURE: state_n = S_FIN_PC_DX_LOAD;

      S_FIN_PC_DX_LOAD: begin
        pc_load_we = 1'b1; pc_load_addr = t_r[$bits(pc_load_addr)-1:0]; pc_load_data = gdx_buf[t_r];
        if (t_r == TW'(NPAIRS-1)) state_n = S_FIN_PC_DX_START;
      end
      S_FIN_PC_DX_START: begin pc_start = 1'b1; state_n = S_FIN_PC_DX_WAIT; end
      S_FIN_PC_DX_WAIT: if (pc_done) state_n = S_FIN_PC_DX_CAPTURE;
      S_FIN_PC_DX_CAPTURE: state_n = S_FIN_PC_DY_LOAD;

      S_FIN_PC_DY_LOAD: begin
        pc_load_we = 1'b1; pc_load_addr = t_r[$bits(pc_load_addr)-1:0]; pc_load_data = gdy_buf[t_r];
        if (t_r == TW'(NPAIRS-1)) state_n = S_FIN_PC_DY_START;
      end
      S_FIN_PC_DY_START: begin pc_start = 1'b1; state_n = S_FIN_PC_DY_WAIT; end
      S_FIN_PC_DY_WAIT: if (pc_done) state_n = S_FIN_PC_DY_CAPTURE;
      S_FIN_PC_DY_CAPTURE: state_n = S_FIN_VN_BASE_LOAD;

      S_FIN_VN_BASE_LOAD: begin
        vn_base_we = 1'b1; vn_base_addr = lane_r[$bits(vn_base_addr)-1:0]; vn_load_data = base_raw[lane_r];
        if (lane_r == BW'(BASE_LEN-1)) state_n = S_FIN_VN_BASE_START;
      end
      S_FIN_VN_BASE_START: begin vn_base_start = 1'b1; state_n = S_FIN_VN_BASE_WAIT; end
      S_FIN_VN_BASE_WAIT: if (vn_base_done) state_n = S_FIN_VN_DX_LOAD;

      S_FIN_VN_DX_LOAD: begin
        vn_dx_we = 1'b1; vn_dx_addr = lane_r[$bits(vn_dx_addr)-1:0]; vn_load_data = dx_raw[lane_r];
        if (lane_r == BW'(31)) state_n = S_FIN_VN_DX_START;
      end
      S_FIN_VN_DX_START: begin vn_dx_start = 1'b1; state_n = S_FIN_VN_DX_WAIT; end
      S_FIN_VN_DX_WAIT: if (vn_dx_done) state_n = S_FIN_VN_DY_LOAD;

      S_FIN_VN_DY_LOAD: begin
        vn_dy_we = 1'b1; vn_dy_addr = lane_r[$bits(vn_dy_addr)-1:0]; vn_load_data = dy_raw[lane_r];
        if (lane_r == BW'(31)) state_n = S_FIN_VN_DY_START;
      end
      S_FIN_VN_DY_START: begin vn_dy_start = 1'b1; state_n = S_FIN_VN_DY_WAIT; end
      S_FIN_VN_DY_WAIT: if (vn_dy_done) state_n = S_FIN_VN_ACD_LOAD;

      S_FIN_VN_ACD_LOAD: begin
        vn_acd_we = 1'b1; vn_acd_addr = lane_r[$bits(vn_acd_addr)-1:0]; vn_load_data = acd_raw[lane_r];
        if (lane_r == BW'(15)) state_n = S_FIN_VN_ACD_START;
      end
      S_FIN_VN_ACD_START: begin vn_acd_start = 1'b1; state_n = S_FIN_VN_ACD_WAIT; end
      S_FIN_VN_ACD_WAIT: if (vn_acd_done) state_n = S_FIN_VN_ACX_LOAD;

      S_FIN_VN_ACX_LOAD: begin
        vn_acx_we = 1'b1; vn_acx_addr = lane_r[$bits(vn_acx_addr)-1:0]; vn_load_data = acx_raw[lane_r];
        if (lane_r == BW'(15)) state_n = S_FIN_VN_ACX_START;
      end
      S_FIN_VN_ACX_START: begin vn_acx_start = 1'b1; state_n = S_FIN_VN_ACX_WAIT; end
      S_FIN_VN_ACX_WAIT: if (vn_acx_done) state_n = S_FIN_VN_PCT_LOAD;

      S_FIN_VN_PCT_LOAD: begin
        vn_pct_we = 1'b1; vn_pct_addr = lane_r[$bits(vn_pct_addr)-1:0]; vn_load_data = pct_raw[lane_r];
        if (lane_r == BW'(9)) state_n = S_FIN_VN_PCT_START;
      end
      S_FIN_VN_PCT_START: begin vn_pct_start = 1'b1; state_n = S_FIN_VN_PCT_WAIT; end
      S_FIN_VN_PCT_WAIT: if (vn_pct_done) state_n = S_DONE;

      S_DONE: state_n = S_IDLE;
      default: state_n = S_IDLE;
    endcase
  end

  assign busy = (state_r != S_IDLE) && (state_r != S_DONE);
  assign done = (state_r == S_DONE);

  genvar gi;
  generate
    for (gi = 0; gi < BASE_LEN; gi++) assign base_norm[gi] = vn_base_packed[gi*32 +: 32];
    for (gi = 0; gi < 32; gi++)       assign dx_norm[gi]   = vn_dx_packed[gi*32 +: 32];
    for (gi = 0; gi < 32; gi++)       assign dy_norm[gi]   = vn_dy_packed[gi*32 +: 32];
    for (gi = 0; gi < 16; gi++)       assign acd_norm[gi]  = vn_acd_packed[gi*32 +: 32];
    for (gi = 0; gi < 16; gi++)       assign acx_norm[gi]  = vn_acx_packed[gi*32 +: 32];
    for (gi = 0; gi < 10; gi++)       assign pct_norm[gi]  = vn_pct_packed[gi*32 +: 32];
  endgenerate

  // Per-index generate blocks for wide parallel captures (Icarus performance;
  // functionally equivalent to loops inside the main always_ff).
  genvar gh;
  generate
    for (gh = 0; gh < HOF_DIM; gh++) begin : g_hof_accum
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) hof_accum_r[gh] <= '0;
        else if (state_r == S_IDLE && start) hof_accum_r[gh] <= '0;
        else if (state_r == S_T_HOF_CAPTURE) hof_accum_r[gh] <= hof_accum_r[gh] + hof_raw_packed[gh*32 +: 32];
      end
    end

    for (gh = 0; gh < AC_LAGS; gh++) begin : g_acd
      always_ff @(posedge clk) begin
        if (state_r == S_FIN_AC_ACD_CAPTURE) acd_raw[gh] <= ac_result_packed[gh*32 +: 32];
      end
    end

    for (gh = 0; gh < AC_LAGS; gh++) begin : g_acx
      always_ff @(posedge clk) begin
        if (state_r == S_FIN_AC_ACX_CAPTURE) acx_raw[gh] <= ac_result_packed[gh*32 +: 32];
      end
    end

    for (gh = 0; gh < 5; gh++) begin : g_pct_dx
      always_ff @(posedge clk) begin
        if (state_r == S_FIN_PC_DX_CAPTURE) pct_raw[gh] <= pc_result_packed[gh*32 +: 32];
      end
    end

    for (gh = 0; gh < 5; gh++) begin : g_pct_dy
      always_ff @(posedge clk) begin
        if (state_r == S_FIN_PC_DY_CAPTURE) pct_raw[5+gh] <= pc_result_packed[gh*32 +: 32];
      end
    end
  endgenerate

endmodule : video_frontend_top
