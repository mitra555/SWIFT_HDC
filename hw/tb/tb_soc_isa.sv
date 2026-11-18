// Full-ISA SoC integration test.
// The real PicoRV32 in hdc_soc_top fetches and executes program.hex, which
// issues every custom instruction (quantize, all baseline ops, all novelty ops,
// all CSRs). Independently, reference hdcu_top / nov_top instances get the same
// operations driven directly (ref_seq.svh). Both start from identical random SPM
// contents. Afterwards every SPM word and every scalar result must match, and
// x31 (rd of every non-scalar instruction) must still hold its sentinel.
import hdcu_pkg::*;

module tb_soc_isa;
  logic clk = 0; always #5 clk = ~clk;
  logic resetn;

  hdc_soc_top #(.MEM_WORDS(4096)) dut (.clk(clk), .resetn(resetn), .trap());
  `include "memio.svh"

  // ---------------- reference instances ----------------
  logic rb_valid, rb_busy, rb_done, rb_unsup; hdcu_instr_t rb_req;
  logic [HVSIZE_W-1:0] rb_hv; logic [PROTCNT_W-1:0] rb_pc;
  logic [POPCNT_ACC_W-1:0] rb_sim; logic [PROTCNT_W-1:0] rb_srch;
  hdcu_top ref_b (.clk, .rst_n(resetn), .req_valid(rb_valid), .req(rb_req), .hdcu_busy(rb_busy),
                  .hdcu_done(rb_done), .unsupported_op(rb_unsup),
                  .spmi_re(1'b0), .spmi_we(1'b0), .spmi_addr('0), .spmi_wdata('0), .spmi_rdata(),
                  .csr_hvsize(rb_hv), .csr_protcnt(rb_pc), .sim_result(rb_sim), .search_result(rb_srch));

  logic rn_valid, rn_busy, rn_done, rn_clear; nov_instr_t rn_req;
  logic [HVSIZE_W-1:0] rn_hv; logic [15:0] rn_srch;
  nov_top ref_n (.clk, .rst_n(resetn), .req_valid(rn_valid), .req(rn_req), .req_clear_first(rn_clear),
                 .nov_busy(rn_busy), .nov_done(rn_done), .csr_hvsize(rn_hv), .search_result(rn_srch), .host_bit_re(1'b0), .host_bit_we(1'b0), .host_wide_re(1'b0), .host_wide_we(1'b0), .host_addr(20'd0), .host_wdata(32'd0), .host_bit_rdata(), .host_wide_rdata());

  `include "expect.svh"
  logic [31:0] ref_scalar [NRES];
  logic [31:0] ref_sim, ref_srch, ref_nsrch;

  task automatic ref_base(hdc_op_e op, int rd, int rs1, int rs2, int imm);
    @(negedge clk);
    rb_valid = 1; rb_req.op = op; rb_req.rd = rd[SPM_ADDR_W-1:0]; rb_req.rs1 = rs1[SPM_ADDR_W-1:0];
    rb_req.rs2 = rs2[SPM_ADDR_W-1:0]; rb_req.imm = imm;
    @(negedge clk); rb_valid = 0;
    wait (rb_done); @(posedge clk); @(negedge clk);
    ref_sim = rb_sim; ref_srch = rb_srch;
  endtask

  task automatic ref_nov(logic [3:0] op, int rd, int rs1, int rs2, int w, int k, bit clear, int hv);
    @(negedge clk);
    rn_hv = hv[HVSIZE_W-1:0];
    rn_valid = 1; rn_clear = clear; rn_req.op = nov_op_e'(op); rn_req.rd = rd[SPM_ADDR_W-1:0];
    rn_req.rs1 = rs1[SPM_ADDR_W-1:0]; rn_req.rs2 = rs2[SPM_ADDR_W-1:0];
    rn_req.weight = w[NOV_WEIGHT_W-1:0]; rn_req.k_protos = k[15:0];
    @(negedge clk); rn_valid = 0; rn_clear = 0;
    wait (rn_done); @(posedge clk); @(negedge clk);
    ref_nsrch = rn_srch;
  endtask

  // ---------------- identical random preload ----------------
  localparam int BW = SPM_DEPTH_BITS / SIMD;     // words per baseline bank
  localparam int NW = NOV_BIT_SPM_WORDS;          // novelty bit-SPM words
  localparam int WW = NOV_WIDE_SPM_WORDS;         // novelty wide-SPM words

  function automatic logic [31:0] safe_counters();   // M_BITS counters never in 5..7 (no clip ties)
    logic [31:0] v;
    for (int l = 0; l < SIMD / M_BITS; l++) begin
      int c; c = $urandom_range(0, 1) ? $urandom_range(0, 2) : $urandom_range(8, 15);
      v[l*M_BITS +: M_BITS] = c[M_BITS-1:0];
    end
    return v;
  endfunction

  `define PRELOAD_BANK(G) \
    for (int i = 0; i < BW; i++) begin \
      logic [31:0] v; v = (G == 3 && i >= 64 && i < 72) ? safe_counters() : $urandom; \
      dut.u_base.g_spm[G].u_spm_a.`SPMMEM[i] = v; ref_b.g_spm[G].u_spm_a.`SPMMEM[i] = v; \
    end
  `define CMP_BANK(G) \
    for (int i = 0; i < BW; i++) \
      if (dut.u_base.g_spm[G].u_spm_a.`SPMMEM[i] !== ref_b.g_spm[G].u_spm_a.`SPMMEM[i]) begin \
        base_mis++; if (base_mis <= 5) $display("  base bank%0d word%0d: soc=%h ref=%h", G, i, \
          dut.u_base.g_spm[G].u_spm_a.`SPMMEM[i], ref_b.g_spm[G].u_spm_a.`SPMMEM[i]); \
      end

  int base_mis = 0, bit_mis = 0, wide_mis = 0, scal_mis = 0, cyc = 0;
  logic trap_seen = 0;
  always @(posedge clk) if (resetn && dut.trap) trap_seen <= 1;

  initial begin
    resetn = 0; rb_valid = 0; rn_valid = 0; rn_clear = 0; rb_req = '0; rn_req = '0; rn_hv = '0;
    load_mem("program.hex", 4096);
    `PRELOAD_BANK(0) `PRELOAD_BANK(1) `PRELOAD_BANK(2) `PRELOAD_BANK(3)
    for (int i = 0; i < NW; i++) begin
      logic [31:0] v; v = $urandom;
      dut.u_nov.u_bit_spm_a.`SPMMEM[i] = v; dut.u_nov.u_bit_spm_b.`SPMMEM[i] = v;
      ref_n.u_bit_spm_a.`SPMMEM[i] = v;     ref_n.u_bit_spm_b.`SPMMEM[i] = v;
    end
    for (int i = 0; i < WW; i++) begin
      logic [SIMD*NOV_ACC_W-1:0] v;
      for (int l = 0; l < SIMD; l++) v[l*NOV_ACC_W +: NOV_ACC_W] = $signed($urandom_range(0, 2000000)) - 1000000;
      `WIDE_SET(dut.u_nov.u_wide_spm, i, v) `WIDE_SET(ref_n.u_wide_spm, i, v)
    end
    for (int i = 250; i < 252; i++) begin logic [SIMD*NOV_ACC_W-1:0] zw; zw = '0; `WIDE_SET(dut.u_nov.u_wide_spm, i, zw) `WIDE_SET(ref_n.u_wide_spm, i, zw) end

    repeat (5) @(posedge clk);
    resetn = 1;

    fork
      begin  // reference path
        `include "ref_seq.svh"
      end
      begin  // SoC path: wait for the completion marker
        while (peek(2048 + NRES - 1) !== 32'hC0FFEE && cyc < 400000) begin @(posedge clk); cyc++; end
      end
    join
    repeat (5) @(posedge clk);

    $display("SoC program finished in %0d cycles", cyc);
    `CMP_BANK(0) `CMP_BANK(1) `CMP_BANK(2) `CMP_BANK(3)
    for (int i = 0; i < NW; i++)
      if (dut.u_nov.u_bit_spm_a.`SPMMEM[i] !== ref_n.u_bit_spm_a.`SPMMEM[i]) begin
        bit_mis++; if (bit_mis <= 5) $display("  nov bit word%0d: soc=%h ref=%h", i, dut.u_nov.u_bit_spm_a.`SPMMEM[i], ref_n.u_bit_spm_a.`SPMMEM[i]);
      end
    for (int i = 0; i < WW; i++)
      if (`WIDE_GET(dut.u_nov.u_wide_spm, i) !== `WIDE_GET(ref_n.u_wide_spm, i)) begin
        wide_mis++; if (wide_mis <= 5) $display("  nov wide word%0d differs", i);
      end
    for (int i = 0; i < NRES; i++) begin
      logic [31:0] g; g = peek(2048 + i);
      if (g !== ref_scalar[i]) begin scal_mis++; $display("  FAIL %-36s soc=%h ref=%h", res_label[i], g, ref_scalar[i]); end
      else $display("  PASS %-36s = %h", res_label[i], g);
    end
    $display("baseline SPM mismatches: %0d / %0d words", base_mis, 4*BW);
    $display("novelty bit-SPM mismatches: %0d / %0d words", bit_mis, NW);
    $display("novelty wide-SPM mismatches: %0d / %0d words", wide_mis, WW);
    $display("trap seen: %0d", trap_seen);
    if (base_mis == 0 && bit_mis == 0 && wide_mis == 0 && scal_mis == 0 && !trap_seen && cyc < 400000)
      $display("===== FULL-ISA SOC TEST: ALL PASS =====");
    else
      $display("===== FULL-ISA SOC TEST: FAIL =====");
    $finish;
  end
endmodule
