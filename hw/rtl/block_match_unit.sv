// =============================================================================
// block_match_unit.sv  (VIDEO FRONT-END, stage (1))
//
// Replicates the notebook's `block_match_frame` EXACTLY at its real
// dimensions: FRAME_SIZE=32, FLOW_GRID=4 (-> CH=CW=8 per cell, 16 cells),
// BLOCK_SEARCH=8 (17x17=289 candidate positions per cell). For one cell,
// sweeps every valid (dys,dxs) search offset, computes the Sum of
// Absolute Differences (SAD) between the reference block (from `curr`)
// and the candidate block (from `prev`), and tracks the minimum -- pure
// integer arithmetic, no transcendental functions, so an exact match to
// the notebook's numpy computation is achievable (unlike HOG's gradient
// angle, this has no rounding-mode ambiguity).
//
// Frame buffers are embedded directly in this module for simplicity;
// a full SoC integration would expose them as a shared SPM bank instead
// (see README for what's still simplified).
// =============================================================================
module block_match_unit #(
  parameter int FRAME_SIZE   = 32,
  parameter int FLOW_GRID    = 4,
  parameter int BLOCK_SEARCH = 8
) (
  input  logic clk,
  input  logic rst_n,

  input  logic              load_we,
  input  logic               load_is_curr,
  input  logic [$clog2(FRAME_SIZE*FRAME_SIZE)-1:0] load_addr,
  input  logic [7:0]        load_data,

  input  logic         start,
  input  logic [1:0]   cell_gy,
  input  logic [1:0]   cell_gx,

  output logic         busy,
  output logic         done,
  output logic signed [$clog2(BLOCK_SEARCH*2+2)-1:0] best_dx,
  output logic signed [$clog2(BLOCK_SEARCH*2+2)-1:0] best_dy,
  output logic [31:0]  best_sad
);

  localparam int CH = FRAME_SIZE / FLOW_GRID;
  localparam int CW = FRAME_SIZE / FLOW_GRID;
  localparam int ADDR_W = $clog2(FRAME_SIZE*FRAME_SIZE);
  localparam int OFF_W  = $clog2(BLOCK_SEARCH*2+2);

  (* ram_style = "block" *) logic [7:0] prev_mem [0:FRAME_SIZE*FRAME_SIZE-1];
  (* ram_style = "block" *) logic [7:0] curr_mem [0:FRAME_SIZE*FRAME_SIZE-1];

  always_ff @(posedge clk) begin
    if (load_we) begin
      if (load_is_curr) curr_mem[load_addr] <= load_data;
      else              prev_mem[load_addr] <= load_data;
    end
  end

  typedef enum logic [2:0] {S_IDLE, S_CHECK_BOUNDS, S_ACCUM, S_COMPARE, S_NEXT_POS, S_DONE} state_e;
  state_e state_r, state_n;

  logic signed [OFF_W-1:0] dys_r, dxs_r;
  logic [$clog2(CH)-1:0]   py_r;
  logic [$clog2(CW)-1:0]   px_r;
  logic [31:0]             sad_acc_r;
  logic [31:0]             best_sad_r;
  logic signed [OFF_W-1:0] best_dx_r, best_dy_r;
  logic [ADDR_W-1:0]       y0_r, x0_r;
  logic                    pos_valid_r;

  wire signed [ADDR_W:0] py0 = $signed({1'b0, y0_r}) + dys_r;
  wire signed [ADDR_W:0] px0 = $signed({1'b0, x0_r}) + dxs_r;
  wire pos_in_bounds = (py0 >= 0) && (py0 + CH <= FRAME_SIZE) && (px0 >= 0) && (px0 + CW <= FRAME_SIZE);

  wire [ADDR_W-1:0] ref_addr  = (y0_r + py_r) * FRAME_SIZE + (x0_r + px_r);
  wire [ADDR_W-1:0] cand_addr = (py0[ADDR_W-1:0] + py_r) * FRAME_SIZE + (px0[ADDR_W-1:0] + px_r);

  wire signed [8:0] ref_pix  = {1'b0, curr_mem[ref_addr]};
  wire signed [8:0] cand_pix = {1'b0, prev_mem[cand_addr]};
  wire signed [9:0] diff     = ref_pix - cand_pix;
  wire [8:0]        abs_diff = diff[9] ? (-diff[8:0]) : diff[8:0];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_r <= S_IDLE;
    end else begin
      state_r <= state_n;

      case (state_r)
        S_IDLE: if (start) begin
          y0_r <= {{(ADDR_W-2){1'b0}}, cell_gy} * CH;
          x0_r <= {{(ADDR_W-2){1'b0}}, cell_gx} * CW;
          dys_r <= -BLOCK_SEARCH[OFF_W-1:0];
          dxs_r <= -BLOCK_SEARCH[OFF_W-1:0];
          best_sad_r <= 32'hFFFFFFFF;
          best_dx_r <= '0;
          best_dy_r <= '0;
        end

        S_CHECK_BOUNDS: begin
          pos_valid_r <= pos_in_bounds;
          py_r <= '0;
          px_r <= '0;
          sad_acc_r <= '0;
        end

        S_ACCUM: begin
          if (pos_valid_r) begin
            sad_acc_r <= sad_acc_r + {23'b0, abs_diff};
            if (px_r == CW-1) begin
              px_r <= '0;
              if (py_r != CH-1) py_r <= py_r + 1'b1;
            end else begin
              px_r <= px_r + 1'b1;
            end
          end
        end

        S_COMPARE: begin
          if (pos_valid_r && sad_acc_r < best_sad_r) begin
            best_sad_r <= sad_acc_r;
            best_dx_r  <= dxs_r;
            best_dy_r  <= dys_r;
          end
        end

        S_NEXT_POS: begin
          if (dxs_r == BLOCK_SEARCH[OFF_W-1:0]) begin
            dxs_r <= -BLOCK_SEARCH[OFF_W-1:0];
            if (dys_r != BLOCK_SEARCH[OFF_W-1:0]) dys_r <= dys_r + 1'b1;
          end else begin
            dxs_r <= dxs_r + 1'b1;
          end
        end

        default: ;
      endcase
    end
  end

  always_comb begin
    state_n = state_r;
    unique case (state_r)
      S_IDLE:         if (start) state_n = S_CHECK_BOUNDS;
      S_CHECK_BOUNDS: state_n = S_ACCUM;
      S_ACCUM:        if (!(pos_valid_r && !(py_r == CH-1 && px_r == CW-1))) state_n = S_COMPARE;
      S_COMPARE:      state_n = S_NEXT_POS;
      S_NEXT_POS:     if (dys_r == BLOCK_SEARCH[OFF_W-1:0] && dxs_r == BLOCK_SEARCH[OFF_W-1:0]) state_n = S_DONE;
                       else state_n = S_CHECK_BOUNDS;
      S_DONE:         state_n = S_IDLE;
      default:        state_n = S_IDLE;
    endcase
  end

  assign busy     = (state_r != S_IDLE) && (state_r != S_DONE);
  assign done     = (state_r == S_DONE);
  assign best_dx  = best_dx_r;
  assign best_dy  = best_dy_r;
  assign best_sad = best_sad_r;

endmodule : block_match_unit
