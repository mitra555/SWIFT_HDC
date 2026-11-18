import asm

OP_CUSTOM0 = 0b0001011
F3_BASELINE = 0b000
F3_NOVELTY  = 0b001
F3_CSR      = 0b010
F3_QUANTIZE = 0b011

CSR_HVSIZE_NOV = 0
CSR_K_NOV      = 1
CSR_WEIGHT_NOV = 2
CSR_Q_FMIN     = 3
CSR_Q_SPAN     = 4
CSR_Q_NLVL     = 5
CSR_DST_ADDR   = 6

NOV_BINDMAC_FIRST = 16
NOV_SIGN          = 2

HDC_CSR_HVSZ = 9
HDC_BIND     = 4
HDC_BUNDLE   = 3
HDC_CLIP     = 7

def csr_set(csr_idx, rs1):
    return asm.rtype(csr_idx, 0, rs1, F3_CSR, 0, OP_CUSTOM0)

def custom_baseline(funct7, rs1, rs2, rd=0):
    return asm.rtype(funct7, rs2, rs1, F3_BASELINE, rd, OP_CUSTOM0)

def custom_novelty(funct7, rs1, rs2, rd=0):
    return asm.rtype(funct7, rs2, rs1, F3_NOVELTY, rd, OP_CUSTOM0)

def custom_quantize(rs1, rd):
    return asm.rtype(0, 0, rs1, F3_QUANTIZE, rd, OP_CUSTOM0)

prog = []
def emit(x):
    if isinstance(x, list): prog.extend(x)
    else: prog.append(x)

X5,X6,X7,X8,X9 = 5,6,7,8,9
X10,X11,X12,X13,X14,X15,X16,X17 = 10,11,12,13,14,15,16,17

RESULT_BYTES = 8192   # word 2048 -- safely away from program code

# ============ A) QUANTIZER ROUND TRIP ============
# fmin=0.0, span=1.0 (Q16.16), nlvl=21, feat=0.5 -> expect idx=10
emit(asm.LI(X5, 0))
emit(csr_set(CSR_Q_FMIN, X5))
emit(asm.LI(X6, 65536))
emit(csr_set(CSR_Q_SPAN, X6))
emit(asm.LI(X7, 21))
emit(csr_set(CSR_Q_NLVL, X7))
emit(asm.LI(X8, 32768))          # feat = 0.5 in Q16.16
emit(custom_quantize(X8, X9))    # X9 <- idx (via pcpi_rd writeback)

X20 = 20
emit(asm.LI(X20, RESULT_BYTES))  # base address for results (S-type imm is only +-2047, can't
                                  # encode 8192 directly -- compute the base in a register instead)
emit(asm.SW(X9, 0, X20))         # store idx to result[0]

# ============ B) NOVELTY WEIGHTED ENCODE + SIGN ============
# lvl/pos SPM words 0,1 preloaded externally (all-zero -> bind=0 everywhere)
# weight=2, dst(X)=addr 100, clear_first=1 -> X[100] lane0 should become +2
emit(asm.LI(X10, 32))
emit(csr_set(CSR_HVSIZE_NOV, X10))
emit(asm.LI(X11, 2))
emit(csr_set(CSR_WEIGHT_NOV, X11))
emit(asm.LI(X12, 100))
emit(csr_set(CSR_DST_ADDR, X12))
emit(asm.LI(X13, 0))              # lvl addr
emit(asm.LI(X14, 1))              # pos addr
emit(custom_novelty(NOV_BINDMAC_FIRST, X13, X14))

emit(asm.LI(X15, 200))            # sign output dst addr
emit(csr_set(CSR_DST_ADDR, X15))
emit(custom_novelty(NOV_SIGN, X12, 0))   # rs1 = X12 (=100, the X address)

# ============ C) BASELINE SANITY: set HVSIZE via native CSR opcode ============
emit(asm.LI(X16, 32))
emit(custom_baseline(HDC_CSR_HVSZ, X16, 0))   # HDC_CSR_HVSZ takes value via imm=pcpi_rs1

# store a sentinel to confirm the program ran to completion
emit(asm.LI(X17, 0xC0FFEE))
emit(asm.SW(X17, 4, X20))

# infinite loop (halt)
halt_addr = len(prog) * 4
emit(asm.JAL(0, 0))

with open("program.hex", "w") as f:
    for instr in prog:
        f.write(f"{instr:08x}\n")

print(f"program length: {len(prog)} instructions ({len(prog)*4} bytes)")
print(f"halt loop at byte address {halt_addr}")
