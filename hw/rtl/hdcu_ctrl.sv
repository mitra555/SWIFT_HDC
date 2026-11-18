// =============================================================================
// hdcu_ctrl.sv
//
// Decode + hardware-loop sequencer for the HDCU. Implements the
// "hardware loops keep the required functional unit busy until
// HVSIZE elements are processed" behaviour described in Section III-A,
// so software never has to re-issue the same instruction in a loop.
// Also implements the two runtime CSRs from Table II: HVSIZE and
// PROT_COUNT.
//
// Only one functional unit is active at a time (matches the single
// shared SPMI datapath in Fig. 2); FUs disabled at synthesis time
// (EN_* = 0 in hdcu_pkg) fall back to asserting `unsupported_op` so
// the host can fall back to software execution.
// =============================================================================
import hdcu_pkg::*;

module hdcu_ctrl (
  input  logic         clk,
  input  logic         rst_n,

  // instruction handshake from decode stage
  input  logic         req_valid,
  input  hdcu_instr_t  req,
  output logic         hdcu_busy,
  output logic         hdcu_done,
  output logic         unsupported_op,

  // runtime CSRs (Table II)
  output logic [HVSIZE_W-1:0]  csr_hvsize,
  output logic [PROTCNT_W-1:0] csr_protcnt,

  // ---- SPM shared read/write interface ----
  output logic                     spm_re,
  output logic [SPM_ADDR_W-1:0]    spm_raddr_a,   // rs1-derived address
  output logic [SPM_ADDR_W-1:0]    spm_raddr_b,   // rs2-derived address
  input  logic [SIMD-1:0]          spm_rdata_a,
  input  logic [SIMD-1:0]          spm_rdata_b,
  output logic                     spm_we,
  output logic [SPM_ADDR_W-1:0]    spm_waddr,
  output logic [SIMD-1:0]          spm_wdata,

  // ---- functional unit datapaths ----
  // binding
  output logic [SIMD-1:0]          bind_a, bind_b,
  input  logic [SIMD-1:0]          bind_y,
  // bundling
  output logic [SIMD/M_BITS*M_BITS-1:0] bund_a_widened,
  output logic [SIMD-1:0]               bund_b_bits,
  input  logic [SIMD/M_BITS*M_BITS-1:0] bund_y_widened,
  // clipping
  output logic [SIMD/M_BITS*M_BITS-1:0] clip_a_widened,
  output logic [M_BITS-1:0]             clip_threshold,
  output logic [SIMD/M_BITS-1:0]        clip_tie_rand,
  input  logic [SIMD/M_BITS-1:0]        clip_y_bits,
  // permutation (buf_in is driven directly by a register in hdcu_top, not here)
  output logic [SIMD-1:0]          perm_chunk_in,
  output logic [$clog2(SIMD+1)-1:0] perm_s,
  input  logic [SIMD-1:0]          perm_chunk_out,
  input  logic [SIMD-1:0]          perm_buf_out,
  output logic                     perm_first,    // chunk 0: carry-in = last chunk (wrap-around)
  output logic                     perm_buf_en,   // SYNC-SRAM: advance perm_buf_r only in the data phase
  // similarity
  output logic                     sim_clear,
  output logic                     sim_valid,
  output logic [SIMD-1:0]          sim_a, sim_b,
  input  logic [POPCNT_ACC_W-1:0]  sim_dist,
  // search
  output logic                     srch_start,
  output logic                     srch_chunk_valid,
  output logic                     srch_new_proto,
  output logic [SIMD-1:0]          srch_query, srch_proto,
  input  logic                     srch_busy,
  input  logic                     srch_done,
  input  logic [PROTCNT_W-1:0]     srch_best_idx
);

  // -------------------------------------------------------------------
  // CSRs
  // -------------------------------------------------------------------
  logic [HVSIZE_W-1:0]  hvsize_r;
  logic [PROTCNT_W-1:0] protcnt_r;
  assign csr_hvsize  = hvsize_r;
  assign csr_protcnt = protcnt_r;

  // -------------------------------------------------------------------
  // Chunk-loop bookkeeping: num_chunks = ceil(HVSIZE / SIMD)
  // -------------------------------------------------------------------
  localparam int CHUNK_CNT_W = HVSIZE_W;
  logic [CHUNK_CNT_W-1:0] num_chunks, chunk_idx;
  logic [CHUNK_CNT_W-1:0] num_protos_chunks; // chunks per prototype (search)

  assign num_chunks = (hvsize_r + SIMD - 1) >> $clog2(SIMD);

  // Bundle/clip operate on the widened accumulator (M_BITS per HV bit), which
  // spans M_BITS times as many SIMD words as the binary vector. Each widened
  // word holds LANES counters, i.e. one LANES-bit slice of a binary word.
  localparam int LANES  = SIMD / M_BITS;
  localparam int MSEL_W = $clog2(M_BITS);

  // Instruction registers (declared before use: iverilog 14 and slang reject the
  // forward reference the original RTL had here -- op_r is read by is_widened_op below).
  hdc_op_e op_r;
  logic [SPM_ADDR_W-1:0] rd_r, rs1_r, rs2_r;
  logic [31:0]           imm_r;
  logic [PROTCNT_W-1:0]  proto_idx_r;
  logic                  first_of_bundle_seq; // controller doesn't force this; SW clears dest per Pseudocode 1

  logic is_widened_op;
  logic [CHUNK_CNT_W-1:0] loop_len;
  logic [MSEL_W-1:0]      slice_idx;      // which LANES-bit slice of the binary word
  logic [CHUNK_CNT_W-1:0] bin_chunk_idx;  // which binary word
  assign is_widened_op = (op_r == HDC_BUNDLE) || (op_r == HDC_CLIP);
  assign loop_len      = is_widened_op ? (num_chunks << MSEL_W) : num_chunks;
  assign slice_idx     = chunk_idx[MSEL_W-1:0];
  assign bin_chunk_idx = chunk_idx >> MSEL_W;
  logic [SIMD-1:0] clip_word_r;           // clip output word being assembled

  typedef enum logic [2:0] {S_IDLE, S_DECODE, S_LOOP, S_SEARCH_LOOP, S_WRBACK, S_DONE} state_e;
  state_e state_r, state_n;

  // SYNCHRONOUS-SRAM ADAPTATION (sky130 macros): each chunk takes two cycles.
  //   rd_phase_r = 0  address phase  -> drive raddr, SRAM latches it this edge
  //   rd_phase_r = 1  data    phase  -> spm_rdata valid, compute + write + advance
  // This is the "one extra pipeline stage per controller loop" from the
  // synthesis README; combinational-read RTL did both halves in one cycle.
  logic rd_phase_r;

  // simple LFSR for clipping tie-break randomness
  logic [SIMD/M_BITS-1:0] lfsr_r;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) lfsr_r <= {(SIMD/M_BITS){1'b1}};
    else        lfsr_r <= {lfsr_r[SIMD/M_BITS-2:0], lfsr_r[SIMD/M_BITS-1] ^ lfsr_r[0]};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_r     <= S_IDLE;
      hvsize_r    <= '0;
      protcnt_r   <= '0;
      chunk_idx   <= '0;
      proto_idx_r <= '0;
      rd_phase_r  <= 1'b0;
    end else begin
      state_r <= state_n;

      if (req_valid && state_r == S_IDLE) begin
        op_r  <= req.op;
        rd_r  <= req.rd;
        rs1_r <= req.rs1;
        rs2_r <= req.rs2;
        imm_r <= req.imm;

        if (req.op == HDC_CSR_HVSZ) hvsize_r  <= req.imm[HVSIZE_W-1:0];
        if (req.op == HDC_CSR_PROT) protcnt_r <= req.imm[PROTCNT_W-1:0];
      end

      case (state_r)
        S_LOOP: begin
          rd_phase_r <= ~rd_phase_r;                 // toggle address/data phase
          if (rd_phase_r) begin                      // advance only after data phase
            if (chunk_idx == loop_len-1) chunk_idx <= '0;
            else                          chunk_idx <= chunk_idx + 1'b1;
            if (op_r == HDC_CLIP) clip_word_r[slice_idx*LANES +: LANES] <= clip_y_bits;
          end
        end
        S_SEARCH_LOOP: begin
          rd_phase_r <= ~rd_phase_r;
          if (rd_phase_r) begin
            if (chunk_idx == num_chunks-1) chunk_idx <= '0;
            else                            chunk_idx <= chunk_idx + 1'b1;
          end
        end
        S_IDLE: begin chunk_idx <= '0; rd_phase_r <= 1'b0; end
        default: ;
      endcase

      if (state_r == S_SEARCH_LOOP && rd_phase_r && chunk_idx == num_chunks-1)
        proto_idx_r <= proto_idx_r + 1'b1;
      if (state_r == S_IDLE)
        proto_idx_r <= '0;
    end
  end

  // -------------------------------------------------------------------
  // Next-state / output logic
  // -------------------------------------------------------------------
  always_comb begin
    state_n         = state_r;
    hdcu_busy       = 1'b0;
    hdcu_done       = 1'b0;
    unsupported_op  = 1'b0;

    spm_re = 1'b0; spm_we = 1'b0;
    spm_raddr_a = '0; spm_raddr_b = '0; spm_waddr = '0; spm_wdata = '0;

    bind_a = spm_rdata_a; bind_b = spm_rdata_b;
    bund_a_widened = '0; bund_b_bits = spm_rdata_b;
    clip_a_widened = '0; clip_threshold = imm_r[M_BITS-1:0]; clip_tie_rand = lfsr_r;
    perm_chunk_in = spm_rdata_a; perm_s = imm_r[$clog2(SIMD+1)-1:0]; perm_first = 1'b0;
    perm_buf_en = (state_r == S_LOOP) && (op_r == HDC_PERM) && rd_phase_r;
    sim_clear = 1'b0; sim_valid = 1'b0; sim_a = spm_rdata_a; sim_b = spm_rdata_b;
    srch_start = 1'b0; srch_chunk_valid = 1'b0; srch_new_proto = 1'b0;
    srch_query = spm_rdata_a; srch_proto = spm_rdata_b;

    unique case (state_r)

      S_IDLE: begin
        if (req_valid) begin
          case (req.op)
            HDC_BUNDLE, HDC_BIND, HDC_PERM, HDC_SIM, HDC_CLIP, HDC_MEMLD, HDC_MEMSTR:
              state_n = S_LOOP;
            HDC_SEARCH:
              state_n = S_SEARCH_LOOP;
            HDC_CSR_HVSZ, HDC_CSR_PROT:
              state_n = S_DONE;
            default:
              state_n = S_IDLE;
          endcase
        end
      end

      S_LOOP: begin
        hdcu_busy = 1'b1;
        spm_re      = !rd_phase_r;   // read in the address phase only; data stays valid
                                     // through the data phase (no same-address read/write)
        spm_raddr_a = rs1_r + (chunk_idx << $clog2(SIMD));
        spm_raddr_b = rs2_r + (chunk_idx << $clog2(SIMD));
        spm_waddr   = rd_r  + (chunk_idx << $clog2(SIMD));

        unique case (op_r)
          HDC_BIND: begin
            if (!EN_BIND) unsupported_op = 1'b1;
            spm_we   = 1'b1;
            spm_wdata = bind_y;
          end
          HDC_BUNDLE: begin
            // widened word chunk_idx (rs1/rd) += slice slice_idx of binary word bin_chunk_idx (rs2)
            if (!EN_BUND) unsupported_op = 1'b1;
            spm_raddr_b    = rs2_r + (bin_chunk_idx << $clog2(SIMD));
            bund_a_widened = spm_rdata_a[SIMD/M_BITS*M_BITS-1:0];
            bund_b_bits    = spm_rdata_b >> (slice_idx * LANES);
            spm_we   = 1'b1;
            spm_wdata = {{(SIMD-(SIMD/M_BITS*M_BITS)){1'b0}}, bund_y_widened};
          end
          HDC_CLIP: begin
            // widened word chunk_idx (rs1) -> slice slice_idx of binary word bin_chunk_idx (rd);
            // the word is written once its last slice is ready
            if (!EN_CLIP) unsupported_op = 1'b1;
            clip_a_widened = spm_rdata_a[SIMD/M_BITS*M_BITS-1:0];
            if (slice_idx == MSEL_W'(M_BITS-1)) begin
              spm_we    = 1'b1;
              spm_waddr = rd_r + (bin_chunk_idx << $clog2(SIMD));
              spm_wdata = clip_word_r;
              spm_wdata[slice_idx*LANES +: LANES] = clip_y_bits;
            end
          end
          HDC_PERM: begin
            if (!EN_PERM) unsupported_op = 1'b1;
            // wrap-around: chunk 0's carry-in is the LAST chunk's low bits,
            // read through the otherwise-unused rs2 port
            if (chunk_idx == 0) begin
              perm_first  = 1'b1;
              spm_raddr_b = rs1_r + ((num_chunks - 1'b1) << $clog2(SIMD));
            end
            // NOTE: simplified single-pass rotation per SIMD chunk shown here;
            // full wrap-around carry handling across chunk boundaries (Fig.4)
            // requires the buffer register threaded chunk-to-chunk, wired at
            // the hdcu_top level via perm_buf_in <= perm_buf_out (see hdcu_top).
            spm_we    = 1'b1;
            spm_wdata = perm_chunk_out;
          end
          HDC_SIM: begin
            if (!EN_SIM) unsupported_op = 1'b1;
            sim_valid = rd_phase_r;                 // accumulate only when operands valid
            sim_clear = (chunk_idx == 0) && rd_phase_r;
            // result is written to SPM in S_DONE: sim_dist is a register, so
            // during the last chunk it does not yet include that chunk's popcount
          end
          HDC_MEMLD, HDC_MEMSTR: begin
            // SPMI: size in imm_r (bytes); simple pass-through per chunk
            spm_we    = (op_r == HDC_MEMSTR) ? 1'b0 : 1'b1; // handled by top-level SPMI mux
            spm_wdata = spm_rdata_a;
          end
          default: unsupported_op = 1'b1;
        endcase

        // In the address phase the SRAM read data is not yet valid, so suppress
        // every write; writes commit only in the data phase.
        if (!rd_phase_r) spm_we = 1'b0;

        if (chunk_idx == loop_len-1 && rd_phase_r)
          state_n = S_DONE;
      end

      S_SEARCH_LOOP: begin
        hdcu_busy = 1'b1;
        if (!EN_SRCH) unsupported_op = 1'b1;
        spm_re      = !rd_phase_r;
        spm_raddr_a = rs1_r + (chunk_idx << $clog2(SIMD));                 // query (fixed base)
        spm_raddr_b = rs2_r + (proto_idx_r * hvsize_r) + (chunk_idx << $clog2(SIMD)); // proto[k]

        srch_start       = (proto_idx_r == 0) && (chunk_idx == 0) && rd_phase_r;
        srch_chunk_valid = rd_phase_r;              // feed a chunk only when proto data valid
        srch_new_proto   = (chunk_idx == 0) && rd_phase_r;

        // best_idx is updated on the same edge that ends this cycle, so the
        // result is written to SPM in S_DONE (writing here stored the stale
        // index whenever the last prototype was the best match)
        if (srch_done) state_n = S_DONE;
      end

      S_DONE: begin
        hdcu_done = 1'b1;
        if (op_r == HDC_SIM) begin
          spm_we    = 1'b1;
          spm_waddr = rd_r;
          spm_wdata = {{(SIMD-POPCNT_ACC_W){1'b0}}, sim_dist};
        end
        if (op_r == HDC_SEARCH) begin
          spm_we    = 1'b1;
          spm_waddr = rd_r;
          spm_wdata = {{(SIMD-PROTCNT_W){1'b0}}, srch_best_idx};
        end
        state_n   = S_IDLE;
      end

      default: state_n = S_IDLE;
    endcase
  end

endmodule : hdcu_ctrl
