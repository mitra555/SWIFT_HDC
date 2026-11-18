// =============================================================================
// nov_ctrl.sv  (NOVELTY EXTENSION)
//
// Decode + hardware-loop sequencer for the novel operations required by
// the reference Python notebook's encode_multigroup / train_eval, which
// the paper's hdcu_ctrl.sv cannot express (see signed_mac_unit.sv,
// sign_unit.sv, dot_search_unit.sv for why each primitive is needed).
//
// Reuses the paper's core idea (Section III-A: "hardware loops keep the
// required functional unit busy until HVSIZE elements are processed")
// for the same reason -- software should issue ONE instruction per
// feature / per prototype-update, not manage per-chunk loops itself.
//
//   NOV_BINDMAC(rd=X, rs1=lvl, rs2=pos, weight, clear_first)
//     -> loops chunks 0..num_chunks-1: X[c] = X[c] + weight*bind(lvl[c],pos[c])
//        (clear_first zeroes X on chunk 0 only, for the very first
//        feature of the very first group in a multi-group encode)
//
//   NOV_PROTO_UPDATE(rd=hvs[class], rs1=hv, weight=+-1)
//     -> same chunk loop, do_bind=0 (pos forced to 0), so hvs[class] +=
//        weight*hv chunk-by-chunk. Software issues this twice per
//        misclassified sample (once for the true label with weight=+1,
//        once for the predicted label with weight=-1).
//
//   NOV_SIGN(rd, rs1=X) -> loops chunks, y_bit[c] = MSB(X[c]), packs
//     result into a plain (bit-level) SPM region.
//
//   NOV_DOTSEARCH(rd, rs1=query hv, rs2=proto base, k_protos)
//     -> loops chunks per prototype x K prototypes (paper's Section
//        III-B f pattern), argmax instead of the paper's argmin.
//
//   NOV_NORMALIZE(rd, rs1=hvs[class])
//     -> L2-normalize finalize step for the "binary + int32 AM" mode:
//        `n = norm(best_h[c]); if n>0: best_h[c] /= n`. Three phases:
//        (1) accumulate sum-of-squares over all chunks (norm_sq_accum_unit),
//        (2) one-shot integer sqrt of the total (isqrt_seq_unit),
//        (3) if norm>0, sequentially divide every lane of every chunk
//            by norm (fixed_div_seq_unit, one shared instance) and
//            write the Q1.(ACC_W-1) fixed-point result to rd; if
//            norm==0, copy rs1 to rd unchanged (matches `if n>0` exactly).
//
// Wide accumulator words (X / hvs[]) are carried as packed
// [SIMD*NOV_ACC_W-1:0] vectors throughout, matching signed_mac_unit's
// port convention.
// =============================================================================
import hdcu_pkg::*;

