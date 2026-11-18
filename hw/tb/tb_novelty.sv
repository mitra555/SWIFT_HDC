// =============================================================================
// tb_novelty.sv
//
// Small, hand-checkable reproduction of the reference Python's two novel
// operations, using SIMD=32 lanes (one chunk = whole toy HV, HVSIZE=32):
//
//   1. encode_multigroup, 2 groups, 2 "features" each (already bound
//      lvl/pos pairs supplied directly as bit patterns), weights
//      w_g0=2, w_g1=1:
//        X = 2*(bind0_g0 + bind1_g0) + 1*(bind0_g1 + bind1_g1)
//        Y = sign(X)
//      Test vectors (per-lane bind bit, 0 => +1 contribution, 1 => -1):
//        lane0: g0f0=0 g0f1=0 g1f0=0 g1f1=0
//               X = 2*(+1+1) + 1*(+1+1) = +6           -> sign = +1 (bit 0)
//        lane1: g0f0=0 g0f1=1 g1f0=0 g1f1=0
//               X = 2*(+1-1) + 1*(+1+1) = +2            -> sign = +1 (bit 0)
//        lane2: g0f0=0 g0f1=1 g1f0=1 g1f1=1
//               X = 2*(+1-1) + 1*(-1-1) = -2             -> sign = -1 (bit 1)
//
//   2. One perceptron retrain step on a 2-class problem: hvs[0]=hvs[1]=0
//      initially, then hvs[0] += hv, hvs[1] -= hv for a bipolar hv equal
//      to Y from step 1 -- afterward dot_search against {hvs[0], hvs[1]}
//      with query hv=Y must pick class 0 (since hvs[0]=+hv gives the
//      largest positive dot product with hv, hvs[1]=-hv gives the most
//      negative).
// =============================================================================
import hdcu_pkg::*;

