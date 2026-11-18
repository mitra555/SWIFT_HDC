module tb_autocorr;
  logic clk=0; always #5 clk=~clk;
  logic rst_n;
  logic load_we;
  logic [5:0] load_addr;
  logic signed [31:0] load_data;
  logic start;
  logic [6:0] num_samples;
  logic busy, done;
  logic [16*32-1:0] result_packed;

  autocorr_unit #(.MAX_T(64), .N_LAGS(16), .VAL_W(32), .ACC_W(80), .DIV_W(128)) dut (
    .clk(clk), .rst_n(rst_n), .load_we(load_we), .load_addr(load_addr), .load_data(load_data),
    .start(start), .num_samples(num_samples), .busy(busy), .done(done), .result_packed(result_packed)
  );

  // golden x values (Q16.16) and expected results (4 lags used here, computed with N_LAGS=16
  // in hardware but we only check the first 4 against golden.py's 4-lag run)
  int xs[10];
  int expected[4];

  int i;
  logic signed [31:0] r;
  initial begin
    xs[0]=-54380; xs[1]=144392; xs[2]=-327605; xs[3]=-129543; xs[4]=-231502;
    xs[5]=-267165; xs[6]=-205613; xs[7]=-101213; xs[8]=-67654; xs[9]=25439;
    expected[0]=417; expected[1]=4522; expected[2]=-7704; expected[3]=-20145;

    rst_n=0; start=0; load_we=0;
    repeat(3) @(posedge clk); rst_n=1;

    for (i=0;i<10;i=i+1) begin
      @(negedge clk);
      load_addr = i[5:0]; load_data = xs[i]; load_we = 1'b1;
      @(posedge clk); #1;
    end
    @(negedge clk); load_we=1'b0;

    @(negedge clk);
    num_samples = 10; start=1'b1;
    @(posedge clk);
    @(negedge clk); start=1'b0;
    wait(done);
    @(posedge clk); #1;

    for (i=0;i<4;i=i+1) begin
      r = result_packed[i*32 +: 32];
      if (r === expected[i] || (r-expected[i] < 3 && r-expected[i] > -3))
        $display("PASS: lag%0d result=%0d (expected ~%0d)", i+1, r, expected[i]);
      else
        $display("FAIL: lag%0d result=%0d (expected ~%0d)", i+1, r, expected[i]);
    end
    $finish;
  end
endmodule
