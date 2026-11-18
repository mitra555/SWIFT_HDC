// =============================================================================
// tb_l2normalize.sv
//
// Exercises NOV_NORMALIZE -- the previously-missing "binary + int32 AM"
// finalize step: `n = norm(best_h[c]); if n>0: best_h[c] /= n`.
//
// Case A: hvs row = [6, -8, 0, 0, ..., 0]  (a 6-8-10 triple so the norm
//         is an exact integer, 10, making the expected fixed-point
//         result hand-computable without rounding ambiguity):
//   norm = sqrt(6^2 + 8^2) = 10
//   normalized = [0.6, -0.8, 0, ...]
//   Q1.31 fixed-point: floor(0.6 * 2^31) = 1288490188
//                       floor(0.8 * 2^31) = 1717986918 (negated -> -1717986918)
//   (cross-checked against a literal numpy computation of the same
//   formula the notebook uses, `n=np.linalg.norm(v); v/n`)
//
// Case B: hvs row = all zeros (norm == 0) -- must leave the prototype
//         completely unchanged (matches the notebook's `if n>0` guard)
//         and must NOT hang attempting to divide by zero.
// =============================================================================
import hdcu_pkg::*;

module tb_l2normalize;
  // Q1.(NOV_ACC_W-1): 6/10 and -8/10, truncated toward zero
  localparam longint EXP0 =  (64'sd6 <<< (NOV_ACC_W-1)) / 10;
  localparam longint EXP1 = -((64'sd8 <<< (NOV_ACC_W-1)) / 10);

  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n;

  logic         req_valid;
  nov_instr_t   req;
  logic         req_clear_first;
  logic         nov_busy, nov_done;
  logic [HVSIZE_W-1:0] csr_hvsize;

  assign csr_hvsize = SIMD;  // HVSIZE == SIMD -> single-chunk ops for this smoke test

  nov_top dut (
    .clk(clk), .rst_n(rst_n),
    .req_valid(req_valid), .req(req), .req_clear_first(req_clear_first),
    .nov_busy(nov_busy), .nov_done(nov_done),
    .csr_hvsize(csr_hvsize)
  , .host_bit_re(1'b0), .host_bit_we(1'b0), .host_wide_re(1'b0), .host_wide_we(1'b0), .host_addr(20'd0), .host_wdata(32'd0), .host_bit_rdata(), .host_wide_rdata());

  task automatic issue(nov_op_e op, logic [SPM_ADDR_W-1:0] rd, rs1, rs2,
                        logic signed [NOV_WEIGHT_W-1:0] w, logic [15:0] k, logic clear_first);
    begin
      @(posedge clk); #1;
      req.op = op; req.rd = rd; req.rs1 = rs1; req.rs2 = rs2; req.weight = w; req.k_protos = k;
      req_clear_first = clear_first;
      req_valid = 1'b1;
      @(posedge clk); #1;
      req_valid = 1'b0;
      wait (nov_done);
      @(posedge clk); #1;
    end
  endtask

  initial begin
    rst_n = 0; req_valid = 0; req_clear_first = 0;
    repeat (3) @(posedge clk);
    #1; rst_n = 1;

    // ---- Case A: preload wide SPM address 0 with [6,-8,0,...,0] ----
    @(posedge clk); #1;
    dut.u_wide_spm.mem[0] = '0;
    dut.u_wide_spm.mem[0][0*NOV_ACC_W +: NOV_ACC_W] = NOV_ACC_W'(6);
    dut.u_wide_spm.mem[0][1*NOV_ACC_W +: NOV_ACC_W] = NOV_ACC_W'(-8);

    issue(NOV_NORMALIZE, 13'd8, 13'd0, 13'd0, 0, 0, 1'b0);  // rd=addr8, rs1=addr0

    @(posedge clk); #1;
    $display("[CaseA] lane0=%0d (expect %0d) lane1=%0d (expect %0d) lane2=%0d (expect 0)",
              $signed(dut.u_wide_spm.mem[8][0*NOV_ACC_W +: NOV_ACC_W]), EXP0,
              $signed(dut.u_wide_spm.mem[8][1*NOV_ACC_W +: NOV_ACC_W]), EXP1,
              $signed(dut.u_wide_spm.mem[8][2*NOV_ACC_W +: NOV_ACC_W]));

    if ($signed(dut.u_wide_spm.mem[8][0*NOV_ACC_W +: NOV_ACC_W]) === EXP0 &&
        $signed(dut.u_wide_spm.mem[8][1*NOV_ACC_W +: NOV_ACC_W]) === EXP1 &&
        $signed(dut.u_wide_spm.mem[8][2*NOV_ACC_W +: NOV_ACC_W]) === 32'sd0)
      $display("[CaseA] PASS: L2-normalize matches Python's n=norm(v); v/n exactly");
    else
      $display("[CaseA] *** FAIL ***");

    // ---- Case B: all-zero prototype (norm == 0) must pass through unchanged ----
    @(posedge clk); #1;
    dut.u_wide_spm.mem[16] = '0;   // all-zero source

    issue(NOV_NORMALIZE, 13'd24, 13'd16, 13'd0, 0, 0, 1'b0);

    @(posedge clk); #1;
    $display("[CaseB] lane0=%0d lane1=%0d (expect 0, 0 -- unchanged, no divide-by-zero hang)",
              $signed(dut.u_wide_spm.mem[24][0*NOV_ACC_W +: NOV_ACC_W]),
              $signed(dut.u_wide_spm.mem[24][1*NOV_ACC_W +: NOV_ACC_W]));

    if (dut.u_wide_spm.mem[24] === '0)
      $display("[CaseB] PASS: norm==0 correctly left the prototype unchanged, no hang");
    else
      $display("[CaseB] *** FAIL ***");

    $finish;
  end

endmodule : tb_l2normalize
