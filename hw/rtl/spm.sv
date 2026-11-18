// =============================================================================
// spm.sv  -- Drop-in macro wrapper for the baseline SPM bank.
//
// Replaces spm.sv with sky130_sram_1kbyte_1rw1r_32x256_8 (256 words x 32-bit,
// 1RW port + 1R port) for synthesis / post-synthesis gate-level simulation.
//
// PORT MAPPING
//   Port 1 (R,  clk1/csb1/addr1/dout1) -> rs1 read  (combinational in original)
//   Port 0 (RW, clk0/csb0/web0/addr0)  -> rs2 read  (web0=1) OR write (web0=0)
//
// READ LATENCY CHANGE (vs spm.sv):
//   Original spm.sv: rdata available in the SAME clock cycle as raddr (comb.).
//   This macro:      rdata valid ONE CYCLE AFTER raddr is presented (sync read).
//   -> hdcu_ctrl.sv must add one wait state per chunk-loop iteration:
//      present raddr in cycle N, consume rdata in cycle N+1 before writing.
//   The synthesis README (synth/README_synth.md) already flags this: "A
//   synchronous-read SRAM needs one extra pipeline stage per controller loop."
//
// CONCURRENT READ AND WRITE:
//   The original spm allows a write and two reads in the same cycle. Here
//   Port 0 is shared between rs2 reads and writes; they cannot be simultaneous.
//   hdcu_ctrl reads only in a chunk's address phase and writes only in its data
//   phase, and hdc_soc_top does the same for CPU accesses, so port 0 never sees a
//   read and a write in one cycle (run_all.sh checks this on the OpenRAM models).
// =============================================================================
`timescale 1ns/1ps
import hdcu_pkg::*;

module spm #(
  parameter int DEPTH_BITS = SPM_DEPTH_BITS,
  parameter int WORD_W     = SIMD
) (
  input  logic                    clk,
  input  logic                    rst_n,

  // read port A (rs1) -> SRAM port 1 (R)
  input  logic                    re,
  input  logic [SPM_ADDR_W-1:0]   raddr,
  output logic [WORD_W-1:0]       rdata,

  // read port B (rs2) -> SRAM port 0 (RW, web=1)
  input  logic                    re_b,
  input  logic [SPM_ADDR_W-1:0]   raddr_b,
  output logic [WORD_W-1:0]       rdata_b,

  // write port -> SRAM port 0 (RW, web=0)
  input  logic                    we,
  input  logic [SPM_ADDR_W-1:0]   waddr,
  input  logic [WORD_W-1:0]       wdata
);

  localparam int N_WORDS = DEPTH_BITS / WORD_W;      // 256 (app bank)
  localparam int IDX_W   = $clog2(N_WORDS);           // 8

  // Extract word index (strip bank-select and sub-word bits)
  wire [IDX_W-1:0] rs1_widx = raddr  [$clog2(WORD_W) +: IDX_W];
  wire [IDX_W-1:0] rs2_widx = raddr_b[$clog2(WORD_W) +: IDX_W];
  wire [IDX_W-1:0] wd_widx  = waddr  [$clog2(WORD_W) +: IDX_W];

`ifdef SYNTHESIS
  // ---- Synthesis: real sky130 macro (256x32, 1RW+1R) ----
  // Port 0 = rs2 read (web=1) or write (web=0); Port 1 = rs1 read.
  wire        p0_csb  = !(re_b || we);
  wire        p0_web  = !we;
  wire [IDX_W-1:0] p0_addr = we ? wd_widx : rs2_widx;
  wire [3:0]  p0_wmask = 4'hF;
  wire        p1_csb  = !re;
  wire [WORD_W-1:0] p0_dout, p1_dout;

  sky130_sram_1kbyte_1rw1r_32x256_8 #(.VERBOSE(0)) u_sram (
    .clk0(clk), .csb0(p0_csb), .web0(p0_web), .wmask0(p0_wmask),
    .addr0(p0_addr), .din0(wdata), .dout0(p0_dout),
    .clk1(clk), .csb1(p1_csb), .addr1(rs1_widx), .dout1(p1_dout)
  );
  assign rdata   = p1_dout;
  assign rdata_b = p0_dout;

`else
  // ---- Simulation: behavioural model, 1-cycle synchronous 2R1W read, matching
  // the macro's latency. `mem` is the flat backdoor array (poke/peek as the
  // original spm). Parameterised depth so oversized test configs also fit.
  logic [WORD_W-1:0] mem [0:N_WORDS-1];
  logic [WORD_W-1:0] rdata_r, rdata_b_r;
  // Macro-faithful: dout is valid only in the cycle after a read with chip
  // select active, and X otherwise; port 0 cannot read while it writes; a read
  // of the address being written in the same cycle returns X.
  always_ff @(posedge clk) begin
    if (we) mem[wd_widx] <= wdata;
    rdata_r   <= (re && !(we && rs1_widx == wd_widx)) ? mem[rs1_widx] : 'x;
    rdata_b_r <= (re_b && !we)                        ? mem[rs2_widx] : 'x;
  end
  assign rdata   = rdata_r;
  assign rdata_b = rdata_b_r;
`endif

endmodule : spm
