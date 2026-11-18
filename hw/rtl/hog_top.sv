// =============================================================================
// hog_top.sv  (VIDEO FRONT-END, stage (2) - top level)
//
// Ties together hog_gradient_unit + hog_block_hist_unit + l2hys_unit across
// the 9 overlapping blocks (3x3 grid, blockStride=8 on a 32x32 window with
// 16x16 blocks) into the final 324-value HOG descriptor, in OpenCV's exact
// block order (blockX-major, i.e. blockData[j*nblocks.height+i]).
// =============================================================================
module hog_top #(
  parameter int WIN_SIZE = 32,
  parameter int BLOCK_SIZE = 16,
  parameter int STRIDE = 8,
  parameter int CELL_SIZE = 8,
  parameter int NBINS = 9
) (
  input  logic clk,
  input  logic rst_n,

  input  logic              load_we,
  input  logic [$clog2(WIN_SIZE*WIN_SIZE)-1:0] load_addr,
  input  logic [7:0]        load_data,

  input  logic         start,
  output logic         busy,
  output logic         done,
  output logic [324*32-1:0] hog_out_packed   // Q16.16, 9 blocks x 36 values, block-X-major
);

  localparam int NBLOCKS = (WIN_SIZE-BLOCK_SIZE)/STRIDE + 1;   // 3
  localparam int NCELLS  = (BLOCK_SIZE/CELL_SIZE)*(BLOCK_SIZE/CELL_SIZE);  // 4
  localparam int BLOCK_HIST_SZ = NCELLS*NBINS;   // 36

  logic grad_start, grad_busy, grad_done;
  logic [WIN_SIZE*WIN_SIZE*32-1:0] dx_full, dy_full;
  hog_gradient_unit #(.WIN_SIZE(WIN_SIZE)) u_grad (
    .clk(clk), .rst_n(rst_n), .load_we(load_we), .load_addr(load_addr), .load_data(load_data),
    .start(grad_start), .busy(grad_busy), .done(grad_done),
    .dx_out_packed(dx_full), .dy_out_packed(dy_full)
  );

  logic [7:0] bx_r, by_r;
  logic [3:0] bi_r, bj_r;   // pixel row/col within the current block

  wire [$clog2(WIN_SIZE*WIN_SIZE)-1:0] global_idx =
      (by_r*STRIDE + bi_r)*WIN_SIZE + (bx_r*STRIDE + bj_r);

  logic signed [31:0] dx_block [256];
  logic signed [31:0] dy_block [256];

  logic hist_start, hist_busy, hist_done;
  logic [BLOCK_HIST_SZ*32-1:0] hist_packed;
  hog_block_hist_unit #(.NBINS(NBINS), .NCELLS(NCELLS), .VAL_W(32)) u_hist (
    .clk(clk), .rst_n(rst_n), .start(hist_start),
    .dx(dx_block), .dy(dy_block),
    .busy(hist_busy), .done(hist_done), .hist_packed(hist_packed)
  );

  logic l2_start, l2_busy, l2_done;
  logic [BLOCK_HIST_SZ*32-1:0] l2_out_packed;
  l2hys_unit #(.SZ(BLOCK_HIST_SZ), .VAL_W(32)) u_l2 (
    .clk(clk), .rst_n(rst_n), .start(l2_start),
    .hist_in_packed(hist_packed), .busy(l2_busy), .done(l2_done),
    .hist_out_packed(l2_out_packed)
  );

  logic [31:0] final_mem [0:323];
  logic [7:0] blk_idx_r;   // 0..8, blockX-major: bx*NBLOCKS+by

  typedef enum logic [3:0] {
    S_IDLE, S_GRAD_START, S_GRAD_WAIT, S_EXTRACT, S_NEXT_EXTRACT,
    S_HIST_START, S_HIST_WAIT, S_L2_START, S_L2_WAIT, S_STORE, S_NEXT_BLOCK, S_DONE
  } state_e;
  state_e state_r, state_n;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_r <= S_IDLE;
    end else begin
      state_r <= state_n;
      case (state_r)
        S_IDLE: if (start) begin
          bx_r <= '0; by_r <= '0;
          bi_r <= '0; bj_r <= '0;
        end

        S_EXTRACT: begin
          dx_block[bi_r*16+bj_r] <= dx_full[global_idx*32 +: 32];
          dy_block[bi_r*16+bj_r] <= dy_full[global_idx*32 +: 32];
          if (bj_r == 4'd15) begin
            bj_r <= '0;
            if (bi_r != 4'd15) bi_r <= bi_r + 1'b1;
          end else begin
            bj_r <= bj_r + 1'b1;
          end
        end

        S_STORE: begin
          for (int k = 0; k < BLOCK_HIST_SZ; k++)
            final_mem[blk_idx_r*BLOCK_HIST_SZ + k] <= l2_out_packed[k*32 +: 32];
        end

        S_NEXT_BLOCK: begin
          if (by_r == NBLOCKS-1) begin
            by_r <= '0;
            bx_r <= bx_r + 1'b1;
          end else begin
            by_r <= by_r + 1'b1;
          end
          bi_r <= '0; bj_r <= '0;
        end

        default: ;
      endcase
    end
  end

  assign grad_start = (state_r == S_GRAD_START);
  assign hist_start = (state_r == S_HIST_START);
  assign l2_start   = (state_r == S_L2_START);
  assign blk_idx_r  = bx_r*NBLOCKS + by_r;

  always_comb begin
    state_n = state_r;
    unique case (state_r)
      S_IDLE:       if (start) state_n = S_GRAD_START;
      S_GRAD_START: state_n = S_GRAD_WAIT;
      S_GRAD_WAIT:  if (grad_done) state_n = S_EXTRACT;

      S_EXTRACT:    if (bi_r == 4'd15 && bj_r == 4'd15) state_n = S_HIST_START;
                    else state_n = S_EXTRACT;

      S_HIST_START: state_n = S_HIST_WAIT;
      S_HIST_WAIT:  if (hist_done) state_n = S_L2_START;
      S_L2_START:   state_n = S_L2_WAIT;
      S_L2_WAIT:    if (l2_done) state_n = S_STORE;
      S_STORE:      state_n = S_NEXT_BLOCK;

      S_NEXT_BLOCK: if (bx_r == NBLOCKS-1 && by_r == NBLOCKS-1) state_n = S_DONE;
                    else state_n = S_EXTRACT;

      S_DONE:       state_n = S_IDLE;
      default:      state_n = S_IDLE;
    endcase
  end

  assign busy = (state_r != S_IDLE) && (state_r != S_DONE);
  assign done = (state_r == S_DONE);

  genvar gi;
  generate
    for (gi = 0; gi < 324; gi++) begin : g_pack
      assign hog_out_packed[gi*32 +: 32] = final_mem[gi];
    end
  endgenerate

endmodule : hog_top
