// Back-door access to main memory that works for both soc_mem builds.
// With -DSYNTHESIS the storage is in the OpenRAM macro models
// (dut.u_mem.g_bank[b].u_sram.mem); compile with -DNBANKS=<WORDS/2048>.
`ifndef NBANKS
`define NBANKS 2
`endif
`ifndef MEMIO_NO_SOCMEM   // main-memory helpers need dut.u_mem (hdc_soc_top)
function automatic logic [31:0] peek(input int w);
`ifdef SYNTHESIS
  case (w / 2048)
    0: return dut.u_mem.g_bank[0].u_sram.mem[w % 2048];
    1: return dut.u_mem.g_bank[1].u_sram.mem[w % 2048];
`ifdef FOUR_BANKS
    2: return dut.u_mem.g_bank[2].u_sram.mem[w % 2048];
    3: return dut.u_mem.g_bank[3].u_sram.mem[w % 2048];
`endif
    default: return 32'hx;
  endcase
`else
  return dut.u_mem.memory[w];
`endif
endfunction
logic [31:0] img [0:8191];
task automatic load_mem(input string fn, input int words);
  for (int i = 0; i < words; i++) img[i] = 32'h0;
  $readmemh(fn, img);
`ifdef SYNTHESIS
  for (int i = 0; i < words; i++)
    case (i / 2048)
      0: dut.u_mem.g_bank[0].u_sram.mem[i % 2048] = img[i];
      1: dut.u_mem.g_bank[1].u_sram.mem[i % 2048] = img[i];
`ifdef FOUR_BANKS
      2: dut.u_mem.g_bank[2].u_sram.mem[i % 2048] = img[i];
      3: dut.u_mem.g_bank[3].u_sram.mem[i % 2048] = img[i];
`endif
      default: ;
    endcase
