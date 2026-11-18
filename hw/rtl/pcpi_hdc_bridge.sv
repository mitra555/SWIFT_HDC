// =============================================================================
// pcpi_hdc_bridge.sv  (RISC-V INTEGRATION)
//
// Decodes PicoRV32's Pico Co-Processor Interface (pcpi_valid/pcpi_insn/
// pcpi_rs1/pcpi_rs2 -> pcpi_wr/pcpi_rd/pcpi_wait/pcpi_ready) into the
// three existing, independently-verified subsystems:
//   - hdcu_top   (baseline, paper-faithful HDC ops, Table I)
//   - nov_top    (novelty: weighted multi-group encode, perceptron retrain)
//   - quantize_unit (input encoder: feature -> level index)
//
// WHY A CSR FOR THE DESTINATION ADDRESS:
// A real RISC-V R-type instruction gives exactly two SOURCE VALUES
// (rs1, rs2) as inputs to a coprocessor -- PCPI exposes pcpi_rs1/
// pcpi_rs2 for exactly this. The `rd` field is consumed entirely by
// the core itself for register-file WRITEBACK routing; the core never
// exposes "the current value sitting in register rd" to the
// coprocessor, only where to send a result. So an op needing a
// destination SPM address PLUS two source SPM addresses (e.g.
// hvbind(rd, rs1, rs2), all three used as read operands in the
// paper's own Table I) genuinely cannot be expressed as a single
// R-type instruction over PCPI -- there is no interface path for a
// third address value. This is resolved exactly the way the paper
// resolves its own analogous problem (CSR_HVSIZE / CSR_PROT_COUNT for
// values that don't fit in the operand fields): a CSR_DST_ADDR,
// written once via a dedicated CSR-set instruction, supplies the
// destination address for whichever data-producing op follows.
//
// Ops that produce a SCALAR result (Hamming distance, predicted class
// index, quantized level index) skip the SPM entirely and return
// their result directly via pcpi_wr/pcpi_rd -- the natural fit for
// PCPI's actual writeback mechanism, and arguably a cleaner match to
// how software actually wants to use a predicted class or an index
// (immediately, in a register) than round-tripping it through SPM.
// =============================================================================
import hdcu_pkg::*;

