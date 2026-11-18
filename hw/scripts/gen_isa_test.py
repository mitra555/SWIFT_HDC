"""Full-ISA SoC test generator.

Emits, from ONE operation list:
  program.hex  -- RV32I + custom-0 program run by the real PicoRV32 in hdc_soc_top
  ref_seq.svh  -- the same HDC operations as direct-drive task calls for reference
                  hdcu_top / nov_top instances in the testbench
  expect.svh   -- which CPU result-memory words hold which scalar results

Every non-scalar custom instruction writes rd = x31, which holds a sentinel; the
sentinel is stored at the end, so any instruction that wrongly writes back a
register (the funct7-overlap bug) is caught.
"""
import sys
sys.path.insert(0, sys.argv[1])          # path to package sw/ (asm.py)
import asm

OP = 0b0001011
F3_BASE, F3_NOV, F3_CSR, F3_Q = 0b000, 0b001, 0b010, 0b011
CSR = dict(HVSIZE_NOV=0, K_NOV=1, WEIGHT_NOV=2, Q_FMIN=3, Q_SPAN=4, Q_NLVL=5, DST=6)
HDC = dict(BUNDLE=3, BIND=4, PERM=5, SIM=6, CLIP=7, SEARCH=8, CSR_HVSZ=9, CSR_PROT=10)
NOV = dict(SIGN=2, DOTSEARCH=3, PROTO_UPDATE=4, NORMALIZE=5, BINDMAC_FIRST=16, BINDMAC_ACC=17)
NOV_OPCODE = dict(SIGN=2, DOTSEARCH=3, PROTO_UPDATE=4, NORMALIZE=5, BINDMAC_FIRST=1, BINDMAC_ACC=1)

X_A, X_B, X_RES, X_SENT = 5, 6, 20, 31
RESULT_BYTES = 8192                       # result area: memory word 2048 onward

prog, ref, expect = [], [], []
nres = 0
st = dict(dst=0, hv_nov=0, k_nov=0, w_nov=0)

def emit(x): prog.extend(x if isinstance(x, list) else [x])
def li(r, v): emit(asm.LI(r, v & 0xFFFFFFFF))

def csr(name, val):
    li(X_A, val)
    emit(asm.rtype(CSR[name], 0, X_A, F3_CSR, X_SENT, OP))   # rd = x31: must NOT be written
    if name == "DST": st["dst"] = val
    if name == "HVSIZE_NOV": st["hv_nov"] = val
    if name == "K_NOV": st["k_nov"] = val
    if name == "WEIGHT_NOV": st["w_nov"] = val

def store_result(reg, label):
    global nres
    emit(asm.SW(reg, 4 * nres, X_RES))
    expect.append((nres, label))
    nres += 1

def base(name, rs1, rs2, scalar=None):
    li(X_A, rs1); li(X_B, rs2)
    rd = 9 if scalar else X_SENT
    emit(asm.rtype(HDC[name], X_B, X_A, F3_BASE, rd, OP))
    imm = rs2 if name in ("PERM", "CLIP") else rs1
    ref.append(f"ref_base(HDC_{name}, {st['dst']}, {rs1}, {rs2}, {imm});")
    if scalar:
        ref.append(f"ref_scalar[{nres}] = ({'ref_srch' if name == 'SEARCH' else 'ref_sim'});")
        store_result(9, scalar)

def nov(name, rs1, rs2, scalar=None):
    li(X_A, rs1); li(X_B, rs2)
    rd = 9 if scalar else X_SENT
    emit(asm.rtype(NOV[name], X_B, X_A, F3_NOV, rd, OP))
    clear = 1 if name == "BINDMAC_FIRST" else 0
    ref.append(f"ref_nov(4'd{NOV_OPCODE[name]}, {st['dst']}, {rs1}, {rs2}, {st['w_nov']}, {st['k_nov']}, {clear}, {st['hv_nov']});")
    if scalar:
        ref.append(f"ref_scalar[{nres}] = ref_nsrch;")
        store_result(9, scalar)

