// hv_gen_unit vs scripts/hvgen.py on 600 random (chunk, C, q, f, seeds, step) cases.
import hdcu_pkg::*;
module tb_hvgen;
  logic [HVSIZE_W-1:0] chunk, nch; logic [7:0] q; logic [15:0] f, step; logic [31:0] sl, sp;
  logic [31:0] lb, pb;
  hv_gen_unit dut (.chunk(chunk), .num_chunks(nch), .q(q), .f(f), .seed_l(sl), .seed_p(sp), .step(step),
                   .lvl_bits(lb), .pos_bits(pb));
  integer fd, n, ok, r; logic [31:0] c_, C_, q_, f_, sl_, sp_, st_, eL, eP;
  initial begin
    fd = $fopen("hvgen_cases.txt", "r"); n = 0; ok = 0;
    while (!$feof(fd)) begin
      r = $fscanf(fd, "%h %h %h %h %h %h %h %h %h\n", c_, C_, q_, f_, sl_, sp_, st_, eL, eP);
      if (r == 9) begin
        chunk = c_; nch = C_; q = q_; f = f_; sl = sl_; sp = sp_; step = st_; #1;
        n++; if (lb === eL && pb === eP) ok++;
        else if (n - ok <= 5) $display("  MISMATCH c=%0d C=%0d q=%0d f=%0d: L %h/%h P %h/%h", c_, C_, q_, f_, lb, eL, pb, eP);
      end
    end
    $display("===== HVGEN SCOREBOARD: %0d / %0d =====", ok, n);
    $finish;
  end
endmodule
