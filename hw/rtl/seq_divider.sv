// =============================================================================
// seq_divider.sv  (VIDEO FRONT-END)
//
// Standalone, reusable sequential signed divider: quotient = dividend/divisor
// (truncating toward zero, like normal integer/fixed-point division), using
// the same restoring bit-serial architecture proven in quantize_unit.sv.
// Used by autocorr_unit.sv (normalizing by variance) and reusable anywhere
// else a scalar fixed-point division is needed.
// =============================================================================
module seq_divider #(
  parameter int W = 32   // width of dividend/divisor/quotient (signed)
) (
  input  logic                  clk,
  input  logic                  rst_n,
  input  logic                  start,
  input  logic signed [W-1:0]   dividend,
  input  logic signed [W-1:0]   divisor,   // caller guarantees divisor != 0
  output logic                  busy,
  output logic                  done,
  output logic signed [W-1:0]   quotient
);

  localparam int ITER_W = $clog2(W+1);

  logic               sign_r;
  logic [W-1:0]       div_sr;
  logic [W-1:0]       divisor_mag_r;
  logic [W:0]         rem_r;
  logic [W-1:0]       quot_r;
  logic [ITER_W-1:0]  iter_r;
  logic               busy_r, done_r;
  logic signed [W-1:0] quotient_r;

  wire signed [W-1:0] dividend_mag = dividend[W-1] ? (~dividend + 1'b1) : dividend;
  wire signed [W-1:0] divisor_mag  = divisor[W-1]  ? (~divisor  + 1'b1) : divisor;
  wire                result_sign  = dividend[W-1] ^ divisor[W-1];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy_r <= 1'b0;
      done_r <= 1'b0;
      quotient_r <= '0;
    end else if (start) begin
      sign_r        <= result_sign;
      div_sr        <= dividend_mag;
      divisor_mag_r <= divisor_mag;
      rem_r         <= '0;
      quot_r        <= '0;
      iter_r        <= W[ITER_W-1:0];
      busy_r        <= 1'b1;
      done_r        <= 1'b0;
    end else if (busy_r) begin
      logic            msb;
      logic [W:0]       rem_shifted;
      logic [W-1:0]     next_quot;
      msb         = div_sr[W-1];
      rem_shifted = {rem_r[W-1:0], msb};
      div_sr      <= div_sr << 1;
      if (rem_shifted >= {1'b0, divisor_mag_r}) begin
        rem_r     <= rem_shifted - {1'b0, divisor_mag_r};
        next_quot =  {quot_r[W-2:0], 1'b1};
      end else begin
        rem_r     <= rem_shifted;
        next_quot =  {quot_r[W-2:0], 1'b0};
      end
      quot_r <= next_quot;
      iter_r <= iter_r - 1'b1;
      if (iter_r == ITER_W'(1)) begin
        busy_r <= 1'b0;
        done_r <= 1'b1;
        quotient_r <= sign_r ? (-{{1{1'b0}}, next_quot}) : {{1{1'b0}}, next_quot};
      end
    end else begin
      done_r <= 1'b0;
    end
  end

  assign busy     = busy_r;
  assign done     = done_r;
  assign quotient = quotient_r;

endmodule : seq_divider