# ---------------- program ----------------
li(X_SENT, 0x5A5A5A5A)
li(X_RES, RESULT_BYTES)

# quantizer: fmin=0, span=1.0, nlvl=21, feat=0.5 -> idx 10
csr("Q_FMIN", 0); csr("Q_SPAN", 65536); csr("Q_NLVL", 21)
li(X_A, 32768); emit(asm.rtype(0, 0, X_A, F3_Q, 9, OP))
ref.append("ref_scalar[0] = 10;")
store_result(9, "quantize idx")

# ---- baseline (bit addresses). HV = 64 bits = 2 chunks ----
li(X_A, 64); emit(asm.rtype(HDC["CSR_HVSZ"], 0, X_A, F3_BASE, X_SENT, OP)); ref.append("ref_base(HDC_CSR_HVSZ, 0, 64, 0, 64);")
li(X_A, 3);  emit(asm.rtype(HDC["CSR_PROT"], 0, X_A, F3_BASE, X_SENT, OP)); ref.append("ref_base(HDC_CSR_PROT, 0, 3, 0, 3);")
A, B, P, W = 0, 8192, 24576, 26624      # banks 0,1,3,3 (bank = addr[14:13])
csr("DST", 16384); base("BIND", A, B)
csr("DST", 16576); base("SIM", A, B, scalar="hvsim distance")
csr("DST", 16448); base("PERM", A, 13)                 # rotate by 13
csr("DST", 16480); base("PERM", B, 32)                 # rotate by a full chunk
csr("DST", W);    base("BUNDLE", W, B)                # widened W += B
csr("DST", W);    base("BUNDLE", W, A)
csr("DST", 16512); base("CLIP", W, 5)                  # threshold 5
csr("DST", 16608); base("SEARCH", A, P, scalar="hvsearch index")

# ---- novelty (word addresses). HV = 64 lanes = 2 chunks ----
csr("HVSIZE_NOV", 64); csr("K_NOV", 3)
csr("WEIGHT_NOV", 3);  csr("DST", 100); nov("BINDMAC_FIRST", 0, 2)
csr("WEIGHT_NOV", -2);                  nov("BINDMAC_ACC", 4, 6)
csr("WEIGHT_NOV", 1);                   nov("BINDMAC_ACC", 8, 10)
csr("DST", 20);                         nov("SIGN", 100, 0)
csr("WEIGHT_NOV", 1);  csr("DST", 202); nov("PROTO_UPDATE", 20, 0)   # proto 1 += hv
csr("WEIGHT_NOV", -1); csr("DST", 204); nov("PROTO_UPDATE", 20, 0)   # proto 2 -= hv
nov("DOTSEARCH", 20, 200, scalar="nov dotsearch index")
csr("DST", 300);                        nov("NORMALIZE", 202, 0)
csr("DST", 310);                        nov("NORMALIZE", 250, 0)     # all-zero region -> copy

store_result(X_SENT, "x31 sentinel (no stray writebacks)")
ref.append(f"ref_scalar[{nres-1}] = 32'h5A5A5A5A;")
li(X_A, 0xC0FFEE); store_result(X_A, "completion marker")
ref.append(f"ref_scalar[{nres-1}] = 32'hC0FFEE;")
emit(asm.JAL(0, 0))

with open("program.hex", "w") as f:
    for i in prog: f.write(f"{i & 0xFFFFFFFF:08x}\n")
with open("ref_seq.svh", "w") as f:
    f.write("\n".join(ref) + "\n")
with open("expect.svh", "w") as f:
    f.write(f"localparam int NRES = {nres};\n")
    f.write("string res_label [NRES];\ninitial begin\n")
    for i, l in expect: f.write(f'  res_label[{i}] = "{l}";\n')
    f.write("end\n")
print(f"{len(prog)} instructions, {nres} result words, {len(ref)} reference steps")
