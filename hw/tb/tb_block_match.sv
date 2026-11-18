module tb_block_match;
  logic clk=0; always #5 clk=~clk;
  logic rst_n;
  logic load_we, load_is_curr;
  logic [9:0] load_addr;
  logic [7:0] load_data;
  logic start;
  logic [1:0] cell_gy, cell_gx;
  logic busy, done;
  logic signed [4:0] best_dx, best_dy;
  logic [31:0] best_sad;

  block_match_unit #(.FRAME_SIZE(32), .FLOW_GRID(4), .BLOCK_SEARCH(8)) dut (
    .clk(clk), .rst_n(rst_n),
    .load_we(load_we), .load_is_curr(load_is_curr), .load_addr(load_addr), .load_data(load_data),
    .start(start), .cell_gy(cell_gy), .cell_gx(cell_gx),
    .busy(busy), .done(done), .best_dx(best_dx), .best_dy(best_dy), .best_sad(best_sad)
  );

  int pass_count=0, total_count=0;
  int golden_dx[0:15], golden_dy[0:15];

  initial begin
    integer fh, r, gd_x, gd_y, i;
    rst_n=0; start=0; load_we=0; load_is_curr=0;
    repeat(3) @(posedge clk); rst_n=1;

    // load golden expected values
    fh = $fopen("bm_golden.txt", "r");
    for (i=0; i<16; i=i+1) begin
      r = $fscanf(fh, "%d %d\n", gd_x, gd_y);
      golden_dx[i] = gd_x; golden_dy[i] = gd_y;
    end
    $fclose(fh);

    // load prev/curr frames into the DUT's embedded memories
    fh = $fopen("prev_frame.hex", "r");
    for (i=0; i<1024; i=i+1) begin
      r = $fscanf(fh, "%h\n", load_data);
      @(negedge clk);
      load_addr = i[9:0]; load_is_curr = 1'b0; load_we = 1'b1;
      @(posedge clk);
      #1;
    end
    @(negedge clk); load_we = 1'b0;
    $fclose(fh);

    fh = $fopen("curr_frame.hex", "r");
    for (i=0; i<1024; i=i+1) begin
      r = $fscanf(fh, "%h\n", load_data);
      @(negedge clk);
      load_addr = i[9:0]; load_is_curr = 1'b1; load_we = 1'b1;
      @(posedge clk);
      #1;
    end
    @(negedge clk); load_we = 1'b0;
    $fclose(fh);

    // run block matching for all 16 cells
    for (i=0; i<16; i=i+1) begin
      @(negedge clk);
      cell_gy = i[3:2]; cell_gx = i[1:0]; start = 1'b1;
      @(posedge clk);
      @(negedge clk); start = 1'b0;
      wait(done);
      total_count = total_count + 2;
      if ((best_dx<0 ? -best_dx : best_dx) === golden_dx[i]) pass_count++;
      else $display("FAIL cell%0d dx: got=%0d expected=%0d", i, (best_dx<0?-best_dx:best_dx), golden_dx[i]);
      if ((best_dy<0 ? -best_dy : best_dy) === golden_dy[i]) pass_count++;
      else $display("FAIL cell%0d dy: got=%0d expected=%0d", i, (best_dy<0?-best_dy:best_dy), golden_dy[i]);
      $display("cell%0d: best_dx=%0d best_dy=%0d best_sad=%0d (golden |dx|=%0d |dy|=%0d)",
        i, best_dx, best_dy, best_sad, golden_dx[i], golden_dy[i]);
      @(posedge clk);
    end

    $display("\n===== BLOCK MATCH SCOREBOARD: %0d / %0d =====", pass_count, total_count);
    if (pass_count==total_count) $display("ALL PASS"); else $display("*** FAIL ***");
    $finish;
  end
endmodule
