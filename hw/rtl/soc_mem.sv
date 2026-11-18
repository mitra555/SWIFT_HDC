// =============================================================================
// soc_mem.sv -- PicoRV32 main memory (program + data), byte-writable,
// 1-cycle synchronous read (address registered at the clock edge, data valid in
// the following cycle). hdc_soc_top's two-cycle handshake (mm_pend) matches this.
//
// Synthesis (`SYNTHESIS defined): WORDS/2048 instances of the OpenRAM macro
// sky130_sram_8kbyte_1rw1r_32x2048_8 (2048 x 32, byte write mask). Only port 0
// (RW) is used; port 1 is deselected. A bank is enabled only on an access
// (en), so idle cycles do not read the array.
//
// Simulation (default): behavioural model with the same latency and a flat
// `memory` array for $readmemh / testbench back-door access.
//
// History: the first macro wrapper used a non-existent 33-bit cell
// (sky130_sram_soc_mem_1rw, left unresolved by Genus) and registered the macro
// output a second time, which made the read latency 2 cycles in silicon versus
// 1 in simulation.
// =============================================================================
`timescale 1ns/1ps

module soc_mem #(
  parameter int WORDS = 4096          // multiple of 2048 for the macro build
) (
  input  logic                       clk,
  input  logic                       en,      // access this cycle (read or write)
  input  logic [$clog2(WORDS)-1:0]   addr,
  input  logic [3:0]                 wstrb,
  input  logic [31:0]                wdata,
  output logic [31:0]                rdata
);

`ifdef SYNTHESIS
  localparam int BANK_WORDS = 2048;
  localparam int NB         = WORDS / BANK_WORDS;
  localparam int SEL_W      = (NB > 1) ? $clog2(NB) : 1;

  wire [10:0]    sub_addr = addr[10:0];
  wire [SEL_W-1:0] sel    = (NB > 1) ? addr[$clog2(WORDS)-1 -: SEL_W] : '0;
  logic [SEL_W-1:0] sel_r;                     // bank whose dout is valid next cycle
  always_ff @(posedge clk) if (en) sel_r <= sel;

  wire [31:0] dout [NB];
  genvar b;
  generate
    for (b = 0; b < NB; b++) begin : g_bank
      wire csb0 = !(en && (sel == b));
      wire web0 = (wstrb == 4'b0);             // active-low write
      wire [31:0] dout1_unused;
      sky130_sram_8kbyte_1rw1r_32x2048_8 #(.VERBOSE(0)) u_sram (
        .clk0(clk), .csb0(csb0), .web0(web0), .wmask0(wstrb),
        .addr0(sub_addr), .din0(wdata), .dout0(dout[b]),
        .clk1(clk), .csb1(1'b1), .addr1(11'b0), .dout1(dout1_unused)
      );
    end
  endgenerate
  assign rdata = dout[sel_r];

`else
  logic [31:0] memory [0:WORDS-1];
  logic [31:0] rdata_r;
  always_ff @(posedge clk) begin
    if (wstrb[0]) memory[addr][ 7: 0] <= wdata[ 7: 0];
    if (wstrb[1]) memory[addr][15: 8] <= wdata[15: 8];
    if (wstrb[2]) memory[addr][23:16] <= wdata[23:16];
    if (wstrb[3]) memory[addr][31:24] <= wdata[31:24];
    rdata_r <= memory[addr];
  end
  assign rdata = rdata_r;
`endif

endmodule : soc_mem
