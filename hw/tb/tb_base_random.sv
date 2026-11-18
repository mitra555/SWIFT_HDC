// Randomized value-level regression for the baseline HDCU (hdcu_top) against
// a behavioural reference model. Every op, HVSIZE in {32,64,128}.
// Regions: A @0 (bank0), B @8192 (bank1), D @16384 (bank2), W @24576 (bank3); bank = addr[14:13].
import hdcu_pkg::*;

module tb_base_random;
  parameter int NITER = 300;
  logic clk = 0; always #5 clk = ~clk;
  logic rst_n, req_valid, busy, done, unsup;
  hdcu_instr_t req;
  logic [HVSIZE_W-1:0] csr_hv; logic [PROTCNT_W-1:0] csr_pc;
  logic [POPCNT_ACC_W-1:0] sim_res; logic [PROTCNT_W-1:0] srch_res;

  hdcu_top dut (.clk, .rst_n, .req_valid, .req, .hdcu_busy(busy), .hdcu_done(done), .unsupported_op(unsup),
                .spmi_re(1'b0), .spmi_we(1'b0), .spmi_addr('0), .spmi_wdata('0), .spmi_rdata(),
                .csr_hvsize(csr_hv), .csr_protcnt(csr_pc), .sim_result(sim_res), .search_result(srch_res));

  localparam int A0 = 0, B0 = 8192, D0 = 16384, W0 = 24576;
  localparam int LANES = SIMD / M_BITS;

  // ---- word-level backdoor access (word = bitaddr>>5) ----
  task automatic setw(int bitaddr, logic [31:0] v);
    int w; w = (bitaddr >> 5) & 255;
    case (bitaddr >> 13)
      0: dut.g_spm[0].u_spm_a.mem[w] = v;  1: dut.g_spm[1].u_spm_a.mem[w] = v;
      2: dut.g_spm[2].u_spm_a.mem[w] = v;  default: dut.g_spm[3].u_spm_a.mem[w] = v;
    endcase
  endtask
  function automatic logic [31:0] getw(int bitaddr);
    int w; w = (bitaddr >> 5) & 255;
    case (bitaddr >> 13)
      0: return dut.g_spm[0].u_spm_a.mem[w];  1: return dut.g_spm[1].u_spm_a.mem[w];
      2: return dut.g_spm[2].u_spm_a.mem[w];  default: return dut.g_spm[3].u_spm_a.mem[w];
    endcase
  endfunction

  task automatic issue(hdc_op_e op, int rd, int rs1, int rs2, int imm);
    @(negedge clk);
    req_valid = 1; req.op = op; req.rd = rd[SPM_ADDR_W-1:0]; req.rs1 = rs1[SPM_ADDR_W-1:0];
    req.rs2 = rs2[SPM_ADDR_W-1:0]; req.imm = imm;
    @(negedge clk); req_valid = 0;
    wait (done); @(posedge clk); @(negedge clk);   // let the S_DONE write land
  endtask

  // op ids: 0 bind 1 sim 2 perm 3 bundle 4 clip 5 search 6 unsupported_op
  int pass [7], tot [7];
  string opname [7];
  task automatic chk(int op, bit ok, string msg);
    tot[op]++;
    if (ok) pass[op]++;
    else if (tot[op] - pass[op] <= 3) $display("FAIL %s: %s", opname[op], msg);
  endtask

  logic [31:0] a [4], b [4], ref_w [16], got;
  int N, HV;

  initial begin
    rst_n = 0; req_valid = 0; req = '0;
    for (int k = 0; k < 7; k++) begin pass[k] = 0; tot[k] = 0; end
    opname[0]="bind"; opname[1]="sim"; opname[2]="perm"; opname[3]="bundle";
    opname[4]="clip"; opname[5]="search"; opname[6]="unsup";
    repeat (3) @(posedge clk); rst_n = 1;

    for (int it = 0; it < NITER; it++) begin
      N  = 1 << $urandom_range(0, 2);       // 1, 2, 4 chunks
      HV = N * SIMD;
      issue(HDC_CSR_HVSZ, 0, 0, 0, HV);
      for (int k = 0; k < 4; k++) begin a[k] = $urandom; b[k] = $urandom; end
      for (int k = 0; k < N; k++) begin setw(A0 + 32*k, a[k]); setw(B0 + 32*k, b[k]); end

      case (it % 6)
        0: begin // BIND
          issue(HDC_BIND, D0, A0, B0, 0);
          for (int k = 0; k < N; k++) begin
            got = getw(D0 + 32*k);
            chk(0, got === (a[k] ^ b[k]), $sformatf("HV=%0d chunk%0d got=%h exp=%h", HV, k, got, a[k]^b[k]));
          end
        end
        1: begin // SIM (scalar port and SPM writeback)
          int e; e = 0;
          for (int k = 0; k < N; k++) e += $countones(a[k] ^ b[k]);
          issue(HDC_SIM, D0, A0, B0, 0);
          chk(1, sim_res == e, $sformatf("HV=%0d port got=%0d exp=%0d", HV, sim_res, e));
          chk(1, getw(D0) == e, $sformatf("HV=%0d spm got=%0d exp=%0d", HV, getw(D0), e));
        end
        2: begin // PERM by s in 1..32, in place and out of place
          logic [127:0] v, r; int s; bit inplace;
          s = $urandom_range(1, SIMD); inplace = $urandom_range(0, 1);
          v = '0; for (int k = 0; k < N; k++) v = (v << 32) | a[k];   // chunk 0 most significant
          r = (v >> s) | (v << (HV - s));
          if (HV < 128) r = r & ((128'd1 << HV) - 1);
          issue(HDC_PERM, inplace ? A0 : D0, A0, 0, s);
          for (int k = 0; k < N; k++) begin
            logic [31:0] e; e = r[(N-1-k)*32 +: 32];
            got = getw((inplace ? A0 : D0) + 32*k);
            chk(2, got === e, $sformatf("HV=%0d s=%0d inplace=%0d chunk%0d got=%h exp=%h", HV, s, inplace, k, got, e));
          end
        end
        3: begin // BUNDLE in place: W += B (saturating M-bit counters)
          for (int j = 0; j < N*M_BITS; j++) begin ref_w[j] = $urandom; setw(W0 + 32*j, ref_w[j]); end
          issue(HDC_BUNDLE, W0, W0, B0, 0);
          for (int bit_i = 0; bit_i < HV; bit_i++) begin
            int w, j, lane; logic [M_BITS-1:0] c0, e, g;
            w = bit_i / 32; j = w*M_BITS + (bit_i % 32) / LANES; lane = (bit_i % 32) % LANES;
            c0 = ref_w[j][lane*M_BITS +: M_BITS];
            e  = (b[w][bit_i % 32] && c0 != '1) ? c0 + 1'b1 : c0;
            g  = getw(W0 + 32*j) >> (lane*M_BITS);
            chk(3, g === e, $sformatf("HV=%0d bit%0d got=%0d exp=%0d (b=%0b)", HV, bit_i, g, e, b[w][bit_i%32]));
          end
        end
        4: begin // CLIP: D = (W > thr), ties excluded (random tie-break)
          int thr; thr = $urandom_range(1, (1<<M_BITS)-2);
          for (int j = 0; j < N*M_BITS; j++) begin ref_w[j] = $urandom; setw(W0 + 32*j, ref_w[j]); end
          issue(HDC_CLIP, D0, W0, 0, thr);
          for (int bit_i = 0; bit_i < HV; bit_i++) begin
            int w, j, lane; logic [M_BITS-1:0] c0; bit g;
            w = bit_i / 32; j = w*M_BITS + (bit_i % 32) / LANES; lane = (bit_i % 32) % LANES;
            c0 = ref_w[j][lane*M_BITS +: M_BITS];
            got = getw(D0 + 32*w); g = got[bit_i % 32];
            if (c0 != thr)
              chk(4, g === (c0 > thr), $sformatf("HV=%0d bit%0d cnt=%0d thr=%0d got=%0b", HV, bit_i, c0, thr, g));
          end
        end
        5: begin // SEARCH: K in 1..4 prototypes in bank 3, unique nearest
          int K, best, bd, d; logic [31:0] p [4][4];
          K = $urandom_range(1, 4);
          best = $urandom_range(0, K-1);
          for (int kk = 0; kk < K; kk++)
            for (int c = 0; c < N; c++)
              p[kk][c] = (kk == best) ? (a[c] ^ (c == 0 ? 32'h1 : 32'h0))                // distance 1
                                      : (a[c] ^ 32'h0000_00FF);                           // distance >= 8
          for (int kk = 0; kk < K; kk++) for (int c = 0; c < N; c++) setw(W0 + kk*HV + 32*c, p[kk][c]);
          issue(HDC_CSR_PROT, 0, 0, 0, K);
          issue(HDC_SEARCH, D0, A0, W0, 0);
          chk(5, srch_res == best, $sformatf("HV=%0d K=%0d got=%0d exp=%0d", HV, K, srch_res, best));
          chk(5, getw(D0) == best, $sformatf("HV=%0d K=%0d spm got=%0d exp=%0d", HV, K, getw(D0), best));
        end
      endcase
      if (unsup) chk(6, 0, "asserted");
    end

    begin
      int tp, tt; tp = 0; tt = 0;
      for (int k = 0; k < 7; k++) if (tot[k] > 0) begin
        $display("  %-8s %0d / %0d", opname[k], pass[k], tot[k]); tp += pass[k]; tt += tot[k];
      end
      $display("===== BASELINE RANDOM SCOREBOARD: %0d / %0d =====", tp, tt);
    end
    $finish;
  end
  initial begin #50000000; $display("TIMEOUT"); $finish; end
endmodule
