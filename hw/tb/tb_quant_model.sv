module tb_qmodel;
  logic clk = 0; always #5 clk = ~clk;
  logic rst_n, start, busy, done; logic signed [31:0] feat, fmin, span; logic [7:0] nlvl, idx;
  quantize_unit #(.FEAT_W(32), .NLVL_W(8), .IDX_W(8)) dut (.clk, .rst_n, .start, .feat, .fmin, .span, .nlvl, .busy, .done, .idx);
  integer fh, r, a, b, c, d, e; int pass = 0, total = 0;
  initial begin
    rst_n = 0; start = 0; repeat (3) @(posedge clk); rst_n = 1;
    fh = $fopen("qcases.txt", "r");
    r = $fscanf(fh, "%d %d %d %d %d\n", a, b, c, d, e);
    while (r == 5) begin
      @(negedge clk); feat = a; fmin = b; span = c; nlvl = d; start = 1;
      @(negedge clk); start = 0;
      wait (done); #1; total++;
      if (idx == e) pass++; else if (total - pass <= 5) $display("FAIL feat=%0d fmin=%0d span=%0d nlvl=%0d got=%0d exp=%0d", a, b, c, d, idx, e);
      @(negedge clk);
      r = $fscanf(fh, "%d %d %d %d %d\n", a, b, c, d, e);
    end
    $display("===== QUANTIZER MODEL-vs-RTL: %0d / %0d =====", pass, total); $finish;
  end
endmodule
