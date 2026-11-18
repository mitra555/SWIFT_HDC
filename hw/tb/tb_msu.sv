// meanstd_sums_unit vs Python golden (scripts/gen_msu_cases.py): exact match required.
module tb_msu;
  logic clk = 0; always #5 clk = ~clk;
  logic rst_n, start, busy, done;
  logic signed [39:0] s1; logic [71:0] s2; logic [6:0] T;
  logic signed [31:0] mean_o, std_o;
  meanstd_sums_unit #(.VAL_W(32), .S1_W(40), .S2_W(72), .TW(7)) dut (
    .clk, .rst_n, .start, .s1, .s2, .num_samples(T), .busy, .done, .mean_out(mean_o), .std_out(std_o));
  integer fh, r, tt; longint a, em, es; logic [71:0] b;
  int pass = 0, total = 0;
  initial begin
    rst_n = 0; start = 0; s1 = 0; s2 = 0; T = 0;
    repeat (3) @(posedge clk); rst_n = 1;
    fh = $fopen("msu_cases.txt", "r");
    r = $fscanf(fh, "%d %d %d %d %d\n", tt, a, b, em, es);
    while (r == 5) begin
      @(negedge clk); s1 = a; s2 = b; T = tt; start = 1;
      @(negedge clk); start = 0;
      wait (done); #1;
      total++;
      if (mean_o == em && std_o == es) pass++;
      else if (total - pass <= 5) $display("FAIL T=%0d s1=%0d: mean %0d/%0d std %0d/%0d", tt, a, mean_o, em, std_o, es);
      @(negedge clk);
      r = $fscanf(fh, "%d %d %d %d %d\n", tt, a, b, em, es);
    end
    $display("===== MEANSTD_SUMS SCOREBOARD: %0d / %0d =====", pass, total);
    $finish;
  end
endmodule
