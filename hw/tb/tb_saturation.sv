import hdcu_pkg::*;
module tb_saturation;
  localparam longint AMAX = (64'sd1 <<< (NOV_ACC_W-1)) - 1;   // lane saturation limits
  localparam longint AMIN = -(64'sd1 <<< (NOV_ACC_W-1));
  logic clk = 0; always #5 clk = ~clk;
  logic rst_n;
  logic req_valid; nov_instr_t req; logic req_clear_first;
  logic nov_busy, nov_done;
  logic [HVSIZE_W-1:0] csr_hvsize;
  int pass_count=0, total_count=0;

  nov_top #(.BIT_SPM_DEPTH(262144), .WIDE_SPM_WORDS(8192)) dut (
    .clk(clk), .rst_n(rst_n), .req_valid(req_valid), .req(req),
    .req_clear_first(req_clear_first), .nov_busy(nov_busy), .nov_done(nov_done),
    .csr_hvsize(csr_hvsize), .host_bit_re(1'b0), .host_bit_we(1'b0), .host_wide_re(1'b0), .host_wide_we(1'b0), .host_addr(20'd0), .host_wdata(32'd0), .host_bit_rdata(), .host_wide_rdata());

  task automatic issue(nov_op_e op, logic [SPM_ADDR_W-1:0] rd, rs1, rs2,
                        logic signed [NOV_WEIGHT_W-1:0] w, logic [15:0] k, logic clear_first);
    begin
      @(posedge clk);
      req.op=op; req.rd=rd; req.rs1=rs1; req.rs2=rs2; req.weight=w; req.k_protos=k;
      req_clear_first = clear_first; req_valid = 1'b1;
      @(posedge clk); req_valid = 1'b0;
      wait(nov_done); @(posedge clk);
    end
  endtask

  task automatic check(string name, longint got, longint exp);
    begin
      total_count++;
      if (got === exp) pass_count++;
      else $display("  FAIL %s: got=%0d expected=%0d", name, got, exp);
    end
  endtask

  initial begin
    rst_n=0; req_valid=0; req_clear_first=0;
    repeat(3) @(posedge clk); rst_n=1;
    csr_hvsize = 32;

    // Preload proto0 lane0 at INT32_MAX - 2, lane1 at INT32_MIN + 2
    dut.u_wide_spm.mem[0] = '0;
    dut.u_wide_spm.mem[0][0*NOV_ACC_W +: NOV_ACC_W] = NOV_ACC_W'(AMAX - 2);   // MAX-2
    dut.u_wide_spm.mem[0][1*NOV_ACC_W +: NOV_ACC_W] = NOV_ACC_W'(AMIN + 2);  // MIN+2
    // hv: lane0 bit=0 (contributes +weight), lane1 bit=0 (contributes +weight) -- push both toward their limits
    dut.u_bit_spm_a.mem[10] = 32'h00000000;

    // push lane0 up by 8 (weight=+4 twice) -- should saturate at INT32_MAX, not wrap
    issue(NOV_PROTO_UPDATE, 13'd0, 13'd10, 13'd0, 8'sd4, 16'd0, 1'b0);
    issue(NOV_PROTO_UPDATE, 13'd0, 13'd10, 13'd0, 8'sd4, 16'd0, 1'b0);
    @(posedge clk);
    check("SAT.lane0_at_max", $signed(dut.u_wide_spm.mem[0][0*NOV_ACC_W +: NOV_ACC_W]), AMAX);

    // now push lane1 (still hv bit=0 -> +weight) which was near MIN -- adding should move it
    // toward zero, NOT toward negative saturation (sanity: not a false trigger)
    check("SAT.lane1_unaffected_direction", $signed(dut.u_wide_spm.mem[0][1*NOV_ACC_W +: NOV_ACC_W]) > AMIN + 2, 1);

    // Now drive lane1 toward MIN using weight=-4 (hv bit=0 -> contributes +weight when do_bind=0;
    // to get a NEGATIVE contribution we need hv bit=1 for that lane)
    dut.u_bit_spm_a.mem[11] = 32'hFFFFFFFF;  // all bits 1 -> all lanes contribute -weight
    dut.u_wide_spm.mem[1] = '0;
    dut.u_wide_spm.mem[1][2*NOV_ACC_W +: NOV_ACC_W] = NOV_ACC_W'(AMIN + 3);  // MIN+3
    issue(NOV_PROTO_UPDATE, 13'd1, 13'd11, 13'd0, 8'sd4, 16'd0, 1'b0);
    issue(NOV_PROTO_UPDATE, 13'd1, 13'd11, 13'd0, 8'sd4, 16'd0, 1'b0);
    @(posedge clk);
    check("SAT.lane2_at_min", $signed(dut.u_wide_spm.mem[1][2*NOV_ACC_W +: NOV_ACC_W]), AMIN);

    $display("\n===== SATURATION SCOREBOARD: %0d / %0d passed =====", pass_count, total_count);
    if (pass_count==total_count) $display("ALL PASS"); else $display("*** FAIL ***");
    $finish;
  end
endmodule