module nov_ctrl (
  input  logic         clk,
  input  logic         rst_n,

  input  logic         req_valid,
  input  nov_instr_t   req,
  input  logic         req_clear_first,   // extra control bit: zero accumulator on chunk 0 (NOV_BINDMAC only)

  output logic         nov_busy,
  output logic         nov_done,

  // table-free encoding (NOV_BINDGEN): generator strobe, chunk and operands
  output logic                  gen_mode,
  output logic                  gen_strobe,
  output logic [HVSIZE_W-1:0]   gen_chunk,
  output logic [7:0]            gen_q,
  output logic [15:0]           gen_f,

  // runtime HV-size CSR (would alias the baseline HDCU's CSR_HVSIZE in a
  // full SoC integration; kept local here for clarity of the novel datapath)
  input  logic [HVSIZE_W-1:0] csr_hvsize,

  // ---- plain (bit) SPM bus: lvl / pos / query / sign-output live here ----
  output logic                  bit_re,
  output logic [SPM_ADDR_W-1:0] bit_raddr_a,   // lvl / hv / query
  output logic [SPM_ADDR_W-1:0] bit_raddr_b,   // pos
  input  logic [SIMD-1:0]       bit_rdata_a,
  input  logic [SIMD-1:0]       bit_rdata_b,
  output logic                  bit_we,
  output logic [SPM_ADDR_W-1:0] bit_waddr,
  output logic [SIMD-1:0]       bit_wdata,

  // ---- wide (signed accumulator) SPM bus: X and hvs[] live here ----
  output logic                        wide_re,
  output logic [SPM_ADDR_W-1:0]       wide_raddr,
  input  logic [SIMD*NOV_ACC_W-1:0]   wide_rdata,
  output logic                        wide_we,
  output logic [SPM_ADDR_W-1:0]       wide_waddr,
  output logic [SIMD*NOV_ACC_W-1:0]   wide_wdata,

  // ---- functional-unit control ----
  output logic                           mac_clear, mac_do_bind,
  output logic signed [NOV_WEIGHT_W-1:0] mac_weight,
  input  logic [SIMD*NOV_ACC_W-1:0]      mac_y,

  input  logic [SIMD-1:0]                sign_y,

  output logic                        srch_start, srch_chunk_valid, srch_new_proto,
  input  logic                        srch_busy, srch_done,
  input  logic [15:0]                 srch_best_idx,

  // ---- L2-normalize datapath ----
  output logic                        normsq_clear, normsq_valid,
  output logic [$clog2(SIMD)-1:0]     normsq_lane,
  input  logic [NOV_NORMSQ_W-1:0]     normsq_acc,

  output logic                        isqrt_start,
  input  logic                        isqrt_busy, isqrt_done,
  input  logic [NOV_NORM_W-1:0]       isqrt_root,

  output logic                        div_start,
  output logic signed [NOV_ACC_W-1:0] div_lane,
  output logic [NOV_NORM_W-1:0]       div_norm,
  input  logic                        div_busy, div_done,
  input  logic signed [NOV_ACC_W-1:0] div_result
);

  localparam int CHUNK_W = HVSIZE_W;
  logic [CHUNK_W-1:0] num_chunks, chunk_idx, proto_idx_r;
  assign num_chunks = (csr_hvsize + SIMD - 1) >> $clog2(SIMD);

  typedef enum logic [3:0] {
    S_IDLE, S_MAC_LOOP, S_SIGN_LOOP, S_SEARCH_LOOP,
    S_NORMSQ_PRIME, S_NORMSQ_LOOP, S_ISQRT_START, S_ISQRT_WAIT,
    S_DIV_ISSUE, S_DIV_WAIT, S_DIV_WRITEBACK,
    S_COPY_LOOP, S_DONE
  } state_e;
  state_e state_r, state_n;

  nov_op_e op_r;
  logic [SPM_ADDR_W-1:0] rd_r, rs1_r, rs2_r;
  logic signed [NOV_WEIGHT_W-1:0] weight_r;
  logic [15:0] kprotos_r;
  logic clear_first_r;

  // SYNCHRONOUS-SRAM ADAPTATION (sky130 wrappers): the read-modify-write loops
  // (MAC / SIGN / SEARCH) take two cycles per chunk -- address phase then data
  // phase -- because the bit/wide SPM reads are now registered, not same-cycle.
  // Reads are issued in the address phase only. NORMALIZE: S_NORMSQ_PRIME reads a
  // chunk before its lane loop; the divide loop reads each chunk one state ahead
  // (S_ISQRT_WAIT / S_DIV_WRITEBACK) and latches it in its first S_DIV_ISSUE; the
  // norm == 0 copy loop is two-phase.
  logic rd_phase_r;

  // L2-normalize bookkeeping
  logic [NOV_NORM_W-1:0]         norm_r;          // captured sqrt(sum of squares)
  logic [$clog2(SIMD+1)-1:0]     lane_idx_r;      // which lane within the current chunk we're dividing
  logic [SIMD*NOV_ACC_W-1:0]     div_out_r;       // accumulates this chunk's divided lanes before writeback
  logic [SIMD*NOV_ACC_W-1:0]     chunk_word_r;    // this chunk's original wide word, latched for the lane loop

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_r <= S_IDLE; chunk_idx <= '0; proto_idx_r <= '0; lane_idx_r <= '0; rd_phase_r <= 1'b0;
    end else begin
      state_r <= state_n;

      if (req_valid && state_r == S_IDLE) begin
        op_r <= req.op; rd_r <= req.rd; rs1_r <= req.rs1; rs2_r <= req.rs2;
        weight_r <= req.weight; kprotos_r <= req.k_protos; clear_first_r <= req_clear_first;
      end

      case (state_r)
        // two-phase (sync SRAM): toggle phase, advance chunk only after data phase
        S_MAC_LOOP, S_SIGN_LOOP, S_SEARCH_LOOP, S_COPY_LOOP: begin
          rd_phase_r <= ~rd_phase_r;
          if (rd_phase_r)
            chunk_idx <= (chunk_idx == num_chunks-1) ? '0 : chunk_idx + 1'b1;
        end
        S_DIV_WRITEBACK:   // one chunk per writeback
          chunk_idx <= (chunk_idx == num_chunks-1) ? '0 : chunk_idx + 1'b1;
        S_NORMSQ_LOOP:   // serialized sum of squares: SIMD lanes per chunk
          if (lane_idx_r == SIMD-1) chunk_idx <= (chunk_idx == num_chunks-1) ? '0 : chunk_idx + 1'b1;
        S_IDLE: begin chunk_idx <= '0; rd_phase_r <= 1'b0; end
        default: ;
      endcase

      if (state_r == S_SEARCH_LOOP && rd_phase_r && chunk_idx == num_chunks-1)
        proto_idx_r <= proto_idx_r + 1'b1;
      if (state_r == S_IDLE)
        proto_idx_r <= '0;

      // latch the chunk's raw wide word once, at the start of its lane loop
      if (state_r == S_ISQRT_WAIT && isqrt_done)
        norm_r <= isqrt_root;
      // Sync SRAM: the chunk's read is issued in the cycle before its first
      // S_DIV_ISSUE (S_ISQRT_WAIT for chunk 0, S_DIV_WRITEBACK for the rest), so the
      // data is valid exactly in that first S_DIV_ISSUE; latch it there.
      if (state_r == S_DIV_ISSUE && lane_idx_r == 0)
        chunk_word_r <= wide_rdata;

      // lane index sequencing: serialized sum of squares, then the divide loop
      if (state_r == S_NORMSQ_LOOP)
        lane_idx_r <= (lane_idx_r == SIMD-1) ? '0 : lane_idx_r + 1'b1;
      else if (state_r == S_DIV_ISSUE)
        lane_idx_r <= lane_idx_r; // held while waiting for div_start to register
      else if (state_r == S_DIV_WAIT && div_done) begin
        div_out_r[lane_idx_r*NOV_ACC_W +: NOV_ACC_W] <= div_result;
        lane_idx_r <= lane_idx_r + 1'b1;
      end else if (state_r == S_DIV_WRITEBACK) begin
        lane_idx_r <= '0;
      end else if (state_r == S_ISQRT_WAIT && isqrt_done) begin
        lane_idx_r <= '0;
      end
    end
  end

  assign gen_mode   = (op_r == NOV_BINDGEN);
  assign gen_strobe = (state_r == S_MAC_LOOP) && !rd_phase_r && (op_r == NOV_BINDGEN);
  assign gen_chunk  = chunk_idx;
  assign gen_q      = rs1_r[7:0];
  assign gen_f      = 16'(rs2_r);

  always_comb begin
    state_n = state_r;
    nov_busy = 1'b0; nov_done = 1'b0;

    bit_re = 1'b0; bit_we = 1'b0; bit_raddr_a = '0; bit_raddr_b = '0; bit_waddr = '0; bit_wdata = '0;
    wide_re = 1'b0; wide_we = 1'b0; wide_raddr = '0; wide_waddr = '0; wide_wdata = '0;

    mac_clear = 1'b0; mac_do_bind = 1'b0; mac_weight = weight_r;
    srch_start = 1'b0; srch_chunk_valid = 1'b0; srch_new_proto = 1'b0;

    normsq_clear = 1'b0; normsq_valid = 1'b0; normsq_lane = lane_idx_r[$clog2(SIMD)-1:0];
    isqrt_start  = 1'b0;
    div_start    = 1'b0; div_lane = '0; div_norm = norm_r;

    unique case (state_r)

      S_IDLE: begin
        if (req_valid) begin
          unique case (req.op)
            NOV_BINDMAC, NOV_PROTO_UPDATE, NOV_BINDGEN: state_n = S_MAC_LOOP;
            NOV_SIGN:                      state_n = S_SIGN_LOOP;
            NOV_DOTSEARCH:                 state_n = S_SEARCH_LOOP;
            NOV_NORMALIZE:                 state_n = S_NORMSQ_PRIME;
            default:                        state_n = S_IDLE;
          endcase
        end
      end

      S_MAC_LOOP: begin
        nov_busy = 1'b1;
        bit_re      = !rd_phase_r && (op_r != NOV_BINDGEN);  // read in the address phase only (BINDGEN: generated)
        bit_raddr_a = rs1_r + chunk_idx;   // lvl (encode) or hv (update)
        bit_raddr_b = rs2_r + chunk_idx;   // pos (encode only; don't-care for update)
        wide_re     = !rd_phase_r;
        wide_raddr  = rd_r + chunk_idx;    // X or hvs[class] accumulator, read-modify-write

        mac_do_bind = (op_r == NOV_BINDMAC) || (op_r == NOV_BINDGEN);
        mac_clear   = clear_first_r && rd_phase_r;   // clears THIS chunk's word; applies across every chunk
                                        // of this instruction's sweep when clear_first_r is set,
                                        // not just chunk 0 -- the whole shared accumulator (all
                                        // HVSIZE/SIMD chunks of it) must be zeroed by the very
                                        // first contribution, matching Python's `X=np.zeros(...)`
                                        // initializing the ENTIRE vector before any group adds to it.

        wide_we    = rd_phase_r;           // write only when read data is valid
        wide_waddr = rd_r + chunk_idx;
        wide_wdata = mac_y;

        if (chunk_idx == num_chunks-1 && rd_phase_r) state_n = S_DONE;
      end

      S_SIGN_LOOP: begin
        nov_busy   = 1'b1;
        wide_re    = !rd_phase_r;
        wide_raddr = rs1_r + chunk_idx;    // X
        bit_we     = rd_phase_r;           // write only when read data is valid
        bit_waddr  = rd_r + chunk_idx;     // packed sign bits out
        bit_wdata  = sign_y;

        if (chunk_idx == num_chunks-1 && rd_phase_r) state_n = S_DONE;
      end

      S_SEARCH_LOOP: begin
        nov_busy    = 1'b1;
        bit_re      = !rd_phase_r;
        bit_raddr_a = rs1_r + chunk_idx;                          // query hv (fixed base)
        wide_re     = !rd_phase_r;
        wide_raddr  = rs2_r + proto_idx_r * num_chunks + chunk_idx; // proto[k] chunk

        srch_start       = (proto_idx_r == 0) && (chunk_idx == 0) && rd_phase_r;
        srch_chunk_valid = rd_phase_r;     // feed a chunk only when read data is valid
        srch_new_proto   = (chunk_idx == 0) && rd_phase_r;

        if (srch_done) state_n = S_DONE;
      end

      // ---- L2-normalize: phase 1, sum of squares over all chunks ----
      // Sync-SRAM settle: present this chunk's address one cycle before the
      // lane loop squares it, so lane 0 sees valid read data.
      S_NORMSQ_PRIME: begin
        nov_busy   = 1'b1;
        wide_re    = 1'b1;
        wide_raddr = rs1_r + chunk_idx;
        state_n    = S_NORMSQ_LOOP;
      end

      S_NORMSQ_LOOP: begin
        nov_busy     = 1'b1;
        wide_re      = 1'b1;
        wide_raddr   = rs1_r + chunk_idx;
        normsq_valid = 1'b1;
        normsq_clear = (chunk_idx == 0) && (lane_idx_r == 0);

        if (lane_idx_r == SIMD-1) begin
          if (chunk_idx == num_chunks-1) state_n = S_ISQRT_START;
          else                            state_n = S_NORMSQ_PRIME;
        end
      end

      // ---- phase 2: one-shot integer sqrt of the total ----
      S_ISQRT_START: begin
        nov_busy    = 1'b1;
        isqrt_start = 1'b1;
        state_n     = S_ISQRT_WAIT;
      end

      S_ISQRT_WAIT: begin
        nov_busy = 1'b1;
        wide_re    = 1'b1;
        wide_raddr = rs1_r;   // pre-fetch chunk 0 for the upcoming divide/copy loop
        if (isqrt_done) begin
          if (isqrt_root == '0) state_n = S_COPY_LOOP;
          else                  state_n = S_DIV_ISSUE;
        end
      end

      // ---- phase 3a: norm > 0, divide every lane of every chunk ----
      S_DIV_ISSUE: begin
        nov_busy = 1'b1;
        div_start = 1'b1;
        div_lane  = (lane_idx_r == 0) ? wide_rdata[0 +: NOV_ACC_W]
                                      : chunk_word_r[lane_idx_r*NOV_ACC_W +: NOV_ACC_W];
        state_n   = S_DIV_WAIT;
      end

      S_DIV_WAIT: begin
        nov_busy = 1'b1;
        if (div_done) begin
          if (lane_idx_r == SIMD-1) state_n = S_DIV_WRITEBACK;
          else                      state_n = S_DIV_ISSUE;
        end
      end

      S_DIV_WRITEBACK: begin
        nov_busy   = 1'b1;
        wide_we    = 1'b1;
        wide_waddr = rd_r + chunk_idx;
        wide_wdata = div_out_r;

        if (chunk_idx == num_chunks-1) begin
          state_n = S_DONE;
        end else begin
          wide_re    = 1'b1;
          wide_raddr = rs1_r + chunk_idx + 1'b1;  // pre-fetch next chunk
          state_n    = S_DIV_ISSUE;
        end
      end

      // ---- phase 3b: norm == 0, leave the prototype unchanged ----
      S_COPY_LOOP: begin                   // two-phase: read, then write the same chunk
        nov_busy   = 1'b1;
        wide_re    = !rd_phase_r;
        wide_raddr = rs1_r + chunk_idx;
        wide_we    = rd_phase_r;
        wide_waddr = rd_r + chunk_idx;
        wide_wdata = wide_rdata;

        if (chunk_idx == num_chunks-1 && rd_phase_r) state_n = S_DONE;
      end

      S_DONE: begin
        nov_done = 1'b1;
        state_n  = S_IDLE;
      end

      default: state_n = S_IDLE;
    endcase
  end

endmodule : nov_ctrl
