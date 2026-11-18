// =============================================================================
// spm_bit_comb.sv  -- Drop-in macro wrapper for the novelty bit SPM.
//
// Replaces spm_bit_comb.sv with sky130_sram_2kbyte_1rw1r_32x512_8
// (512 words x 32-bit, 1RW + 1R port) for synthesis / gate-level sim.
//
// Two instances of this module are used in nov_top: u_bit_spm_a and u_bit_spm_b.
// Both instances receive the SAME waddr/wdata/we (shared write bus) and
// DIFFERENT raddr (rs1 vs rs2). The macro's two ports map directly:
//   Port 0 (RW) -> write port (web0=0 when we, else chip-deselected)
//   Port 1 (R)  -> read port  (the per-instance raddr)
//
// READ LATENCY CHANGE: same as spm_sky130 -- one cycle synchronous.
// nov_ctrl.sv must add one wait state per chunk loop iteration.
// =============================================================================
`timescale 1ns/1ps
import hdcu_pkg::*;

module spm_bit_comb #(
  parameter int DEPTH_BITS = SPM_DEPTH_BITS,
  parameter int WORD_W     = SIMD
) (
  input  logic                    clk,
  input  logic                    rst_n,

  // read port -> SRAM port 1 (R)
  input  logic                    re,
  input  logic [SPM_ADDR_W-1:0]   raddr,
  output logic [WORD_W-1:0]       rdata,

  // write port -> SRAM port 0 (RW, web=0)
  input  logic                    we,
  input  logic [SPM_ADDR_W-1:0]   waddr,
  input  logic [WORD_W-1:0]       wdata
);

  localparam int N_WORDS = DEPTH_BITS / WORD_W;   // NOV_BIT_SPM_WORDS = 512 (app)
  localparam int IDX_W   = $clog2(N_WORDS);

`ifdef SYNTHESIS
  // ---- Synthesis: real sky130 macro (512x32, 1RW+1R) ----
  wire [8:0] r_widx = 9'(raddr[IDX_W-1:0]);
  wire [8:0] w_widx = 9'(waddr[IDX_W-1:0]);
  wire       p0_csb   = !we;        // port 0: only active on writes
  wire       p0_web   = 1'b0;
  wire [3:0] p0_wmask = 4'hF;
  wire       p1_csb   = !re;
  wire [WORD_W-1:0] p1_dout;
  wire [WORD_W-1:0] p0_dout_unused;

  sky130_sram_2kbyte_1rw1r_32x512_8 #(.VERBOSE(0)) u_sram (
    .clk0(clk), .csb0(p0_csb), .web0(p0_web), .wmask0(p0_wmask),
    .addr0(w_widx), .din0(wdata), .dout0(p0_dout_unused),
    .clk1(clk), .csb1(p1_csb), .addr1(r_widx), .dout1(p1_dout)
  );
  assign rdata = p1_dout;

`else
  // ---- Simulation: behavioural 1-cycle synchronous read, flat `mem` backdoor,
  // parameterised depth so oversized test configs fit. Macro-faithful: data valid
  // only in the cycle after a read, X otherwise and on a same-address read/write.
  wire [IDX_W-1:0] r_widx = raddr[IDX_W-1:0];
  wire [IDX_W-1:0] w_widx = waddr[IDX_W-1:0];
  logic [WORD_W-1:0] mem [0:N_WORDS-1];
  logic [WORD_W-1:0] rdata_r;
  always_ff @(posedge clk) begin
    if (we) mem[w_widx] <= wdata;
    // macro-faithful: valid only after a read; X on a same-address read/write
    rdata_r <= (re && !(we && r_widx == w_widx)) ? mem[r_widx] : 'x;
  end
  assign rdata = rdata_r;
`endif

endmodule : spm_bit_comb
