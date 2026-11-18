// tb_nov_kth.sv -- the novelty core on REAL KTH data, against the accuracy model.
//
// Inputs (scripts/hw_accuracy_eval.py --dump-rtl DIR --dump-bits <lane width>):
//   protos_raw.hex   the 5 prototypes trained by the mode-E model (int lanes, saturating)
//   protos_norm.hex  the model's NOV_NORMALIZE result for them (Q1.(W-1))
//   queries.hex      the 180 KTH test-set query hypervectors (157 words each)
//   pred.hex         the model's predicted class for each query
//   kth_case.svh     sizes
// The test runs NOV_NORMALIZE on every prototype in place and compares every lane,
// then runs NOV_DOTSEARCH for every query and compares the predicted class. Works on
// the behavioural memories and, with -DSYNTHESIS, on the OpenRAM macro models.
import hdcu_pkg::*;

module tb_nov_kth;
  `include "kth_case.svh"
  logic clk = 0; always #5 clk = ~clk;
  logic rst_n;
  logic req_valid; nov_instr_t req; logic req_clear_first;
  logic nov_busy, nov_done;
  logic [HVSIZE_W-1:0] csr_hvsize;

  nov_top dut (.clk(clk), .rst_n(rst_n), .req_valid(req_valid), .req(req),
               .req_clear_first(req_clear_first), .nov_busy(nov_busy), .nov_done(nov_done),
               .csr_hvsize(csr_hvsize), .host_bit_re(1'b0), .host_bit_we(1'b0), .host_wide_re(1'b0),
               .host_wide_we(1'b0), .host_addr(20'd0), .host_wdata(32'd0), .host_bit_rdata(), .host_wide_rdata());
  `define MEMIO_NO_SOCMEM
  `include "memio.svh"

  logic [SIMD*NOV_ACC_W-1:0] raw  [KC*CHN];
  logic [SIMD*NOV_ACC_W-1:0] nrm  [KC*CHN];
  logic [31:0]               qry  [NQ*CHN];
  logic [31:0]               pred [NQ];

  task automatic issue(nov_op_e op, logic [SPM_ADDR_W-1:0] rd, rs1, rs2, logic [15:0] k);
    @(posedge clk);
    req = '0; req.op = op; req.rd = rd; req.rs1 = rs1; req.rs2 = rs2; req.weight = 0; req.k_protos = k;
    req_clear_first = 1'b0; req_valid = 1'b1;
    @(posedge clk); req_valid = 1'b0;
    wait (nov_done); @(posedge clk);
  endtask

  int lane_bad = 0, idx_bad = 0, cyc = 0;
  always @(posedge clk) cyc++;

  initial begin
    if (LANE != NOV_ACC_W) begin
      $display("tb_nov_kth: dump is for %0d-bit lanes but the RTL has %0d-bit lanes", LANE, NOV_ACC_W);
      $display("===== NOV KTH TEST: FAIL ====="); $finish;
    end
    $readmemh("protos_raw.hex", raw); $readmemh("protos_norm.hex", nrm);
    $readmemh("queries.hex", qry);    $readmemh("pred.hex", pred);
    rst_n = 0; req_valid = 0; req = '0; req_clear_first = 0; csr_hvsize = HVSIZE_W'(CHN * SIMD);
    repeat (3) @(posedge clk); #1 rst_n = 1;
    for (int r = 0; r < KC*CHN; r++) `WIDE_SET(dut.u_wide_spm, r, raw[r])

    // 1) normalize every prototype in place, compare every lane with the model
    for (int k = 0; k < KC; k++) issue(NOV_NORMALIZE, SPM_ADDR_W'(k*CHN), SPM_ADDR_W'(k*CHN), '0, 16'd0);
    @(posedge clk);
    for (int r = 0; r < KC*CHN; r++) begin
      logic [SIMD*NOV_ACC_W-1:0] g; g = `WIDE_GET(dut.u_wide_spm, r);
      for (int l = 0; l < SIMD; l++)
        if (g[l*NOV_ACC_W +: NOV_ACC_W] !== nrm[r][l*NOV_ACC_W +: NOV_ACC_W]) begin
          lane_bad++;
          if (lane_bad <= 5) $display("  normalize mismatch proto %0d chunk %0d lane %0d: rtl=%0d model=%0d", r / CHN, r % CHN, l,
                                      $signed(g[l*NOV_ACC_W +: NOV_ACC_W]), $signed(nrm[r][l*NOV_ACC_W +: NOV_ACC_W]));
        end
    end
    $display("normalize: %0d prototypes x %0d lanes, mismatches: %0d", KC, CHN*SIMD, lane_bad);

    // 2) dot-product search for every KTH test query
    for (int i = 0; i < NQ; i++) begin
      for (int c = 0; c < CHN; c++) begin
        dut.u_bit_spm_a.`SPMMEM[c] = qry[i*CHN + c];
        dut.u_bit_spm_b.`SPMMEM[c] = qry[i*CHN + c];
      end
      issue(NOV_DOTSEARCH, '0, '0, '0, 16'(KC));
      if (32'(dut.u_dsrch.best_idx_r) !== pred[i]) begin
        idx_bad++;
        if (idx_bad <= 5) $display("  search mismatch query %0d: rtl=%0d model=%0d", i, dut.u_dsrch.best_idx_r, pred[i]);
      end
    end
    $display("dot search: %0d KTH test queries, class mismatches vs model: %0d (model accuracy on them: %0d/%0d)",
             NQ, idx_bad, MODEL_CORRECT, NQ);
    $display("cycles: %0d", cyc);
    if (lane_bad == 0 && idx_bad == 0) $display("===== NOV KTH TEST: ALL PASS =====");
    else                               $display("===== NOV KTH TEST: FAIL =====");
    $finish;
  end
endmodule
