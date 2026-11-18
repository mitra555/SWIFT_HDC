// =============================================================================
// search_unit.sv  (Section III-B, f)
//
// hvsearch(*rd, *rs1, *rs2): compares the query HV (rs1) against
// CSR_PROT_COUNT (K) prototype HVs stored contiguously from rs2, using
// the similarity_unit's Hamming-distance datapath. The query stays
// latched on one input while the other input iterates through the K
// prototypes; the best (minimum Hamming distance) is tracked in a
// 13-bit register together with its winning index. When the whole
// search completes, `done` pulses and `best_idx` is the class to be
// written back to the SPM by the controller.
// =============================================================================
import hdcu_pkg::*;

module search_unit #(
  parameter int SIMD_W  = SIMD,
  parameter int ACC_W   = POPCNT_ACC_W,
  parameter int PROT_W  = PROTCNT_W
) (
  input  logic               clk,
  input  logic               rst_n,

  input  logic               start,        // pulse: begin a new search
  input  logic [PROT_W-1:0]  k_prototypes, // CSR_PROT_COUNT value

  // per-chunk streaming interface (driven by hdcu_ctrl hardware loop)
  input  logic               chunk_valid,
  input  logic               new_prototype,  // pulses on the first chunk of each prototype
  input  logic [SIMD_W-1:0]  query_chunk,
  input  logic [SIMD_W-1:0]  proto_chunk,

  output logic               busy,
  output logic               done,          // 1-cycle pulse when the search completes
  output logic [PROT_W-1:0]  best_idx
);

  logic                sim_clear;
  logic [ACC_W-1:0]     sim_dist;

  similarity_unit #(.SIMD_W(SIMD_W), .ACC_W(ACC_W)) u_sim (
    .clk          (clk),
    .rst_n        (rst_n),
    .clear        (sim_clear),
    .valid        (chunk_valid),
    .a_chunk      (query_chunk),
    .b_chunk      (proto_chunk),
    .hamming_dist (sim_dist)
  );

  assign sim_clear = new_prototype;

  logic [ACC_W-1:0]   best_dist_r;
  logic [PROT_W-1:0]  best_idx_r, proto_cnt_r;
  logic               busy_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy_r      <= 1'b0;
      best_dist_r <= {ACC_W{1'b1}};   // max distance = worst similarity
      best_idx_r  <= '0;
      proto_cnt_r <= '0;
    end else if (start) begin
      busy_r      <= 1'b1;
      best_dist_r <= {ACC_W{1'b1}};
      best_idx_r  <= '0;
      proto_cnt_r <= '0;
    end else if (busy_r && new_prototype) begin
      // a prototype's final distance is available on the cycle
      // *before* new_prototype pulses for the next one (i.e. right now)
      if (sim_dist < best_dist_r) begin
        best_dist_r <= sim_dist;
        best_idx_r  <= proto_cnt_r;
      end
      proto_cnt_r <= proto_cnt_r + 1'b1;
      if (proto_cnt_r + 1'b1 == k_prototypes)
        busy_r <= 1'b0;
    end
  end

  assign busy     = busy_r;
  assign done     = busy_r && new_prototype && (proto_cnt_r + 1'b1 == k_prototypes);
  assign best_idx = best_idx_r;

endmodule : search_unit
