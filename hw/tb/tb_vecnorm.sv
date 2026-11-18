// tb_vecnorm.sv
// Drives vecnorm_unit through the exact cases produced by
// scripts/gen_vecnorm_cases.py (run that script first to produce
// vecnorm_cases.txt in the run directory).
//
// Timing note: every `@(posedge clk)` below is followed by `#1` before any
// blocking assignment to a DUT input, to avoid racing the DUT's own
// `always_ff @(posedge clk)` for the same edge. See tb_meanstd.sv for detail.
module tb_vecnorm;
  localparam int N     = 32;
  localparam int VAL_W = 32;

  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n;
  logic load_we;
  logic [$clog2(N)-1:0] load_addr;
  logic signed [VAL_W-1:0] load_data;
  logic start, busy, done;
  logic [N*VAL_W-1:0] result_packed;

  vecnorm_unit #(.N(N), .VAL_W(VAL_W)) dut (
    .clk(clk), .rst_n(rst_n),
    .load_we(load_we), .load_addr(load_addr), .load_data(load_data),
    .start(start), .busy(busy), .done(done), .result_packed(result_packed)
  );

  integer fd, ncases, n_in_file, tcase, i, r, guard;
  integer qval, exp_out;
  integer pass_count, total_count;
  logic case_ok;

  initial begin
    pass_count = 0; total_count = 0;
    rst_n = 0; load_we = 0; load_addr = 0; load_data = 0; start = 0;
    repeat (3) @(posedge clk); #1;
    rst_n = 1;
    @(posedge clk); #1;

    fd = $fopen("vecnorm_cases.txt", "r");
    if (fd == 0) begin
      $display("ERROR: cannot open vecnorm_cases.txt -- run scripts/gen_vecnorm_cases.py first");
      $finish;
    end
    r = $fscanf(fd, "%d %d", ncases, n_in_file);
    if (n_in_file != N) begin
      $display("ERROR: file N=%0d does not match testbench N=%0d", n_in_file, N);
      $finish;
    end

    for (tcase = 0; tcase < ncases; tcase = tcase + 1) begin
      for (i = 0; i < N; i = i + 1) begin
        r = $fscanf(fd, "%d", qval);
        load_we = 1; load_addr = i[$clog2(N)-1:0]; load_data = qval;
        @(posedge clk); #1;
      end
      load_we = 0;

      start = 1;
      @(posedge clk); #1;
      start = 0;

      guard = 0;
      while (!done && guard < 5000) begin
        @(posedge clk); #1;
        guard = guard + 1;
      end

      total_count = total_count + 1;
      case_ok = 1;
      if (guard >= 5000) begin
        case_ok = 0;
        $display("FAIL case %0d: TIMEOUT waiting for done", tcase);
      end
      for (i = 0; i < N; i = i + 1) begin
        r = $fscanf(fd, "%d", exp_out);
        if (guard < 5000 && $signed(result_packed[i*VAL_W +: VAL_W]) !== exp_out) begin
          case_ok = 0;
          $display("FAIL case %0d lane %0d: got %0d expected %0d",
                    tcase, i, $signed(result_packed[i*VAL_W +: VAL_W]), exp_out);
        end
      end
      if (case_ok) begin
        pass_count = pass_count + 1;
        $display("PASS case %0d", tcase);
      end
      @(posedge clk); #1;
    end

    $fclose(fd);
    $display("\n===== VECNORM SCOREBOARD: %0d / %0d passed =====", pass_count, total_count);
    if (pass_count == total_count) $display("ALL PASS"); else $display("*** FAIL ***");
    $finish;
  end
endmodule
