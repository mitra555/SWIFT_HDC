// =============================================================================
// spm_wide.sv  -- Drop-in macro wrapper for the novelty wide SPM.
//
// Builds the 1024-word x (SIMD x NOV_ACC_W)-bit wide SPM from parallel
// sky130_sram_4kbyte_1rw1r_32x1024_8 macros, one per 32-bit slice of the row:
// 16 macros (512 Kbit) for 16-bit lanes, 32 macros (1 Mbit) for 32-bit lanes.
//
// All 32 instances share the SAME address and control signals; only the data
// bus is sliced. This is the standard way to build wide SRAMs from narrow macros.
//
// PORT MAPPING (per instance):
//   Port 0 (RW, web=0) -> write port
//   Port 1 (R)         -> read port
//
// READ LATENCY CHANGE: 1-cycle synchronous, same as the other sky130 wrappers.
// nov_ctrl.sv must add one wait state per chunk loop iteration when using
// these macros (see synth/README_synth.md open item 2).
//
// NOTE: spm_wide.sv originally defaults to DEPTH_WORDS=4096 (overridden in
// nov_top to NOV_WIDE_SPM_WORDS=1024). This wrapper is sized to 1024 words
// matching the application; set NOV_WIDE_SPM_WORDS=1024 in hdcu_pkg.sv.
// =============================================================================
`timescale 1ns/1ps
import hdcu_pkg::*;

module spm_wide #(
  parameter int DEPTH_WORDS = NOV_WIDE_SPM_WORDS,  // 1024
  parameter int SIMD_W      = SIMD,                 // 32 lanes
  parameter int ACC_W       = NOV_ACC_W             // bits per lane (16 or 32)
) (
  input  logic                        clk,
  input  logic                        rst_n,

  input  logic                        re,
  input  logic [SPM_ADDR_W-1:0]       raddr,
  output logic [SIMD_W*ACC_W-1:0]     rdata,

  input  logic                        we,
  input  logic [SPM_ADDR_W-1:0]       waddr,
  input  logic [SIMD_W*ACC_W-1:0]     wdata
);

  localparam int IDX_W = $clog2(DEPTH_WORDS);  // 10 bits

  wire [IDX_W-1:0] r_widx = raddr[IDX_W-1:0];
  wire [IDX_W-1:0] w_widx = waddr[IDX_W-1:0];

`ifdef SYNTHESIS
  // ---- Synthesis: the SIMD_W*ACC_W-bit row is cut into 32-bit slices, one
  // sky130_sram_4kbyte_1rw1r_32x1024_8 per slice: 32 macros for 32-bit lanes
  // (one lane each), 16 macros for 16-bit lanes (two lanes each). All macros
  // share address and control; only the data bus is sliced.
  localparam int ROW_W = SIMD_W * ACC_W;
  localparam int NMAC  = ROW_W / 32;
  wire [ROW_W-1:0] row_dout;   // SIMD_W*ACC_W must be a multiple of 32
  assign rdata = row_dout;
  wire p0_csb  = !we;
  wire p0_web  = 1'b0;          // port 0 used for writes only
  wire [3:0] p0_wmask = 4'hF;
  wire p1_csb  = !re;

  genvar g;
  generate
    for (g = 0; g < NMAC; g++) begin : g_lane
      wire [31:0] mac_dout0_unused;
      sky130_sram_4kbyte_1rw1r_32x1024_8 #(.VERBOSE(0)) u_sram (
        .clk0(clk), .csb0(p0_csb), .web0(p0_web), .wmask0(p0_wmask),
        .addr0(w_widx), .din0(wdata[g*32 +: 32]), .dout0(mac_dout0_unused),
        .clk1(clk), .csb1(p1_csb), .addr1(r_widx), .dout1(row_dout[g*32 +: 32])
      );
    end
  endgenerate

`else
  // ---- Simulation: behavioural packed model of the SAME storage ----
  // SystemVerilog forbids variable indexing into the 32 generate instances
  // above, so testbenches cannot poke/compare them as one word. This mirror
  // is the single-word-addressable equivalent: poke/peek `u_wide_spm.mem[i]`
  // exactly as the behavioural spm_wide. Its registered (1-cycle) read matches
  // the macro's synchronous read, so nov_ctrl's two-phase loop sees identical
  // timing in sim and in silicon. The macro path itself is simulated with the
  // OpenRAM models by run_all.sh (m_tb_* tests, -DSYNTHESIS).
  logic [SIMD_W*ACC_W-1:0] mem [0:DEPTH_WORDS-1];
  logic [SIMD_W*ACC_W-1:0] rdata_r;

  always_ff @(posedge clk) begin
    if (we) mem[w_widx] <= wdata;
    // macro-faithful: valid only after a read; X on a same-address read/write
    rdata_r <= (re && !(we && r_widx == w_widx)) ? mem[r_widx] : 'x;
  end
  assign rdata = rdata_r;
`endif

endmodule : spm_wide
