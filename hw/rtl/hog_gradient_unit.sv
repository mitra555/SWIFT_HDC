// =============================================================================
// hog_gradient_unit.sv  (VIDEO FRONT-END, stage (2) - gradient)
//
// Computes the centered-difference gradient (dx,dy) for every pixel in a
// WIN_SIZE x WIN_SIZE window, using OpenCV's BORDER_REFLECT_101 edge
// handling (reflects without repeating the edge pixel itself, e.g. for
// size=5: gfedcb|abcde|dcbag -- matches computeGradient's `borderInterpolate`
// call exactly, verified against hog_golden.py's reflect101()).
// gammaCorrection=false (cv2.HOGDescriptor default), so the LUT is identity.
// =============================================================================
module hog_gradient_unit #(
  parameter int WIN_SIZE = 32
) (
  input  logic clk,
  input  logic rst_n,

  input  logic              load_we,
  input  logic [$clog2(WIN_SIZE*WIN_SIZE)-1:0] load_addr,
  input  logic [7:0]        load_data,

  input  logic         start,
  output logic         busy,
  output logic         done,
  output logic [WIN_SIZE*WIN_SIZE*32-1:0] dx_out_packed,   // Q16.16
  output logic [WIN_SIZE*WIN_SIZE*32-1:0] dy_out_packed
);

  logic [7:0] img_mem [0:WIN_SIZE*WIN_SIZE-1];
  always_ff @(posedge clk) if (load_we) img_mem[load_addr] <= load_data;

  // BORDER_REFLECT_101 index map, precomputable per WIN_SIZE (compile-time,
  // matches hog_golden.py's reflect101() exactly): for offset -1 and
  // WIN_SIZE (the two out-of-range neighbors ever needed by a centered
  // difference), the reflected index is always 1 and WIN_SIZE-2
  // respectively (true for any WIN_SIZE >= 3).
  function automatic logic [$clog2(WIN_SIZE)-1:0] reflect(input int idx);
    begin
      if (idx < 0) reflect = -idx;              // idx==-1 -> 1
      else if (idx >= WIN_SIZE) reflect = 2*WIN_SIZE-2-idx;  // idx==WIN_SIZE -> WIN_SIZE-2
      else reflect = idx[$clog2(WIN_SIZE)-1:0];
    end
  endfunction

  logic [$clog2(WIN_SIZE*WIN_SIZE)-1:0] pix_r;
  // Gradients of 8-bit pixels lie in [-255, 255]: stored as 9-bit signed integers
  // and expanded to Q16.16 on the output (sign-extend, <<16) -- identical values,
  // 18 kbit of storage instead of 64 kbit.
  logic signed [8:0] dx_mem [WIN_SIZE*WIN_SIZE];
  logic signed [8:0] dy_mem [WIN_SIZE*WIN_SIZE];

  typedef enum logic [1:0] {S_IDLE, S_COMPUTE, S_NEXT, S_DONE} state_e;
  state_e state_r, state_n;

  wire [$clog2(WIN_SIZE)-1:0] row = pix_r / WIN_SIZE;
  wire [$clog2(WIN_SIZE)-1:0] col = pix_r % WIN_SIZE;
  wire [$clog2(WIN_SIZE)-1:0] col_lo = reflect(int'(col) - 1);
  wire [$clog2(WIN_SIZE)-1:0] col_hi = reflect(int'(col) + 1);
  wire [$clog2(WIN_SIZE)-1:0] row_lo = reflect(int'(row) - 1);
  wire [$clog2(WIN_SIZE)-1:0] row_hi = reflect(int'(row) + 1);

  wire [7:0] px_left  = img_mem[row*WIN_SIZE + col_lo];
  wire [7:0] px_right = img_mem[row*WIN_SIZE + col_hi];
  wire [7:0] px_up    = img_mem[row_lo*WIN_SIZE + col];
  wire [7:0] px_down  = img_mem[row_hi*WIN_SIZE + col];

  // gammaCorrection=false -> LUT is identity, so dx/dy are plain integer
  // differences; stored as Q16.16 (<<16) for uniform fixed-point downstream.
  wire signed [16:0] dx_raw = $signed({1'b0, px_right}) - $signed({1'b0, px_left});
  wire signed [16:0] dy_raw = $signed({1'b0, px_down})  - $signed({1'b0, px_up});

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_r <= S_IDLE;
    end else begin
      state_r <= state_n;
      case (state_r)
        S_IDLE: if (start) pix_r <= '0;
        S_COMPUTE: begin
          dx_mem[pix_r] <= dx_raw[8:0];
          dy_mem[pix_r] <= dy_raw[8:0];
        end
        S_NEXT: pix_r <= pix_r + 1'b1;
        default: ;
      endcase
    end
  end

  always_comb begin
    state_n = state_r;
    unique case (state_r)
      S_IDLE:    if (start) state_n = S_COMPUTE;
      S_COMPUTE: state_n = S_NEXT;
      S_NEXT:    if (pix_r == WIN_SIZE*WIN_SIZE-1) state_n = S_DONE;
                 else state_n = S_COMPUTE;
      S_DONE:    state_n = S_IDLE;
      default:   state_n = S_IDLE;
    endcase
  end

  assign busy = (state_r != S_IDLE) && (state_r != S_DONE);
  assign done = (state_r == S_DONE);

  genvar gi;
  generate
    for (gi = 0; gi < WIN_SIZE*WIN_SIZE; gi++) begin : g_pack
      assign dx_out_packed[gi*32 +: 32] = {{7{dx_mem[gi][8]}}, dx_mem[gi], 16'b0};   // Q16.16
      assign dy_out_packed[gi*32 +: 32] = {{7{dy_mem[gi][8]}}, dy_mem[gi], 16'b0};
    end
  endgenerate

endmodule : hog_gradient_unit