`else
  for (int i = 0; i < words; i++) dut.u_mem.memory[i] = img[i];
`endif
endtask
`endif


// Back-door paths into the scratchpads, valid for both builds: behavioural
// models (flat `mem`) and -DSYNTHESIS (OpenRAM macro models inside the wrappers;
// the wide SPM is 32 lane macros).
`ifdef SYNTHESIS
`define SPMMEM u_sram.mem
`ifdef NOV_LANE32
`define WIDE_GET(P,i) {P.g_lane[31].u_sram.mem[i], P.g_lane[30].u_sram.mem[i], P.g_lane[29].u_sram.mem[i], P.g_lane[28].u_sram.mem[i], P.g_lane[27].u_sram.mem[i], P.g_lane[26].u_sram.mem[i], P.g_lane[25].u_sram.mem[i], P.g_lane[24].u_sram.mem[i], P.g_lane[23].u_sram.mem[i], P.g_lane[22].u_sram.mem[i], P.g_lane[21].u_sram.mem[i], P.g_lane[20].u_sram.mem[i], P.g_lane[19].u_sram.mem[i], P.g_lane[18].u_sram.mem[i], P.g_lane[17].u_sram.mem[i], P.g_lane[16].u_sram.mem[i], P.g_lane[15].u_sram.mem[i], P.g_lane[14].u_sram.mem[i], P.g_lane[13].u_sram.mem[i], P.g_lane[12].u_sram.mem[i], P.g_lane[11].u_sram.mem[i], P.g_lane[10].u_sram.mem[i], P.g_lane[9].u_sram.mem[i], P.g_lane[8].u_sram.mem[i], P.g_lane[7].u_sram.mem[i], P.g_lane[6].u_sram.mem[i], P.g_lane[5].u_sram.mem[i], P.g_lane[4].u_sram.mem[i], P.g_lane[3].u_sram.mem[i], P.g_lane[2].u_sram.mem[i], P.g_lane[1].u_sram.mem[i], P.g_lane[0].u_sram.mem[i]}
`define WIDE_SET(P,i,V) begin P.g_lane[0].u_sram.mem[i] = V[0*32 +: 32]; P.g_lane[1].u_sram.mem[i] = V[1*32 +: 32]; P.g_lane[2].u_sram.mem[i] = V[2*32 +: 32]; P.g_lane[3].u_sram.mem[i] = V[3*32 +: 32]; P.g_lane[4].u_sram.mem[i] = V[4*32 +: 32]; P.g_lane[5].u_sram.mem[i] = V[5*32 +: 32]; P.g_lane[6].u_sram.mem[i] = V[6*32 +: 32]; P.g_lane[7].u_sram.mem[i] = V[7*32 +: 32]; P.g_lane[8].u_sram.mem[i] = V[8*32 +: 32]; P.g_lane[9].u_sram.mem[i] = V[9*32 +: 32]; P.g_lane[10].u_sram.mem[i] = V[10*32 +: 32]; P.g_lane[11].u_sram.mem[i] = V[11*32 +: 32]; P.g_lane[12].u_sram.mem[i] = V[12*32 +: 32]; P.g_lane[13].u_sram.mem[i] = V[13*32 +: 32]; P.g_lane[14].u_sram.mem[i] = V[14*32 +: 32]; P.g_lane[15].u_sram.mem[i] = V[15*32 +: 32]; P.g_lane[16].u_sram.mem[i] = V[16*32 +: 32]; P.g_lane[17].u_sram.mem[i] = V[17*32 +: 32]; P.g_lane[18].u_sram.mem[i] = V[18*32 +: 32]; P.g_lane[19].u_sram.mem[i] = V[19*32 +: 32]; P.g_lane[20].u_sram.mem[i] = V[20*32 +: 32]; P.g_lane[21].u_sram.mem[i] = V[21*32 +: 32]; P.g_lane[22].u_sram.mem[i] = V[22*32 +: 32]; P.g_lane[23].u_sram.mem[i] = V[23*32 +: 32]; P.g_lane[24].u_sram.mem[i] = V[24*32 +: 32]; P.g_lane[25].u_sram.mem[i] = V[25*32 +: 32]; P.g_lane[26].u_sram.mem[i] = V[26*32 +: 32]; P.g_lane[27].u_sram.mem[i] = V[27*32 +: 32]; P.g_lane[28].u_sram.mem[i] = V[28*32 +: 32]; P.g_lane[29].u_sram.mem[i] = V[29*32 +: 32]; P.g_lane[30].u_sram.mem[i] = V[30*32 +: 32]; P.g_lane[31].u_sram.mem[i] = V[31*32 +: 32]; end
`define WIDE_LANE(P,i,L) P.g_lane[L].u_sram.mem[i]
`else
`define WIDE_GET(P,i) {P.g_lane[15].u_sram.mem[i], P.g_lane[14].u_sram.mem[i], P.g_lane[13].u_sram.mem[i], P.g_lane[12].u_sram.mem[i], P.g_lane[11].u_sram.mem[i], P.g_lane[10].u_sram.mem[i], P.g_lane[9].u_sram.mem[i], P.g_lane[8].u_sram.mem[i], P.g_lane[7].u_sram.mem[i], P.g_lane[6].u_sram.mem[i], P.g_lane[5].u_sram.mem[i], P.g_lane[4].u_sram.mem[i], P.g_lane[3].u_sram.mem[i], P.g_lane[2].u_sram.mem[i], P.g_lane[1].u_sram.mem[i], P.g_lane[0].u_sram.mem[i]}
`define WIDE_SET(P,i,V) begin P.g_lane[0].u_sram.mem[i] = V[0*32 +: 32]; P.g_lane[1].u_sram.mem[i] = V[1*32 +: 32]; P.g_lane[2].u_sram.mem[i] = V[2*32 +: 32]; P.g_lane[3].u_sram.mem[i] = V[3*32 +: 32]; P.g_lane[4].u_sram.mem[i] = V[4*32 +: 32]; P.g_lane[5].u_sram.mem[i] = V[5*32 +: 32]; P.g_lane[6].u_sram.mem[i] = V[6*32 +: 32]; P.g_lane[7].u_sram.mem[i] = V[7*32 +: 32]; P.g_lane[8].u_sram.mem[i] = V[8*32 +: 32]; P.g_lane[9].u_sram.mem[i] = V[9*32 +: 32]; P.g_lane[10].u_sram.mem[i] = V[10*32 +: 32]; P.g_lane[11].u_sram.mem[i] = V[11*32 +: 32]; P.g_lane[12].u_sram.mem[i] = V[12*32 +: 32]; P.g_lane[13].u_sram.mem[i] = V[13*32 +: 32]; P.g_lane[14].u_sram.mem[i] = V[14*32 +: 32]; P.g_lane[15].u_sram.mem[i] = V[15*32 +: 32]; end
`define WIDE_LANE(P,i,L) P.g_lane[(L)/2].u_sram.mem[i][((L)%2)*16 +: 16]
`endif
`else
`define SPMMEM mem
`define WIDE_GET(P,i) P.mem[i]
`define WIDE_SET(P,i,V) P.mem[i] = V;
`define WIDE_LANE(P,i,L) P.mem[i][(L)*`NOV_LANE_W +: `NOV_LANE_W]
`endif
