// Production-parameter test for autocorr_unit, percentile_unit, meanstd_unit.
// MAX_T is overridden on the command line (-Ptb_prod_stats.MAX_T=3) to match
// how video_frontend_top actually instantiates these units (MAX_T = NPAIRS).
// Any X in a result counts as a failure (catches out-of-range array reads).
module tb_prod_stats;
  parameter int MAX_T = 3;
  parameter int NCASES = 200;
  localparam int AW = (MAX_T > 1) ? $clog2(MAX_T) : 1;
  localparam int TW = $clog2(MAX_T+1);

  logic clk = 0; always #5 clk = ~clk;
  logic rst_n;

  logic ld_we; logic [AW-1:0] ld_addr; logic signed [31:0] ld_data;
  logic [TW-1:0] nsamp;
  logic ac_start, ac_done, pc_start, pc_done, ms_start, ms_done;
  logic [16*32-1:0] ac_res; logic [5*32-1:0] pc_res;
  logic signed [31:0] ms_mean, ms_std;

  autocorr_unit #(.MAX_T(MAX_T), .N_LAGS(16), .VAL_W(32), .ACC_W(80), .DIV_W(128)) u_ac (
    .clk, .rst_n, .load_we(ld_we), .load_addr(ld_addr), .load_data(ld_data),
    .start(ac_start), .num_samples(nsamp), .busy(), .done(ac_done), .result_packed(ac_res));
  percentile_unit #(.MAX_T(MAX_T), .VAL_W(32)) u_pc (
    .clk, .rst_n, .load_we(ld_we), .load_addr(ld_addr), .load_data(ld_data),
    .start(pc_start), .num_samples(nsamp), .busy(), .done(pc_done), .result_packed(pc_res));
  meanstd_unit #(.MAX_T(MAX_T), .VAL_W(32)) u_ms (
    .clk, .rst_n, .load_we(ld_we), .load_addr(ld_addr), .load_data(ld_data),
    .start(ms_start), .num_samples(nsamp), .busy(), .done(ms_done), .mean_out(ms_mean), .std_out(ms_std));

  integer fa, fp, fm, r, i, c, T, lat;
  int xs [0:255];
  longint exp_ac [16]; longint exp_pc [5]; longint exp_mean, exp_std;
  int ac_pass = 0, ac_tot = 0, pc_pass = 0, pc_tot = 0, ms_pass = 0, ms_tot = 0, hang = 0;
  longint ac_maxerr = 0, pc_maxerr = 0, ms_maxerr = 0;

  task automatic load_all(input int T);
    for (int k = 0; k < T; k++) begin
      @(negedge clk); ld_we = 1; ld_addr = k[AW-1:0]; ld_data = xs[k];
    end
    @(negedge clk); ld_we = 0;
  endtask

  function automatic longint absl(longint v); return v < 0 ? -v : v; endfunction

  initial begin
    rst_n = 0; ld_we = 0; ac_start = 0; pc_start = 0; ms_start = 0; nsamp = '0;
    repeat (3) @(posedge clk); rst_n = 1;
    fa = $fopen("ac_cases.txt", "r"); fp = $fopen("pc_cases.txt", "r"); fm = $fopen("ms_cases.txt", "r");
    for (c = 0; c < NCASES; c++) begin
      // ---------------- autocorr ----------------
      r = $fscanf(fa, "%d", T);
      for (i = 0; i < MAX_T; i++) r = $fscanf(fa, "%d", xs[i]);
      for (i = 0; i < 16; i++) r = $fscanf(fa, "%d", exp_ac[i]);
      nsamp = T[TW-1:0];
      load_all(T);
      @(negedge clk); ac_start = 1; @(negedge clk); ac_start = 0;
      lat = 0; while (!ac_done && lat < 200000) begin @(posedge clk); lat++; end
      if (!ac_done) begin hang++; $display("HANG autocorr case %0d T=%0d", c, T); end
      #1;
      for (i = 0; i < 16; i++) begin
        logic signed [31:0] got; got = ac_res[i*32 +: 32];
        ac_tot++;
        if ($isunknown(got)) $display("AC X case %0d T=%0d lag%0d", c, T, i+1);
        else begin
          if (absl(longint'(got) - exp_ac[i]) > ac_maxerr) ac_maxerr = absl(longint'(got) - exp_ac[i]);
          if (absl(longint'(got) - exp_ac[i]) <= 1) ac_pass++;
          else if (ac_tot - ac_pass < 12) $display("AC FAIL case %0d T=%0d lag%0d got=%0d exp=%0d", c, T, i+1, got, exp_ac[i]);
        end
      end
      // ---------------- percentile ----------------
      r = $fscanf(fp, "%d", T);
      for (i = 0; i < MAX_T; i++) r = $fscanf(fp, "%d", xs[i]);
      for (i = 0; i < 5; i++) r = $fscanf(fp, "%d", exp_pc[i]);
      nsamp = T[TW-1:0];
      load_all(T);
      @(negedge clk); pc_start = 1; @(negedge clk); pc_start = 0;
      lat = 0; while (!pc_done && lat < 200000) begin @(posedge clk); lat++; end
      if (!pc_done) begin hang++; $display("HANG percentile case %0d", c); end
      #1;
      for (i = 0; i < 5; i++) begin
        logic signed [31:0] got; got = pc_res[i*32 +: 32];
        pc_tot++;
        if ($isunknown(got)) $display("PC X case %0d p%0d", c, i);
        else begin
          if (absl(longint'(got) - exp_pc[i]) > pc_maxerr) pc_maxerr = absl(longint'(got) - exp_pc[i]);
          if (absl(longint'(got) - exp_pc[i]) <= 1) pc_pass++;
          else if (pc_tot - pc_pass < 12) $display("PC FAIL case %0d T=%0d p%0d got=%0d exp=%0d", c, T, i, got, exp_pc[i]);
        end
      end
      // ---------------- meanstd ----------------
      r = $fscanf(fm, "%d", T);
      for (i = 0; i < MAX_T; i++) r = $fscanf(fm, "%d", xs[i]);
      r = $fscanf(fm, "%d %d", exp_mean, exp_std);
      nsamp = T[TW-1:0];
      load_all(T);
      @(negedge clk); ms_start = 1; @(negedge clk); ms_start = 0;
      lat = 0; while (!ms_done && lat < 200000) begin @(posedge clk); lat++; end
      if (!ms_done) begin hang++; $display("HANG meanstd case %0d", c); end
      #1;
      ms_tot += 2;
      if ($isunknown(ms_mean) || $isunknown(ms_std)) $display("MS X case %0d", c);
      else begin
        if (absl(longint'(ms_mean) - exp_mean) > ms_maxerr) ms_maxerr = absl(longint'(ms_mean) - exp_mean);
        if (absl(longint'(ms_std) - exp_std) > ms_maxerr) ms_maxerr = absl(longint'(ms_std) - exp_std);
        if (absl(longint'(ms_mean) - exp_mean) <= 1) ms_pass++; else if (ms_tot - ms_pass < 12) $display("MS mean FAIL case %0d got=%0d exp=%0d", c, ms_mean, exp_mean);
        if (absl(longint'(ms_std) - exp_std) <= 1) ms_pass++; else if (ms_tot - ms_pass < 12) $display("MS std FAIL case %0d got=%0d exp=%0d", c, ms_std, exp_std);
      end
    end
    $display("MAX_T=%0d  AUTOCORR %0d/%0d (max err %0d LSB)  PERCENTILE %0d/%0d (max err %0d)  MEANSTD %0d/%0d (max err %0d)  HANGS %0d",
             MAX_T, ac_pass, ac_tot, ac_maxerr, pc_pass, pc_tot, pc_maxerr, ms_pass, ms_tot, ms_maxerr, hang);
    $finish;
  end
endmodule
