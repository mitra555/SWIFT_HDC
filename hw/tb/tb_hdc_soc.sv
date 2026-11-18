// =============================================================================
// tb_hdc_soc.sv  (RISC-V INTEGRATION -- end-to-end test)
//
// Loads a hand-assembled RV32I program (program.hex) into the SoC's
// memory and lets the REAL PicoRV32 core fetch, decode, and execute it
// -- including issuing custom-0 instructions that flow through
// pcpi_hdc_bridge to the quantizer and the novelty HDC datapath. This
// is the actual proof the integration works: nothing here is driven
// directly by the testbench except memory contents before reset release.
// =============================================================================
import hdcu_pkg::*;

module tb_hdc_soc;
  logic clk = 0;
  always #5 clk = ~clk;
  logic resetn;

  hdc_soc_top #(.MEM_WORDS(4096)) dut (.clk(clk), .resetn(resetn), .trap());
  `include "memio.svh"

  int pass_count = 0, total_count = 0;
  logic trap_seen;
  task automatic check(string name, logic [31:0] got, logic [31:0] expected);
    begin
      total_count++;
      if (got === expected) begin
        pass_count++;
        $display("PASS: %s = 0x%08h", name, got);
      end else begin
        $display("FAIL: %s = 0x%08h (expected 0x%08h)", name, got, expected);
      end
    end
  endtask

  initial begin
    resetn = 0;

    // load the hand-assembled program
    load_mem("program.hex", 4096);

    // preload novelty bit-SPM inputs (lvl=addr0, pos=addr1), both
    // all-zero -> bind=0 everywhere -> +weight contribution every lane.
    // (Representing data already staged by a prior load step, same
    // convention used throughout the earlier standalone verification.)
    dut.u_nov.u_bit_spm_a.`SPMMEM[0] = 32'h00000000;
    dut.u_nov.u_bit_spm_b.`SPMMEM[0] = 32'h00000000;
    dut.u_nov.u_bit_spm_a.`SPMMEM[1] = 32'h00000000;
    dut.u_nov.u_bit_spm_b.`SPMMEM[1] = 32'h00000000;

    repeat (5) @(posedge clk);
    resetn = 1;

    // monitor for illegal-instruction traps throughout
    trap_seen = 1'b0;
    fork
      begin : trap_monitor
        forever begin
          @(posedge clk);
          if (dut.trap) begin
            trap_seen = 1'b1;
            $display("*** TRAP asserted at t=%0t -- an instruction was not recognized/handled ***", $time);
          end
        end
      end
    join_none

    // run long enough for the whole program (quantizer's sequential
    // divider alone takes ~40+ cycles; give generous headroom)
    repeat (2000) @(posedge clk);
    disable trap_monitor;

    $display("\n--- Results ---");
    check("quantizer idx  (result[0], expect 10)", peek(2048), 32'd10);
    check("sentinel       (result[1], expect 0xC0FFEE)", peek(2049), 32'hC0FFEE);
    check("nov X[100] lane0 (expect +2)", `WIDE_LANE(dut.u_nov.u_wide_spm, 100, 0), 32'd2);
    check("nov sign[200] bit0 (expect 0, i.e. +1)", {31'b0, dut.u_nov.u_bit_spm_a.`SPMMEM[200][0]}, 32'd0);
    check("core never trapped", {31'b0, trap_seen}, 32'd0);

    $display("\n===== SOC INTEGRATION SCOREBOARD: %0d / %0d passed =====", pass_count, total_count);
    if (pass_count == total_count) $display("ALL PASS");
    else $display("*** FAIL ***");
    $finish;
  end
endmodule
