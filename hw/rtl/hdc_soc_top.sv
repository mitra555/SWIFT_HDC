// =============================================================================
// hdc_soc_top.sv  (RISC-V INTEGRATION)
//
// PicoRV32 (ENABLE_PCPI=1) + pcpi_hdc_bridge + hdcu_top (baseline) +
// nov_top (novelty extension) + quantize_unit (input encoder), plus a
// simple synchronous byte-addressable memory for program/data, in the
// same minimal style as picorv32's own testbench_ez.v.
// =============================================================================
import hdcu_pkg::*;

module hdc_soc_top #(
  parameter int MEM_WORDS = 4096
) (
  input  logic        clk,
  input  logic        resetn,
  output logic        trap        // core trapped (illegal instruction / bus error)
);

  // -------------------------------------------------------------------
  // PicoRV32 core
  // -------------------------------------------------------------------
  wire        mem_valid, mem_instr;
  reg         mem_ready;
  wire [31:0] mem_addr, mem_wdata;
  wire [3:0]  mem_wstrb;
  reg  [31:0] mem_rdata;

  wire        pcpi_valid;
  wire [31:0] pcpi_insn;
  wire [31:0] pcpi_rs1, pcpi_rs2;
  wire        pcpi_wr;
  wire [31:0] pcpi_rd;
  wire        pcpi_wait;
  wire        pcpi_ready;


  picorv32 #(
    .ENABLE_PCPI(1),
    .ENABLE_MUL(0),
    .ENABLE_DIV(0),
    .ENABLE_FAST_MUL(0),
    .ENABLE_IRQ(0),
    .ENABLE_COUNTERS(0)
  ) cpu (
    .clk       (clk),
    .resetn    (resetn),
    .trap      (trap),
    .mem_valid (mem_valid),
    .mem_instr (mem_instr),
    .mem_ready (mem_ready),
    .mem_addr  (mem_addr),
    .mem_wdata (mem_wdata),
    .mem_wstrb (mem_wstrb),
    .mem_rdata (mem_rdata),
    .pcpi_valid(pcpi_valid),
    .pcpi_insn (pcpi_insn),
    .pcpi_rs1  (pcpi_rs1),
    .pcpi_rs2  (pcpi_rs2),
    .pcpi_wr   (pcpi_wr),
    .pcpi_rd   (pcpi_rd),
    .pcpi_wait (pcpi_wait),
    .pcpi_ready(pcpi_ready),
    .irq       (32'b0)
  );

  // -------------------------------------------------------------------
  // Simple synchronous memory (program + data), matching testbench_ez.v
  // -------------------------------------------------------------------
  // Main memory (program + data) is its own module so synthesis can replace it
  // with an SRAM macro (black box), exactly like the scratchpads.
  logic        mm_we;
  logic        mm_en;
  logic [3:0]  mm_wstrb;
  logic [31:0] mm_rdata;
  logic [$clog2(MEM_WORDS)-1:0] mm_addr;
  soc_mem #(.WORDS(MEM_WORDS)) u_mem (
    .clk(clk), .en(mm_en), .addr(mm_addr), .wstrb(mm_wstrb), .wdata(mem_wdata), .rdata(mm_rdata)
  );

  // -------------------------------------------------------------------
  // Address map
  //   0x0000_0000  main memory (program + data), MEM_WORDS words
  //   0x1000_0000  baseline HDCU SPM:  word w = SPM bit address 32*w (bank = w/256)
  //   0x2000_0000  novelty bit SPM:    word w
  //   0x3000_0000  novelty wide SPM:   word n = lane (n % SIMD) of chunk (n / SIMD), signed int32
  // SPM regions are word-access only (sw/lw); partial-word stores are ignored.
  // The PCPI bridge stalls the core for the full duration of every HDC
  // instruction, so CPU SPM accesses never overlap accelerator accesses.
  // -------------------------------------------------------------------
  localparam logic [3:0] RGN_MEM = 4'h0, RGN_BASE = 4'h1, RGN_NBIT = 4'h2, RGN_NWIDE = 4'h3;
  wire [3:0]  rgn      = mem_addr[31:28];
  wire [25:0] widx     = mem_addr[27:2];
  wire        acc      = mem_valid && !mem_ready;
  wire        full_wr  = (mem_wstrb == 4'hF);
  wire        rd_only  = (mem_wstrb == 4'h0);

  logic        base_host_re, base_host_we;
  logic [31:0] base_host_rdata;
  logic        nov_host_bit_re, nov_host_bit_we, nov_host_wide_re, nov_host_wide_we;
  logic [31:0] nov_host_bit_rdata, nov_host_wide_rdata;
  // Synchronous-read SRAMs: every access takes two cycles (see mm_pend below).
  // Address cycle (!mm_pend): the SRAM is read -- for reads, and for writes too,
  // because a wide-SPM lane write is a read-modify-write of the whole row.
  // Data cycle (mm_pend): the read data is valid; writes commit here, merged with it.
  // Ignored partial-word SPM stores still complete the handshake (default arm).
  logic mm_pend;
  wire  a_cyc = acc && !mm_pend;
  wire  d_cyc = acc &&  mm_pend;
  assign base_host_re     = a_cyc && (rgn == RGN_BASE)  && (rd_only || full_wr);
  assign base_host_we     = d_cyc && (rgn == RGN_BASE)  && full_wr;
  assign nov_host_bit_re  = a_cyc && (rgn == RGN_NBIT)  && (rd_only || full_wr);
  assign nov_host_bit_we  = d_cyc && (rgn == RGN_NBIT)  && full_wr;
  assign nov_host_wide_re = a_cyc && (rgn == RGN_NWIDE) && (rd_only || full_wr);
  assign nov_host_wide_we = d_cyc && (rgn == RGN_NWIDE) && full_wr;

  // -------------------------------------------------------------------
  // Table copy engine (PCPI_F3_MEMCPY): streams n words from main memory into
  // the novelty bit SPM at one word per cycle while the CPU is stalled on the
  // instruction. Cycle t reads word i (synchronous SRAM); cycle t+1 writes it
  // to bit-SPM word dst+i and reads word i+1. n words take n+1 cycles.
  // -------------------------------------------------------------------
  logic        dma_start, dma_done, dma_act, dma_rv;
  logic [31:0] dma_src_b;
  logic [15:0] dma_n_in, dma_left;
  logic [SPM_ADDR_W-1:0] dma_dst_in;
  logic [$clog2(MEM_WORDS)-1:0] dma_raddr;
  logic [19:0] dma_waddr;
  wire  dma_rd = dma_act && (dma_left != 0);
  always_ff @(posedge clk) begin
    if (!resetn) begin
      dma_act <= 1'b0; dma_rv <= 1'b0; dma_left <= '0; dma_done <= 1'b0;
    end else begin
      dma_done <= 1'b0;
      if (dma_start) begin
        dma_act   <= 1'b1;  dma_rv <= 1'b0;
        dma_left  <= dma_n_in;
        dma_raddr <= dma_src_b[$clog2(MEM_WORDS)+1:2];
        dma_waddr <= 20'(dma_dst_in);
      end else if (dma_act) begin
        dma_rv <= dma_rd;
        if (dma_rd) begin dma_left <= dma_left - 1'b1; dma_raddr <= dma_raddr + 1'b1; end
        if (dma_rv) dma_waddr <= dma_waddr + 1'b1;
        if (!dma_rd && !dma_rv) begin dma_act <= 1'b0; dma_done <= 1'b1; end
      end
    end
  end

  assign mm_addr  = dma_act ? dma_raddr : mem_addr[$clog2(MEM_WORDS)+1:2];
  // main memory: read or write once, in the address cycle
  assign mm_en    = dma_act ? dma_rd : (a_cyc && rgn == RGN_MEM && mem_addr[31:2] < MEM_WORDS);
  assign mm_wstrb = (mm_en && !dma_act) ? mem_wstrb : 4'b0;

  // SYNCHRONOUS-SRAM ADAPTATION: every memory (main soc_mem and the cores'
  // host SPM read paths) is now a 1-cycle synchronous read. A two-cycle
  // handshake per access holds the address for one cycle, then asserts
  // mem_ready with the (now valid) read data on the next cycle. `pend`
  // distinguishes the address cycle from the data cycle; acc stays high across
  // both (mem_ready is still 0), so the address assigns above remain stable.
  always @(posedge clk) begin
    mem_ready <= 0;
    if (!resetn) begin
      mm_pend <= 1'b0;
    end else if (acc && !mm_pend && !mem_ready) begin
      mm_pend <= 1'b1;                    // address cycle: SRAMs latch the address
    end else if (mm_pend) begin
      mm_pend <= 1'b0;                    // data cycle: read data is valid now
      case (rgn)
        RGN_MEM: if (mem_addr[31:2] < MEM_WORDS) begin
          mem_ready <= 1; mem_rdata <= mm_rdata;
        end
        RGN_BASE:  begin mem_ready <= 1; mem_rdata <= base_host_rdata;     end
        RGN_NBIT:  begin mem_ready <= 1; mem_rdata <= nov_host_bit_rdata;  end
        RGN_NWIDE: begin mem_ready <= 1; mem_rdata <= nov_host_wide_rdata; end
        default:   begin mem_ready <= 1;                                   end
      endcase
    end
  end

  // -------------------------------------------------------------------
  // Baseline HDCU
  // -------------------------------------------------------------------
  logic         base_req_valid, base_busy, base_done, base_unsupported;
  hdcu_instr_t  base_req;
  logic [POPCNT_ACC_W-1:0] base_sim_result;
  logic [PROTCNT_W-1:0]    base_search_result;
  logic [HVSIZE_W-1:0]     base_csr_hvsize;
  logic [PROTCNT_W-1:0]    base_csr_protcnt;

  hdcu_top u_base (
    .clk(clk), .rst_n(resetn),
    .req_valid(base_req_valid), .req(base_req),
    .hdcu_busy(base_busy), .hdcu_done(base_done), .unsupported_op(base_unsupported),
    .spmi_re(base_host_re), .spmi_we(base_host_we),
    .spmi_addr(SPM_ADDR_W'({widx, 5'b0})), .spmi_wdata(mem_wdata), .spmi_rdata(base_host_rdata),
    .csr_hvsize(base_csr_hvsize), .csr_protcnt(base_csr_protcnt),
    .sim_result(base_sim_result), .search_result(base_search_result)
  );

  // -------------------------------------------------------------------
  // Novelty extension
  // -------------------------------------------------------------------
  logic         nov_req_valid, nov_busy, nov_done, nov_req_clear_first;
  nov_instr_t   nov_req;
  logic [15:0]  nov_search_result;
  logic [HVSIZE_W-1:0] nov_hvsize_from_bridge;
  logic [31:0] gen_seedl, gen_seedp;
  logic [15:0] gen_step;

  nov_top u_nov (
    .clk(clk), .rst_n(resetn),
    .req_valid(nov_req_valid), .req(nov_req), .req_clear_first(nov_req_clear_first),
    .nov_busy(nov_busy), .nov_done(nov_done),
    .csr_hvsize(nov_hvsize_from_bridge),
    .csr_gen_seedl(gen_seedl), .csr_gen_seedp(gen_seedp), .csr_gen_step(gen_step),
    .search_result(nov_search_result),
    .host_bit_re(nov_host_bit_re), .host_bit_we(nov_host_bit_we || (dma_act && dma_rv)),
    .host_wide_re(nov_host_wide_re), .host_wide_we(nov_host_wide_we),
    .host_addr(dma_act ? dma_waddr : widx[19:0]), .host_wdata(dma_act ? mm_rdata : mem_wdata),
    .host_bit_rdata(nov_host_bit_rdata), .host_wide_rdata(nov_host_wide_rdata)
  );

  // -------------------------------------------------------------------
  // Input encoder
  // -------------------------------------------------------------------
  logic quant_start, quant_busy, quant_done;
  logic signed [31:0] quant_feat, quant_fmin, quant_span;
  logic [7:0] quant_nlvl, quant_idx;

  quantize_unit #(.FEAT_W(32), .NLVL_W(8), .IDX_W(8)) u_quant (
    .clk(clk), .rst_n(resetn), .start(quant_start),
    .feat(quant_feat), .fmin(quant_fmin), .span(quant_span), .nlvl(quant_nlvl),
    .busy(quant_busy), .done(quant_done), .idx(quant_idx)
  );

  // -------------------------------------------------------------------
  // PCPI bridge
  // -------------------------------------------------------------------
  pcpi_hdc_bridge u_bridge (
    .clk(clk), .resetn(resetn),
    .pcpi_valid(pcpi_valid), .pcpi_insn(pcpi_insn), .pcpi_rs1(pcpi_rs1), .pcpi_rs2(pcpi_rs2),
    .pcpi_wr(pcpi_wr), .pcpi_rd(pcpi_rd), .pcpi_wait(pcpi_wait), .pcpi_ready(pcpi_ready),

    .base_req_valid(base_req_valid), .base_req(base_req),
    .base_busy(base_busy), .base_done(base_done), .base_unsupported(base_unsupported),

    .nov_req_valid(nov_req_valid), .nov_req(nov_req), .nov_req_clear_first(nov_req_clear_first),
    .nov_busy(nov_busy), .nov_done(nov_done),

    .quant_start(quant_start), .quant_feat(quant_feat), .quant_fmin(quant_fmin),
    .quant_span(quant_span), .quant_nlvl(quant_nlvl),
    .quant_busy(quant_busy), .quant_done(quant_done), .quant_idx(quant_idx),

    .dma_start(dma_start), .dma_src(dma_src_b), .dma_n(dma_n_in), .dma_dst(dma_dst_in), .dma_done(dma_done),

    .base_sim_result(base_sim_result[12:0]),
    .base_search_idx(base_search_result),
    .nov_search_idx(nov_search_result),
    .csr_hvsize_nov(nov_hvsize_from_bridge),
    .csr_gen_seedl(gen_seedl), .csr_gen_seedp(gen_seedp), .csr_gen_step(gen_step)
  );

endmodule : hdc_soc_top
