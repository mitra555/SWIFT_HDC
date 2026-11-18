// =============================================================================
// binding_unit.sv  (Section III-B, a)
// Binding (⊗) = bit-wise XOR. SIMD parameter sets how many XOR gates
// operate in parallel per clock cycle.
// =============================================================================
import hdcu_pkg::*;

module binding_unit #(
  parameter int WIDTH = SIMD
) (
  input  logic [WIDTH-1:0] a_chunk,
  input  logic [WIDTH-1:0] b_chunk,
  output logic [WIDTH-1:0] y_chunk
);

  assign y_chunk = a_chunk ^ b_chunk;

endmodule : binding_unit
