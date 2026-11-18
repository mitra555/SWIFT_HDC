"""Software-only SoC flow test at application size (D = 5024 novelty, 8192-bit baseline).

The testbench preloads NOTHING into any scratchpad. Firmware running on the real
PicoRV32 moves every hypervector through the memory-mapped SPM windows:
  0x1000_0000 baseline SPM | 0x2000_0000 novelty bit SPM | 0x3000_0000 novelty wide SPM
and reads every result back with LW. Expected results come from an independent
Python model of the instruction semantics, not from the RTL.

Writes: mem.hex (program + data image), expect.hex (expected result area), flow.svh
"""
import sys, random
sys.path.insert(0, sys.argv[1])          # package sw/ directory (asm.py)
import asm
import os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hvgen
LANE_W = int(sys.argv[2]) if len(sys.argv) > 2 else 16   # novelty lane width (NOV_LANE_W)
USE_DMA = (sys.argv[3] if len(sys.argv) > 3 else "dma") != "cpu"   # feature tables via MEMCPY (default) or CPU loads/stores

random.seed(1234)
MEM_WORDS   = 8192
D, SIMD     = 5024, 32
CH          = D // SIMD                   # 157 chunks
K           = 5
BASE_HV     = 8192                        # baseline: one full 8192-bit bank
WEIGHTS     = [3, -2, 1]

OP = 0b0001011
F3_BASE, F3_NOV, F3_CSR, F3_MEMCPY = 0b000, 0b001, 0b010, 0b100
CSR_HVSIZE_NOV, CSR_K_NOV, CSR_WEIGHT_NOV, CSR_DST = 0, 1, 2, 6
CSR_GEN_SEEDL, CSR_GEN_SEEDP, CSR_GEN_STEP = 7, 8, 9
NOV_BINDGEN_FIRST, NOV_BINDGEN_ACC = 18, 19
# table-free features (BINDGEN): (group, level q, feature index f, weight, levels in group)
# f = 64 has a zero sub-word shift, f = 5000 wraps past the start of the vector
GEN = [(0, 7, 13, 2, 21), (1, 3, 64, -1, 11), (2, 10, 5000, 1, 11), (3, 0, 901, 3, 21)]
HDC_BIND, HDC_CSR_HVSZ = 4, 9
HDC_BUNDLE, HDC_PERM, HDC_SIM, HDC_CLIP, HDC_SEARCH, HDC_CSR_PROT = 3, 5, 6, 7, 8, 10
NOV_SIGN, NOV_DOTSEARCH, NOV_PROTO_UPDATE, NOV_NORMALIZE = 2, 3, 4, 5
NOV_BINDMAC_FIRST, NOV_BINDMAC_ACC = 16, 17

BASE_WIN, NBIT_WIN, NWIDE_WIN = 0x1000_0000, 0x2000_0000, 0x3000_0000

# ---------------- data layout (word indices into main memory) ----------------
DATA0   = 1024
A_W     = DATA0                     # 256 words
B_W     = A_W + 256                 # 256 words
FEAT_W  = B_W + 256                 # 3 features x (lvl, pos) x 157 words
RES0    = FEAT_W + 3 * 2 * CH       # result area
R_BIND  = RES0                      # 256 words: baseline A^B read back
R_Q     = R_BIND + 256              # 157 words: encoded (sign) HV read back
R_X     = R_Q + CH                  # 32 words: accumulator lanes of chunk 0
R_X_LAST= R_X + 32                  # 32 words: accumulator lanes of last chunk
R_SRCH  = R_X_LAST + 32             # 1 word : dotsearch index
R_NORM  = R_SRCH + 1                # 32 words: normalized proto 1, chunk 0 lanes
R_P3    = R_NORM + 32               # 32 words: proto 3 chunk 5 lanes (after -Q update)
R_NORM1 = R_P3 + 32                 # 32 words: normalized proto 1, chunk 1 lanes
R_NORML = R_NORM1 + 32              # 32 words: normalized proto 1, last chunk lanes
R_LANE  = R_NORML + 32              # 32 words: X chunk 3 after a CPU write to lane 7 only
LANE_C, LANE_L, LANE_V = 3, 7, -12345   # fits any lane width >= 16; read back sign-extended
R_DONE  = R_LANE + 32               # completion marker
NRES    = R_DONE - RES0 + 1
assert R_DONE < MEM_WORDS

