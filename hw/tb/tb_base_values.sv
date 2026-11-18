// Value-level check of the baseline HDCU (hdcu_top): does each op produce
// the right bits, not just complete? HVSIZE = 64 bits = 2 SIMD chunks.
// Operand A at bit address 0 (bank 0), B at 8192 (bank 1), dest at 16384 (bank 2),
// search prototypes at 24576 + k*64 (bank 3). Banks are 8192 bits; bank = addr[14:13].
import hdcu_pkg::*;

module tb_base_values;
  logic clk = 0; always #5 clk = ~clk;
  logic rst_n, req_valid, busy, done, unsup;
  hdcu_instr_t req;
  logic [HVSIZE_W-1:0] csr_hv; logic [PROTCNT_W-1:0] csr_pc;
  logic [POPCNT_ACC_W-1:0] sim_res; logic [PROTCNT_W-1:0] srch_res;

  hdcu_top dut (.clk, .rst_n, .req_valid, .req, .hdcu_busy(busy), .hdcu_done(done), .unsupported_op(unsup),
                .spmi_re(1'b0), .spmi_we(1'b0), .spmi_addr('0), .spmi_wdata('0), .spmi_rdata(),
                .csr_hvsize(csr_hv), .csr_protcnt(csr_pc), .sim_result(sim_res), .search_result(srch_res));

  localparam int HV = 64;
  int pass = 0, total = 0;

  // word index inside a bank = (bit address >> 5) mod 256 (spm uses addr[12:5]); bank = addr[14:13]
  function automatic int widx(int bitaddr); return (bitaddr >> 5) & 255; endfunction
  function automatic int bank(int bitaddr); return bitaddr >> 13; endfunction

  task automatic poke(int bitaddr, logic [63:0] v);
    case (bank(bitaddr))
      0: begin dut.g_spm[0].u_spm_a.mem[widx(bitaddr)] = v[31:0]; dut.g_spm[0].u_spm_a.mem[widx(bitaddr)+1] = v[63:32]; end
      1: begin dut.g_spm[1].u_spm_a.mem[widx(bitaddr)] = v[31:0]; dut.g_spm[1].u_spm_a.mem[widx(bitaddr)+1] = v[63:32]; end
      2: begin dut.g_spm[2].u_spm_a.mem[widx(bitaddr)] = v[31:0]; dut.g_spm[2].u_spm_a.mem[widx(bitaddr)+1] = v[63:32]; end
      3: begin dut.g_spm[3].u_spm_a.mem[widx(bitaddr)] = v[31:0]; dut.g_spm[3].u_spm_a.mem[widx(bitaddr)+1] = v[63:32]; end
    endcase
  endtask
  function automatic logic [63:0] peek(int bitaddr);
    case (bank(bitaddr))
      0: return {dut.g_spm[0].u_spm_a.mem[widx(bitaddr)+1], dut.g_spm[0].u_spm_a.mem[widx(bitaddr)]};
      1: return {dut.g_spm[1].u_spm_a.mem[widx(bitaddr)+1], dut.g_spm[1].u_spm_a.mem[widx(bitaddr)]};
      2: return {dut.g_spm[2].u_spm_a.mem[widx(bitaddr)+1], dut.g_spm[2].u_spm_a.mem[widx(bitaddr)]};
      default: return {dut.g_spm[3].u_spm_a.mem[widx(bitaddr)+1], dut.g_spm[3].u_spm_a.mem[widx(bitaddr)]};
    endcase
  endfunction

  task automatic issue(hdc_op_e op, int rd, int rs1, int rs2, int imm);
    @(negedge clk);
    req_valid = 1; req.op = op; req.rd = rd[SPM_ADDR_W-1:0]; req.rs1 = rs1[SPM_ADDR_W-1:0];
    req.rs2 = rs2[SPM_ADDR_W-1:0]; req.imm = imm;
    @(negedge clk); req_valid = 0;
    wait (done); @(posedge clk); @(negedge clk);   // let the S_DONE write land
  endtask

  task automatic check(string name, logic [63:0] got, logic [63:0] exp);
    total++;
    if (got === exp) begin pass++; $display("PASS %s = %h", name, got); end
    else $display("FAIL %s got=%h exp=%h", name, got, exp);
  endtask

  logic [63:0] A, B, P[3];
  initial begin
    rst_n = 0; req_valid = 0; req = '0;
    repeat (3) @(posedge clk); rst_n = 1;
    A = 64'h0123_4567_89AB_CDEF;
    B = 64'hF0F0_0FF0_1234_8001;
    poke(0, A); poke(8192, B);
    issue(HDC_CSR_HVSZ, 0, 0, 0, HV);
    check("csr_hvsize", csr_hv, HV);

    // BIND (XOR)
    poke(16384, '0);
    issue(HDC_BIND, 16384, 0, 8192, 0);
    check("bind A^B", peek(16384), A ^ B);

    // SIM (Hamming distance A vs B)
    issue(HDC_SIM, 16384, 0, 8192, 0);
    check("sim popcount(A^B)", {51'b0, sim_res}, $countones(A ^ B));

    // SIM self (A vs A, same bank) -> 0
    poke(64, A);
    issue(HDC_SIM, 16384, 0, 64, 0);
    check("sim A vs copy-of-A (same bank)", {51'b0, sim_res}, 0);

    // SEARCH: query A, 3 prototypes; proto 1 = A with 2 bits flipped (closest)
    P[0] = ~A; P[1] = A ^ 64'h0000_0100_0000_0001; P[2] = B;
    poke(24576, P[0]); poke(24576 + 64, P[1]); poke(24576 + 128, P[2]);
    issue(HDC_CSR_PROT, 0, 0, 0, 3);
    issue(HDC_SEARCH, 16384, 0, 24576, 0);
    check("search best idx (expect 1)", {48'b0, srch_res}, 1);

    // FULL-BANK CAPACITY: HVSIZE = 8192 bits = all 256 words of a bank.
    // (Before the address fix only 64 of 256 words per bank were reachable.)
    begin
      logic [31:0] fa [256], fb [256]; int bad; bad = 0;
      for (int w = 0; w < 256; w++) begin
        fa[w] = $urandom; fb[w] = $urandom;
        dut.g_spm[0].u_spm_a.mem[w] = fa[w]; dut.g_spm[1].u_spm_a.mem[w] = fb[w]; dut.g_spm[2].u_spm_a.mem[w] = '0;
      end
      issue(HDC_CSR_HVSZ, 0, 0, 0, 8192);
      issue(HDC_BIND, 16384, 0, 8192, 0);
      for (int w = 0; w < 256; w++) if (dut.g_spm[2].u_spm_a.mem[w] !== (fa[w] ^ fb[w])) bad++;
      check("full 8192-bit bank bind (mismatching words)", bad, 0);
    end

    $display("\n===== BASELINE VALUE SCOREBOARD: %0d / %0d =====", pass, total);
    $finish;
  end
  initial begin #200000; $display("TIMEOUT"); $finish; end
endmodule
