// Novelty-core lane width (bits per prototype / accumulator lane). 16 is the
// paper configuration (KTH accuracy equal to 32-bit lanes over 20 seed sets, half
// the wide-SPM macros); define NOV_LANE32 (+define+NOV_LANE32 / -DNOV_LANE32) for
// the int32 variant.
`ifndef NOV_LANE_W
`ifdef NOV_LANE32
`define NOV_LANE_W 32
`else
`define NOV_LANE_W 16
`endif
`endif
// =============================================================================
// hdcu_pkg.sv
// Shared parameters, opcodes and typedefs for the Hyperdimensional
// Coprocessor Unit (HDCU), based on:
//   Martino et al., "Configurable Hardware Acceleration for Hyperdimensional
//   Computing Extension on RISC-V," IEEE Trans. Computers, vol.75, no.2, 2026.
// =============================================================================
package hdcu_pkg;

  // ---------------------------------------------------------------------
  // SYNTHESIS-TIME PARAMETERS (Table II)
  // ---------------------------------------------------------------------
  parameter int SIMD           = 32;   // data-level parallelism (bits/cycle)
  parameter int M_BITS         = 4;    // Bundle Capacity precision, M = log2(BC)
  parameter int SPM_DEPTH_BITS = 8192; // bits per SPM bank (8192 bits = 1 KB)
  parameter int NUM_SPM        = 4;    // spmA(BV) spmB(LV) spmC(scratch) spmD(accum)
  // Bit address covering all banks: top $clog2(NUM_SPM) bits select the bank,
  // the rest index bits inside it (4 x 8192 bits -> 15 bits). Was fixed at 13,
  // which made the bank-select bits overlap the word index, so each bank only
  // ever used 1/4 of its words.
  parameter int SPM_ADDR_W     = $clog2(NUM_SPM * SPM_DEPTH_BITS);
  parameter int MAX_HVSIZE     = 8192; // upper bound the HVSIZE CSR can hold
  parameter int HVSIZE_W       = $clog2(MAX_HVSIZE+1);
  parameter int PROTCNT_W      = 16;   // width of CSR_PROT_COUNT
  parameter int POPCNT_ACC_W   = 13;   // 13-bit accumulator, per Section III-B(e)

  // Functional-unit enable mask (synthesis-time; each FU can be dropped)
  parameter bit EN_BIND  = 1'b1;
  parameter bit EN_BUND  = 1'b1;
  parameter bit EN_CLIP  = 1'b1;
  parameter bit EN_PERM  = 1'b1;
  parameter bit EN_SIM   = 1'b1;
  parameter bit EN_SRCH  = 1'b1;

  // ---------------------------------------------------------------------
  // ISE opcodes  (funct7 field of the custom R-type HDC extension,
  // Table I). funct3 is reserved for datatype -- fixed to BINARY here.
  // ---------------------------------------------------------------------
  typedef enum logic [3:0] {
    HDC_NOP      = 4'h0,
    HDC_MEMLD    = 4'h1,  // hvmemld  (*rd, *rs1, size)
    HDC_MEMSTR   = 4'h2,  // hvmemstr (*rd, *rs1, size)
    HDC_BUNDLE   = 4'h3,  // hvbundle (*rd, *rs1, *rs2)
    HDC_BIND     = 4'h4,  // hvbind   (*rd, *rs1, *rs2)
    HDC_PERM     = 4'h5,  // hvperm   (*rd, *rs1, *rs2)
    HDC_SIM      = 4'h6,  // hvsim    (*rd, *rs1, *rs2)
    HDC_CLIP     = 4'h7,  // hvclip   (*rd, *rs1, *rs2)
    HDC_SEARCH   = 4'h8,  // hvsearch (*rd, *rs1, *rs2)
    HDC_CSR_HVSZ = 4'h9,  // CSR_HVSIZE(imm)
    HDC_CSR_PROT = 4'hA   // CSR_PROT_COUNT(imm)
  } hdc_op_e;

  // Generic SPM address/operand bundle passed from decode to the HDCU
  typedef struct packed {
    hdc_op_e                 op;
    logic [SPM_ADDR_W-1:0]   rd;
    logic [SPM_ADDR_W-1:0]   rs1;
    logic [SPM_ADDR_W-1:0]   rs2;
    logic [31:0]             imm;   // size / shift-amount / threshold / CSR value
  } hdcu_instr_t;

  // ---------------------------------------------------------------------
  // NOVELTY EXTENSION (mirrors encode_multigroup / train_eval in the
  // reference Python notebook, which the base paper's ISE cannot express):
  //   - a SIGNED, WEIGHTED accumulator, not the paper's saturating
  //     0/1-increment majority counter, because (a) multi-group encoding
  //     needs each group's contribution scaled by an integer weight w_g,
  //     and (b) perceptron retraining needs signed +hv / -hv updates.
  //   - an argmax DOT-PRODUCT search against that non-binarized signed
  //     accumulator, because the paper's hvsearch only does Hamming
  //     distance / argmin against BINARY prototypes (correct only once
  //     training has finished and prototypes are sign()-ed).
  // ---------------------------------------------------------------------
  // Novelty scratchpad sizing for the target application (KTH notebook):
  // D = 5024 (157 x 32-lane chunks; nearest multiple of SIMD to the notebook's 5000), K = 5 classes.
  //   bit SPM : level HV + position HV + encoded/query HV = 3 x 157 = 471 words -> 512 words (16 Kbit)
  //   wide SPM: accumulator X + 5 prototypes (normalized in place) = 6 x 157 = 942 -> 1024 words
  //             of SIMD x NOV_ACC_W bits (512 Kbit at 16-bit lanes, 1 Mbit at 32-bit)
  parameter int NOV_BIT_SPM_WORDS  = 512;
  parameter int NOV_WIDE_SPM_WORDS = 1024;
  parameter int NOV_ACC_W    = `NOV_LANE_W;  // signed per-lane width of the encode accumulator X and
                                     // the prototypes (saturating). 32 matches the notebook's
                                     // int32 prototypes; 16 is enough on KTH: |X| <= 1914 by
                                     // construction (12 bits) and trained prototypes stay
                                     // below 100, and 16-bit accuracy equals 32-bit
                                     // (hw_accuracy_eval.py mode J, 20 seed sets).
  parameter int NOV_WEIGHT_W = 8;   // signed integer weight width (covers w_base in [1..4], and +-1 retrain)
  parameter int NOV_DIST_W   = 2 * NOV_ACC_W;  // running dot-product sum during argmax search
                                     // (64 for 32-bit lanes; 32 for 16-bit: |dot| <= 2^15*8192);
                                     // generous headroom well beyond any realistic
                                     // (ACC_W-magnitude x HVSIZE) accumulation.

  // ---- L2-normalize finalize step ("binary + int32 AM" mode) ----
  // Covers: `n = norm(best_h[c]); if n>0: best_h[c] /= n`  -- the ONE
  // notebook corner case flagged as missing in the prior round: unlike
  // "fully binary (XOR)" mode, this mode's final class prototype is a
  // unit-L2-norm REAL vector, never binarized.
  parameter int NOV_NORMSQ_W = 2 * NOV_ACC_W + 16;  // sum of squares (80 for 32-bit lanes): covers
                                     // (2^(ACC_W-1))^2 * MAX_HVSIZE with margin, i.e.
                                     // 2*(ACC_W-1) + log2(MAX_HVSIZE) + slack bits.
  parameter int NOV_NORM_W   = NOV_ACC_W + 8;  // unsigned norm = floor(sqrt(sum_of_squares)), ceil(NORMSQ_W/2)
  parameter int NOV_QFRAC    = NOV_ACC_W - 1;  // Q1.(ACC_W-1) fixed-point format for the
                                     // normalized output: since |lane| <= ||v||_2 always
                                     // (a single lane can't exceed the vector's own norm),
                                     // every normalized lane lies in [-1, 1), so a signed
                                     // Q1.(ACC_W-1) word (same physical width as NOV_ACC_W)
                                     // represents it exactly with no extra storage needed --
                                     // the same spm_wide bank holds raw int32 accumulators
                                     // OR normalized fixed-point values interchangeably.

  typedef enum logic [2:0] {
    NOV_MAC_ENCODE  = 3'h0,  // acc += weight * bind(lvl_bit, pos_bit)   (multi-group weighted encode)
    NOV_MAC_UPDATE  = 3'h1   // acc += weight * hv_bit                  (perceptron prototype update, pos forced 0)
  } nov_mac_mode_e;

  typedef enum logic [3:0] {
    NOV_NOP           = 4'h0,
    NOV_BINDMAC       = 4'h1,  // fused bind + signed-weighted accumulate into shared X (encode_multigroup inner loop)
    NOV_SIGN          = 4'h2,  // final one-shot binarization: y_bit = MSB(acc)  (sign(X), ties -> +1)
    NOV_DOTSEARCH     = 4'h3,  // argmax dot-product search vs K non-binary prototypes (predict step)
    NOV_PROTO_UPDATE  = 4'h4,  // signed prototype update: hvs[lbl] += hv ; hvs[pred] -= hv
    NOV_NORMALIZE     = 4'h5,  // L2-normalize finalize: hvs[c] /= ||hvs[c]||_2 (no-op if norm==0)
    NOV_BINDGEN       = 4'h6   // table-free BINDMAC: L_g[q] and P_gf generated on the fly (hv_gen_unit)
  } nov_op_e;

  typedef struct packed {
    nov_op_e                    op;
    logic [SPM_ADDR_W-1:0]      rd;
    logic [SPM_ADDR_W-1:0]      rs1;
    logic [SPM_ADDR_W-1:0]      rs2;
    logic signed [NOV_WEIGHT_W-1:0] weight;
    logic [15:0]                 k_protos;   // NUM_CLASSES for dot-search
  } nov_instr_t;

  // ---------------------------------------------------------------------
  // PCPI (PicoRV32 Pico Co-Processor Interface) CUSTOM INSTRUCTION ENCODING
  //
  // RISC-V reserves four "custom" major opcodes for exactly this purpose;
  // we use custom-0 for the entire HDC extension (baseline + novelty +
  // input-encoder ops), following standard R-type layout:
  //   [31:25] funct7   [24:20] rs2   [19:15] rs1   [14:12] funct3
  //   [11:7]  rd       [6:0]   opcode
  //
  // funct3 selects the INSTRUCTION FAMILY; funct7 selects the operation
  // within that family (mirrors the paper's own opcode/funct3/funct7
  // split, Section III-A -- funct3 there picks datatype, funct7 picks
  // the op; here funct3 picks family since we have more op families).
  //
  // Real R-type instructions give exactly TWO source registers (rs1,
  // rs2) plus one destination (rd). Several operations genuinely need a
  // fourth value (e.g. NOV_BINDMAC needs a destination address, TWO
  // source addresses, AND a weight). The paper hits this same wall and
  // solves it with CSR_HVSIZE / CSR_PROT_COUNT -- infrequently-changed
  // scalars set once via a dedicated instruction, then implicitly used
  // by later R-type instructions. We extend the same pattern uniformly
  // rather than inventing a different mechanism per instruction:
  //   - CSR_SET family (funct3=PCPI_F3_CSR): rs1 carries the value,
  //     funct7 selects which CSR. rd/rs2 unused.
  //   - Every op that needs a "current scalar" (weight, HVSIZE, K) reads
  //     it from a CSR set beforehand, exactly like the baseline paper.
  //   - The "clear the whole accumulator before its first contribution"
  //     step (paper: "the first of a cumulative bundling sequence should
  //     always have a zeroed HV as its destination") is its own explicit
  //     instruction (PCPI_NOV_ZERO) rather than an inline per-call flag,
  //     which is exactly how the paper's own baseline ISA handles it too
  //     (software pre-zeroes memory; there's no hardware "clear" bit on
  //     hvbundle either).
  // ---------------------------------------------------------------------
  parameter logic [6:0] PCPI_OPCODE_CUSTOM0 = 7'b0001011;

  typedef enum logic [2:0] {
    PCPI_F3_BASELINE = 3'b000,  // funct7 = hdc_op_e (Table I ops)
    PCPI_F3_NOVELTY  = 3'b001,  // funct7 = nov_op_e (+ PCPI_NOV_ZERO)
    PCPI_F3_CSR      = 3'b010,  // funct7 = pcpi_csr_e, value from rs1
    PCPI_F3_QUANTIZE = 3'b011,  // input-encoder op (quantize_unit)
    PCPI_F3_MEMCPY   = 3'b100   // table copy engine: main memory (rs1 = byte addr, rs2 = words) -> bit SPM word DST_ADDR
  } pcpi_family_e;

  typedef enum logic [6:0] {
    CSR_HVSIZE_NOV   = 7'd0,   // novelty HVSIZE               (nov_ctrl; genuinely needs a
                                // bridge-side CSR since nov_top's csr_hvsize is an external
                                // input wire, not settable via its own req/op path -- unlike
                                // the baseline, which already has HDC_CSR_HVSZ/HDC_CSR_PROT
                                // native opcodes for exactly this, so no separate CSR needed
                                // there; those route through base_req.imm like any other op)
    CSR_K_NOV        = 7'd1,   // novelty prototype count K    (dot_search_unit)
    CSR_WEIGHT_NOV   = 7'd2,   // novelty signed weight        (signed_mac_unit)
    CSR_Q_FMIN       = 7'd3,   // quantizer: fmin, Q16.16 signed
    CSR_Q_SPAN       = 7'd4,   // quantizer: span=(fmax-fmin), Q16.16 signed (>0)
    CSR_Q_NLVL       = 7'd5,   // quantizer: nlvl (small unsigned int)
    CSR_GEN_SEEDL    = 7'd7,   // table-free encoding: level seed of the current group
    CSR_GEN_SEEDP    = 7'd8,   // table-free encoding: position seed of the current group
    CSR_GEN_STEP     = 7'd9,   // table-free encoding: threshold step = 2^16 / (2(n_levels-1))
    CSR_DST_ADDR     = 7'd6    // generic destination SPM address (see pcpi_hdc_bridge.sv header
                                // for why this exists: PCPI exposes rs1/rs2 VALUES but never the
                                // current value of rd -- only where to write the result BACK to --
                                // so any op needing a destination address plus two source
                                // addresses genuinely cannot fit in one R-type instruction over
                                // this interface, and needs the destination supplied via CSR)
  } pcpi_csr_e;

  // Novelty family funct7 encoding: nov_op_e's own values are reused
  // directly EXCEPT for NOV_BINDMAC, which gets two funct7 codes so the
  // "clear the accumulator on this call" bit (nov_ctrl's existing,
  // already-verified req_clear_first input) can be selected by the
  // instruction itself without adding any new state to nov_ctrl -- the
  // PCPI bridge alone decodes funct7 into (op=NOV_BINDMAC, clear_first).
  parameter logic [6:0] PCPI_NOV_BINDMAC_FIRST = 7'd16;  // -> NOV_BINDMAC, clear_first=1
  parameter logic [6:0] PCPI_NOV_BINDMAC_ACC   = 7'd17;  // -> NOV_BINDMAC, clear_first=0
  // Table-free encoding: rs1 = level index q, rs2 = feature index f (position rotation)
  parameter logic [6:0] PCPI_NOV_BINDGEN_FIRST = 7'd18;  // -> NOV_BINDGEN, clear_first=1
  parameter logic [6:0] PCPI_NOV_BINDGEN_ACC   = 7'd19;  // -> NOV_BINDGEN, clear_first=0

endpackage : hdcu_pkg