module pcpi_hdc_bridge (
  input  logic         clk,
  input  logic         resetn,

  // ---- PCPI ----
  input  logic         pcpi_valid,
  input  logic [31:0]  pcpi_insn,
  input  logic [31:0]  pcpi_rs1,
  input  logic [31:0]  pcpi_rs2,
  output logic         pcpi_wr,
  output logic [31:0]  pcpi_rd,
  output logic         pcpi_wait,
  output logic         pcpi_ready,

  // ---- baseline HDCU (hdcu_top) ----
  output logic         base_req_valid,
  output hdcu_instr_t  base_req,
  input  logic         base_busy,
  input  logic         base_done,
  input  logic         base_unsupported,

  // ---- novelty extension (nov_top) ----
  output logic         nov_req_valid,
  output nov_instr_t   nov_req,
  output logic         nov_req_clear_first,
  input  logic         nov_busy,
  input  logic         nov_done,

  // ---- input encoder (quantize_unit) ----
  output logic                quant_start,
  output logic signed [31:0]  quant_feat,
  output logic signed [31:0]  quant_fmin,
  output logic signed [31:0]  quant_span,
  output logic [7:0]          quant_nlvl,
  input  logic                quant_busy,
  input  logic                quant_done,
  input  logic [7:0]          quant_idx,

  // ---- table copy engine (hdc_soc_top): main memory -> novelty bit SPM ----
  output logic                dma_start,
  output logic [31:0]         dma_src,     // byte address in main memory
  output logic [15:0]         dma_n,       // number of 32-bit words
  output logic [SPM_ADDR_W-1:0] dma_dst,   // bit-SPM word index
  input  logic                dma_done,

  // ---- scalar results from baseline HDC_SIM / HDC_SEARCH, exposed by
  // the caller's hdcu_top instance via its own SPM readback or a small
  // side-channel; kept as plain inputs here so the bridge doesn't need
  // to know hdcu_top's internals ----
  input  logic [12:0]  base_sim_result,     // HDC_SIM: Hamming distance
  input  logic [15:0]  base_search_idx,     // HDC_SEARCH: best-matching prototype index
  input  logic [15:0]  nov_search_idx,      // nov_top's dot_search best_idx

  // nov_top's csr_hvsize is a genuine external input (unlike the
  // baseline, which sets its HVSIZE via its own native HDC_CSR_HVSZ
  // opcode through req.imm) -- exposed here as a proper port rather
  // than reaching into the bridge's internals from the top level.
  output logic [HVSIZE_W-1:0] csr_hvsize_nov,

  // table-free encoding parameters (hv_gen_unit in nov_top)
  output logic [31:0] csr_gen_seedl,
  output logic [31:0] csr_gen_seedp,
  output logic [15:0] csr_gen_step
);

  // -------------------------------------------------------------------
  // Instruction field decode
  // -------------------------------------------------------------------
  wire [6:0] opcode = pcpi_insn[6:0];
  wire [4:0] rd_f   = pcpi_insn[11:7];   // unused as a value (see header); kept for completeness
  wire [2:0] funct3 = pcpi_insn[14:12];
  wire [6:0] funct7 = pcpi_insn[31:25];

  wire is_custom0 = (opcode == PCPI_OPCODE_CUSTOM0);

  // -------------------------------------------------------------------
  // CSR bank: destination address + per-family scalars, written by
  // PCPI_F3_CSR instructions (funct7 selects which, value = pcpi_rs1)
  // -------------------------------------------------------------------
  logic [SPM_ADDR_W-1:0]          csr_dst_addr;
  logic [HVSIZE_W-1:0]            csr_hvsize_nov_r;
  logic [15:0]                    csr_k_nov;
  logic signed [NOV_WEIGHT_W-1:0] csr_weight_nov;
  logic signed [31:0]             csr_q_fmin, csr_q_span;
  logic [7:0]                     csr_q_nlvl;

  assign csr_hvsize_nov = csr_hvsize_nov_r;

  // -------------------------------------------------------------------
  // Dispatch FSM: one instruction in flight at a time (matches the
  // paper's own single-shared-datapath philosophy, Fig. 2)
  // -------------------------------------------------------------------
  typedef enum logic [2:0] {S_IDLE, S_CSR, S_BASE, S_NOV, S_QUANT, S_DMA, S_DONE} state_e;
  state_e state_r, state_n;

  logic result_is_scalar_r;     // this op's result should go to pcpi_rd, not SPM
  logic [31:0] scalar_result_r;

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      state_r <= S_IDLE;
      csr_dst_addr <= '0;
      csr_hvsize_nov_r <= '0; csr_k_nov <= '0; csr_weight_nov <= '0;
      csr_q_fmin <= '0; csr_q_span <= '0; csr_q_nlvl <= '0;
      csr_gen_seedl <= '0; csr_gen_seedp <= '0; csr_gen_step <= '0;
      result_is_scalar_r <= 1'b0;
      scalar_result_r <= '0;
    end else begin
      state_r <= state_n;

      if (state_r == S_IDLE && pcpi_valid && is_custom0 && funct3 == PCPI_F3_CSR) begin
        unique case (funct7)
          CSR_HVSIZE_NOV:   csr_hvsize_nov_r <= pcpi_rs1[HVSIZE_W-1:0];
          CSR_K_NOV:        csr_k_nov        <= pcpi_rs1[15:0];
          CSR_WEIGHT_NOV:   csr_weight_nov   <= pcpi_rs1[NOV_WEIGHT_W-1:0];
          CSR_Q_FMIN:       csr_q_fmin       <= pcpi_rs1;
          CSR_Q_SPAN:       csr_q_span       <= pcpi_rs1;
          CSR_Q_NLVL:       csr_q_nlvl       <= pcpi_rs1[7:0];
          CSR_DST_ADDR:     csr_dst_addr     <= pcpi_rs1[SPM_ADDR_W-1:0];
          CSR_GEN_SEEDL:    csr_gen_seedl    <= pcpi_rs1;
          CSR_GEN_SEEDP:    csr_gen_seedp    <= pcpi_rs1;
          CSR_GEN_STEP:     csr_gen_step     <= pcpi_rs1[15:0];
          default: ;
        endcase
      end

      // HDC_SEARCH returns the prototype index, HDC_SIM the Hamming distance
      // (previously both returned base_sim_result, so hvsearch gave a distance).
      if (state_r == S_BASE && base_done)
        scalar_result_r <= (funct7 == HDC_SEARCH) ? {16'b0, base_search_idx}
                                                  : {19'b0, base_sim_result};
      if (state_r == S_NOV && nov_done)
        scalar_result_r <= {16'b0, nov_search_idx};
      if (state_r == S_QUANT && quant_done)
        scalar_result_r <= {24'b0, quant_idx};
    end
  end

  logic is_base_scalar_op, is_nov_scalar_op;
  // Qualified by funct3: funct7 values overlap across families (e.g. CSR_DST_ADDR=6
  // equals HDC_SIM, CSR_Q_FMIN=3 and HDC_BUNDLE=3 equal NOV_DOTSEARCH), and an
  // unqualified match wrote a stale scalar into rd for those instructions.
  assign is_base_scalar_op = (funct3 == PCPI_F3_BASELINE) && ((funct7 == HDC_SIM) || (funct7 == HDC_SEARCH));
  assign is_nov_scalar_op  = (funct3 == PCPI_F3_NOVELTY)  && (funct7 == NOV_DOTSEARCH);

  always_comb begin
    state_n = state_r;

    base_req_valid = 1'b0;
    base_req.op  = HDC_NOP;
    base_req.rd  = csr_dst_addr;
    base_req.rs1 = pcpi_rs1[SPM_ADDR_W-1:0];
    base_req.rs2 = pcpi_rs2[SPM_ADDR_W-1:0];
    base_req.imm = pcpi_rs1;

    nov_req_valid = 1'b0;
    nov_req_clear_first = 1'b0;
    nov_req.op       = NOV_NOP;
    nov_req.rd       = csr_dst_addr;
    nov_req.rs1      = pcpi_rs1[SPM_ADDR_W-1:0];
    nov_req.rs2      = pcpi_rs2[SPM_ADDR_W-1:0];
    nov_req.weight   = csr_weight_nov;
    nov_req.k_protos = csr_k_nov;

    quant_start = 1'b0;
    dma_start   = 1'b0;
    dma_src     = pcpi_rs1;
    dma_n       = pcpi_rs2[15:0];
    dma_dst     = csr_dst_addr;
    quant_feat  = pcpi_rs1;
    quant_fmin  = csr_q_fmin;
    quant_span  = csr_q_span;
    quant_nlvl  = csr_q_nlvl;

    pcpi_wr    = 1'b0;
    pcpi_rd    = scalar_result_r;
    pcpi_wait  = 1'b0;
    pcpi_ready = 1'b0;

    unique case (state_r)

      S_IDLE: begin
        if (pcpi_valid && is_custom0) begin
          pcpi_wait = 1'b1;   // claim the instruction THIS cycle, regardless of family,
                              // so the core's PCPI timeout counter never starts decrementing
          unique case (funct3)
            PCPI_F3_CSR: begin
              state_n = S_DONE;   // 1-cycle CSR write, ready next cycle
            end
            PCPI_F3_BASELINE: begin
              base_req_valid = 1'b1;
              base_req.op  = hdc_op_e'(funct7[3:0]);
              base_req.rd  = csr_dst_addr;
              base_req.rs1 = pcpi_rs1[SPM_ADDR_W-1:0];
              base_req.rs2 = pcpi_rs2[SPM_ADDR_W-1:0];
              // HDC_PERM (shift amount) and HDC_CLIP (threshold) take their
              // immediate from rs2, which they don't use as an address; taking
              // it from rs1 (the source address, always chunk-aligned) forced
              // shift = 0/32 and threshold = 0. CSR ops keep imm = rs1.
              base_req.imm = (funct7[3:0] == HDC_PERM || funct7[3:0] == HDC_CLIP) ? pcpi_rs2 : pcpi_rs1;
              state_n = S_BASE;
            end
            PCPI_F3_NOVELTY: begin
              nov_req_valid = 1'b1;
              if (funct7 == PCPI_NOV_BINDMAC_FIRST || funct7 == PCPI_NOV_BINDMAC_ACC) begin
                nov_req.op = NOV_BINDMAC;
                nov_req_clear_first = (funct7 == PCPI_NOV_BINDMAC_FIRST);
              end else if (funct7 == PCPI_NOV_BINDGEN_FIRST || funct7 == PCPI_NOV_BINDGEN_ACC) begin
                nov_req.op = NOV_BINDGEN;
                nov_req_clear_first = (funct7 == PCPI_NOV_BINDGEN_FIRST);
              end else begin
                nov_req.op = nov_op_e'(funct7[3:0]);
              end
              state_n = S_NOV;
            end
            PCPI_F3_QUANTIZE: begin
              quant_start = 1'b1;
              state_n = S_QUANT;
            end
            PCPI_F3_MEMCPY: begin
              dma_start = 1'b1;
              state_n = S_DMA;
            end
            default: begin
              pcpi_wait = 1'b0;  // truly unrecognized -- release the claim, let it trap/fall through
              state_n = S_IDLE;
            end
          endcase
        end
      end

      S_BASE: begin
        pcpi_wait = 1'b1;
        if (base_done) state_n = S_DONE;
      end

      S_NOV: begin
        pcpi_wait = 1'b1;
        if (nov_done) state_n = S_DONE;
      end

      S_QUANT: begin
        pcpi_wait = 1'b1;
        if (quant_done) state_n = S_DONE;
      end

      S_DMA: begin
        pcpi_wait = 1'b1;
        if (dma_done) state_n = S_DONE;
      end

      S_DONE: begin
        pcpi_ready = 1'b1;
        // scalar-result ops write back to the CPU register; SPM-writing
        // ops still signal ready (unblocking the core) but don't touch
        // the register file.
        pcpi_wr = is_base_scalar_op || is_nov_scalar_op || (funct3 == PCPI_F3_QUANTIZE);
        state_n = S_IDLE;
      end

      default: state_n = S_IDLE;
    endcase
  end

endmodule : pcpi_hdc_bridge
