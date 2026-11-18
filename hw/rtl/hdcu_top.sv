// =============================================================================
// hdcu_top.sv
//
// Top-level Hyperdimensional Coprocessor Unit, integrated into the
// execution stage of a RISC-V core (Fig. 1). Wires the controller
// (hdcu_ctrl), the six functional units (Fig. 2) and NUM_SPM scratchpad
// memory banks together. Presents a simple request/valid handshake to
// the decode stage, corresponding to the custom ISE in Table I.
// =============================================================================
import hdcu_pkg::*;

module hdcu_top (
  input  logic         clk,
  input  logic         rst_n,

  // decode-stage handshake
  input  logic         req_valid,
  input  hdcu_instr_t  req,
  output logic         hdcu_busy,
  output logic         hdcu_done,
  output logic         unsupported_op,

  // SPMI: host <-> SPM bulk transfer path (hvmemld / hvmemstr), 32-bit wide
  // Host (CPU) access port, 32 bits wide: spmi_addr is the BIT address of a
  // 32-bit word. Used only while the controller is idle (the CPU is stalled
  // by the PCPI bridge for the whole duration of every HDC instruction).
  input  logic                spmi_re,
  input  logic                spmi_we,
  input  logic [SPM_ADDR_W-1:0] spmi_addr,
  input  logic [31:0]          spmi_wdata,
  output logic [31:0]          spmi_rdata,

  // exposed CSRs for debug/status
  output logic [HVSIZE_W-1:0]  csr_hvsize,
  output logic [PROTCNT_W-1:0] csr_protcnt,

  // scalar results (RISC-V INTEGRATION addition): HDC_SIM's Hamming
  // distance and HDC_SEARCH's best-match class index are computed
  // internally and written to SPM by hdcu_ctrl, but a PCPI-style
  // integration wants them directly as a register value too -- these
  // ports simply tap the existing internal wires, no logic changes.
  output logic [POPCNT_ACC_W-1:0] sim_result,
  output logic [PROTCNT_W-1:0]    search_result
);

  // -------------------------------------------------------------------
  // Shared SPM read/write bus driven by the controller
  // -------------------------------------------------------------------
  logic                  spm_re, spm_we;
  logic [SPM_ADDR_W-1:0] spm_raddr_a, spm_raddr_b, spm_waddr;
  logic [SIMD-1:0]       spm_rdata_a, spm_rdata_b, spm_wdata;

  // controller-side copies, muxed with the host port below
  logic                  ctl_spm_re, ctl_spm_we;
  logic [SPM_ADDR_W-1:0] ctl_spm_raddr_a, ctl_spm_raddr_b, ctl_spm_waddr;
  logic [SIMD-1:0]       ctl_spm_wdata;

  // host access: allowed only while the controller is idle
  logic host_act;
  int   host_sub;                       // which 32-bit slice of the SIMD-wide chunk
  logic [SPM_ADDR_W-1:0] host_chunk_addr;
  logic [SIMD-1:0]       host_merged;
  assign host_act        = (spmi_re || spmi_we) && !hdcu_busy && !hdcu_done;
  assign host_sub        = (spmi_addr >> 5) % (SIMD / 32);
  assign host_chunk_addr = (spmi_addr >> $clog2(SIMD)) << $clog2(SIMD);
  always_comb begin
    host_merged = spm_rdata_a;                       // read-modify-write when SIMD > 32
    host_merged[host_sub*32 +: 32] = spmi_wdata;
  end

  assign spm_re      = host_act ? spmi_re         : ctl_spm_re;
  assign spm_raddr_a = host_act ? host_chunk_addr : ctl_spm_raddr_a;
  assign spm_raddr_b = ctl_spm_raddr_b;
  assign spm_we      = host_act ? spmi_we         : ctl_spm_we;
  assign spm_waddr   = host_act ? host_chunk_addr : ctl_spm_waddr;
  assign spm_wdata   = host_act ? host_merged     : ctl_spm_wdata;

  // rd/rs1/rs2 select which of the NUM_SPM banks each address targets;
  // top SPM_ADDR_W-$clog2(NUM_SPM) bits = bank select (by convention,
  // matches "spmA/spmB/spmC/spmD" naming in Section IV-B).
  localparam int BANK_SEL_W = $clog2(NUM_SPM);
  logic [BANK_SEL_W-1:0] bank_a, bank_b, bank_w;
  assign bank_a = spm_raddr_a[SPM_ADDR_W-1 -: BANK_SEL_W];
  assign bank_b = spm_raddr_b[SPM_ADDR_W-1 -: BANK_SEL_W];
  assign bank_w = spm_waddr [SPM_ADDR_W-1 -: BANK_SEL_W];

  logic [SIMD-1:0] spm_rdata_a_bank [NUM_SPM];
  logic [SIMD-1:0] spm_rdata_b_bank [NUM_SPM];

  genvar g;
  generate
    for (g = 0; g < NUM_SPM; g++) begin : g_spm
      logic re_a, re_b, we;
      assign re_a = spm_re && (bank_a == g);
      assign re_b = spm_re && (bank_b == g);
      assign we   = spm_we && (bank_w == g);

      spm #(.DEPTH_BITS(SPM_DEPTH_BITS), .WORD_W(SIMD)) u_spm_a (
        .clk(clk), .rst_n(rst_n),
        .re(re_a),   .raddr(spm_raddr_a),   .rdata(spm_rdata_a_bank[g]),
        .re_b(re_b), .raddr_b(spm_raddr_b), .rdata_b(spm_rdata_b_bank[g]),
        .we(we),     .waddr(spm_waddr),     .wdata(spm_wdata)
      );

      // second read port view of the same logical bank contents for rs2
      // (kept as a distinct instance would duplicate storage; in practice
      // this bank is dual-read-ported -- shown here as a second spm
      // instance sharing the write side is NOT valid RTL, so real
      // implementations should give `spm` a true 1W/2R interface).
    end
  endgenerate

  // Synchronous-read SPMs: the read data belongs to the address of the previous
  // read cycle, so the bank select for the read-data mux is latched with it.
  logic [BANK_SEL_W-1:0] bank_a_r, bank_b_r;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin bank_a_r <= '0; bank_b_r <= '0; end
    else if (spm_re) begin bank_a_r <= bank_a; bank_b_r <= bank_b; end
  end
  always_comb begin
    spm_rdata_a = '0;
    spm_rdata_b = '0;
    for (int i = 0; i < NUM_SPM; i++) begin
      if (bank_a_r == i) spm_rdata_a = spm_rdata_a_bank[i];
      if (bank_b_r == i) spm_rdata_b = spm_rdata_b_bank[i];  // true second read port
    end
  end

  // SPMI (Section III-A): 32-bit host read path (same-cycle read)
  assign spmi_rdata = spm_rdata_a[host_sub*32 +: 32];

  // -------------------------------------------------------------------
  // Functional unit datapaths
  // -------------------------------------------------------------------
  logic [SIMD-1:0] bind_a, bind_b, bind_y;
  binding_unit #(.WIDTH(SIMD)) u_bind (.a_chunk(bind_a), .b_chunk(bind_b), .y_chunk(bind_y));

  logic [SIMD/M_BITS*M_BITS-1:0] bund_a_w, bund_y_w;
  logic [SIMD-1:0]               bund_b_bits;
  bundling_unit #(.SIMD_W(SIMD), .M(M_BITS)) u_bund (
    .b_bits(bund_b_bits), .a_widened(bund_a_w), .y_widened(bund_y_w)
  );

  logic [SIMD/M_BITS*M_BITS-1:0] clip_a_w;
  logic [M_BITS-1:0]             clip_thr;
  logic [SIMD/M_BITS-1:0]        clip_tie, clip_y;
  clipping_unit #(.SIMD_W(SIMD), .M(M_BITS)) u_clip (
    .a_widened(clip_a_w), .threshold(clip_thr), .tie_rand(clip_tie), .y_bits(clip_y)
  );

  logic [SIMD-1:0] perm_in, perm_buf_in, perm_out, perm_buf_out;
  logic [$clog2(SIMD+1)-1:0] perm_s;
  permutation_unit #(.SIMD_W(SIMD)) u_perm (
    .chunk_in(perm_in), .buf_in(perm_buf_in), .s(perm_s),
    .chunk_out(perm_out), .buf_out(perm_buf_out)
  );
  // carry buffer threaded across chunks of the SAME permutation op
  logic [SIMD-1:0] perm_buf_r;
  logic perm_buf_en;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n)           perm_buf_r <= '0;
    else if (perm_buf_en) perm_buf_r <= perm_buf_out;   // advance once per chunk (data phase)
  logic perm_first;
  assign perm_buf_in = perm_first ? spm_rdata_b : perm_buf_r;   // wrap-around on chunk 0

  logic              sim_clear, sim_valid;
  logic [SIMD-1:0]   sim_a, sim_b;
  logic [POPCNT_ACC_W-1:0] sim_dist;
  similarity_unit #(.SIMD_W(SIMD), .ACC_W(POPCNT_ACC_W)) u_sim (
    .clk(clk), .rst_n(rst_n), .clear(sim_clear), .valid(sim_valid),
    .a_chunk(sim_a), .b_chunk(sim_b), .hamming_dist(sim_dist)
  );

  logic srch_start, srch_valid, srch_new_proto, srch_busy, srch_done;
  logic [SIMD-1:0]      srch_query, srch_proto;
  logic [PROTCNT_W-1:0] srch_best_idx;
  search_unit #(.SIMD_W(SIMD), .ACC_W(POPCNT_ACC_W), .PROT_W(PROTCNT_W)) u_srch (
    .clk(clk), .rst_n(rst_n), .start(srch_start), .k_prototypes(csr_protcnt),
    .chunk_valid(srch_valid), .new_prototype(srch_new_proto),
    .query_chunk(srch_query), .proto_chunk(srch_proto),
    .busy(srch_busy), .done(srch_done), .best_idx(srch_best_idx)
  );

  // -------------------------------------------------------------------
  // Controller
  // -------------------------------------------------------------------
  hdcu_ctrl u_ctrl (
    .clk(clk), .rst_n(rst_n),
    .req_valid(req_valid), .req(req),
    .hdcu_busy(hdcu_busy), .hdcu_done(hdcu_done), .unsupported_op(unsupported_op),
    .csr_hvsize(csr_hvsize), .csr_protcnt(csr_protcnt),

    .spm_re(ctl_spm_re), .spm_raddr_a(ctl_spm_raddr_a), .spm_raddr_b(ctl_spm_raddr_b),
    .spm_rdata_a(spm_rdata_a), .spm_rdata_b(spm_rdata_b),
    .spm_we(ctl_spm_we), .spm_waddr(ctl_spm_waddr), .spm_wdata(ctl_spm_wdata),

    .bind_a(bind_a), .bind_b(bind_b), .bind_y(bind_y),

    .bund_a_widened(bund_a_w), .bund_b_bits(bund_b_bits), .bund_y_widened(bund_y_w),

    .clip_a_widened(clip_a_w), .clip_threshold(clip_thr), .clip_tie_rand(clip_tie), .clip_y_bits(clip_y),

    .perm_chunk_in(perm_in), .perm_s(perm_s),
    .perm_chunk_out(perm_out), .perm_buf_out(perm_buf_out), .perm_first(perm_first), .perm_buf_en(perm_buf_en),

    .sim_clear(sim_clear), .sim_valid(sim_valid), .sim_a(sim_a), .sim_b(sim_b), .sim_dist(sim_dist),

    .srch_start(srch_start), .srch_chunk_valid(srch_valid), .srch_new_proto(srch_new_proto),
    .srch_query(srch_query), .srch_proto(srch_proto),
    .srch_busy(srch_busy), .srch_done(srch_done), .srch_best_idx(srch_best_idx)
  );

  assign sim_result    = sim_dist;
  assign search_result = srch_best_idx;

endmodule : hdcu_top
