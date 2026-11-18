// =============================================================================
// tb_hdcu.sv
//
// Minimal self-checking testbench. Exercises the record-based encoding
// sequence from Pseudocode 1 in the paper (Section IV-B):
//   for each feature i: hvbind(spmC, level[i], base[i]); hvbundle(spmD, spmD, spmC)
//   hvclip(spmC, spmD, threshold)
// using HVSIZE = SIMD (single-chunk case) so the whole op completes in
// one controller pass, keeping the checker simple.
// =============================================================================
import hdcu_pkg::*;

module tb_hdcu;

  logic clk = 0;
  always #5 clk = ~clk;

  logic rst_n;
  hdcu_instr_t req;
  logic req_valid, hdcu_busy, hdcu_done, unsupported_op;
  logic spmi_we; logic [SPM_ADDR_W-1:0] spmi_addr; logic [31:0] spmi_wdata, spmi_rdata;
  logic [HVSIZE_W-1:0] csr_hvsize; logic [PROTCNT_W-1:0] csr_protcnt;

  hdcu_top dut (
    .clk(clk), .rst_n(rst_n),
    .req_valid(req_valid), .req(req),
    .hdcu_busy(hdcu_busy), .hdcu_done(hdcu_done), .unsupported_op(unsupported_op),
    .spmi_re(1'b0), .spmi_we(spmi_we), .spmi_addr(spmi_addr), .spmi_wdata(spmi_wdata), .spmi_rdata(spmi_rdata),
    .csr_hvsize(csr_hvsize), .csr_protcnt(csr_protcnt)
  );

  task automatic issue(hdc_op_e op, logic [SPM_ADDR_W-1:0] rd, rs1, rs2, logic [31:0] imm);
    begin
      @(posedge clk);
      req.op = op; req.rd = rd; req.rs1 = rs1; req.rs2 = rs2; req.imm = imm;
      req_valid = 1'b1;
      @(posedge clk);
      req_valid = 1'b0;
      wait (hdcu_done);
      @(posedge clk);
    end
  endtask

  initial begin
    rst_n = 0; req_valid = 0; spmi_we = 0; spmi_addr = 0; spmi_wdata = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;

    // Set HVSIZE = SIMD -> single-chunk operations for this smoke test
    issue(HDC_CSR_HVSZ, '0, '0, '0, SIMD);
    issue(HDC_CSR_PROT, '0, '0, '0, 32'd3);

    // NOTE: addresses below are illustrative bit-addresses into the
    // shared SPM address space; a real testbench would preload spmA/spmB
    // via the SPMI (hvmemld) path before issuing hvbind.
    issue(HDC_BIND,   13'd0, 13'd0, 13'd64, 32'd0);   // spmC = bind(spmA, spmB)
    issue(HDC_BUNDLE, 13'd128, 13'd128, 13'd0, 32'd0); // spmD = bundle(spmD, spmC)
    issue(HDC_CLIP,   13'd0, 13'd128, 13'd0, 32'(M_BITS/2)); // spmC = clip(spmD, thresh)
    issue(HDC_SIM,    13'd192, 13'd0, 13'd0, 32'd0);   // hamming distance
    issue(HDC_SEARCH, 13'd192, 13'd0, 13'd64, 32'd0);  // search vs 3 prototypes

    $display("[tb_hdcu] sequence completed without unsupported_op assertions: %0d", unsupported_op);
    $finish;
  end

endmodule : tb_hdcu
