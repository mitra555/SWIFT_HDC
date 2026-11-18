// tb_meanstd.sv
// Drives meanstd_unit through the exact cases produced by
// scripts/gen_meanstd_cases.py (run that script first to produce
// meanstd_cases.txt in the run directory).
//
// Timing note: every `@(posedge clk)` below is followed by `#1` before any
// blocking assignment to a DUT input. Without that, the assignment races
// the DUT's own `always_ff @(posedge clk)` for the same edge (a classic
// Verilog testbench hazard: whether the DUT's clocked block or the
// initial block's post-edge continuation runs first for the same trigger
// is not guaranteed by the LRM). Found and fixed during development of
// this testbench; it is a testbench issue only and does not affect the RTL.
module tb_meanstd;
  localparam int MAX_T = 64;
  localparam int VAL_W = 32;

  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n;
  logic load_we;
  logic [$clog2(MAX_T)-1:0] load_addr;
  logic signed [VAL_W-1:0] load_data;
  logic start;
  logic [$clog2(MAX_T+1)-1:0] num_samples;
  logic busy, done;
  logic signed [VAL_W-1:0] mean_out, std_out;

  meanstd_unit #(.MAX_T(MAX_T), .VAL_W(VAL_W)) dut (
    .clk(clk), .rst_n(rst_n),
    .load_we(load_we), .load_addr(load_addr), .load_data(load_data),
    .start(start), .num_samples(num_samples),
    .busy(busy), .done(done), .mean_out(mean_out), .std_out(std_out)
  );

  integer fd, ncases, tcase, T, i, r, guard;
  integer exp_mean, exp_std, qval;
  integer pass_count, total_count;

  initial begin
    pass_count = 0; total_count = 0;
    rst_n = 0; load_we = 0; load_addr = 0; load_data = 0; start = 0; num_samples = 0;
    repeat (3) @(posedge clk); #1;
    rst_n = 1;
    @(posedge clk); #1;

    fd = $fopen("meanstd_cases.txt", "r");
    if (fd == 0) begin
      $display("ERROR: cannot open meanstd_cases.txt -- run scripts/gen_meanstd_cases.py first");
      $finish;
    end
    r = $fscanf(fd, "%d", ncases);

    for (tcase = 0; tcase < ncases; tcase = tcase + 1) begin
      r = $fscanf(fd, "%d", T);
      for (i = 0; i < T; i = i + 1) begin
        r = $fscanf(fd, "%d", qval);
        load_we = 1; load_addr = i[$clog2(MAX_T)-1:0]; load_data = qval;
        @(posedge clk); #1;
      end
      load_we = 0;
      r = $fscanf(fd, "%d", exp_mean);
      r = $fscanf(fd, "%d", exp_std);

      num_samples = T[$clog2(MAX_T+1)-1:0];
      start = 1;
      @(posedge clk); #1;
      start = 0;

      guard = 0;
      while (!done && guard < 5000) begin
        @(posedge clk); #1;
        guard = guard + 1;
      end

      total_count = total_count + 1;
      if (guard >= 5000) begin
        $display("FAIL case %0d: TIMEOUT waiting for done (T=%0d)", tcase, T);
      end else if (mean_out === exp_mean && std_out === exp_std) begin
        pass_count = pass_count + 1;
        $display("PASS case %0d: T=%0d mean=%0d std=%0d", tcase, T, mean_out, std_out);
      end else begin
        $display("FAIL case %0d: T=%0d mean=%0d(exp %0d) std=%0d(exp %0d)",
                  tcase, T, mean_out, exp_mean, std_out, exp_std);
      end
      @(posedge clk); #1;
    end

    $fclose(fd);
    $display("\n===== MEANSTD SCOREBOARD: %0d / %0d passed =====", pass_count, total_count);
    if (pass_count == total_count) $display("ALL PASS"); else $display("*** FAIL ***");
    $finish;
  end
endmodule
