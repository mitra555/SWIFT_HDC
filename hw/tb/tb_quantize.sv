// =============================================================================
// tb_quantize.sv -- verifies quantize_unit against golden values computed
// from the notebook's exact formula: idx = clip(round((feat-fmin)/span*(nlvl-1)),0,nlvl-1)
// =============================================================================
import hdcu_pkg::*;

module tb_quantize;
  logic clk = 0; always #5 clk = ~clk;
  logic rst_n;

  logic start;
  logic signed [31:0] feat, fmin, span;
  logic [7:0] nlvl;
  logic busy, done;
  logic [7:0] idx;

  quantize_unit #(.FEAT_W(32), .NLVL_W(8), .IDX_W(8)) dut (
    .clk(clk), .rst_n(rst_n), .start(start),
    .feat(feat), .fmin(fmin), .span(span), .nlvl(nlvl),
    .busy(busy), .done(done), .idx(idx)
  );

  int pass_count = 0, total_count = 0;

  task automatic run_case(logic signed [31:0] f, m, s, logic [7:0] n, logic [7:0] expected);
    begin
      @(negedge clk);
      feat = f; fmin = m; span = s; nlvl = n; start = 1'b1;
      @(posedge clk);
      @(negedge clk); start = 1'b0;
      wait(done);
      total_count++;
      if (idx === expected) begin
        pass_count++;
        $display("PASS: feat=%0d fmin=%0d span=%0d nlvl=%0d -> idx=%0d", f, m, s, n, idx);
      end else begin
        $display("FAIL: feat=%0d fmin=%0d span=%0d nlvl=%0d -> idx=%0d (expected %0d)", f, m, s, n, idx, expected);
      end
      @(posedge clk);
    end
  endtask

  initial begin
    rst_n = 0; start = 0;
    repeat(3) @(posedge clk); rst_n = 1;

    // Q16.16 fixed-point values, cross-checked against golden.py
    run_case(32'sd0,      32'sd0,      32'sd65536,   8'd21, 8'd0);   // feat==fmin
    run_case(32'sd65536,  32'sd0,      32'sd65536,   8'd21, 8'd20);  // feat==fmax
    run_case(32'sd32768,  32'sd0,      32'sd65536,   8'd21, 8'd10);  // midpoint
    run_case(32'sd24248,  32'sd0,      32'sd65536,   8'd21, 8'd7);
    run_case(-32'sd32768, 32'sd0,      32'sd65536,   8'd11, 8'd0);   // below fmin -> clamp 0
    run_case(32'sd131072, 32'sd0,      32'sd65536,   8'd11, 8'd10);  // above fmax -> clamp nlvl-1
    run_case(32'sd806093, -32'sd524288, 32'sd1572864, 8'd11, 8'd8);  // nonzero fmin, wide span
    run_case(32'sd205887, -32'sd524288, 32'sd1572864, 8'd11, 8'd5);

    $display("\n===== QUANTIZER SCOREBOARD: %0d / %0d passed =====", pass_count, total_count);
    if (pass_count == total_count) $display("ALL PASS"); else $display("*** FAIL ***");
    $finish;
  end
endmodule
