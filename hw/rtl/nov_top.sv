// =============================================================================
// nov_top.sv  (NOVELTY EXTENSION)
//
// Top-level wiring for the novel datapath: signed_mac_unit + sign_unit +
// dot_search_unit driven by nov_ctrl, backed by a plain bit-level SPM
// (for level/position/hv/query/sign-output) and a wide signed SPM (for
// the shared multi-group accumulator X and the perceptron prototype
// memory hvs[]). This sits alongside (not in place of) the paper-faithful
// hdcu_top.sv: a real SoC would have both share the same CSR_HVSIZE and
// SPMI, since they're really the same accelerator with an extended ISE.
// =============================================================================
import hdcu_pkg::*;

module nov_top #(
  parameter int BIT_SPM_DEPTH  = NOV_BIT_SPM_WORDS * SIMD,   // bits
  parameter int WIDE_SPM_WORDS = NOV_WIDE_SPM_WORDS
) (
  input  logic         clk,
  input  logic         rst_n,

  input  logic         req_valid,
  input  nov_instr_t   req,
  input  logic         req_clear_first,
  output logic         nov_busy,
  output logic         nov_done,

  input  logic [HVSIZE_W-1:0] csr_hvsize,
  // table-free encoding parameters (CSR GEN_SEEDL / GEN_SEEDP / GEN_STEP)
  input  logic [31:0]  csr_gen_seedl,
  input  logic [31:0]  csr_gen_seedp,
  input  logic [15:0]  csr_gen_step,

  // scalar result (RISC-V INTEGRATION addition): dot_search_unit's
  // argmax class index, exposed directly -- taps the existing internal
  // wire, no logic changes.
  output logic [15:0] search_result,

  // Host (CPU) access port, used only while the controller is idle (the CPU
  // is stalled by the PCPI bridge during every novelty instruction).
  //   bit SPM : host_addr = 32-bit word index
  //   wide SPM: host_addr = lane index = chunk*SIMD + lane (one NOV_ACC_W lane)
  input  logic        host_bit_re,
  input  logic        host_bit_we,
  input  logic        host_wide_re,
  input  logic        host_wide_we,
  input  logic [19:0] host_addr,
  input  logic [31:0] host_wdata,
  output logic [31:0] host_bit_rdata,
  output logic [31:0] host_wide_rdata
);

  // -------------------------------------------------------------------
  // Plain bit-level SPM (lvl / pos / hv / query / sign-output)
  // -------------------------------------------------------------------
  logic                  bit_re, bit_we;
  logic [SPM_ADDR_W-1:0] bit_raddr_a, bit_raddr_b, bit_waddr;
  logic [SIMD-1:0]       bit_rdata_a, bit_rdata_b, bit_wdata;
  logic                  ctl_bit_re, ctl_bit_we;
  logic [SPM_ADDR_W-1:0] ctl_bit_raddr_a, ctl_bit_raddr_b, ctl_bit_waddr;
  logic [SIMD-1:0]       ctl_bit_wdata;

  spm_bit_comb #(.DEPTH_BITS(BIT_SPM_DEPTH), .WORD_W(SIMD)) u_bit_spm_a (
    .clk(clk), .rst_n(rst_n),
    .re(bit_re), .raddr(bit_raddr_a), .rdata(bit_rdata_a),
    .we(bit_we), .waddr(bit_waddr),   .wdata(bit_wdata)
  );
  // second read view for rs2 (position vector); see hdcu_top.sv note on
  // needing a true dual-read port for a production version
  spm_bit_comb #(.DEPTH_BITS(BIT_SPM_DEPTH), .WORD_W(SIMD)) u_bit_spm_b (
    .clk(clk), .rst_n(rst_n),
    .re(bit_re), .raddr(bit_raddr_b), .rdata(bit_rdata_b),
    .we(bit_we), .waddr(bit_waddr),   .wdata(bit_wdata)
  );

  // -------------------------------------------------------------------
  // Wide signed SPM (shared accumulator X / prototype memory hvs[])
  // -------------------------------------------------------------------
  logic                        wide_re, wide_we;
  logic [SPM_ADDR_W-1:0]       wide_raddr, wide_waddr;
  logic [SIMD*NOV_ACC_W-1:0]   wide_rdata, wide_wdata;
  logic                        ctl_wide_re, ctl_wide_we;
  logic [SPM_ADDR_W-1:0]       ctl_wide_raddr, ctl_wide_waddr;
  logic [SIMD*NOV_ACC_W-1:0]   ctl_wide_wdata;

  // ---- host port mux (controller idle only) ----
  logic host_bit_act, host_wide_act;
  logic [SPM_ADDR_W-1:0] host_bit_chunk, host_wide_chunk;
  int host_bit_sub, host_lane;
  logic [SIMD-1:0]             host_bit_merged;
  logic [SIMD*NOV_ACC_W-1:0]   host_wide_merged;
  assign host_bit_act    = (host_bit_re  || host_bit_we)  && !nov_busy && !nov_done;
  assign host_wide_act   = (host_wide_re || host_wide_we) && !nov_busy && !nov_done;
  assign host_bit_chunk  = SPM_ADDR_W'(host_addr / (SIMD / 32));
  assign host_bit_sub    = host_addr % (SIMD / 32);
  assign host_wide_chunk = SPM_ADDR_W'(host_addr / SIMD);
  assign host_lane       = host_addr % SIMD;
  always_comb begin
    host_bit_merged = bit_rdata_a;
    host_bit_merged[host_bit_sub*32 +: 32] = host_wdata;
    host_wide_merged = wide_rdata;                         // read-modify-write of one lane
    host_wide_merged[host_lane*NOV_ACC_W +: NOV_ACC_W] = host_wdata[NOV_ACC_W-1:0];  // low lane bits
  end
  assign host_bit_rdata  = bit_rdata_a[host_bit_sub*32 +: 32];
  assign host_wide_rdata = 32'($signed(wide_rdata[host_lane*NOV_ACC_W +: NOV_ACC_W]));  // sign-extended

  assign bit_re      = host_bit_act ? host_bit_re     : ctl_bit_re;
  assign bit_raddr_a = host_bit_act ? host_bit_chunk  : ctl_bit_raddr_a;
  assign bit_raddr_b = ctl_bit_raddr_b;
  assign bit_we      = host_bit_act ? host_bit_we     : ctl_bit_we;
  assign bit_waddr   = host_bit_act ? host_bit_chunk  : ctl_bit_waddr;
  assign bit_wdata   = host_bit_act ? host_bit_merged : ctl_bit_wdata;
  assign wide_re     = host_wide_act ? host_wide_re     : ctl_wide_re;
  assign wide_raddr  = host_wide_act ? host_wide_chunk  : ctl_wide_raddr;
  assign wide_we     = host_wide_act ? host_wide_we     : ctl_wide_we;
  assign wide_waddr  = host_wide_act ? host_wide_chunk  : ctl_wide_waddr;
  assign wide_wdata  = host_wide_act ? host_wide_merged : ctl_wide_wdata;

  spm_wide #(.DEPTH_WORDS(WIDE_SPM_WORDS), .SIMD_W(SIMD), .ACC_W(NOV_ACC_W)) u_wide_spm (
    .clk(clk), .rst_n(rst_n),
    .re(wide_re), .raddr(wide_raddr), .rdata(wide_rdata),
    .we(wide_we), .waddr(wide_waddr), .wdata(wide_wdata)
  );

  // -------------------------------------------------------------------
  // Functional units
  // -------------------------------------------------------------------
  logic mac_clear, mac_do_bind;
  logic signed [NOV_WEIGHT_W-1:0] mac_weight;
  logic [SIMD*NOV_ACC_W-1:0]      mac_y;

  // table-free encoding: generate L_g[q] / P_gf chunk in the address cycle, register it,
  // and feed it to the MAC in the data cycle in place of the bit-SPM read data
  logic                gen_mode, gen_strobe;
  logic [HVSIZE_W-1:0] gen_chunk;
  logic [7:0]          gen_q;
  logic [15:0]         gen_f;
  logic [SIMD-1:0]     gen_l, gen_p, gen_l_r, gen_p_r;
  hv_gen_unit #(.SIMD_W(SIMD), .CW(HVSIZE_W)) u_gen (
    .chunk(gen_chunk), .num_chunks(HVSIZE_W'((csr_hvsize + SIMD - 1) >> $clog2(SIMD))),
    .q(gen_q), .f(gen_f), .seed_l(csr_gen_seedl), .seed_p(csr_gen_seedp), .step(csr_gen_step),
    .lvl_bits(gen_l), .pos_bits(gen_p)
  );
  always_ff @(posedge clk) if (gen_strobe) begin gen_l_r <= gen_l; gen_p_r <= gen_p; end

  signed_mac_unit #(.SIMD_W(SIMD), .ACC_W(NOV_ACC_W), .WGT_W(NOV_WEIGHT_W)) u_mac (
    .clear(mac_clear), .do_bind(mac_do_bind),
    .lvl_chunk(gen_mode ? gen_l_r : bit_rdata_a), .pos_chunk(gen_mode ? gen_p_r : bit_rdata_b), .weight(mac_weight),
    .acc_in(wide_rdata), .acc_out(mac_y)
  );

  logic [SIMD-1:0] sign_y;
  sign_unit #(.SIMD_W(SIMD), .ACC_W(NOV_ACC_W)) u_sign (
    .acc_in(wide_rdata), .y_bits(sign_y)
  );

  logic srch_start, srch_valid, srch_new_proto, srch_busy, srch_done;
  logic [15:0] srch_best_idx;
  logic signed [NOV_DIST_W-1:0] srch_best_dot;

  dot_search_unit #(.SIMD_W(SIMD), .ACC_W(NOV_ACC_W), .DIST_W(NOV_DIST_W), .PROT_W(16)) u_dsrch (
    .clk(clk), .rst_n(rst_n), .start(srch_start), .k_prototypes(req.k_protos),
    .chunk_valid(srch_valid), .new_prototype(srch_new_proto),
    .query_bits(bit_rdata_a), .proto_word(wide_rdata),
    .busy(srch_busy), .done(srch_done), .best_idx(srch_best_idx), .best_dot(srch_best_dot)
  );

  logic normsq_clear, normsq_valid;
  logic [$clog2(SIMD)-1:0] normsq_lane;
  logic [NOV_NORMSQ_W-1:0] normsq_acc;
  norm_sq_accum_unit #(.SIMD_W(SIMD), .ACC_W(NOV_ACC_W), .NORMSQ_W(NOV_NORMSQ_W)) u_normsq (
    .clk(clk), .rst_n(rst_n), .clear(normsq_clear), .valid(normsq_valid),
    .proto_word(wide_rdata), .lane(normsq_lane), .normsq_acc(normsq_acc)
  );

  logic isqrt_start, isqrt_busy, isqrt_done;
  logic [NOV_NORM_W-1:0] isqrt_root;
  isqrt_seq_unit #(.NORMSQ_W(NOV_NORMSQ_W), .ROOT_W(NOV_NORM_W)) u_isqrt (
    .clk(clk), .rst_n(rst_n), .start(isqrt_start), .value(normsq_acc),
    .busy(isqrt_busy), .done(isqrt_done), .root(isqrt_root)
  );

  logic div_start, div_busy, div_done;
  logic signed [NOV_ACC_W-1:0] div_lane, div_result;
  logic [NOV_NORM_W-1:0] div_norm;
  fixed_div_seq_unit #(.ACC_W(NOV_ACC_W), .NORM_W(NOV_NORM_W), .QFRAC(NOV_QFRAC)) u_div (
    .clk(clk), .rst_n(rst_n), .start(div_start), .proto_lane(div_lane), .norm(div_norm),
    .busy(div_busy), .done(div_done), .result(div_result)
  );

  // -------------------------------------------------------------------
  // Controller
  // -------------------------------------------------------------------
  nov_ctrl u_ctrl (
    .clk(clk), .rst_n(rst_n),
    .req_valid(req_valid), .req(req), .req_clear_first(req_clear_first),
    .nov_busy(nov_busy), .nov_done(nov_done),
    .gen_mode(gen_mode), .gen_strobe(gen_strobe), .gen_chunk(gen_chunk), .gen_q(gen_q), .gen_f(gen_f),
    .csr_hvsize(csr_hvsize),

    .bit_re(ctl_bit_re), .bit_raddr_a(ctl_bit_raddr_a), .bit_raddr_b(ctl_bit_raddr_b),
    .bit_rdata_a(bit_rdata_a), .bit_rdata_b(bit_rdata_b),
    .bit_we(ctl_bit_we), .bit_waddr(ctl_bit_waddr), .bit_wdata(ctl_bit_wdata),

    .wide_re(ctl_wide_re), .wide_raddr(ctl_wide_raddr), .wide_rdata(wide_rdata),
    .wide_we(ctl_wide_we), .wide_waddr(ctl_wide_waddr), .wide_wdata(ctl_wide_wdata),

    .mac_clear(mac_clear), .mac_do_bind(mac_do_bind), .mac_weight(mac_weight), .mac_y(mac_y),
    .sign_y(sign_y),
    .srch_start(srch_start), .srch_chunk_valid(srch_valid), .srch_new_proto(srch_new_proto),
    .srch_busy(srch_busy), .srch_done(srch_done), .srch_best_idx(srch_best_idx),

    .normsq_clear(normsq_clear), .normsq_valid(normsq_valid), .normsq_lane(normsq_lane), .normsq_acc(normsq_acc),
    .isqrt_start(isqrt_start), .isqrt_busy(isqrt_busy), .isqrt_done(isqrt_done), .isqrt_root(isqrt_root),
    .div_start(div_start), .div_lane(div_lane), .div_norm(div_norm),
    .div_busy(div_busy), .div_done(div_done), .div_result(div_result)
  );

  assign search_result = srch_best_idx;

endmodule : nov_top
