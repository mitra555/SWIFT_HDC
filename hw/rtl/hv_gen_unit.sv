// =============================================================================
// hv_gen_unit.sv  (NOVELTY EXTENSION, table-free encoding)
//
// Generates one 32-lane chunk of a level hypervector L_g[q] and of a position
// hypervector P_gf on the fly, so encoding needs no level/position tables in
// memory and no copies into the bit SPM. Bit 1 encodes -1 (bipolar), lane i of
// chunk c is global dimension 32c+i, and D = 32*C (HVSIZE a multiple of 32).
//
//   H(s, k)   = mix(s + k*W) with mix(x) = (x ^ x>>16) * K, then ^ >>16      (32-bit)
//   level     : base word H(seedL, c); lane threshold t_i = (g_i*G + seedL[15:0]) mod 2^16
//               (golden-ratio Weyl sequence, g_i = 32c+i); lane flips when t_i < q*step,
//               so level q flips a fraction q*step/2^16 of the dimensions (step =
//               2^16 / (2(n-1)): the top level flips half, as in the reference model)
//   position  : chunk c of P_gf is the word H(seedP, f*C + c): every feature reads its
//               own stretch of one hash sequence, so position vectors are independent
//               random vectors (statistically the same as a random table)
//
// Purely combinational; nov_top registers the outputs in the address cycle of each
// chunk, so the MAC sees them in the data cycle exactly like bit-SPM read data.
// Bit-exact reference: scripts/hvgen.py.
// =============================================================================
import hdcu_pkg::*;

module hv_gen_unit #(
  parameter int SIMD_W = SIMD,
  parameter int CW     = HVSIZE_W         // chunk-index width
) (
  input  logic [CW-1:0]  chunk,          // c
  input  logic [CW-1:0]  num_chunks,     // C = D/32
  input  logic [7:0]     q,              // level index (QUANTIZE result)
  input  logic [15:0]    f,              // feature index within the group (rotation)
  input  logic [31:0]    seed_l,
  input  logic [31:0]    seed_p,
  input  logic [15:0]    step,
  output logic [SIMD_W-1:0] lvl_bits,
  output logic [SIMD_W-1:0] pos_bits
);
  localparam logic [31:0] W   = 32'h9E3779B9;
  localparam logic [31:0] K   = 32'h045D9F3B;
  localparam logic [15:0] G16 = 16'h9E37;

  function automatic logic [31:0] hmix(input logic [31:0] s, input logic [31:0] k);
    logic [31:0] x;
    x = s + k * W;
    x = x ^ (x >> 16);
    x = x * K;
    x = x ^ (x >> 16);
    return x;
  endfunction

  // ---- level ----
  logic [31:0] base_w;
  logic [23:0] thr_lim;
  logic [15:0] t0;
  assign base_w  = hmix(seed_l, 32'(chunk));
  assign thr_lim = q * step;                              // 8 x 16 -> 24 bits
  assign t0      = 16'(chunk) * 16'(G16 << 5) + seed_l[15:0];   // threshold of lane 0
  genvar i;
  generate
    for (i = 0; i < SIMD_W; i++) begin : g_lane
      logic [15:0] t;
      assign t = t0 + 16'(i) * G16;
      assign lvl_bits[i] = base_w[i] ^ ({8'b0, t} < thr_lim);
    end
  endgenerate

  // ---- position: word f*C + c of the seed sequence ----
  logic [31:0] kp;
  assign kp       = 32'(f) * 32'(num_chunks) + 32'(chunk);
  assign pos_bits = hmix(seed_p, kp);

endmodule : hv_gen_unit