module tb_novelty;

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

  // convenience: preload the plain bit-SPM banks directly via hierarchical
  // reference for this smoke test (a real flow would use hvmemld/SPMI)
  task automatic preload_bits(int bank_word_addr, logic [SIMD-1:0] value);
    begin
      dut.u_bit_spm_a.mem[bank_word_addr] = value;
      dut.u_bit_spm_b.mem[bank_word_addr] = value;
    end
  endtask

  task automatic issue(nov_op_e op, logic [SPM_ADDR_W-1:0] rd, rs1, rs2,
                        logic signed [NOV_WEIGHT_W-1:0] w, logic [15:0] k, logic clear_first);
    begin
      @(posedge clk);
      req.op = op; req.rd = rd; req.rs1 = rs1; req.rs2 = rs2; req.weight = w; req.k_protos = k;
      req_clear_first = clear_first;
      req_valid = 1'b1;
      @(posedge clk);
      req_valid = 1'b0;
      wait (nov_done);
      @(posedge clk);
    end
  endtask

  logic [SIMD-1:0] lvl_g0f0, pos_g0f0, lvl_g0f1, pos_g0f1;
  logic [SIMD-1:0] lvl_g1f0, pos_g1f0, lvl_g1f1, pos_g1f1;
  logic [SIMD-1:0] y_expected;

  initial begin
    rst_n = 0; req_valid = 0; req_clear_first = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;

    // ---- construct the bind patterns lane-by-lane per the header comment ----
    // Lane 0: all four operand pairs equal -> bind bit = 0 (i.e. +1) everywhere
    // Lane 1: group0 pairs differ (bind=1,-1) group1 pairs equal (bind=0,+1)
    // Lane 2: group0 pairs: (equal,differ) group1 pairs: (differ,differ)
    // Remaining lanes (3..31) left at 0 (bind=0 => +1 contributions, not checked)
    lvl_g0f0 = '0; pos_g0f0 = '0;                      // lane0 eq(bind0) lane1 eq(bind0) lane2 eq(bind0)
    lvl_g0f1 = '0; pos_g0f1 = '0; pos_g0f1[1] = 1'b1; pos_g0f1[2] = 1'b1; // lane1,2 differ -> bind=1
    lvl_g1f0 = '0; pos_g1f0 = '0; pos_g1f0[2] = 1'b1;  // lane2 differ -> bind=1, lanes0,1 bind=0
    lvl_g1f1 = '0; pos_g1f1 = '0; pos_g1f1[2] = 1'b1;  // lane2 differ -> bind=1

    // load rs1/rs2 for each (feature) into distinct bit-SPM addresses
    preload_bits(0, lvl_g0f0); preload_bits(1, pos_g0f0);
    preload_bits(2, lvl_g0f1); preload_bits(3, pos_g0f1);
    preload_bits(4, lvl_g1f0); preload_bits(5, pos_g1f0);
    preload_bits(6, lvl_g1f1); preload_bits(7, pos_g1f1);

    // ---- encode_multigroup: X += w_g * bind(lvl,pos), shared accumulator at wide addr 0 ----
    issue(NOV_BINDMAC, 13'd0, 13'd0, 13'd1, 4'sd2, 16'd0, 1'b1); // group0 feat0, weight=2, clear X
    issue(NOV_BINDMAC, 13'd0, 13'd2, 13'd3, 4'sd2, 16'd0, 1'b0); // group0 feat1, weight=2
    issue(NOV_BINDMAC, 13'd0, 13'd4, 13'd5, 4'sd1, 16'd0, 1'b0); // group1 feat0, weight=1
    issue(NOV_BINDMAC, 13'd0, 13'd6, 13'd7, 4'sd1, 16'd0, 1'b0); // group1 feat1, weight=1

    // ---- sign(X) -> packed bipolar HV at bit-SPM address 8 ----
    issue(NOV_SIGN, 13'd8, 13'd0, 13'd0, 4'sd0, 16'd0, 1'b0);
    @(posedge clk);
    $display("[tb_novelty] X lane0=%0d lane1=%0d lane2=%0d",
              $signed(dut.u_wide_spm.mem[0][0*NOV_ACC_W +: NOV_ACC_W]),
              $signed(dut.u_wide_spm.mem[0][1*NOV_ACC_W +: NOV_ACC_W]),
              $signed(dut.u_wide_spm.mem[0][2*NOV_ACC_W +: NOV_ACC_W]));
    $display("[tb_novelty] sign bits: lane0=%0b (expect 0/+1) lane1=%0b (expect 0/+1) lane2=%0b (expect 1/-1)",
              dut.u_bit_spm_a.mem[8][0], dut.u_bit_spm_a.mem[8][1], dut.u_bit_spm_a.mem[8][2]);

    if ($signed(dut.u_wide_spm.mem[0][0*NOV_ACC_W +: NOV_ACC_W]) !== 16'sd6 ||
        $signed(dut.u_wide_spm.mem[0][1*NOV_ACC_W +: NOV_ACC_W]) !== 16'sd2 ||
        $signed(dut.u_wide_spm.mem[0][2*NOV_ACC_W +: NOV_ACC_W]) !== -16'sd2)
      $display("[tb_novelty] *** FAIL: accumulator values don't match hand-computed expectation ***");
    else
      $display("[tb_novelty] PASS: weighted multi-group accumulator matches hand computation");

    // ---- perceptron retrain step: hvs[0] += hv ; hvs[1] -= hv, hv = sign(X) from address 8 ----
    issue(NOV_PROTO_UPDATE, 13'd100, 13'd8, 13'd0, 4'sd1,  16'd0, 1'b1); // hvs[0] = 0 + hv
    issue(NOV_PROTO_UPDATE, 13'd200, 13'd8, 13'd0, -4'sd1, 16'd0, 1'b1); // hvs[1] = 0 - hv

    // ---- dot-search: query = hv, prototypes at addr 100 (class0) and 200 (class1), K=2 ----
    issue(NOV_DOTSEARCH, 13'd0, 13'd8, 13'd100, 4'sd0, 16'd2, 1'b0);
    @(posedge clk);
    $display("[tb_novelty] dot_search best_idx=%0d best_dot=%0d (expect class 0, positive)",
              dut.u_dsrch.best_idx_r, dut.u_dsrch.best_dot_r);
    if (dut.u_dsrch.best_idx_r !== 16'd0)
      $display("[tb_novelty] *** FAIL: perceptron-updated search did not pick the reinforced class ***");
    else
      $display("[tb_novelty] PASS: dot-product argmax search correctly picks the reinforced prototype");

    $finish;
  end

endmodule : tb_novelty
