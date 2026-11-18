module tb_percentile;
  logic clk=0; always #5 clk=~clk;
  logic rst_n;
  logic load_we;
  logic [5:0] load_addr;
  logic signed [31:0] load_data;
  logic start;
  logic [6:0] num_samples;
  logic busy, done;
  logic [5*32-1:0] result_packed;

  percentile_unit #(.MAX_T(64), .VAL_W(32)) dut (
    .clk(clk), .rst_n(rst_n), .load_we(load_we), .load_addr(load_addr), .load_data(load_data),
    .start(start), .num_samples(num_samples), .busy(busy), .done(done), .result_packed(result_packed)
  );

  int xs[20];
  int expected[5];
  int i;
  logic signed [31:0] r;

  initial begin
    xs[0]=66582; xs[1]=272824; xs[2]=-274065; xs[3]=14192; xs[4]=515043;
    xs[5]=519429; xs[6]=-490753; xs[7]=-383723; xs[8]=-587901; xs[9]=-77582;
    xs[10]=-616201; xs[11]=-56580; xs[12]=195486; xs[13]=-290341; xs[14]=231021;
    xs[15]=119096; xs[16]=-623926; xs[17]=77141; xs[18]=-315553; xs[19]=-111279;
    expected[0]=-590731; expected[1]=-332595; expected[2]=-67081; expected[3]=138193; expected[4]=297046;

    rst_n=0; start=0; load_we=0;
    repeat(3) @(posedge clk); rst_n=1;

    for (i=0;i<20;i=i+1) begin
      @(negedge clk);
      load_addr = i[5:0]; load_data = xs[i]; load_we = 1'b1;
      @(posedge clk); #1;
    end
    @(negedge clk); load_we = 1'b0;

    @(negedge clk);
    num_samples = 20; start = 1'b1;
    @(posedge clk);
    @(negedge clk); start = 1'b0;
    wait(done);
    @(posedge clk); #1;

    for (i=0;i<5;i=i+1) begin
      r = result_packed[i*32 +: 32];
      if (r === expected[i] || (r-expected[i] < 5 && r-expected[i] > -5))
        $display("PASS: p%0d result=%0d (expected ~%0d)", i, r, expected[i]);
      else
        $display("FAIL: p%0d result=%0d (expected ~%0d)", i, r, expected[i]);
    end
    $finish;
  end
endmodule