# novelty SPM layout (word / chunk indices)
L_BIT, P_BIT, Q_BIT = 0, CH, 2 * CH          # bit SPM regions
X_W, PROTO_W = 0, CH                         # wide SPM: X then K prototypes

mem = [0] * MEM_WORDS
A = [random.getrandbits(32) for _ in range(256)]
B = [random.getrandbits(32) for _ in range(256)]
mem[A_W:A_W + 256] = A; mem[B_W:B_W + 256] = B
feats = []
for f in range(3):
    lvl = [random.getrandbits(32) for _ in range(CH)]
    pos = [random.getrandbits(32) for _ in range(CH)]
    feats.append((lvl, pos))
    mem[FEAT_W + f*2*CH : FEAT_W + f*2*CH + CH] = lvl
    mem[FEAT_W + f*2*CH + CH : FEAT_W + (f+1)*2*CH] = pos

# ---------------- independent reference model ----------------
def bits(words): return [(words[i // 32] >> (i % 32)) & 1 for i in range(len(words) * 32)]
X = [0] * D
for (lvl, pos), w in zip(feats, WEIGHTS):
    lb, pb = bits(lvl), bits(pos)
    for i in range(D):
        X[i] += w * (-1 if (lb[i] ^ pb[i]) else 1)
for g, q, fi, w, nl in GEN:                                      # table-free features (hvgen.py)
    sl, sp = hvgen.seeds(0, g)
    lb = hvgen.level_bits(sl, hvgen.step_for(nl), q, D); pb = hvgen.pos_bits(sp, fi, D)
    for i in range(D):
        X[i] += w * (-1 if (int(lb[i]) ^ int(pb[i])) else 1)
q_bits = [1 if X[i] < 0 else 0 for i in range(D)]               # sign: negative -> 1, ties -> +1
Q = [sum(q_bits[c*32 + l] << l for l in range(32)) for c in range(CH)]
hvq = [1 - 2*b for b in q_bits]                                  # bipolar query
protos = [[0]*D for _ in range(K)]
protos[1] = [ v for v in hvq]                                    # += Q
protos[3] = [-v for v in hvq]                                    # -= Q
dots = [sum(a*b for a, b in zip(hvq, p)) for p in protos]
best = max(range(K), key=lambda k: (dots[k], -k))                # argmax, first wins on ties
nsq = sum(v*v for v in protos[1]); norm = int(nsq ** 0.5)
while norm * norm > nsq: norm -= 1
while (norm + 1) ** 2 <= nsq: norm += 1
def qdiv(v):                                                     # Q1.(LANE_W-1), truncating toward zero
    q = min((abs(v) << (LANE_W - 1)) // norm, 2**(LANE_W - 1) - 1)
    return -q if v < 0 else q
normed0 = [qdiv(protos[1][l]) & 0xFFFFFFFF for l in range(32)]
normed1 = [qdiv(protos[1][32 + l]) & 0xFFFFFFFF for l in range(32)]
normedL = [qdiv(protos[1][(CH-1)*32 + l]) & 0xFFFFFFFF for l in range(32)]

exp = {}
for i in range(256): exp[R_BIND + i] = A[i] ^ B[i]
for c in range(CH): exp[R_Q + c] = Q[c]
for l in range(32): exp[R_X + l] = X[l] & 0xFFFFFFFF
for l in range(32): exp[R_X_LAST + l] = X[(CH-1)*32 + l] & 0xFFFFFFFF
exp[R_SRCH] = best
for l in range(32): exp[R_NORM + l] = normed0[l]
for l in range(32): exp[R_P3 + l] = protos[3][5*32 + l] & 0xFFFFFFFF
for l in range(32): exp[R_NORM1 + l] = normed1[l]
for l in range(32): exp[R_NORML + l] = normedL[l]
for l in range(32): exp[R_LANE + l] = (LANE_V if l == LANE_L else X[LANE_C*32 + l]) & 0xFFFFFFFF
exp[R_DONE] = 0xC0FFEE

# ---------------- firmware ----------------
prog = []
def emit(x): prog.extend(x if isinstance(x, list) else [x])
def li(r, v): emit(asm.LI(r, v & 0xFFFFFFFF))
def btype(imm, rs2, rs1, f3, opc=0b1100011):
    imm &= 0x1FFF
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) | \
           (f3 << 12) | (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | opc
T0, T1, T2, T3, T4 = 5, 6, 7, 28, 29
A0, A1 = 10, 11
SENT = 31

def copy_words(src_byte, dst_byte, n):          # dst[i] = src[i]
    li(T0, src_byte); li(T1, dst_byte); li(T2, n)
    loop = len(prog)
    emit(asm.LW(T3, 0, T0)); emit(asm.SW(T3, 0, T1))
    emit(asm.ADDI(T0, T0, 4)); emit(asm.ADDI(T1, T1, 4)); emit(asm.ADDI(T2, T2, -1))
    emit(btype((loop - len(prog)) * 4, 0, T2, 0b001))          # bne t2, x0, loop

def fill_zero(dst_byte, n):
    li(T1, dst_byte); li(T2, n)
    loop = len(prog)
    emit(asm.SW(0, 0, T1)); emit(asm.ADDI(T1, T1, 4)); emit(asm.ADDI(T2, T2, -1))
    emit(btype((loop - len(prog)) * 4, 0, T2, 0b001))

def csr(idx, val):
    li(A0, val); emit(asm.rtype(idx, 0, A0, F3_CSR, SENT, OP))
def base(f7, rs1, rs2):
    li(A0, rs1); li(A1, rs2); emit(asm.rtype(f7, A1, A0, F3_BASE, SENT, OP))
def nov(f7, rs1, rs2, rd=SENT):
    li(A0, rs1); li(A1, rs2); emit(asm.rtype(f7, A1, A0, F3_NOV, rd, OP))
def memcpy(src_byte, dst_word, n):              # copy engine: main memory -> bit SPM word dst_word
    csr(CSR_DST, dst_word); li(A0, src_byte); li(A1, n); emit(asm.rtype(0, A1, A0, F3_MEMCPY, SENT, OP))

li(SENT, 0x5A5A5A5A)
# 1) baseline: A -> bank 0, B -> bank 1, bind -> bank 2, read back
copy_words(A_W*4, BASE_WIN + 0*4,   256)        # SPM words 0..255   = bank 0
copy_words(B_W*4, BASE_WIN + 256*4, 256)        # SPM words 256..511 = bank 1
li(A0, BASE_HV); emit(asm.rtype(HDC_CSR_HVSZ, 0, A0, F3_BASE, SENT, OP))
csr(CSR_DST, 2 * 8192)                          # bank 2
base(HDC_BIND, 0, 8192)
copy_words(BASE_WIN + 512*4, R_BIND*4, 256)

# 2) encode 3 features at D = 5024
csr(CSR_HVSIZE_NOV, D); csr(CSR_K_NOV, K); csr(CSR_DST, X_W)
for f, w in enumerate(WEIGHTS):
    if USE_DMA:
        memcpy((FEAT_W + f*2*CH) * 4,      L_BIT, CH)
        memcpy((FEAT_W + f*2*CH + CH) * 4, P_BIT, CH)
        csr(CSR_DST, X_W)
    else:
        copy_words((FEAT_W + f*2*CH) * 4,      NBIT_WIN + L_BIT*4, CH)
        copy_words((FEAT_W + f*2*CH + CH) * 4, NBIT_WIN + P_BIT*4, CH)
    csr(CSR_WEIGHT_NOV, w)
    nov(NOV_BINDMAC_FIRST if f == 0 else NOV_BINDMAC_ACC, L_BIT, P_BIT)
csr(CSR_DST, X_W)
for g, q, fi, w, nl in GEN:                    # table-free encoding: no tables, no copies
    sl, sp = hvgen.seeds(0, g)
    csr(CSR_GEN_SEEDL, sl); csr(CSR_GEN_SEEDP, sp); csr(CSR_GEN_STEP, hvgen.step_for(nl)); csr(CSR_WEIGHT_NOV, w)
    nov(NOV_BINDGEN_ACC, q, fi)
csr(CSR_DST, Q_BIT); nov(NOV_SIGN, X_W, 0)
copy_words(NBIT_WIN + Q_BIT*4, R_Q*4, CH)
copy_words(NWIDE_WIN + 0, R_X*4, 32)                                  # X lanes, chunk 0
copy_words(NWIDE_WIN + (CH-1)*32*4, R_X_LAST*4, 32)                   # X lanes, last chunk

# 3) train / predict / normalize
fill_zero(NWIDE_WIN + PROTO_W*32*4, K*CH*32)                          # zero all prototypes
csr(CSR_WEIGHT_NOV, 1);  csr(CSR_DST, PROTO_W + 1*CH); nov(NOV_PROTO_UPDATE, Q_BIT, 0)
csr(CSR_WEIGHT_NOV, -1); csr(CSR_DST, PROTO_W + 3*CH); nov(NOV_PROTO_UPDATE, Q_BIT, 0)
nov(NOV_DOTSEARCH, Q_BIT, PROTO_W, rd=9)
li(T4, R_SRCH*4); emit(asm.SW(9, 0, T4))
copy_words(NWIDE_WIN + (PROTO_W + 3*CH + 5)*32*4, R_P3*4, 32)          # before normalize
csr(CSR_DST, PROTO_W + 1*CH); nov(NOV_NORMALIZE, PROTO_W + 1*CH, 0)   # in place
copy_words(NWIDE_WIN + (PROTO_W + 1*CH)*32*4, R_NORM*4, 32)
copy_words(NWIDE_WIN + (PROTO_W + 1*CH + 1)*32*4, R_NORM1*4, 32)
copy_words(NWIDE_WIN + (PROTO_W + 2*CH - 1)*32*4, R_NORML*4, 32)
# a single-lane CPU store into the wide SPM must leave the other 31 lanes intact
li(T3, LANE_V); li(T4, NWIDE_WIN + (X_W + LANE_C)*32*4 + LANE_L*4); emit(asm.SW(T3, 0, T4))
copy_words(NWIDE_WIN + (X_W + LANE_C)*32*4, R_LANE*4, 32)
# 4) baseline-HDCU workload (switching activity for hdcu_top power; results not checked
#    here -- every baseline instruction is value-checked by tb_base_values / tb_soc_isa).
#    2048-bit HVs: the largest a 4-bit-counter bundle fits in one 8 Kbit bank.
#    bank0: A   bank1: B, T2 at 10240   bank2: prototypes 16384/18432/20480, T at 22528
#    bank3: widened bundle accumulator W (2048 x 4 bits)
BHV, BT, BT2, BW = 2048, 22528, 10240, 24576
li(A0, BHV); emit(asm.rtype(HDC_CSR_HVSZ, 0, A0, F3_BASE, SENT, OP))
li(A0, 3);   emit(asm.rtype(HDC_CSR_PROT, 0, A0, F3_BASE, SENT, OP))
for k in range(3):                                   # prototypes: rotations of A
    csr(CSR_DST, 16384 + k * BHV); base(HDC_PERM, 0, 7 * k + 1)
fill_zero(BASE_WIN + (BW // 32) * 4, 256)            # clear the widened accumulator
for it in range(16):                                 # encode-like loop: permute, bind, bundle
    csr(CSR_DST, BT2); base(HDC_PERM, 8192, it + 3)
    csr(CSR_DST, BT);  base(HDC_BIND, 0, BT2)
    csr(CSR_DST, BW);  base(HDC_BUNDLE, BW, BT)
csr(CSR_DST, BT);  base(HDC_CLIP, BW, 8)             # majority of 16 (ties: LFSR)
csr(CSR_DST, BT2); base(HDC_SIM, BT, 0)              # Hamming distance to A
csr(CSR_DST, BT2); base(HDC_SEARCH, BT, 16384)       # nearest of the 3 prototypes

li(T3, 0xC0FFEE); li(T4, R_DONE*4); emit(asm.SW(T3, 0, T4))
emit(asm.JAL(0, 0))
assert len(prog) < DATA0, len(prog)

mem[0:len(prog)] = [i & 0xFFFFFFFF for i in prog]
with open("mem.hex", "w") as f:
    for w in mem: f.write(f"{w & 0xFFFFFFFF:08x}\n")
with open("expect.hex", "w") as f:
    for i in range(RES0, R_DONE + 1): f.write(f"{exp.get(i, 0) & 0xFFFFFFFF:08x}\n")
with open("flow.svh", "w") as f:
    f.write(f"localparam int MEMW = {MEM_WORDS};\nlocalparam int RES0 = {RES0};\nlocalparam int NRES = {NRES};\n")
    f.write(f"localparam int R_BIND = {R_BIND}, R_Q = {R_Q}, R_X = {R_X}, R_X_LAST = {R_X_LAST}, "
            f"R_SRCH = {R_SRCH}, R_NORM = {R_NORM}, R_P3 = {R_P3}, R_NORM1 = {R_NORM1}, "
            f"R_NORML = {R_NORML}, R_LANE = {R_LANE}, R_DONE = {R_DONE};\n")
print(f"lane width {LANE_W}; {len(prog)} instructions; results {NRES} words; dots={dots}; best={best}; norm={norm}")
