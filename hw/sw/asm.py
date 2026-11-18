"""Minimal RV32I + custom-0 instruction encoder for hand-building test programs."""

def rtype(funct7, rs2, rs1, funct3, rd, opcode):
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode

def itype(imm, rs1, funct3, rd, opcode):
    imm = imm & 0xFFF
    return (imm << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode

def stype(imm, rs2, rs1, funct3, opcode):
    imm = imm & 0xFFF
    imm_11_5 = (imm >> 5) & 0x7F
    imm_4_0  = imm & 0x1F
    return (imm_11_5 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (imm_4_0 << 7) | opcode

def utype(imm20, rd, opcode):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | opcode

def jtype(imm, rd, opcode):
    imm21 = imm & 0x1FFFFF
    bit20    = (imm21 >> 20) & 0x1
    bits10_1 = (imm21 >> 1)  & 0x3FF
    bit11    = (imm21 >> 11) & 0x1
    bits19_12= (imm21 >> 12) & 0xFF
    return (bit20<<31)|(bits10_1<<21)|(bit11<<20)|(bits19_12<<12)|(rd<<7)|opcode

# standard RV32I opcodes
OP_LUI    = 0b0110111
OP_AUIPC  = 0b0010111
OP_JAL    = 0b1101111
OP_JALR   = 0b1100111
OP_BRANCH = 0b1100011
OP_LOAD   = 0b0000011
OP_STORE  = 0b0100011
OP_IMM    = 0b0010011
OP_REG    = 0b0110011
OP_SYSTEM = 0b1110011
OP_CUSTOM0 = 0b0001011

def ADDI(rd, rs1, imm):  return itype(imm, rs1, 0b000, rd, OP_IMM)
def LUI(rd, imm20):      return utype(imm20, rd, OP_LUI)
def SW(rs2, imm, rs1):   return stype(imm, rs2, rs1, 0b010, OP_STORE)
def LW(rd, imm, rs1):    return itype(imm, rs1, 0b010, rd, OP_LOAD)
def JAL(rd, imm):        return jtype(imm, rd, OP_JAL)
def EBREAK():            return itype(1, 0, 0, 0, OP_SYSTEM)

def LI(rd, val):
    """32-bit load-immediate: LUI + ADDI (handles sign-extension of the low 12 bits)."""
    val = val & 0xFFFFFFFF
    lo = val & 0xFFF
    if lo & 0x800:
        hi = ((val >> 12) + 1) & 0xFFFFF
    else:
        hi = (val >> 12) & 0xFFFFF
    lo_signed = lo - 0x1000 if (lo & 0x800) else lo
    return [LUI(rd, hi), ADDI(rd, rd, lo_signed)]

def CUSTOM0(funct7, rs2, rs1, funct3, rd):
    return rtype(funct7, rs2, rs1, funct3, rd, OP_CUSTOM0)
