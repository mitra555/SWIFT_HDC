module tb_seq_div;
  logic clk=0; always #5 clk=~clk;
  logic rst_n, start;
  logic signed [31:0] dividend, divisor, quotient;
  logic busy, done;
  int pass_count=0, total_count=0;

  seq_divider #(.W(32)) dut(.clk(clk),.rst_n(rst_n),.start(start),
    .dividend(dividend),.divisor(divisor),.busy(busy),.done(done),.quotient(quotient));

  task automatic run_case(int d, int v, int expected);
    begin
      @(negedge clk);
      dividend = d; divisor = v; start = 1'b1;
      @(posedge clk);
      @(negedge clk); start = 1'b0;
      wait(done);
      total_count++;
      if (quotient === expected) begin pass_count++; $display("PASS: %0d/%0d = %0d", d, v, quotient); end
      else $display("FAIL: %0d/%0d = %0d (expected %0d)", d, v, quotient, expected);
      @(posedge clk);
    end
  endtask

  initial begin
    rst_n=0; start=0;
    repeat(3) @(posedge clk); rst_n=1;
    run_case(100, 7, 14);
    run_case(-100, 7, -14);
    run_case(100, -7, -14);
    run_case(-100, -7, 14);
    run_case(0, 5, 0);
    run_case(2147483647, 1, 2147483647);
    run_case(-2147483648, 1, -2147483648);
    run_case(17, 5, 3);
    run_case(-17, 5, -3);
    $display("\n===== SEQ_DIVIDER SCOREBOARD: %0d/%0d =====", pass_count, total_count);
    $finish;
  end
endmodule
