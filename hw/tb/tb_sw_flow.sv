`timescale 1ns/1ps   // 10 ns clock: the VCD for power analysis must carry real time
// Software-only SoC flow at application size (see scripts/gen_sw_flow.py).
// Nothing is preloaded into any scratchpad: firmware moves all data through the
// memory-mapped SPM windows and reads every result back. Result words that are X
// count as failures, so any dependence on uninitialised SPM contents is caught.
import hdcu_pkg::*;

module tb_sw_flow;
  `include "flow.svh"
  logic clk = 0; always #5 clk = ~clk;
  logic resetn;
  hdc_soc_top #(.MEM_WORDS(MEMW)) dut (.clk(clk), .resetn(resetn), .trap());
  `include "memio.svh"

  logic [31:0] expv [NRES];
  int cyc = 0, bad = 0;
  logic trap_seen = 0;
  always @(posedge clk) if (resetn && dut.trap) trap_seen <= 1;

  function automatic string region(int w);
    if (w < R_Q) return "baseline bind readback";
    if (w < R_X) return "encoded HV readback";
    if (w < R_X_LAST) return "accumulator chunk0";
    if (w < R_SRCH) return "accumulator last chunk";
    if (w == R_SRCH) return "dotsearch index";
    if (w < R_P3) return "normalized proto1";
    if (w < R_NORM1) return "proto3 after -Q";
    if (w < R_NORML) return "normalized proto1 chunk1";
    if (w < R_LANE) return "normalized proto1 last chunk";
    if (w < R_DONE) return "wide lane write (neighbours)";
    return "done marker";
  endfunction

`ifdef DUMP_VCD
  // Switching activity for power analysis (compile with -DDUMP_VCD; with -DSYNTHESIS the
  // SRAM macro instances match the synthesized netlist). +vcd_core selects the window:
  //   nov  : cycles where the novelty core is busy (power of nov_top while it works)
  //   base : cycles where the baseline HDCU is busy (hdcu_top)
  //   busy : either core or the table-copy engine busy (default)
  //   all  : the whole firmware run, CPU copy loops included (SoC average power)
  // +vcd_start/+vcd_stop select an explicit cycle window instead.
  int vcd_start = -1, vcd_stop = -1;
  string vcd_core = "busy";
  logic dumping = 0;
  initial begin
    void'($value$plusargs("vcd_start=%d", vcd_start));
    void'($value$plusargs("vcd_stop=%d", vcd_stop));
    void'($value$plusargs("vcd_core=%s", vcd_core));
    $dumpfile("activity.vcd");
    $dumpvars(0, dut);
    $dumpoff;
  end
  always @(posedge clk) begin
    logic want;
    if (vcd_start >= 0)        want = (cyc >= vcd_start && cyc < vcd_stop);
    else if (vcd_core == "nov")  want = dut.u_nov.nov_busy;
    else if (vcd_core == "base") want = dut.u_base.hdcu_busy;
    else if (vcd_core == "all")  want = resetn && (peek(R_DONE) !== 32'hC0FFEE);
    else                         want = dut.u_base.hdcu_busy || dut.u_nov.nov_busy || dut.dma_act;
    if (want && !dumping) begin $dumpon; dumping <= 1; end
    else if (!want && dumping) begin $dumpoff; dumping <= 0; end
  end
`endif

  initial begin
    resetn = 0;
    load_mem("mem.hex", MEMW);
    $readmemh("expect.hex", expv);
    repeat (5) @(posedge clk); resetn = 1;
    while (peek(R_DONE) !== 32'hC0FFEE && cyc < 20000000) begin @(posedge clk); cyc++; end
    repeat (3) @(posedge clk);
    for (int i = 0; i < NRES; i++) begin
      logic [31:0] g; g = peek(RES0 + i);
      if (g !== expv[i]) begin
        bad++;
        if (bad <= 8) $display("  MISMATCH %-24s word %0d: got=%h exp=%h", region(RES0 + i), RES0 + i, g, expv[i]);
      end
    end
    $display("firmware cycles: %0d   trap: %0d   result words: %0d   mismatches: %0d", cyc, trap_seen, NRES, bad);
    if (bad == 0 && !trap_seen && cyc < 20000000) $display("===== SW FLOW TEST: ALL PASS =====");
    else $display("===== SW FLOW TEST: FAIL =====");
    $finish;
  end
endmodule
